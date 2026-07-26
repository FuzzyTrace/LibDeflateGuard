### LibDeflateGuard v1.0.0

- Established the independently maintained `LibDeflateGuard` module identity
  from upstream LibDeflate `1.0.2-release` at commit
  `afc3b78d12fb3bcfa6b21e5332031ad3d7572e19`.
- Removed LibStub lookup, registration, and substitution. The fork now returns
  a private module and can attach it only to the loading addon's private
  namespace.
- Added default and caller-configurable compressed-input, output, block,
  Huffman-symbol, and deterministic work-unit limits.
- Added stable, non-throwing symbolic failures and exception containment at
  decompression and channel-decode seams.
- Rejects complete trailing bytes after raw Deflate and zlib members.
- Rejects malformed and non-canonical World of Warcraft addon-channel escapes.
- Rejects non-canonical custom-codec escape input and print-codec terminal
  padding.
- Uses a supplied zlib dictionary only when FDICT and DICTID bind it to the
  member.
- Retains RFC 1951, zlib, World of Warcraft channel, and LibDeflate print-codec
  wire compatibility, including an RCLootCouncil compatibility fixture.
- Added independent regression coverage for module collisions, valid block
  forms, malformed input, resource limits, codecs, and compatibility data.
- Documented security scope, limits, provenance, and the upstream update
  process.

The entries below are the preserved upstream LibDeflate release history.

### v1.0.2-release

- Change the license to the zlib license (Formerly LGPLv3). This license is more permissive than LGPLv3.
- Increase compression speed by up to 25% on high compression level on non-JIT lua interpreter.
- Bump the World of Warcraft toc version to 80300

### v1.0.1-release

- 2019/11/18
- No functional change
- Bump the World of Warcraft toc version to 80205
- No longer "Load on Demand" in Warcraft toc, because this library does not consume much memory. This makes easier to load and test this library.
- Change the license to LGPLv3 (Formerly GPLv3)

### v1.0.0-release

- 2018/7/30
- Documentation updates.

### v0.9.0-beta4

- 2018/5/25
- "DecodeForPrint" always remove prefixed or trailing control or space characters before decoding. This makes this API easier to use.

### v0.9.0-beta3

- 2018/5/23
- Fix an issue in "DecodeForPrint" that certain undecodable string
  could cause an Lua error.
- Add an parameter to "DecodeForPrint". If set, remove trailing spaces in the
  input string before decode it.
- Add input type checks for all encode/decode functions.

### v0.9.0-beta2

- 2018/5/22
- API "Encode6Bit" is renamed to "EncodeForPrint"
- API "Decode6Bit" is renamed to "DecodeForPrint"

### v0.9.0-beta1

- 2018/5/22
- No change

### v0.9.0-alpha2

- 2018/5/21
- Remove API LibDeflate:VerifyDictionary
- Remove API LibDeflate:DictForWoW
- Changed API LibDeflate:CreateDictionary

### v0.9.0-alpha1

- 2018/5/20
- The first working version.
