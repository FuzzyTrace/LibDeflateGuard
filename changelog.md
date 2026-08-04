### LibDeflateGuard v1.2.0

- **Added.** `LibDeflateGuard.WithPolicy(policy)` returns an object bound to
  one decode policy. It carries the whole budget: the decompressors take the
  policy, the codec decoders take an input cap derived from the policy's
  `max_input_bytes` using the ratios this module already applies to its own
  defaults, and the compressors take a derived input cap too. This removes
  the coupling the README used to document as "a caller that raises
  `max_input_bytes` must raise these to match", and retires the positional
  cap parameters as the recommended call shape. Those parameters are
  unchanged and still work.

  The resolved policy is held in an upvalue, not a field, so mutating the
  table passed to `WithPolicy` or writing to the instance cannot change what
  the instance enforces. That is the property `LIMIT_PRESETS` and
  `DEFAULT_LIMITS` already have. An invalid policy is reported as
  `nil, invalid_argument` by the same validator the `limits` parameter uses,
  rather than raised.

- **Added.** The four compress entry points accept `max_input_bytes` in their
  existing configuration table. Omitting it means no cap, which is the
  behaviour of every earlier release. A malformed cap raises, like every other
  malformed compression argument; an input larger than a well-formed cap
  returns `nil` plus `ERRORS.INPUT_LIMIT_EXCEEDED`, the shape the decode path
  uses. Both paths return exactly two values.

  Declared as a table key rather than as a trailing positional argument on
  purpose. A trailing optional argument on a function whose natural argument
  is the output of a multi-value function is what made the v1.1.1 nesting bug
  possible.

- **Behaviour change.** A `configs` table containing `max_input_bytes` used to
  raise as an unsupported key. It is now accepted.

- **Fixed.** `DecodeForPrint` accepted a string one symbol longer than any
  encoding can be, and decoded it to the same value as its own prefix:
  `DecodeForPrint("Hj2ya")` returned `"abc"`, exactly as
  `DecodeForPrint("Hj2y")` does. A trailing group of one symbol carries 6
  bits, fewer than the 8 needed to emit a byte, so the symbol was dropped
  rather than refused, and the existing check on unused bits still passed
  when that symbol was the zero symbol. `EncodeForPrint` turns n bytes into
  `ceil(4n/3)` symbols — 0, 2, 3, 4, 6, 7, 8, 10, 11, 12 and so on — a
  sequence that never reaches a length congruent to 1 modulo 4, so such a
  length is now refused as `invalid_print`. The length tested is the one left
  after the leading and trailing control characters and spaces are stripped,
  and the new rule subsumes the narrower `strlen == 1` check it replaces.

  This is a strictness fix. No string `EncodeForPrint` can produce has an
  affected length, so canonical data, including RCLootCouncil export data,
  round trips unchanged. A caller that fed the decoder hand-edited or
  truncated strings may now see `invalid_print` where a value was previously
  returned, which is the point: two different strings decoding to one value
  is exactly what a decoder guarding untrusted input should not do.

  Inherited from upstream LibDeflate `1.0.2-release`, and present in v1.1.0
  and v1.1.2 as well, so it is not a regression from recent work. The
  escape-based channel and custom codecs do not use the 6-bit packing and are
  unaffected. Found by the nightly fuzz soak; the fuzz suite reaches the case
  at roughly 1.4e-6 per candidate, so the regression test is a fixed vector
  rather than a probabilistic one.

### LibDeflateGuard v1.1.2

- **Fixed.** Decoding an encode result inline failed. `codec:Encode` forwarded
  `string.gsub`'s substitution count as a second return value, and v1.1.0 had
  just given the codec decoders an optional input cap as their last argument,
  so the count arrived as the cap:

  ```lua
  Guard:DecodeForWoWAddonChannel(Guard:EncodeForWoWAddonChannel(str))
  ```

  A payload with bytes to escape was refused as `input_limit_exceeded`,
  because an encoding is always longer than its own substitution count. A
  payload with nothing to escape was refused as `invalid_argument`, because a
  count of zero is not a valid cap. This affected `DecodeForWoWAddonChannel`,
  `DecodeForWoWChatChannel`, and `codec:Decode` in both v1.1.0 and v1.1.1.
  `EncodeForPrint` never forwarded a count and was unaffected.

  Every call in the test suites and in `examples/example.lua` stores the
  encode result in a local first, which truncates to one value and hid the
  fault. The regression test is written in the nested form for that reason,
  and covers both failure modes.

- **Behaviour change.** `codec:Encode`, `EncodeForWoWAddonChannel`, and
  `EncodeForWoWChatChannel` now return exactly one value. The substitution
  count was never intended API; it was upstream `string.gsub` leaking through
  a `return`. A caller that relied on it — `local s, n = Encode(x)` — now
  gets `nil` for `n`. In differential fuzz against a pre-1.1.2 reference this
  shows up as an expected arity divergence on `custom codec encode`.

- **Fixed.** The command-line tool could compress a file it could not then
  decompress. It decoded with whatever the shipping default policy happened
  to be, so v1.1.0's move to the addon preset capped it at 512 KiB of output.
  The binding cap was `max_output_bytes`, not the input cap: a member well
  inside 64 KiB still decodes past 512 KiB. A file named on the command line
  is not the untrusted frame-thread input the budgets exist for, so the CLI
  now decodes unbounded. `--limits <none/addon/generous>` opts back into a
  preset, and a rejection now reports the reason instead of a bare
  "Decompress fails.". The existing command-line coverage used a 738-byte
  fixture, far below every budget, so it could not see this.

- Hardened two seams that ran through the public module table. The zlib
  decoder verified a member's Adler-32 with `LibDeflateGuard:Adler32`, a
  writable field, so anything holding the module could have replaced the
  checksum check. Every failure path also read `LibDeflateGuard.ERRORS` at
  call time, so the stable error codes were not stable against mutation.
  Both are now bound privately, and `LibDeflateGuard.ERRORS` is an inspection
  copy like `DEFAULT_LIMITS` and `LIMIT_PRESETS`.

### LibDeflateGuard v1.1.1

- No functional change. Apart from the version strings, `LibDeflateGuard.lua`
  is identical to v1.1.0, so there is no reason to upgrade for the library
  itself.
- Repository and CI only. The release workflow can publish generated
  documentation to `gh-pages` again; its `GITHUB_TOKEN` had been read-only
  since the fork was created, so every attempt had failed and the published
  docs still described the pre-rename `LibDeflate.lua`. The `luaunit` install
  now retries, having flaked on a macOS runner when luarocks.org failed to
  serve a rockspec. The GitHub Actions used by CI moved to releases running on
  Node 24, ahead of the Node 20 runtime being retired.

### LibDeflateGuard v1.1.0

- **Breaking.** The default decode policy is now the addon-sized one. It was
  `max_input_bytes = 1 MiB` and `max_output_bytes = 8 MiB`; it is now 64 KiB
  and 512 KiB, with the block, symbol, and work budgets scaled to match. The
  previous values remain available as `LIMIT_PRESETS.generous`. A decode on a
  game client runs on the frame thread, and the old defaults still permitted a
  stall of roughly a tenth of a second per call on a fast interpreter and
  several times that on the World of Warcraft one. Callers who decode larger
  members must now pass `LIMIT_PRESETS.generous` or a policy of their own.
- **Breaking.** Codec decoders now cap their input. `DecodeForPrint`,
  `DecodeForWoWAddonChannel`, `DecodeForWoWChatChannel`, and `codec:Decode`
  take an optional cap as their last argument and refuse oversized input with
  `input_limit_exceeded`. A codec decode runs before any decompression budget
  applies, so it previously performed unbounded work on attacker-supplied
  bytes; a 32 MiB print string cost about a second and 104 MiB of heap before
  the decompressor ever saw it. The decode is linear, so this was a stall
  rather than an amplification. The defaults are derived from the decompress
  input cap rather than guessed, and are exposed as `DEFAULT_CODEC_LIMITS`.
- Added `LIMIT_PRESETS`, with `addon` and `generous` entries. Both are
  inspection copies, like `DEFAULT_LIMITS`.
- Added two adversarial regression vectors to `tests/GuardTest.lua`: a maximum
  amplification match bomb and a dynamic-header flood. Both are well-formed
  RFC 1951, so neither is reachable by mutating a valid member, which is all
  the fuzz suite could previously produce. They assert exact budget boundaries
  rather than wall-clock bounds.
- Documented that the budgets are per call, and that bounding a stream of
  messages needs the caller's transport context.
- Corrected the README's account of the non-throwing contract. Upstream
  LibDeflate does not raise on malformed string input, and a 40000-case
  differential fuzz across every decode entry point found no upstream throw.
  The contract is a stable failure reason and structural containment, not a
  patched upstream defect.
- `tests/Test.lua` now passes an explicit conformance policy. It is a
  wire-format suite over a multi-megabyte third-party corpus and should not be
  silently bounded by whatever the shipping default happens to be.
- No measurable decode cost. Against v1.0.1 over interleaved best-of-three
  runs, raw Deflate, addon-channel, and print decoding all land within half a
  microsecond per call in both directions, with and without the JIT. The codec
  cap keeps its default path inline so an unoverridden call pays no extra
  function call.

### LibDeflateGuard v1.0.1

- Reduced decode-path overhead. Raw Deflate decoding is about 10 per cent
  faster and zlib about 13 per cent, stored blocks about a third faster, and
  World of Warcraft addon-channel decoding about twice as fast. A sweep of many
  small messages also allocates far less, because a guarded decode no longer
  builds a closure and a limits table on every call.
- No decoder behaviour change. Every limit, error code, and accepted or
  rejected input is the same. The optimised decoder was compared against the
  previous one over hundreds of thousands of calls with no divergence.
- Documented that `max_output_bytes` bounds the decoded string and not the Lua
  heap, which peaks at roughly three to four times the decoded size. The
  default 8 MiB output cap therefore implies a transient peak nearer 26 to
  32 MiB.
- Added `tests/FuzzTest.lua`, a randomized decode-path suite with
  exact-boundary coverage for every resource limit across stored, fixed, and
  dynamic blocks, and an optional differential mode that compares two copies of
  the library call for call.
- Fixed `tools/format_lua.sh`, which never passed a filename to the formatter,
  so the Lua formatting check had never inspected anything. Formatted the Lua
  sources to the repository's own configuration and excluded the vendored
  LibCompress copy from formatting.
- Added `.gitattributes` so shell scripts keep LF line endings. Every script in
  `tools/` failed immediately on a Windows checkout before this.
- Documented the local validation toolchain in `dev_docs/toolchain.md`.

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
