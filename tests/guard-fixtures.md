# LibDeflateGuard guard fixture provenance

The byte strings in `GuardTest.lua` exercise the RFC 1951 stored, fixed
Huffman, dynamic Huffman, and multi-block grammar. They are test vectors, not
copies of RFC prose. RFC 1951 is available from the
[RFC Editor](https://www.rfc-editor.org/rfc/rfc1951).

The zlib wrapper vector was generated with zlib 1.3.1 and checks RFC 1950
framing and Adler-32 validation.

The RCLootCouncil print-codec fixture comes from
[`ProfileDecode.lua`](https://github.com/evil-morfar/RCLootCouncil2/blob/4d82e87f822780c1b292a80f70ffb73b1903dee7/__tests/SavedVariables/ProfileDecode.lua)
at commit `4d82e87f822780c1b292a80f70ffb73b1903dee7` in RCLootCouncil2.
The project's addon metadata identifies Potdisc as author. RCLootCouncil2
identifies the source as LGPL-3.0. The fixture is retained only as
compatibility test data. Its pipeline is the LibDeflate print codec wrapped
around a raw Deflate member. The source project's license is reproduced in
`tests/licenses/RCLootCouncil2-LICENSE.md`.

The upstream implementation and test corpus remain attributed and licensed as
described in `LICENSE.txt`, the source header in `LibDeflateGuard.lua`, and
`tests/data/3rdparty/README.txt`.
