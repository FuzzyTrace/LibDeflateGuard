# Roadmap

Ordered work items. Each is a separate pull request. Do them in order: every
item assumes the ones above it have landed.

GitHub issues are disabled on this repository, so this file is the tracking
artifact. Tick items off here as they land.

## Status

Items A–D were agreed after the v1.1.2 regression fixes. Items E–G were agreed
after an external review of the whole fork against upstream `afc3b78`, and
shipped in v1.2.1. Item H was found by review of item G's documentation; it is
done and unreleased, and is a minor version because it changes behaviour.

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
deliberately must copy the entry and write to the copy, which is what
`## Safe decoding` now shows. A key the module has no meaning for is no longer
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
