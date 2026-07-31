# LibDeflateGuard

LibDeflateGuard is an independently maintained, security-hardened fork of
[SafeteeWoW/LibDeflate](https://github.com/SafeteeWoW/LibDeflate). It keeps the
proven LibDeflate compressor, RFC 1951 wire format, and established World of
Warcraft codecs while adding strict resource limits and stable, non-throwing
decode failures.

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
- Decoder and channel-decode failures return stable symbolic error codes. They
  do not throw for malformed or wrongly typed untrusted input.
- Raw Deflate and zlib members reject complete trailing bytes.
- World of Warcraft addon-channel decoding rejects dangling, unknown, and
  otherwise non-canonical escape sequences.
- Custom-codec escape input and print-codec terminal padding must use the
  canonical form produced by their encoders.
- A supplied zlib dictionary is usable only when the member declares FDICT and
  its DICTID matches.

LibDeflateGuard does not replace an installed stock LibDeflate. An application
can load both modules without either one mutating the other.

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
defaults:

```lua
LibDeflateGuard.DEFAULT_LIMITS = {
  max_input_bytes = 1024 * 1024,
  max_output_bytes = 8 * 1024 * 1024,
  max_blocks = 4096,
  max_symbols = 10000000,
  max_work_units = 25000000,
}
```

`DEFAULT_LIMITS` is an inspection copy. Mutating it does not alter the private
defaults enforced by the decoder.

Example policy override:

```lua
local limits = {
  max_input_bytes = 64 * 1024,
  max_output_bytes = 512 * 1024,
  max_blocks = 256,
  max_symbols = 750000,
  max_work_units = 1500000,
}
local output, decode_error =
  LibDeflateGuard:DecompressDeflate(compressed, limits)
```

`max_symbols` counts every Huffman decode attempt, including dynamic-header,
literal/length, distance, and end-of-block symbols. `max_work_units` counts
blocks, Huffman symbols, output bytes, and dynamic-table entries. It is a
deterministic operation budget, not a wall-clock deadline.

The complete input string counts toward `max_input_bytes`. A valid compressed
member followed by one or more complete bytes fails with `trailing_data`.
Unused padding bits in the final raw Deflate byte remain valid RFC 1951
padding.

## Compression and codecs

The original compressor and dictionary APIs remain available:

- `CompressDeflate` and `CompressDeflateWithDict`
- `CompressZlib` and `CompressZlibWithDict`
- `CreateDictionary` and `Adler32`

Compression output remains wire-compatible with LibDeflate and RFC 1951.
Compression and dictionary construction are trusted, programmer-facing APIs
and retain their original argument-error behavior.

The original codec names are retained:

- `EncodeForWoWAddonChannel` and `DecodeForWoWAddonChannel`
- `EncodeForWoWChatChannel` and `DecodeForWoWChatChannel`
- `EncodeForPrint` and `DecodeForPrint`
- `CreateCodec`

The print codec stays compatible with existing LibDeflate consumers, including
canonical RCLootCouncil export data. Previously tolerated nonzero unused bits
in a final print-codec group are rejected as `invalid_print`. Decode methods
return `nil, error_code` on invalid untrusted input. Encode methods remain
programmer-facing and retain the original argument-error behavior.

## Security scope

This release bounds single-call decoding. It does not:

- provide streaming or incremental decompression;
- authenticate compressed or encoded data;
- make compression safe for secrets in attacker-influenced contexts;
- impose operating-system memory or wall-clock limits;
- treat caller-created dictionary tables as an untrusted serialization format.

The compressed input must already fit in a Lua string before the decoder can
check its size. Callers should also enforce transport-level message limits.

## Validation

The focused guard suite has no external dependencies:

```text
lua tests/GuardTest.lua
luajit tests/GuardTest.lua
```

It covers stock LibDeflate/LibStub isolation, private addon export, stored,
fixed, dynamic, and multi-block vectors, malformed/truncated/trailing members,
all resource limits, exception containment, all-byte addon-channel round trips,
malformed escapes, zlib framing, and an RCLootCouncil compatibility fixture.

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
