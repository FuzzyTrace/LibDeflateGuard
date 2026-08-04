# Roadmap after v1.1.2

Ordered work items agreed after the v1.1.2 regression fixes. Each is a
separate pull request. Do them in order: every item assumes the ones above it
have landed.

GitHub issues are disabled on this repository, so this file is the tracking
artifact. Tick items off here as they land.

## Status

| #   | Item                                            | State      |
| --- | ----------------------------------------------- | ---------- |
| A   | CI: fuzz soak, differential gate, version check | done       |
| B   | Bound policy instance, plus a compressor cap    | done       |
| C   | Resumable decode (prototype only)               | prototyped |
| D   | Huffman decode LUT                              | dropped    |

## A. CI: fuzz soak, differential gate, version check

One pull request. These are workflow-only changes and are batched
deliberately, not filed one at a time.

`tests/FuzzTest.lua` already supports everything below through
`LIBDEFLATEGUARD_FUZZ_SEED`, `LIBDEFLATEGUARD_FUZZ_ITERATIONS`, and
`LIBDEFLATEGUARD_FUZZ_REFERENCE`. CI currently runs only the default
single-iteration pass, so the capability exists and is unused.

1. **Nightly soak.** A scheduled workflow running `FuzzTest` with a raised
   iteration count and a rotating seed. The seed must be printed on both
   success and failure, because a soak that cannot be replayed is not a
   regression test. Seeds must be whole numbers below 2147483647; the suite
   rejects anything else rather than running a workload nobody can reproduce.

2. **Differential gate on decode-path pull requests.** Check the latest
   release tag out into a worktree, point `LIBDEFLATEGUARD_FUZZ_REFERENCE` at
   its `LibDeflateGuard.lua`, and run the suite. Every public decode entry
   point must return identical tuples.

   This needs a deliberate answer for intentional divergences before it can
   block a merge. v1.1.2 is itself an example: the codec encoder arity change
   surfaces as `custom codec encode: got (<string len=8>, nil), reference (<string len=8>, 0)`, which is correct and expected. Options are to run it
   advisory-only, or to require an explicit acknowledgement in the pull
   request. Decide this before wiring it as a required check.

   **Decided:** the gate blocks, and a maintainer-applied
   `differential-divergence-ok` label overrides it. The job still finds and
   prints the divergence under the label; it just stops failing. The workflow
   triggers on `labeled` and `unlabeled` so applying the label re-runs it.
   Note that `main` carries no branch protection today, so "blocks" means the
   check goes red, not that GitHub refuses the merge.

3. **Version consistency check.** A release carries four version sites that
   are currently hand-edited:

   - `LibDeflateGuard.lua` line 2, the header banner
   - `LibDeflateGuard.lua` `_VERSION`
   - `LibDeflateGuard.lua` `_COPYRIGHT`
   - `rockspecs/libdeflateguard-<version>-1.rockspec`, both `version` and
     `tag`

   Assert they all agree with each other, and on a tag push that they agree
   with the tag. v1.1.1 was a release whose only source change was those
   strings, which is the failure mode this prevents.

**Do this before item C.** Not because it would have caught the v1.1.2
regressions — it would not, see "What the differential harness does not
cover" below — but because C is the first change since the fork began that
materially restructures the decode path, and it should land on top of a
working soak and a working differential gate.

**Outcome.** The soak paid for itself on its first scheduled night. Seed
`2089977218` at 1000 iterations failed in the print codec: `DecodeForPrint`
accepted a string one symbol longer than any encoding can be and decoded it to
the same value as its prefix, a defect inherited from upstream LibDeflate
`1.0.2-release` that every release of this fork has carried. The printed seed
replayed the failure on another machine, which is the property item 1 was
specified for — the CI-only default single-iteration pass had run that code on
every pull request for the whole life of the repository without reaching it, at
roughly 1.4e-6 per candidate. See `changelog.md`.

## B. Bound policy instance, plus a compressor cap

One pull request covering two related API changes.

### Bound policy instance

```lua
local guard = LibDeflateGuard.WithPolicy(LibDeflateGuard.LIMIT_PRESETS.generous)
guard:DecompressDeflate(msg)
guard:DecodeForPrint(pasted)
```

Today a caller passes a policy to every decompress call and a separate cap to
every codec decode, and the README has to tell them to keep the two in step:
"A caller that raises `max_input_bytes` must raise these to match." A bound
instance derives the codec caps from `max_input_bytes` using the ratio the
module already applies at load time — 4/3 for the print codec, 1:1 for the
channel codecs — and removes the manual coupling.

It also retires the variadic trailing cap as the recommended call shape. That
parameter is what made the v1.1.2 nesting bug possible: adding an optional
last argument to a function whose natural argument is the output of a
multi-value encoder. The v1.1.2 fix removed the trigger by making the
encoders single-valued. It did not remove the shape. Keep the existing
positional parameter for compatibility.

### Compressor input cap

Decode is bounded carefully; compression is not. Measured on this hardware,
`luajit -joff` as a proxy for the World of Warcraft interpreter, level 6
compression runs at roughly 1.9 MB/s, so a one-megabyte user-pasted string is
a multi-second freeze on the frame thread. "Compression is a trusted,
programmer-facing API" is defensible for the wire format but not for the
stall: an addon compressing a user's chat message or export blob is the
normal case, not an edge case.

Add an optional input cap to the compress entry points. Note that compression
currently raises on bad arguments rather than returning an error code, and
that is deliberate and should stay; the cap needs to fit that contract rather
than fight it.

## C. Resumable decode (prototype only)

The `addon` preset exists because "a decode runs on the frame thread and a
rejected message must not be felt". That bounds the damage but also bounds the
feature: a WeakAuras-sized import cannot be decoded at all under the default
policy. Making the decode yieldable is the structural answer.

Sketch, to be validated rather than trusted:

- Run `Inflate` inside a coroutine.
- `DecodeUntilEndOfBlock` already compares against a single local
  `max_work_units` in its hot loop. Replace it with
  `work_deadline = min(slice_end, max_work_units)`. When the deadline trips,
  yield and refresh it if the total budget survives; fail exactly as today if
  it does not. The hot loop keeps one comparison, so the one-shot path pays
  nothing.
- Coroutine locals persist across a yield, so the existing
  write-back-on-success logic in that function does not change.
- **Containment must use `coroutine.resume`, not `pcall`.** Lua 5.1, which is
  what World of Warcraft runs, cannot yield across a `pcall` boundary.
  `coroutine.resume` already returns `false, err` on a raise, which gives the
  same `internal_error` contract the module promises today.

Ship it as a prototype behind the differential harness, not as a planned
feature. Gates before it becomes real:

- `GuardTest` and `FuzzTest` green, and the differential harness clean for
  the one-shot path.
- A benchmark showing no measurable regression on one-shot decoding.
- The existing adversarial vectors in `GuardTest` still charge exactly. They
  assert precise budget boundaries specifically so that an optimisation which
  stops charging for a step fails deterministically.

Kill criterion: if this starts pulling the module away from "LibDeflate plus
budgets", stop. The value of this fork is a small, auditable delta from
upstream, and that is worth more than any single feature.

### What the prototype found

Built and parked as an open draft pull request. Deliberately not merged: the
sketch above holds up, but the case for shipping it does not close on its own.
The kill criterion did not trip.

Against the four gates:

- `GuardTest` and `FuzzTest` green, on every interpreter in the matrix. The
  differential harness is clean for the one-shot path — 316854 compared calls
  against v1.1.2, no divergence.
- The adversarial vectors still charge exactly, with **no expected value
  changed**. Not one increment moved.
- The benchmark is **inconclusive rather than flat**, and should be reported
  that way. Five shapes on `luajit -joff`, medians of 21 alternated rounds,
  three independent runs: everything lands within ±3–6%, with the sign
  flipping between runs — the branch reads 6.9% _faster_ on one match-bomb
  run, which it cannot be. The measurement floor is the result. What holds is
  that no regression exists above that floor, and that the structure agrees:
  the hot loop keeps one comparison per charge, because `work_deadline`
  replaces the hoisted `max_work_units` local rather than adding to it.
- The delta stayed small: +144/−17 in the module, of which only six lines land
  in functions upstream LibDeflate also has.

The containment constraint was real and is satisfied. `coroutine.resume`
carries the resumable path; the one-shot path keeps `pcall`, because it passes
no slice and so can never reach a yield. `lua_test` runs `GuardTest` on
`lua-5.1.5`, so the suspend-and-resume test executes on a stock 5.1 where
yielding across `pcall` is impossible — the constraint is tested, not assumed.

**The finding that decides this item is not in the code.** Resumability alone
does not deliver the motivating use case. The total budget is unchanged by
design, so a WeakAuras-sized import still cannot be decoded under the `addon`
preset. What the prototype buys is that a _raised_ policy no longer has to be
paid in one frame. Adopting it therefore means also telling callers to raise
their policy, and that is a second decision this roadmap has not made. Item C
was justified above as "the structural answer"; it is half of one.

Smaller limits worth carrying forward:

- Yield granularity is bounded below by the coarsest single charge. A stored
  block charges up to 65535 work units at once and cannot be split.
- An abandoned step function holds the whole decode state alive.
- Only raw deflate is surfaced.

One incidental result, unrelated to resumability but found by mutating the
charge sites: removing only the _check_ at the literal site, leaving the
increment, fails no test, because the next site catches the overage one symbol
later. The adversarial vectors pin the charging, not the placement of every
trip site. That is pre-existing and is not a reason to change them.

Revisit when someone reports the import case for real. The question of raising
the default policy is answered below.

### Should the default policy be raised? No

The question the prototype left open, measured rather than argued. Both
presets on `luajit -joff` as the World of Warcraft interpreter proxy, best of
five, each saturating its own output cap:

| Preset     | Shape       | Input    | Decoded | Time       | Heap    |
| ---------- | ----------- | -------- | ------- | ---------- | ------- |
| `addon`    | match bomb  | 0.7 KB   | 512 KB  | **9 ms**   | 1.8 MB  |
| `addon`    | import blob | 41.6 KB  | 512 KB  | **14 ms**  | 2.3 MB  |
| `generous` | match bomb  | 11.3 KB  | 8 MB    | **126 ms** | 14.4 MB |
| `generous` | import blob | 662.4 KB | 8 MB    | **237 ms** | 22.6 MB |

A frame at 60 fps is 16.7 ms. The `addon` preset's worst case is 14 ms — one
frame, at the edge but inside it, which is what it was sized for and agrees
with the "about 10 ms" measured for item D.

Raising the default to `generous` makes the worst case 237 ms, about fourteen
dropped frames, plus a 22.6 MB spike on a shared Lua heap where addon memory
is a real budget and the resulting collection is its own hitch. The
asymmetry is the argument: it helps the few addons doing large imports and
exposes every addon handling untrusted messages, which is the population this
fork exists to protect. Note that the 126 ms adversarial case is reached from
11 KB of attacker-supplied input.

The opt-in is the right shape, and item B already built it. An addon that
needs a large import writes
`LibDeflateGuard.WithPolicy(LibDeflateGuard.LIMIT_PRESETS.generous)` and
accepts the stall knowingly.

**This is also what item C is for.** An import is a user-initiated paste, not
a frame-thread message, so a few hundred milliseconds behind a progress
indicator is acceptable there in a way it never is for an incoming chat
packet. The pairing is a raised policy _plus_ a resumable decode: the policy
makes the import legal, the slicing makes paying for it not freeze the client.
Neither delivers the import case alone.

Two limits on the above. The numbers are one machine with `luajit -joff`, and
the real client interpreter is slower, so 237 ms is a floor rather than a
ceiling. And only the two existing presets were measured: whether some
intermediate policy — 256 KB in, 2 MB out, which would land near 60 ms — is a
better default than either is untested. That is the only version of "raise the
default" worth reopening, and it needs a real report of an addon being blocked
before it justifies the churn.

## D. Huffman decode LUT — dropped

Replacing the bit-by-bit canonical decode in `CreateReader`'s `Decode` with a
9-bit lookup table, the way zlib does, was considered and rejected for now.

Measured worst cases at the default policy, `luajit -joff`:

| Shape                            | Result                 |
| -------------------------------- | ---------------------- |
| Match bomb, hits the output cap  | 7.85 ms                |
| Header flood, hits the block cap | 7.10 ms                |
| Largest well-formed member       | about 10 ms            |
| Peak heap during decode          | 3.05x the decoded size |

The budgets calibrate cleanly across adversarial shapes, because the
bit-walk cost is bounded by input bits and the input cap binds first. A LUT
would trade that clean story for a 512-entry allocation per dynamic block
which would itself need work-unit charging, and at `max_blocks = 256` that is
131072 entries. The win is smallest for the short messages that dominate the
World of Warcraft use case. Revisit only if someone reports a real stall.

## What the differential harness does not cover

Worth recording, because it was assumed otherwise during the v1.1.2 work.

The differential mode would not have caught either v1.1.2 regression. Every
decode call site in `tests/FuzzTest.lua` — lines 620, 675, 691, 703 and 718 —
passes either a truncated local or `encoded[1]`. The nested
`Decode(Encode(x))` form appears nowhere in the suite, in `GuardTest`, or in
`examples/example.lua`. The encoder arity did not change when the input cap
was added either, so there was no divergence for the harness to find; the
fault was a latent interaction between two individually consistent sides.

The lesson is to assert the call shape a user writes, not the shape the
harness finds convenient. Storing a result in a local truncates multiple
returns and hides exactly this class of fault.

## Repository traps

Collected because each one has cost time at least once.

- **Formatting is a required check.** `check_format` runs LuaFormatter over
  `*.lua` and prettier over `*.md` and `*.yml`, each followed by
  `git diff --exit-code`. Run `tools/format_lua.sh` and `tools/format_doc.sh`
  before pushing.
- **Prettier rewrites line endings on Windows.** A run touches every Markdown
  and YAML file in the tree while changing the content of almost none. Check
  `git diff --stat`, which normalises, rather than `git status`, and stage the
  intended files explicitly instead of `git add -A`.
- **`tests/Test.lua` needs luaunit and the reference binaries.** See
  `dev_docs/toolchain.md`. Without freshly built `puff` and `zdeflate` the
  suite reports a large number of failures that have nothing to do with the
  change under test. Compare the failure set against a baseline worktree
  before believing any of them; CI builds those binaries and is the real gate.
- **The command-line tests shell out to `lua`.** A machine with only
  `luajit` on PATH needs `lua_program` in `tests/Test.lua` overridden for a
  local run.
