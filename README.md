# LibDeflateGuard

LibDeflateGuard is an independently maintained, security-hardened fork of
[SafeteeWoW/LibDeflate](https://github.com/SafeteeWoW/LibDeflate). It keeps the
proven LibDeflate compressor, RFC 1951 wire format, and established World of
Warcraft codecs while adding strict resource limits and stable, non-throwing
decode failures.

"Security-hardened" is meant narrowly and is worth reading as written: it means
bounded single-call decoding and strict rejection of non-canonical input, with
the resource limits as the part that closes a reachable vulnerability. It is
not a claim of protection against code that already shares your Lua state.
`## Security scope` says what is and is not covered.

The first maintained release is based on upstream LibDeflate
`1.0.2-release`, commit `afc3b78d12fb3bcfa6b21e5332031ad3d7572e19`.
The original history, zlib license, copyright, and source attribution are
preserved.

## What is different

- The module is named and loaded as `LibDeflateGuard`.
- It never looks up or registers `LibDeflate` through LibStub.
- It never creates `_G.LibDeflate` or `_G.LibDeflateGuard`.
- Every load creates the private module table returned by
  `require("LibDeflateGuard")` or stores it in the loading addon's private
  namespace.
- Deflate and zlib decoders enforce compressed-input, output, block, Huffman
  symbol, and deterministic work-unit limits.
- Codec decoders enforce their own input cap, because they run before any
  decompression budget applies.
- `LibDeflateGuard.WithPolicy(policy)` binds one policy to an object that
  carries the whole budget, so a decompress policy and a codec cap cannot
  drift apart.
- The compressors accept an optional input cap, because compressing a
  user-pasted string on a frame thread is the normal case, not an edge case.
- Decoder and channel-decode failures return stable symbolic error codes,
  including for malformed or wrongly typed untrusted input.
- Raw Deflate and zlib members reject complete trailing bytes.
- World of Warcraft addon-channel decoding rejects dangling, unknown, and
  otherwise non-canonical escape sequences.
- Custom-codec escape input and print-codec terminal padding must use the
  canonical form produced by their encoders.
- A supplied zlib dictionary is usable only when the member declares FDICT and
  its DICTID matches.

LibDeflateGuard does not replace an installed stock LibDeflate. An application
can load both modules without either one mutating the other.

## Migrating from LibDeflate

Every behaviour in this section is stated somewhere else in this file too,
except the arity table at the end, which is collected here and nowhere else.
The rest is repeated because all of it fails at run time rather than at load
time, and because a reader arriving from upstream's README will not find it
where it lives.

### `Decompress(Compress(x))` is refused on the module

A compressor returns two values, the second being `padding_bitlen`. On the
module the second value lands in the decompressor's `limits` slot, which is not
a policy:

```lua
-- Refused: returns nil, "invalid_argument"
LibDeflateGuard:DecompressDeflate(LibDeflateGuard:CompressDeflate(message))
```

Name the intermediate value, or use a policy instance, whose bound decoders
take no policy argument and ignore the extra value:

```lua
local compressed = LibDeflateGuard:CompressDeflate(message)
local round_tripped = LibDeflateGuard:DecompressDeflate(compressed)

-- or
local guard = LibDeflateGuard.WithPolicy()
guard:DecompressDeflate(guard:CompressDeflate(message))
```

This is deliberate. Accepting a number in the `limits` slot and discarding it
would make one entry point silently ignore an argument every other malformed
value in that position is refused for.

### The default budget is 64 KiB in and 512 KiB out

This is the most likely upgrade break: upstream has no budget, so a member that
decompressed before can now return `nil, "output_limit_exceeded"`. Raise it
deliberately rather than by accident:

```lua
local guard = LibDeflateGuard.WithPolicy(LibDeflateGuard.LIMIT_PRESETS.generous)
```

Know what that costs. The default `addon` preset's worst accepted call is 10 to
15 ms, which is inside one frame at 60 fps with little to spare. Under
`generous` the same shapes are 155 to 238 ms and about 25 MB of allocation. See
`## Performance`.

### Decoders answer instead of raising

Upstream raises on a wrongly typed argument to a decoder. Every decoder here
returns `nil` and a stable code from `LibDeflateGuard.ERRORS` instead. An
existing `pcall` wrapper around a decode still works and is now dead code:
there is nothing left for it to catch.

Compressors, encoders and `CreateDictionary` are unchanged and still raise on a
programmer error.

### Encoders return exactly one value

`codec:Encode`, `EncodeForWoWAddonChannel` and `EncodeForWoWChatChannel`
forwarded `string.gsub`'s substitution count as a second return value before
v1.1.2. They no longer do. A caller written as `local s, n = Encode(x)` now
gets `nil` for `n`.

### A `WithPolicy` instance caps compression input

An instance derives a compression input cap from its own `max_input_bytes`, so
binding an instance for safe _decoding_ also imposes a compression ceiling —
64 KiB under the default policy. `guard:CompressDeflate(big)` returns
`nil, "input_limit_exceeded"` where `LibDeflateGuard:CompressDeflate(big)`
would have compressed it. Defensible, and surprising, so it is said here.

The derived cap is a default, not a ceiling on the ceiling. A
`configs.max_input_bytes` passed at the call site wins over it, in either
direction:

```lua
local guard = LibDeflateGuard.WithPolicy() -- compression capped at 64 KiB
guard:CompressDeflate(big, {max_input_bytes = 1024 * 1024}) -- 1 MiB applies
```

An explicit argument at the call site beating a value the instance derived for
you is the ordinary reading of both, so it is deliberate. It does mean an
instance bounds compression only for callers who do not pass the key.

### Channel decoding costs more

`DecodeForWoWAddonChannel` is about 50% slower than upstream, which is the
direct cost of rejecting non-canonical escapes. `DecodeForWoWChatChannel`
measures 11 to 17% slower but rarely outside the measurement's own spread, so it
should be read as somewhat slower rather than as a number. `DecodeForPrint` and
the deflate paths are about flat, and stored blocks are about 40% faster. See
`## Performance` for the measurements and for what they are measured on.

### Arity

Success and failure paths for every public entry point. The channel decoders
return a trailing `nil` on success where `DecodeForPrint` and `codec:Decode`
return one value, which matters if you forward a decode result straight into
another call's argument list.

| Call                                               | Success        | Failure                |
| -------------------------------------------------- | -------------- | ---------------------- |
| `CompressDeflate`, `CompressZlib`, `…WithDict`     | `str, padding` | `nil, code`, or raises |
| `DecompressDeflate`, `DecompressZlib`, `…WithDict` | `str, 0`       | `nil, code`            |
| `EncodeForPrint`                                   | `str`          | raises                 |
| `EncodeForWoWAddonChannel`                         | `str`          | raises                 |
| `EncodeForWoWChatChannel`                          | `str`          | raises                 |
| `codec:Encode`                                     | `str`          | raises                 |
| `DecodeForPrint`                                   | `str`          | `nil, code`            |
| `DecodeForWoWAddonChannel`                         | `str, nil`     | `nil, code`            |
| `DecodeForWoWChatChannel`                          | `str, nil`     | `nil, code`            |
| `codec:Decode`                                     | `str`          | `nil, code`            |
| `WithPolicy`                                       | `instance`     | `nil, code`            |
| `CreateCodec`                                      | `codec`        | `nil, text`, or raises |
| `CreateDictionary`                                 | `dictionary`   | raises                 |
| `Adler32`                                          | `number`       | raises                 |
| `GetPolicy`, `GetCodecLimits`                      | `table`        | none                   |

A compressor raises on a malformed argument, including a malformed
`max_input_bytes`, because that is a programmer error. An input that merely
exceeds a well-formed cap is a runtime outcome and returns
`nil, "input_limit_exceeded"`. The same shapes hold on a `WithPolicy` instance.

`CreateCodec` is the one asymmetric row and is worth reading twice. A
wrongly typed argument raises, like every other programmer-facing entry point.
A well-typed argument the constructor cannot satisfy — too few escape
characters for the reserved set — returns `nil` and an English sentence,
`"Out of escape characters."`, which is inherited from upstream and is _not_ a
stable code from `ERRORS`. Do not match on it. `GetPolicy` and
`GetCodecLimits` exist only on a `WithPolicy` instance and take no argument, so
they have no failure path at all.

## Loading the private module

Standalone Lua:

```lua
local LibDeflateGuard = require("LibDeflateGuard")
```

For a World of Warcraft addon, embed `LibDeflateGuard.lua` in the consuming
addon and load it before the consumer file. WoW passes the same private addon
table to both files:

```lua
local addon_name, private = ...
local LibDeflateGuard = private.LibDeflateGuard
```

`LibDeflateGuard.xml` is supplied for embedded XML loading. Installing
LibDeflateGuard as a separate shared addon is not the supported integration
model because this fork deliberately exposes no global or LibStub identity.
Release archives are embed-source bundles for copying into the consuming
project. They intentionally contain no standalone addon TOC.

## Safe decoding

```lua
local output, decode_error = LibDeflateGuard:DecompressDeflate(compressed)
if not output then
  print("Rejected:", decode_error)
end
```

The same contract applies to:

- `DecompressDeflate(str, limits)`
- `DecompressDeflateWithDict(str, dictionary, limits)`
- `DecompressZlib(str, limits)`
- `DecompressZlibWithDict(str, dictionary, limits)`

Success returns the decoded string and numeric status `0`, preserving the
upstream success tuple. Failure returns `nil` and one of the strings in
`LibDeflateGuard.ERRORS`. The stable error codes include
invalid arguments, input/output/work/block/symbol limit exhaustion, trailing
data, truncation, invalid streams, checksum or dictionary failures, invalid
codec input, and contained internal exceptions.

All limits are positive integer byte or work counts. Omitted keys use the
defaults. Two presets ship with the library:

```lua
LibDeflateGuard.LIMIT_PRESETS = {
  addon = {                      -- the default
    max_input_bytes = 64 * 1024,
    max_output_bytes = 512 * 1024,
    max_blocks = 256,
    max_symbols = 750000,
    max_work_units = 1500000,
  },
  generous = {
    max_input_bytes = 1024 * 1024,
    max_output_bytes = 8 * 1024 * 1024,
    max_blocks = 4096,
    max_symbols = 10000000,
    max_work_units = 25000000,
  },
}
```

`addon` is the default because a decode on a game client runs on the frame
thread, where a rejected message must not be felt. `generous` is for a server
or desktop tool that can afford a longer stall:

```lua
local output, decode_error =
  LibDeflateGuard:DecompressDeflate(compressed,
                                    LibDeflateGuard.LIMIT_PRESETS.generous)
```

A caller can also supply any table of its own; omitted keys fall back to the
`addon` values. `DEFAULT_LIMITS` and `LIMIT_PRESETS` are inspection copies.
Mutating them does not alter the private defaults enforced by the decoder.

These are per-call budgets. Bounding a _stream_ of messages needs the caller's
transport context and remains the caller's job.

### A bound policy instance

Passing a policy to every decompress call, and a matching cap to every codec
decode, is the shape that has to be kept in step by hand. `WithPolicy` binds
one policy to an object that carries the whole budget:

```lua
local guard = LibDeflateGuard.WithPolicy(LibDeflateGuard.LIMIT_PRESETS.generous)

local payload = guard:DecodeForPrint(pasted)
local message = guard:DecompressDeflate(payload)
```

The instance accepts exactly the policy shapes the `limits` parameter accepts:
a `LIMIT_PRESETS` entry, a partial table whose omitted keys fall back to the
`addon` defaults, or nothing at all. An invalid policy is reported rather than
raised, so the same code that reads a policy out of saved variables can check
it:

```lua
local guard, policy_error = LibDeflateGuard.WithPolicy(user_policy)
if not guard then
  print("Rejected policy:", policy_error) -- invalid_argument
end
```

It exposes the budgeted surface:

- `DecompressDeflate(str)`, `DecompressDeflateWithDict(str, dictionary)`,
  `DecompressZlib(str)`, `DecompressZlibWithDict(str, dictionary)`
- `DecodeForPrint(str)`, `DecodeForWoWAddonChannel(str)`,
  `DecodeForWoWChatChannel(str)`
- `CompressDeflate(str, configs)`, `CompressDeflateWithDict(str, dictionary, configs)`, `CompressZlib(str, configs)`,
  `CompressZlibWithDict(str, dictionary, configs)`
- `CreateCodec(reserved_chars, escape_chars, map_chars)`, whose codec decodes
  under the instance's derived cap

and, unbudgeted and unchanged, `EncodeForPrint`, `EncodeForWoWAddonChannel`,
`EncodeForWoWChatChannel`, `CreateDictionary` and `Adler32`, so a whole
pipeline can be written against the instance. An encoder's input is the
caller's own bytes and is already bounded by the compression cap in a
compress-then-encode pipeline, so giving the encoders a failure return would
add an error path to functions that have none.

`GetPolicy()` and `GetCodecLimits()` return fresh copies of the enforced
numbers. Like `LIMIT_PRESETS` and `DEFAULT_LIMITS` they are for inspection:
mutating what they return, or mutating the table originally passed to
`WithPolicy`, cannot change what the instance enforces.

The bound decoders take no policy or cap argument, and ignore anything passed
after the ones documented above. That is deliberate. A compressor answers with
two values, so the nested form works on the instance:

```lua
guard:DecompressDeflate(guard:CompressDeflate(message))
```

On the module itself the same nesting puts the compressor's `padding_bitlen`
into the decompressor's `limits` slot, which is not a policy and is refused
with `invalid_argument`. Use the instance, or name the intermediate value.

The instance retires the positional cap parameters as the recommended shape.
It does not remove them: `DecompressDeflate(str, limits)`,
`DecodeForPrint(str, max_input_bytes)` and the rest are unchanged.

`max_symbols` counts every Huffman decode attempt, including dynamic-header,
literal/length, distance, and end-of-block symbols. `max_work_units` counts
blocks, Huffman symbols, output bytes, and dynamic-table entries. It is a
deterministic operation budget, not a wall-clock deadline.

The complete input string counts toward `max_input_bytes`. A valid compressed
member followed by one or more complete bytes fails with `trailing_data`.
Unused padding bits in the final raw Deflate byte remain valid RFC 1951
padding.

`max_output_bytes` bounds the decoded string, not the Lua heap. A decode holds
the flushed output chunks, the final concatenated string, and the 32768-byte
sliding window live at the same time, so the transient cost is a multiple of
the decoded size — and the multiple falls as the decode grows, because the
window is a fixed 32768 bytes however large the output is. Measured with
`tests/BenchTest.lua`, one call allocates roughly 4 to 5 times the decoded size
at the default 512 KiB cap, about 2.0 to 2.5 MB, and roughly 2 to 3 times at
the `generous` 8 MiB cap, about 16 to 25 MB. Those are allocation totals and
include garbage the call discards, so they bound the peak rather than being it:
an earlier hand measurement of peak heap on shapes built to the same
description, though not from the same bytes, read 1.8 to 2.3 MB and 14.4 to
22.6 MB. Size a policy against the upper figure. See `## Performance`.

## Compression and codecs

The original compressor and dictionary APIs remain available:

- `CompressDeflate` and `CompressDeflateWithDict`
- `CompressZlib` and `CompressZlibWithDict`
- `CreateDictionary` and `Adler32`

Compression output remains wire-compatible with LibDeflate and RFC 1951.
Compression and dictionary construction are trusted, programmer-facing APIs
and retain their original argument-error behavior.

Compression is nevertheless slow in pure Lua, and roughly linear in the length
of its input: measured on `luajit -joff` as a proxy for the World of Warcraft
interpreter, level 6 runs at about 1.9 MB/s, so a one-megabyte user-pasted
string is a multi-second freeze on the frame thread. The four compress entry
points therefore accept an optional cap in their existing configuration table:

```lua
local compressed, compress_error =
  LibDeflateGuard:CompressDeflate(pasted, {level = 6, max_input_bytes = 65536})
if not compressed then
  print("Rejected:", compress_error) -- input_limit_exceeded
end
```

Omitting the key means no cap, which is the behavior of every earlier release.
A malformed cap — the wrong type, zero, negative, fractional, infinite —
raises, exactly as every other malformed compression argument does. An input
that merely exceeds a well-formed cap is a runtime outcome, not a programmer
error, so it returns `nil` plus
`LibDeflateGuard.ERRORS.INPUT_LIMIT_EXCEEDED`, the same shape the decode path
uses. Both paths return exactly two values, so no caller's argument list
changes shape.

A policy instance derives this cap from its own `max_input_bytes`, so
`guard:CompressDeflate(str)` is capped without a configuration table. Note
what that does and does not promise: it bounds the bytes going in, which is
what the stall is proportional to. It does not guarantee the compressed result
clears the same policy's decompress input cap, because an incompressible
payload at exactly the cap deflates to a few bytes more than it started with.

The original codec names are retained:

- `EncodeForWoWAddonChannel` and `DecodeForWoWAddonChannel`
- `EncodeForWoWChatChannel` and `DecodeForWoWChatChannel`
- `EncodeForPrint` and `DecodeForPrint`
- `CreateCodec`

The print codec stays compatible with existing LibDeflate consumers, including
canonical RCLootCouncil export data. Previously tolerated nonzero unused bits
in a final print-codec group are rejected as `invalid_print`, and so is a
string whose length no encoding can have: `EncodeForPrint` turns n bytes into
`ceil(4n/3)` symbols, which is never congruent to 1 modulo 4, so a stripped
length of 5, 9, 13 and so on is refused rather than decoded as its own
prefix. Decode methods
return `nil, error_code` on invalid untrusted input. Encode methods remain
programmer-facing and retain the original argument-error behavior.

Every encode method returns exactly one value, so an encode result can be
passed straight to its decoder:

```lua
local round_tripped =
  LibDeflateGuard:DecodeForWoWAddonChannel(
    LibDeflateGuard:EncodeForWoWAddonChannel(str))
```

Before 1.1.2, `codec:Encode` and the two channel encoders forwarded
`string.gsub`'s substitution count as a second value, which the decoders read
as the input cap described below. See `changelog.md`.

Every decode method takes an optional input cap as its last argument:

```lua
local compressed, decode_error = LibDeflateGuard:DecodeForPrint(pasted, 65536)
```

A codec decode runs before any decompression budget applies, so it carries its
own cap rather than inheriting one. The decode is linear, so an oversized input
is a stall rather than an amplification, but it is still unbounded work on
attacker-supplied bytes. The defaults are derived from the decompress input
cap rather than guessed, and are exposed for inspection:

```lua
LibDeflateGuard.DEFAULT_CODEC_LIMITS = {
  print_max_input_bytes = 87381,    -- 4/3 * max_input_bytes
  channel_max_input_bytes = 65536,  -- max_input_bytes
}
```

The print codec emits 0.75 bytes per input byte, so anything above 4/3 of
`max_input_bytes` cannot produce a member that a default-limits decompress
would accept. The channel codecs never grow their input, so their cap is
`max_input_bytes` itself.

A caller that raises `max_input_bytes` should use `WithPolicy` rather than
raising each cap by hand: an instance applies exactly these ratios to its own
policy, so the codec caps and the decompress budget cannot drift apart.

## Performance

Every figure in this section comes from `tests/BenchTest.lua`, and can be
regenerated by anyone. Nothing here is hand-timed.

### Against upstream LibDeflate

Upstream LibDeflate `1.0.2-release` at `afc3b78`, `luajit -joff` as the World
of Warcraft interpreter proxy, median of 21 alternated rounds, ten independent
runs. The right-hand column is the range of what those ten runs actually
printed, so that the claim in the middle column can be checked against its own
evidence. It is a record of what those ten runs produced rather than a
tolerance band: a re-run usually lands inside it, and the widest-spread rows —
stored blocks most of all — can fall outside it without anything being wrong.

| Path                                   | vs upstream          | Measured, ten runs              |
| -------------------------------------- | -------------------- | ------------------------------- |
| `DecompressDeflate`, compressible text | about flat           | +3.5% to +6.2%, spread ±3–11%   |
| `DecompressDeflate`, stored blocks     | about 40% **faster** | −40.7% to −43.5%, spread ±8–17% |
| `DecodeForWoWAddonChannel`             | about 50% **slower** | +46.8% to +54.0%, spread ±6–27% |
| `DecodeForWoWChatChannel`              | about flat           | +11.1% to +17.3%, spread ±4–16% |
| `DecodeForPrint`                       | about flat           | −2.9% to +3.1%, spread ±9–19%   |
| Small message, decode then decompress  | about flat           | +7.9% to +11.5%, spread ±5–14%  |

Four of the six rows say "about flat" because the difference the harness found
is smaller than the harness's own spread for that comparison, and a number
smaller than its floor is not a result. The harness names those rows in words
under its table rather than leaving a reader to compare two columns.

Three of them are worth reading more carefully than "flat" suggests.
`DecompressDeflate` on compressible text, `DecodeForWoWChatChannel` and the
small-message round trip all read positive on every one of the ten runs — at
roughly 4 to 6%, 11 to 17% and 8 to 11% respectively — and none of the three
cleared its own spread on any of those ten runs. A fresh run does clear it
occasionally, but rarely enough that all three are best described as somewhat
slower, not measurably so. Do not quote a figure for any of them. Only stored
blocks and `DecodeForWoWAddonChannel` clear the floor, and both do so by a wide
margin.

Allocated bytes per call are within 3% of upstream on every path, and identical
to the byte on the three codec decoders. Unlike the timings, the allocation
figures reproduce exactly: all ten runs printed the same six numbers.

**Which call shape the deflate rows measured.** The harness passes an explicit
`LIMIT_PRESETS.addon` table on every one of this module's decompress calls,
which is a shape upstream has no analogue for: resolving a supplied policy
means two short walks over a five-key table and one table allocation per call,
none of which upstream does. The table above is therefore the cost of the
explicit-policy call shape, and it is worth saying so rather than leaving a
reader to assume the plainest call was the one timed.

Measured, that argument turns out to cost almost nothing. Paired inside one
process, 41 alternated rounds, `DecompressDeflate(str, policy)` against
`DecompressDeflate(str)` — the same enforced numbers either way, since `addon`
_is_ the module default — the median difference on the 8 KB member is a point or
two at most and not separable from zero: two runs of this protocol gave +0.00%
and +1.80%. A 256 B member reads +0.44%, about 0.25 µs of fixed cost per call.
Running the whole table with the policy argument dropped moves no row outside
its own ten-run range. So the deflate rows are not inflated by the argument in
any degree the harness can see; the caveat is about what was measured, not about
a correction to apply. A `WithPolicy` instance resolves its policy once at bind
time and does not pay even that.

### Where the cost is

- **Per-symbol budget charging on the Huffman path.** Every literal, length,
  distance and end-of-block symbol increments a work counter and tests it. That
  is the mechanism the whole budget is built on, and it is why the deflate
  paths are at best flat rather than free.
- **A second linear pass over the input on every codec decode.** Before the
  substitution passes upstream runs, this fork scans for a reserved character
  and then walks every escape byte in the string checking that its suffix is
  one the encoder could have produced. That is the direct cost of rejecting
  dangling, unknown and otherwise non-canonical escapes, and it is what the
  addon channel's 50% buys.

The two channel decoders differ so much because that extra pass is a fixed cost
per byte while the codecs do very different amounts of other work. On the same
2369-byte member, `DecodeForWoWAddonChannel` takes about 48 µs and
`DecodeForWoWChatChannel` about 920 µs, because the chat codec substitutes
across a far larger reserved set. The same added pass is therefore about a
third of one call and a small fraction of the other.

### Where the fork is faster

`ReadBytes`, which carries the stored-block path, is unrolled eight ways and
reads through the `_byte_to_char` table instead of calling `string.sub` once
per byte. That is worth about 40% on a stored member. It has nothing to do with
the guard and is a straight win.

### The compressors

The harness does not measure them, so this section publishes no compressor
number of its own and no vs-upstream compressor delta. The one compression
figure this file quotes — about 1.9 MB/s at level 6, under
`## Compression and codecs` — is an earlier hand measurement, kept where it is
used rather than repeated here, so that "nothing here is hand-timed" stays true
of this section.

The compression code itself is unchanged from upstream. What the input cap
added is a length check in each of the four public entry points, plus, in the
shared argument validator, one more key comparison per entry in the `pairs`
walk it already made over `configs` and a validation branch that runs only when
`max_input_bytes` is present. That is more than "a single check", which is what
this section said before, but all of it still runs once per call before any
compression work begins and none of it is inside a loop over the input, so the
substance is unchanged: compression throughput here is upstream's.

### Worst accepted work per preset

What sizes a policy: the most expensive single call each preset will accept,
with each shape built to decode to exactly that preset's `max_output_bytes`.

| Preset     | Shape       | Input    | Decoded | Time   | Allocated |
| ---------- | ----------- | -------- | ------- | ------ | --------- |
| `addon`    | match bomb  | 2.5 KB   | 512 KB  | 10 ms  | 2.0 MB    |
| `addon`    | import blob | 30.5 KB  | 512 KB  | 15 ms  | 2.5 MB    |
| `generous` | match bomb  | 39.5 KB  | 8 MB    | 155 ms | 16.4 MB   |
| `generous` | import blob | 483.5 KB | 8 MB    | 238 ms | 24.6 MB   |

Each **Time** is the highest median any of the ten runs produced, rounded up. A
worst case that rounds down is not a worst case. The ranges behind the four
rows are 8.9–9.6, 13.0–14.6, 143–155 and 214–238 ms.

A frame at 60 fps is 16.7 ms, so the `addon` preset's worst accepted call fits
inside one frame — but only just. 15 ms against 16.7 is about 1.7 ms of
headroom, roughly 10%, on the machine named below, and the World of Warcraft
client's interpreter is slower than that machine, so there the same call can
run past a frame. What the preset was sized for survives that margin, because
the claim is that a rejected or maximal message costs a dropped frame rather
than a freeze, and a call two or three times slower than 15 ms is still a hitch
of a few frames. It is not a claim that the budget sits comfortably inside a
frame; it does not. `generous` is 238 ms, about fourteen dropped frames, and is
not frame-safe. Note that the 155 ms adversarial case is reached from 39.5 KB
of attacker-supplied input.

**Allocated** is bytes allocated during one call with the collector stopped, so
it counts garbage the call discards as well as what it keeps. It is not peak
heap, which cannot be sampled from inside Lua, but it does bound peak heap from
above, and unlike peak heap it is regenerable.

An earlier hand measurement read peak heap of 1.8, 2.3, 14.4 and 22.6 MB. Its
four shapes were built to the same description as these — match bomb and import
blob, each saturating each preset's output cap — but not from the same bytes:
that measurement's match bomb was 0.7 KB of input for 512 KB out where the
harness's is 2.5 KB. So the two are measurements of similar work rather than of
the same call. The times agree closely and each peak figure sits below the
allocation total for its row, which is what a bound should do; that is
corroboration, not a paired reading. The regenerable figures are the ones in
the table.

### One machine

AMD Ryzen 9 7900X, Windows 11, LuaJIT 2.1.1720049189 run with `-joff`. The
World of Warcraft client's interpreter is slower than this, so every millisecond
figure above is a floor rather than a ceiling.

Regenerate the comparison with:

```sh
git worktree add ../upstream-baseline afc3b78d12fb3bcfa6b21e5332031ad3d7572e19
LIBDEFLATEGUARD_BENCH_REFERENCE=../upstream-baseline/LibDeflate.lua \
  luajit -joff tests/BenchTest.lua
```

Run without `LIBDEFLATEGUARD_BENCH_REFERENCE` for the saturation table alone,
which needs no reference module. Use `-joff` for anything that goes into a
document: with the JIT on, two modules this similar share one trace cache and a
delta moves further between runs than the spread reported within a run. The
harness prints that warning itself, and prints `jit.status()` either way. See
`dev_docs/toolchain.md`.

## Security scope

This release bounds single-call decoding. It does not:

- provide streaming or incremental decompression;
- authenticate compressed or encoded data;
- make compression safe for secrets in attacker-influenced contexts;
- impose operating-system memory or wall-clock limits;
- treat caller-created dictionary tables as an untrusted serialization format.

The compressed input must already fit in a Lua string before the decoder can
check its size. Callers should also enforce transport-level message limits.

The resource limits are the part of this fork that closes a reachable
vulnerability. The non-throwing contract is a different kind of change and is
worth describing accurately: upstream LibDeflate already returns `nil` rather
than raising for malformed _string_ input, and a 40000-case differential fuzz
across every decode entry point produced no upstream throw. What this fork adds
there is a stable machine-readable reason for each failure, uniform handling of
wrongly typed arguments, and structural containment so a future decode-path
change cannot reintroduce a raise. That is an API contract and defense in
depth, not a patched upstream defect.

### The stall is bounded, not removed

The budgets are per call. What they bound is the work of one decode, not the
time your client spends in this library.

- Under the default `addon` preset the worst call the policy accepts costs 10
  to 15 ms, against a 16.7 ms frame at 60 fps. That is inside a frame by about
  1.7 ms on the machine `## Performance` names, and the client's interpreter is
  slower than that machine, so treat the margin as thin rather than as spare
  capacity. A rejected or maximal message is a dropped frame or a few, not a
  freeze. That is what the preset was sized for.
- Under `generous` the same shapes cost 155 to 238 ms. That is not frame-safe.
  It is the right choice for a user-initiated import behind a progress
  indicator, and the wrong one for incoming traffic.
- Bounding a _stream_ of messages needs transport context this library does not
  have, and remains the caller's job. A message flood is still an exposure:
  every message is individually cheap and bounded, and a thousand of them are
  not.

See `## Performance` for the measurements and the machine they were taken on.

### What mutation resistance covers

Within one Lua state, this module resists a consumer that writes to the
`LibDeflateGuard` table:

- `ERRORS`, `DEFAULT_LIMITS` and `LIMIT_PRESETS` are inspection copies rather
  than the private tables the module resolves against, so mutating them cannot
  change what the module's own default path enforces. Read the bullet below on
  what that does not extend to.
- The Adler-32 check the zlib decoder verifies a member with is bound
  privately, rather than read back off the module table at call time.
- The two World of Warcraft channel codecs are built by a private constructor,
  so replacing `LibDeflateGuard.CreateCodec` cannot choose the codec a channel
  decode runs through — including after `internals.InternalClearCache()`, which
  is public and clears the lazy cache.
- A `WithPolicy` instance holds its resolved policy in an upvalue, so mutating
  the table passed to `WithPolicy`, or the copies `GetPolicy()` and
  `GetCodecLimits()` return, cannot change what the instance enforces.

What it does not cover:

- **A preset is an inspection copy, not a read-only one, and a policy derived
  from a mutated preset carries the mutation.** `LIMIT_PRESETS.generous` is one
  table built at load time and hung on the public module table, and
  `## Migrating from LibDeflate` tells you to hand that entry straight to
  `WithPolicy`. The copy is made once, so the read a caller performs is a read
  of whatever is in the table by then:

  ```lua
  LibDeflateGuard.LIMIT_PRESETS.generous.max_output_bytes = 4096
  local guard =
    LibDeflateGuard.WithPolicy(LibDeflateGuard.LIMIT_PRESETS.generous)
  -- the instance enforces 4096, not 8 MiB
  ```

  It loosens as readily as it tightens: the same write can hand an `addon`
  instance a 512 MB output cap. What the copy stops is a mutation reaching the
  module's own defaults. What it does not stop is one reaching an instance a
  caller builds out of a preset, or a table a caller passes as `limits`. Write
  the numbers out, or copy the entry yourself, if that matters to you. Item H
  in `dev_docs/roadmap.md` proposes closing it.

- A `WithPolicy` instance is an ordinary table. Anything holding it can replace
  its _methods_; only the policy is sealed.
- `LibDeflateGuard.internals` is test-only and writable.
- A codec returned by your own `CreateCodec` call is yours, and reshaping it is
  legitimate rather than an attack. The guard suite pins that boundary
  deliberately so a later hardening pass does not close it by accident.

The frame this belongs in matters. In World of Warcraft's shared Lua state,
this is defence in depth against accident and against a library that reaches
too far. It is not a boundary against a hostile addon, which is already inside
the same state and can reach your tables directly. Claiming otherwise would be
claiming something Lua cannot deliver here.

## Validation

The focused guard suite has no external dependencies:

```text
lua tests/GuardTest.lua
luajit tests/GuardTest.lua
```

It covers stock LibDeflate/LibStub isolation, private addon export, stored,
fixed, dynamic, and multi-block vectors, malformed/truncated/trailing members,
all resource limits, limit presets, codec input caps, the compression input
cap, policy instances and their derived caps, exception containment, all-byte
addon-channel round trips, malformed escapes, zlib framing, and an
RCLootCouncil compatibility fixture.

Its round-trip assertions are written in the nested form a caller actually
types — `guard:DecodeForPrint(guard:EncodeForPrint(x))` rather than a local
holding the encode result — because storing a result in a local truncates
multiple returns and hides exactly the class of fault that reached v1.1.1.

It also carries two adversarial vectors that a mutation fuzzer cannot reach,
because both are well-formed RFC 1951 rather than corrupted: a maximum
amplification match bomb, and a dynamic-header flood that produces zero output
while forcing a Huffman table build per block. Both assert exact budget
boundaries rather than wall-clock bounds, so an optimisation that stops
charging for a step fails deterministically on every interpreter.

The randomized decode-path suite is also dependency-free:

```text
lua tests/FuzzTest.lua
```

It drives every decoder with valid, truncated, mutated, trailing, and wrongly
typed input, and with tight and invalid limit policies. A decoder must never
throw and must always answer with a decoded string or a stable code from
`ERRORS`. It also asserts two properties that hold without a reference
implementation: anything a codec accepts must re-encode to exactly the bytes
it was given, and a symbol budget below the RFC 1951 floor of one symbol per
258 output bytes must always be refused.

Its workload is reproducible. `LIBDEFLATEGUARD_FUZZ_SEED` selects the seed and
`LIBDEFLATEGUARD_FUZZ_ITERATIONS` scales the iteration counts, so a longer soak
is `LIBDEFLATEGUARD_FUZZ_ITERATIONS=50 lua tests/FuzzTest.lua`. The generator is
a private one, not `math.random`, so a seed reproduces the same workload on
every supported interpreter.

Point `LIBDEFLATEGUARD_FUZZ_REFERENCE` at another copy of `LibDeflateGuard.lua`
to turn the suite into a differential harness. Every public decode entry point
must then return identical tuples from both modules, which is the check to run
when changing the decode path:

```text
git worktree add ../guard-baseline <known-good-revision>
LIBDEFLATEGUARD_FUZZ_REFERENCE=../guard-baseline/LibDeflateGuard.lua \
  lua tests/FuzzTest.lua
```

The inherited upstream suite remains in `tests/Test.lua` for compressor,
dictionary, and broad format regression testing.

## Provenance and upstream updates

The maintained upstream remote is:

```text
https://github.com/SafeteeWoW/LibDeflate.git
```

For an update:

1. Fetch upstream without rewriting or squashing its history.
2. Review upstream changes against the private-module boundary and every
   decoder budget seam.
3. Integrate the smallest source change while preserving the zlib license and
   upstream copyright.
4. Run the focused guard suite and the inherited multi-version suite.
5. Verify stock LibDeflate isolation plus raw Deflate, zlib, addon-channel, and
   print-codec compatibility before release.
6. Record the new upstream commit and any intentional compatibility change in
   `changelog.md`.

Do not copy an upstream LibStub registration block into this fork. Doing so
would reintroduce shared-library substitution and could bypass the guardrails.

## License and credits

LibDeflateGuard is distributed under the zlib license in `LICENSE.txt`.
Copyright for the original LibDeflate implementation remains with Haoqian He.
This repository is plainly marked as an altered, independently maintained
fork. Third-party test data keeps its own provenance and license notices under
`tests/`.

The implementation follows [RFC 1951](https://www.rfc-editor.org/rfc/rfc1951)
and [RFC 1950](https://www.rfc-editor.org/rfc/rfc1950). Original LibDeflate
credits for zlib, puff, LibCompress, and WeakAuras remain in the source header.
