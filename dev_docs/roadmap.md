# Roadmap

Ordered work items. Each is a separate pull request. Do them in order: every
item assumes the ones above it have landed.

GitHub issues are disabled on this repository, so this file is the tracking
artifact. Tick items off here as they land.

## Status

Items A–D were agreed after the v1.1.2 regression fixes. Items E–G were agreed
after an external review of the whole fork against upstream `afc3b78`, and
shipped in v1.2.1. Item H was found by review of item G's documentation, and
shipped in v1.3.0 — a minor version rather than a patch because it changes
behaviour. Item I was found by review of item H's documentation, and is
documentation and a test rather than a behaviour change. Item J came from an
external review of the limit model, which found that two of the five budgets
could not fire at either shipped preset.

| #   | Item                                            | State      |
| --- | ----------------------------------------------- | ---------- |
| A   | CI: fuzz soak, differential gate, version check | done       |
| B   | Bound policy instance, plus a compressor cap    | done       |
| C   | Resumable decode (prototype only)               | prototyped |
| D   | Huffman decode LUT                              | dropped    |
| E   | Close the channel-codec constructor seam        | done       |
| F   | Benchmark harness against a reference module    | done       |
| G   | Document performance, migration, and scope      | done       |
| H   | Preset mutation carries into a derived policy   | done       |
| I   | `ERRORS` cannot be anchored the same way        | done       |
| J   | `max_symbols` and `max_work_units` are derived  | done       |

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

## E. Close the channel-codec constructor seam

One pull request. A behaviour-preserving hardening fix, plus its regression
test.

### The defect

v1.1.2 bound `_Adler32` privately and made `LibDeflateGuard.ERRORS` an
inspection copy, on the stated grounds that "anything holding the module could
have replaced the checksum check" and that "the stable error codes were not
stable against mutation". The same seam is still open one layer down.

`GenerateWoWAddonChannelCodec` and `GenerateWoWChatChannelCodec` build their
codecs by calling `LibDeflateGuard:CreateCodec(...)` — a read of the public,
writable module table. The channel codecs are cached lazily, so that read
happens at first use, which is after any consumer has had the chance to write
to the table. Demonstrated on v1.2.0:

```text
addon decode after CreateCodec swap:   payload  <-- injected
```

`internals.InternalClearCache()` nils both cached codecs and is public, so the
window re-opens on demand even after first use:

```text
before:                      payload
after ClearCache + swap:     payload <-- injected
```

The `type(codec.Decode) ~= "function"` check in `DecodeForWoWAddonChannel` and
`DecodeForWoWChatChannel` does not help: a substituted codec satisfies it.
That check guards against a broken codec, not a chosen one.

### The fix

Call the private constructor, which both generators already have in scope:

```lua
local function GenerateWoWAddonChannelCodec()
  return CreateCodecInternal("\000", "\001", "", _default_codec_input_bytes)
end
```

and likewise for the chat codec with
`CreateCodecInternal(reserved_chars, "\029\031", "\015\020", _default_codec_input_bytes)`.

`LibDeflateGuard:CreateCodec` adds only a type check over three string
literals, and passes exactly `_default_codec_input_bytes` as the cap, so the
constructed codecs are identical. **This changes no decode output.** State
that expectation in the pull request: `differential_gate` must come back
clean, and if it does not, the change is wrong.

`InternalClearCache` stays public and unchanged. `tests/Test.lua:407` uses it,
and once the generators no longer read the public table, clearing the cache
can only rebuild the same codec. It stops being a seam rather than being
removed.

### What this deliberately does not do

- It does not lock `LibDeflateGuard.internals`. That table is documented as
  test-only and `tests/Test.lua` reads five entries from it. After this fix
  nothing in it can alter a decode result.
- It does not freeze the module table or a policy instance. See item G for
  why, and for the scope statement that replaces the implicit claim.
- It does not touch a codec returned by a caller's own `CreateCodec` call.
  That object is the caller's, and reshaping it is legitimate. The regression
  test pins that boundary explicitly so a later hardening pass does not close
  it by accident.

### Regression test

Add one test to `tests/GuardTest.lua`. It needs a module whose codec cache is
cold, so build fresh instances with `loadfile`, the way the existing
"addon-private module export" test already does, rather than reusing the
suite-level `Guard`:

1. **Cold cache.** Fresh module, replace `CreateCodec` with a wrapper that
   poisons the returned codec's `Decode`, then round trip through
   `EncodeForWoWAddonChannel` / `DecodeForWoWAddonChannel` and the chat pair.
   Both must return the payload unmodified.
2. **Warm cache re-opened.** Fresh module, force the codec to be built, assert
   the baseline, then poison `CreateCodec` and call
   `internals.InternalClearCache()`. The next decode must still return the
   payload unmodified.
3. **Caller-owned codec.** Fresh module, poison `CreateCodec`, then call it
   directly. The poison _must_ take effect, which pins the boundary above as
   intentional.

Fixed vectors, not fuzz. `FuzzTest` drives inputs, not module tampering.

### Release

Patch release, v1.2.1. Four version sites plus a new
`rockspecs/libdeflateguard-1.2.1-1.rockspec`;
`tools/check_version_consistency.sh` is the gate. Changelog entry describes it
as completing the v1.1.2 hardening rather than as a new one, because that is
what it is.

## F. Benchmark harness against a reference module

One pull request. `tests/BenchTest.lua`, modelled on the differential mode of
`tests/FuzzTest.lua`.

### Why

The fork has never published a number against upstream, and item G needs one.
The measurements that exist are scattered across changelog prose and this
file, were taken by hand, and are not reproducible by a reader. Worse, the
v1.0.1 changelog line "World of Warcraft addon-channel decoding about twice as
fast" is guard-v1.0.0 → guard-v1.0.1 — the fork recovering overhead it had
itself added. Against upstream that path is materially _slower_. Nothing in
the changelog is false and nothing in it says so either.

### Shape

Environment, matching the names `FuzzTest` already uses:

- `LIBDEFLATEGUARD_BENCH_REFERENCE` — path to a reference module. Accepts
  either an upstream `LibDeflate.lua` or an older `LibDeflateGuard.lua`.
  Unset means benchmark this module alone and print absolute numbers.
- `LIBDEFLATEGUARD_BENCH_ROUNDS` — alternated A/B rounds, default 21.
- `LIBDEFLATEGUARD_BENCH_SEED` — corpus seed.

Requirements, each of which exists because a previous measurement in this
repository went wrong without it:

- **Reuse `FuzzTest`'s private PRNG, not `math.random`.** A published number
  must come from a corpus that is identical on every interpreter.
- **Report the median of alternated rounds, not a best-of.** Item C already
  established that a best-of on this workload reads 6.9% faster on a branch
  that cannot be faster. Print the spread alongside the median so a reader can
  see when a result is inside the measurement floor, and say so in words when
  it is.
- **Cross-check outputs before timing.** Every shape asserts that both modules
  return byte-identical results. This is free and it is the only part of the
  harness allowed to fail.
- **Adapt the call shape to the reference.** Upstream `DecompressDeflate(str)`
  takes no policy and its codec decoders take no cap. Detect with
  `reference._NAME == "LibDeflateGuard"` and dispatch, rather than passing
  arguments upstream will read as something else — which is the same footgun
  the v1.1.2 fix was about.
- **Print the interpreter and `jit.status()`.** A number without them is not a
  measurement.
- **Never exit non-zero on a timing threshold.**

### Shapes to cover

The six migration-relevant paths, sized like real traffic:

`DecompressDeflate` on compressible text; `DecompressDeflate` on a
stored-block member; `DecodeForWoWAddonChannel`; `DecodeForWoWChatChannel`;
`DecodeForPrint`; and a small-message round trip
(decode-then-decompress at a few hundred bytes), which is the shape the World
of Warcraft use case actually generates and the one where fixed per-call
overhead shows up.

Plus the two saturation shapes item C's table already uses — match bomb and
import blob, each run at `addon` and at `generous` — so the worst-accepted-work
numbers become regenerable rather than folklore. These need no reference
module and should run in the unset-reference mode too.

Report time and allocated bytes per call for each.

### CI

**No workflow.** Timing on a shared GitHub runner is noise, and this
repository has already written down that "the measurement floor is the
result". Document the invocation in `dev_docs/toolchain.md` and add it to
`CONTRIBUTING.md` next to the differential gate, as the thing to run by hand
when a change touches the decode path:

```text
git worktree add ../upstream-baseline afc3b78d12fb3bcfa6b21e5332031ad3d7572e19
LIBDEFLATEGUARD_BENCH_REFERENCE=../upstream-baseline/LibDeflate.lua \
  luajit tests/BenchTest.lua
```

Revisit only if a regression ships that a scheduled run would have caught.

## G. Document performance, migration, and scope

One pull request, documentation only, landing after E and F. Three gaps, all
of the same kind: something true was measured or decided, and the place a
reader would look does not say it.

### G1. A performance section in `README.md`

The README contains no performance claim of any kind today — not a false one,
none at all. Add `## Performance` between `## Compression and codecs` and
`## Security scope`, carrying:

1. **A vs-upstream table**, regenerated on the release machine with item F.
   Indicative figures from the review, `luajit -joff` as the World of Warcraft
   interpreter proxy, upstream at `afc3b78`:

   | Path                                   | Δ vs upstream |
   | -------------------------------------- | ------------- |
   | `DecompressDeflate`, compressible text | +6 to +7%     |
   | `DecompressDeflate`, stored blocks     | −38%          |
   | `DecodeForWoWAddonChannel`             | +52%          |
   | `DecodeForWoWChatChannel`              | +20%          |
   | `DecodeForPrint`                       | about flat    |
   | Small message, decode then decompress  | +8 to +9%     |
   | Every compressor                       | unchanged     |

   Allocation is within a few percent on every path.

2. **Where the cost is.** Per-symbol budget charging on the Huffman path; a
   second linear pass over the input for the canonical-escape check on the
   channel decoders, which is what the +52% buys and is the direct cost of
   rejecting non-canonical escapes.

3. **Where the fork is faster.** The unrolled `ReadBytes` reading through
   `_byte_to_char` instead of `string_sub`. Note that this is unrelated to the
   guard and is a straight win.

4. **The worst-accepted-work table**, promoted out of this file into
   user-facing documentation, because it is what sizes a policy:

   | Preset     | Shape       | Input   | Decoded | Time   | Heap    |
   | ---------- | ----------- | ------- | ------- | ------ | ------- |
   | `addon`    | match bomb  | 0.7 KB  | 512 KB  | 9 ms   | 1.8 MB  |
   | `addon`    | import blob | 41.6 KB | 512 KB  | 14 ms  | 2.3 MB  |
   | `generous` | match bomb  | 11.3 KB | 8 MB    | 126 ms | 14.4 MB |
   | `generous` | import blob | 662 KB  | 8 MB    | 237 ms | 22.6 MB |

5. **One machine.** State the hardware and interpreter, state that the real
   client interpreter is slower, and give the command to regenerate.

Also deal with `docs/benchmark.md`, which the fork inherited and has never
touched. It compares upstream LibDeflate with LibCompress on a 2019 machine
and says nothing about this module, so a reader who finds it first gets
numbers that are not about the code they are running. Do not regenerate it: it
needs LibCompress and a corpus this repository does not carry, and the
comparison it makes is not the one a consumer of this fork is asking. Add a
header saying it is inherited upstream material describing upstream
LibDeflate, and point at the new README section for anything about
LibDeflateGuard.

### G2. A migration section in `README.md`

Add `## Migrating from LibDeflate` directly after `## What is different`.
Every item below already holds; none of them is currently where someone
porting an addon will look, and all of them fail at run time rather than at
load time.

- **`Decompress(Compress(x))` is refused on the module.** The compressor's
  `padding_bitlen` lands in the decompressor's `limits` slot and is not a
  policy, so the call returns `nil, invalid_argument`. Use a policy instance,
  which ignores the extra value, or name the intermediate. This is stated
  today at README:180, inside the bound-instance subsection, which is not
  where a reader arrives from upstream's README. Repeat it here with the
  before/after.
- **The default budget is 64 KiB in and 512 KiB out.** The single most likely
  upgrade break. Point at `LIMIT_PRESETS.generous` and at the measured cost of
  choosing it.
- **Decoders return `nil, code` instead of raising on a wrongly typed
  argument.** Existing `pcall` wrappers around a decode still work and are now
  dead code.
- **`codec:Encode` and the channel encoders return exactly one value.** The
  `string.gsub` substitution count is gone.
- **A `WithPolicy` instance caps compression input at `max_input_bytes`.**
  Binding an instance for safe decoding imposes a 64 KiB compression ceiling
  under the default policy. Defensible and surprising; say it.
- **Channel decoding costs 20–50% more than upstream.** Link to G1.
- **An arity table** for every encoder and decoder, success and failure paths.

### G3. Scope statements

Two edits to `## Security scope`, one to the intro, one to the changelog.

- **What mutation resistance covers.** After item E the module resists a
  consumer that writes to `LibDeflateGuard`: `ERRORS`, `DEFAULT_LIMITS` and
  `LIMIT_PRESETS` are inspection copies, the Adler-32 check and the channel
  codec constructors are privately bound, and a policy instance holds its
  resolved policy in an upvalue. State also what it does not cover: a
  `WithPolicy` instance is an ordinary table whose _methods_ can be replaced
  by anything holding it — only the policy is sealed — and `internals` is
  test-only and writable. And state the frame: in World of Warcraft's shared
  Lua state this is defence in depth against accident and against a library
  that reaches too far, not a boundary against a hostile addon that can
  already reach your tables. Claiming otherwise would be claiming something
  Lua cannot deliver here.
- **The stall is bounded, not removed.** `## Safe decoding` says the budgets
  are per call; the millisecond consequence lives only in this file. Put it in
  the README: the `addon` preset's worst case is 9–14 ms, which is one frame
  at 60 fps, so a rejected or maximal message is a dropped frame rather than a
  freeze; `generous` is 126–237 ms and is not frame-safe; and bounding a
  _stream_ of messages needs transport context and remains the caller's job. A
  message flood is still an exposure.
- **Intro paragraph.** Keep "security-hardened" — it is accurate — and scope
  it in the same sentence to what it means here: bounded single-call decoding
  and strict rejection of non-canonical input, with the resource limits as the
  part that closes a reachable vulnerability. `## Security scope` already says
  this well; the summary at the top of the file should not overshoot it.
- **Changelog.** Add one clause to the v1.0.1 entry making its baseline
  explicit: those figures compare v1.0.1 with v1.0.0, not with upstream. No
  number changes. The alternative — leaving shipped history untouched and
  disambiguating only in the v1.2.1 entry — is worse, because the misreadable
  sentence stays the one a reader finds first.

### Not proposed

**Making `Decompress(Compress(x))` work on the module.** Accepting a number in
the `limits` slot and ignoring it would close the trap, and `padding_bitlen`
is always 0–7 while a policy is always a table, so the disambiguation is
sound. It is still not proposed: it makes one entry point silently discard an
argument that any other malformed value in the same position is refused for,
and that is the class of quiet asymmetry that produced the v1.1.2 bug in the
first place. The decision to route callers to `WithPolicy` was already made
and tested; G2 makes it findable. Reopen only if a real consumer reports
hitting it.

### Outcome

Landed. The G1 table above is left as written, because the point of item F was
to find out whether the review's hand figures survived a harness, and two of
them did not. Recording that is worth more than a tidy file.

Regenerated with `tests/BenchTest.lua` under `luajit -joff` against upstream
`afc3b78`, **ten** independent runs, medians of 21 alternated rounds. An
earlier pass over only three runs is superseded: three runs of a comparison
whose own spread reaches ±27% do not describe what a re-run produces, and one
of its conclusions did not survive being asked ten times.

| Path                                   | G1 said    | Harness measured                |
| -------------------------------------- | ---------- | ------------------------------- |
| `DecompressDeflate`, compressible text | +6 to +7%  | +3.5% to +6.2%, inside spread   |
| `DecompressDeflate`, stored blocks     | −38%       | −40.7% to −43.5%                |
| `DecodeForWoWAddonChannel`             | +52%       | +46.8% to +54.0%                |
| `DecodeForWoWChatChannel`              | +20%       | +11.1% to +17.3%, inside spread |
| `DecodeForPrint`                       | about flat | −2.9% to +3.1%, inside spread   |
| Small message, decode then decompress  | +8 to +9%  | +7.9% to +11.5%, inside spread  |

Findings, in descending order of how wrong the old table was:

- **`DecodeForWoWChatChannel` is not +20%.** It measures 11 to 17% across these
  ten runs and cleared its own spread on none of them; fresh runs clear it only
  rarely. The +20% came from a hand-rolled benchmark on a different corpus. The
  README publishes "about flat", with the range stated in prose as something not
  to quote.
- **Three rows were published as figures the measurement cannot support.**
  Compressible text, `DecodeForWoWChatChannel` and the small round trip all sat
  inside the comparison's spread on all ten runs, and clear it only rarely on
  fresh ones. Only stored blocks and `DecodeForWoWAddonChannel` clear the floor,
  and both do so by a wide margin and repeat to within a few points.
- **Correction to the three-run pass: compressible text does not change sign.**
  That pass justified calling the row "about flat" partly on the grounds that
  it read −7.0% on one run and +6.5% on another. Over ten runs the row is
  positive every single time, from +3.5% to +6.2%, and the negative reading did
  not reproduce once. It was one observation out of eleven and it was noise.
  The row is still reported as "about flat", because it did not clear its own
  spread on any of the ten runs — but on the honest grounds, which are that the
  difference is below the floor, not that the sign is unstable. The README now
  gives it the same prose treatment `DecodeForWoWChatChannel` and the small
  round trip get: positive on every run, at roughly 4 to 6%, do not quote a
  figure. A justification that rests on an artefact is worth correcting even
  when the conclusion it supported happens to survive.
- **The two figures that survived moved a little and in opposite directions.**
  Stored blocks are better than −38%. The addon channel straddles +52% rather
  than sitting under it: ten runs span +46.8% to +54.0%, so "about 50%" is what
  the data supports and the three-run +48.5% to +48.8% was a 0.3-point window
  cut out of 7 points of real variation. Neither changes any conclusion drawn
  from them.
- **The evidence column has to be as wide as re-running is.** Its stated
  purpose is that a reader can check the middle column against it, and a reader
  who regenerates has to land inside it. Every range published in the README is
  now the full span of ten runs rather than the span of the first few.

The G1 worst-accepted-work table carried a `Heap` column taken from item C's
separate hand measurement. The harness cannot regenerate it: it reports bytes
allocated per call with the collector stopped, which counts garbage, and peak
heap cannot be sampled from inside Lua at all. The README therefore publishes
the harness's allocation figures under a column named for what they are, and
keeps item C's peak-heap numbers in prose, attributed as an earlier hand
measurement. Merging the two quantities into one column would have been the
easy option and would have published a number nobody could reproduce.

The saturation input sizes also differ from item C's, because the harness
builds its payloads differently — its match bomb is 2.5 KB in for 512 KB out
where item C's was 0.7 KB. Three of the four times agree closely; the
`generous` match bomb does not, at 143–155 ms across ten runs against item C's
126 ms, which is what a differently built payload for the same output cap
buys. The README publishes the regenerable sizes and times, and the worst-case
column is the highest median observed rounded up, never a mean and never
rounded down.

One further claim did not survive, and was not part of the specification.
`README.md` said peak heap is "roughly 3 to 4 times the decoded size" and that
the `generous` 8 MiB cap therefore implies 26 to 32 MiB. A `generous` decode
saturating its output cap allocates 16.4 to 24.6 MB in total, which bounds peak
heap from above, so the published peak was above what the call allocates. The
multiplier is real at 512 KiB and falls at 8 MiB, because the 32768-byte
sliding window is a fixed cost. Corrected, with the measurement, in
`## Safe decoding`.

## H. Preset mutation carries into a derived policy — done

Found by review of item G's documentation, not by a test. The `README.md`
`## Security scope` bullet has been corrected to state the limit precisely;
this item proposes the code fix, which is deliberately not part of that
documentation change.

### The defect

`LIMIT_PRESETS` is described as an inspection copy, and it is one — but the
copy is made once, at load time, and then hung on the public module table. So
mutating it cannot change what the module's own default path enforces, and
that much of the claim holds. What does not hold is that mutating it "changes
nothing the decoder enforces", because the README also tells a migrating
caller to read an entry back out and pass it to `WithPolicy`:

```lua
G.LIMIT_PRESETS.generous.max_output_bytes = 4096
local guard = G.WithPolicy(G.LIMIT_PRESETS.generous)  -- enforces 4096, not 8 MiB
```

It loosens as readily as it tightens: the same write hands an `addon` instance
a 512 MB output cap, which is the direction that matters for a fork whose
reason to exist is bounding a decode.

**This is the same shape as item E, with the caller performing the read.** In E
the module itself read `LibDeflateGuard:CreateCodec` back off the public table
at first use, after a consumer had had the chance to write to it. Here the
module hands a caller a table and documents the read; the write window is the
same one, and closing it needs the same move — hand out something a write
cannot reach.

The `limits` parameter has the same property for the same reason, and the same
fix applies to whatever is decided for presets.

### Two options

1. **Per-access copies.** A metatable `__index` on `LIMIT_PRESETS` that returns
   a fresh copy of the requested preset. A mutation then goes into a table
   nothing else will ever see.

2. **Deep-copy on the way in.** `WithPolicy` and the `limits` validator already
   read every key they enforce; have them resolve into private storage from
   the values read, which they largely do. The gap is that a mutated preset is
   already the wrong _value_ by the time it is read, so this option does not
   close the defect on its own — it only guarantees that a later mutation of
   the same table cannot reach an instance already built. Worth stating so the
   next reader does not mistake it for a fix.

Only option 1 closes what the reproduction above shows.

### The trade-off, which is why this is not already done

Option 1 breaks table identity:

```lua
G.LIMIT_PRESETS.generous ~= G.LIMIT_PRESETS.generous
```

That is its own surprise, and a legitimate one for a caller who caches a
preset, compares two policies, or uses one as a table key. It also allocates
on every access to a table a hot path may read. Neither cost is large, and
neither is obviously worth paying for a threat this repository's own scope
statement describes as defence in depth against accident rather than a
boundary against a hostile addon.

Deciding it is the work. Do not land the code change without deciding whether
the identity break is acceptable, and if it is, say so in `## Security scope`
and in the migration section rather than leaving a reader to discover it.

### Outcome

Neither of the two options above shipped. The identity break option 1 pays for
is not necessary: what the fix needs is for a mutation not to be _read_, and a
per-access copy is only one way to get that. The other is to stop reading the
exported table at all.

**What landed is a third option: anchor on identity rather than replace it.**
Each exported limit table is registered at load time against the private table
it names, in a private map, and `ResolveDecompressLimits` resolves a registered
table from that private source instead of from its contents:

```lua
local canonical = _canonical_decompress_limits[limits]
if canonical then return canonical end
```

Two lines in the validator and a registration helper beside `LIMIT_PRESETS`.
Every property option 1 would have cost survives: the exported tables are
still ordinary tables with real fields, so `pairs()` and `next()` enumerate
them, `LIMIT_PRESETS.generous == LIMIT_PRESETS.generous`, a preset still works
as a table key, and no allocation happens per access. That mattered more than
it looked: `tests/FuzzTest.lua` iterates `DEFAULT_LIMITS`, `tests/GuardTest.lua`
iterates both `LIMIT_PRESETS` and a preset, and `tests/BenchTest.lua` indexes
presets by name. Option 1 would have broken all of them, and — the reason it
cannot be papered over — silently, because `pairs()` over an empty table with
an `__index` yields nothing and Lua 5.1 and LuaJIT have no `__pairs`. It is
also marginally _faster_ than what it replaced, since a registered table skips
the two five-key walks and the table allocation the validator does otherwise.
The README's benchmark note on the explicit-policy call shape was corrected to
say so; the published figures were measured on the more expensive path and now
bound the current one from above.

**Registration does not close the whole hole, and a second change does.**
Identity anchors a table this module handed out. It cannot anchor one a
consumer put in its place: `LIMIT_PRESETS.generous = {max_output_bytes = 4096}`
is the same one-liner and yields a table indistinguishable from a policy the
caller wrote. So the decompressors and `WithPolicy` now also accept a preset
_name_ — `"addon"` or `"generous"`, the vocabulary `--limits` already used —
resolved against a private table through a value that cannot be mutated at all.
That is the shape `README.md` and `examples/example.lua` now recommend, and it
is what lets `## Security scope` state the strong form rather than a qualified
one. An unrecognised name is `invalid_argument`, not a silent fall back to the
defaults, so the two `bad_policies` lists that already pass `"not a table"`
keep passing unchanged.

**What it costs, recorded because it is a behaviour change.** Writing to a
shipped limit table no longer customises anything. That write was never a
supported customisation channel — the tables have been documented as
inspection copies since v1.1.0 — but it was honoured by a policy built
afterwards, which is precisely the defect. A caller who was using one
deliberately must derive from `WithPolicy("generous"):GetPolicy()`, which is
what `## Safe decoding` now shows. A key the module has no meaning for is no longer
a policy error when it is written onto a shipped table either: the contents are
not read, so nothing written there can be rejected any more than it can be
enforced. A caller's own table is validated exactly as before.

`DEFAULT_CODEC_LIMITS` was considered and deliberately left alone. It carries
scalars, and the codec decoders take a number; identity can anchor a table a
caller hands back but not a number a caller read out of one. The shape that
resolves privately there already exists — omit the cap, or use a `WithPolicy`
instance, whose codec decoders take none — and `## Security scope` says so
rather than implying the table is anchored. `ERRORS` is never handed back to
this module as an argument at all, so it needs no registration.

No decode output changes: the differential gate reports zero divergences
against v1.2.1 over 13246 compared calls.

### What review found afterwards, and what changed for it

An adversarial review of the pull request could not break the resolver. It
broke the documentation around it, in one place that mattered.

`README.md` stated that a write to a shipped limit table cannot reach a policy
derived from it, and then, four hundred lines earlier, told a caller to derive
one with `for key, value in pairs(LIMIT_PRESETS.generous)`. That loop reads the
exported table's **contents**. Identity anchors the table, not the values read
out of it, so the copy starts from the poison and is then enforced exactly as
written — it is a policy the caller wrote, and nothing about it is
distinguishable from one. The claim and the recipe on the same page could not
both be true. `changelog.md` compounded it by pointing anyone broken by the
behaviour change at that same loop as the migration path, and this section
endorsed it by reference.

The recipe was replaced rather than the claim retracted. A poison-free
derivation already shipped: `WithPolicy("generous"):GetPolicy()` returns a copy
of the private numbers a name resolved to, so the write to the copy starts from
values nothing on the module table can reach. `README.md`, `changelog.md` and
the paragraph above now show that shape, and `## Security scope` names the
hand-rolled `pairs()` copy under what mutation resistance does not cover — the
recommended path had to become safe _and_ the unsafe path had to be named, or
the next caller writes the loop from memory. `tests/GuardTest.lua` pins the new
idiom on a real decode outcome rather than on what `GetPolicy()` reports.

Review also sharpened the entry-substitution bullet. It described a replaced
entry as "indistinguishable from one you wrote yourself", which is right for a
fabricated table and understates the cheapest variant:

```lua
LibDeflateGuard.LIMIT_PRESETS.addon = LibDeflateGuard.LIMIT_PRESETS.generous
```

That table is registered, so it is not one the module fails to recognise — it
is one the module positively blesses, resolving canonically to `generous`'s
private numbers and handing a victim 8 MiB where it asked for 512 KiB. The net
effect stays inside the documented class and the answer is unchanged, so this
is a clause rather than a new bullet.

## I. `ERRORS` cannot be anchored the way the limit tables were — done

Found by review of item H's own sentence, the same way H was found by review of
item G's. Documentation and a regression test; no code change beyond a comment.

### The defect

`README.md` `### What mutation resistance covers` opened with `ERRORS`,
`DEFAULT_LIMITS` and `LIMIT_PRESETS` in one list of inspection copies. After H
that sentence carried the weight of a strong claim for the two limit tables —
they are anchored by identity, and a write cannot reach a policy derived from
them. `ERRORS` sat in the same sentence with none of that, and the paragraph
below it dismissed the question in one clause: never handed back as an
argument, so no registration needed. True, and not the whole exposure.

```lua
LibDeflateGuard.ERRORS.OUTPUT_LIMIT_EXCEEDED = "x"
local output, err = LibDeflateGuard:DecompressDeflate(bomb, "addon")
-- returned code:                             output_limit_exceeded
-- err == G.ERRORS.OUTPUT_LIMIT_EXCEEDED  ->  false
```

The code a decode _returns_ is stable, because every failure path reads the
private `_ERRORS`. The table a consumer _compares against_ is a plain writable
field on the public module table, and one line from another addon breaks every
consumer's error handling in the state while the decode underneath reports
correctly. Silently: the branch is simply not taken.

### Why item H's mechanism does not transfer

This is the distinction worth keeping, because it is what decides the answer.
Identity anchoring works on the limit tables because **this module performs the
read**. A caller hands a table back to the policy validator, and the validator
resolves it from private storage instead of from its contents, so the write is
never read. There is a read of ours to put the anchor in front of.

An error code is read by **the consumer**. There is no read of ours in the
path, so there is nothing to anchor. The asymmetry is structural, not an
oversight in H.

### Options, and why only one is defensible

1. **Narrow the claim.** Split `ERRORS` out, state the guarantee that does
   hold, name the one that does not, and document the codes as literals to
   compare against.
2. **A resolver on the module table** — `GetErrorCode("OUTPUT_LIMIT_EXCEEDED")`
   — returning from private storage. **This buys nothing.** A consumer has to
   read the resolver off the same writable module table, so it is one more
   field to overwrite, and against the threat in question it is strictly weaker
   than the string literal it would compete with. It also adds public API for
   it, and the kill criterion in this file is that pulling away from "LibDeflate
   plus budgets" is a reason to stop.
3. **Make `ERRORS` read-only** with an `__index`/`__newindex` proxy. Breaks
   `pairs()` on Lua 5.1 and LuaJIT for the same reason option 1 in item H did,
   and a consumer can replace `LibDeflateGuard.ERRORS` wholesale regardless, so
   it buys a partial defence at the cost H already declined to pay.

Option 1 is what a consumer can act on today: the codes have always been
stable strings, so `err == "output_limit_exceeded"` is a comparison nothing in
the state can reach. The gap was that `README.md` described the codes by
category rather than listing them, so the advice was not followable.

### Outcome

Landed as documentation, one source comment, one line of `examples/example.lua`
and one test. `## Safe decoding` lists all fifteen codes and states the
comparison rule; `### What mutation resistance covers` states the narrow
guarantee and names the writable table under what it does not cover, with the
reasoning above so the resolver is not proposed again; the migration section
points at the rule where a caller writes their first comparison. The example no
longer models a comparison through `ERRORS`.

Worth recording that this is a smaller claim than the one it replaces, not a
larger one. The frame at the end of `## Security scope` already said this is
defence in depth against accident rather than a boundary against a hostile
addon; `ERRORS` is a case where that frame is load-bearing rather than a
disclaimer.

### Regression test

`tests/GuardTest.lua` overwrites every value in `ERRORS`, then replaces the
table outright, and asserts real decode outcomes: the limit, argument, stream,
truncation, trailing, codec and compressor paths all still return their
documented literals. Asserting against literals is the whole point — a code
read back out of the poisoned table would compare equal to anything.

It also pins the other half deliberately, the way the codec-reshaping boundary
in item E is pinned: comparing through the public table is broken by a write,
and a later change that makes that equality hold is a strengthening that should
update `## Security scope` rather than delete the assertion.

Checked by mutation. Reverting one failure path to `LibDeflateGuard.ERRORS.…`
— the v1.1.2 shape — fails this test and **nothing else in the suite**, because
every other assertion in `GuardTest.lua` compares through `ERRORS` and moves
with the poison.

## J. `max_symbols` and `max_work_units` are derived, not chosen — done

Found by external review of the limit model, and confirmed by two independent
investigations before anything was changed. Behaviour change at the defaults;
no API change.

### The finding

**Neither budget could fire at either shipped preset.** Every Huffman decode
consumes at least one input bit, and every literal produces one output byte, so
the input and output caps already bound both counters well below the constants
the presets carried:

| preset     | symbol cap | reachable | work cap   | reachable  |
| ---------- | ---------- | --------- | ---------- | ---------- |
| `addon`    | 750,000    | 524,288   | 1,500,000  | 1,134,592  |
| `generous` | 10,000,000 | 8,388,608 | 25,000,000 | 18,153,472 |

The root cause is not the gap. It is that `750000` and `1500000` appear in
`README.md`, this file and `changelog.md` with **no derivation anywhere** — so
there was nothing to check them against, and nothing to move them by when a
caller raised the budgets they were supposed to back up. A number with no
derivation cannot be reviewed, and this is what that costs.

What the gap did cost a caller was a limit they never named:

```lua
LibDeflateGuard:DecompressDeflate(member, {
  max_input_bytes = 64 * 1024 * 1024,
  max_output_bytes = 64 * 1024 * 1024,
})
-- v1.3.0: work_limit_exceeded, from the addon work cap the policy inherited
```

Both budgets the caller wrote admit the member. It is refused by a third the
caller did not write, cannot see in the policy, and had no way to size.

### The measurement, and why no figure is quoted

A variant with both counters stripped from `DecodeUntilEndOfBlock` was
benchmarked over nine `-joff` runs plus one at 101 rounds. The deflate rows
read **+4.0% and +5.3% median, positive on 9 of 9 runs, and clear of their own
spread on only 2 of 9**, against control rows — byte-identical codec paths —
scattering ±3% between the same two builds.

By the standard `tests/BenchTest.lua` prints under every table it produces, a
delta smaller than its spread is the floor talking. **The cost of these two
counters is inside the floor and must not be quoted as a figure.** It is
recorded here so the next person does not re-run it expecting a number.

### Why deletion was rejected

Three reasons, none of them the measurement:

1. The cost is unmeasurable, so deletion buys nothing that can be stated.
2. `ResolveDecompressLimits` rejects unknown keys. Removing the keys would make
   `{max_symbols = …}` an `invalid_argument`, which breaks the `GetPolicy()`
   round-trip idiom `README.md` recommends — a caller reads a policy out,
   edits one field, hands it back.
3. It would delete a deliberate tripwire. `tests/GuardTest.lua`'s
   exact-boundary vectors and item C's prototype both drive the decoder by
   setting these two, and both would lose the only budget that charges per
   decode rather than per byte.

### The derivation

Both are backstops on the other three budgets, which is what they have always
been in fact. Each term traces to a charge site in the decoder:

```
max_symbols    = 8 * max_input_bytes + 318
max_work_units = max_symbols + max_output_bytes + 336 * max_blocks
```

- `8 * max_input_bytes` — every `Decode` consumes at least one bit, and every
  symbol charge is one `Decode` call. Loose in the safe direction for zlib,
  whose two header bytes and four Adler bytes are not deflate bits.
- `336 * max_blocks` — one work unit per block, plus `ncode + nlen + ndist` per
  dynamic header, which RFC 1951 bounds at 19 + 286 + 30 = 335.
- `max_output_bytes` — one work unit per output byte.

### The slack term, which is not decoration

`ReaderBitlenLeft() < 0` is tested **after** a symbol is decoded, and the
code-length loop in `DecompressDynamicBlock` does not test it at all. So a
truncated member decodes symbols past exhaustion, and `8 * max_input_bytes` is
not an upper bound on what it charges.

This was constructed rather than argued. A four-byte member — `BFINAL`,
`BTYPE 10`, `HLIT` 286, `HDIST` 30, `HCLEN` 4, and four two-bit code lengths —
runs out of input the instant its code-length loop begins, and every all-zero
decode past the end yields code-length symbol 0 and advances the loop by one:

```
truncated dynamic header, 4 bytes = 32 input bits
  symbols charged      : 316
  overshoot over 8*len : 284
```

Scaled up, it reaches the shipped `addon` preset. A 64 KiB member holding one
dynamic block whose literal/length alphabet is two **one-bit** codes — literal
`A` and end-of-block — charges one symbol per input bit for 523,926 literals,
then a 29-bit truncated second header:

```
64 KiB pressed against the addon caps, 65536 bytes, 523926 literals
  symbols charged      : 524501
  8 * max_input_bytes  : 524288
  overshoot            : 213
  output bytes         : 523926 of 524288
  with slack 0   -> symbol_limit_exceeded
  with slack 318 -> invalid_stream   (v1.3.0: invalid_stream)
```

Without slack the backstop fires **at the shipped default** and reports
`symbol_limit_exceeded` for a member whose fault is that it is malformed. A
budget answering for truncation is exactly the defect this item set out not to
introduce.

`318 = 286 + 30 + 2` bounds it: one dynamic code-length alphabet is `nlen + ndist` entries at most, and `DecodeUntilEndOfBlock` can then charge one
literal/length plus one distance symbol before its own test fires. Nothing can
follow, because `ReaderBitlenLeft()` never rises once it has gone negative, so
no second header can straddle exhaustion.

The two halves cannot both be maximal in one member: 316 phantom entries leave
every code length zero, so the alphabet is rejected and the body never runs; a
member that reaches the body must have written its literal/length lengths for
real, leaving at most `ndist` = 30 entries to overshoot. Measured, that path
charges 31 past exhaustion and reports `truncated_input`. 318 is used anyway
because it is a bound that needs no case analysis to stay true.

### What this does to both caps

Deriving to the reachable bound means neither cap can fire under a derived
policy. Symbols cannot, because a decode cannot charge more than the input has
bits plus the slack above. Work cannot, because
`work = symbols + output + block work` and all three are separately guarded
with the tighter check first at every shared charge site.

Checked rather than asserted: 4,800 decodes over compressed, truncated and
trailing members under policies naming neither key produced
`invalid_stream`, `truncated_input`, `trailing_data`, `output_limit_exceeded`,
`input_limit_exceeded`, `block_limit_exceeded` and success — and **zero** of
either backstop. Adding explicit `max_symbols` policies to the same run brought
`symbol_limit_exceeded` back 174 times, so the counters are alive.

This is stated in `README.md` rather than left for someone to rediscover, and
framed there as what it is: a cap sitting exactly on a bound is a tripwire. If
a later change adds a charge site, stops charging one, or breaks the
one-bit-per-decode property, the derived cap starts firing. The keys are still
settable for anyone who wants to drive the decoder with them.

### Outcome

`LIMIT_PRESETS` carries the derived numbers, so a preset and a partial policy
naming the same three budgets enforce the same two backstops:

| preset     | `max_symbols` | `max_work_units` |
| ---------- | ------------- | ---------------- |
| `addon`    | 524,606       | 1,134,910        |
| `generous` | 8,388,926     | 18,153,790       |

Both keys remain explicitly settable and an explicit value is used as given.
An explicit `max_symbols` also feeds the work derivation, so tightening one
tightens the other.

`tests/BenchTest.lua` carries literal copies of the preset numbers, for
reference modules old enough to predate `LIMIT_PRESETS`, and cross-checks them
against the shipped tables. They were updated in the same commit; the
cross-check is what makes that not optional.

### Differential gate

The new values are a tightening, but to the reachable bound, so nothing the
other three budgets admit changes outcome. Verified against `v1.3.0` at the
default iteration count and at `LIBDEFLATEGUARD_FUZZ_ITERATIONS=12`: 13,246 and
152,405 calls compared, **zero divergences**.

The gate cannot see the slack question. It mutates and truncates members the
compressor produced, and the shapes above are hand-built ones it will not
generate — which is why they are pinned in `tests/GuardTest.lua` instead.

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
- **Prettier rewriting line endings on Windows — fixed.** `.gitattributes` now
  carries `*.md text eol=lf` and `*.yml text eol=lf`, so a checkout gives those
  files the LF endings prettier writes and `tools/format_doc.sh` no longer
  touches every Markdown and YAML file in the tree on every run. Before that,
  cleaning up the churn it produced cost a working tree once. If it ever
  returns, the tell is unchanged: `git diff --stat` normalises and `git status`
  does not, so trust the former.
- **`tests/Test.lua` needs luaunit and the reference binaries.** See
  `dev_docs/toolchain.md`. Without freshly built `puff` and `zdeflate` the
  suite reports a large number of failures that have nothing to do with the
  change under test. Compare the failure set against a baseline worktree
  before believing any of them; CI builds those binaries and is the real gate.
- **The command-line tests shell out to `lua`.** A machine with only
  `luajit` on PATH needs `lua_program` in `tests/Test.lua` overridden for a
  local run.
