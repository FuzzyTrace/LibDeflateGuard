-- Focused LibDeflateGuard regression tests.
-- Run from the repository root: lua tests/GuardTest.lua
package.path = "?.lua;" .. (package.path or "")

local failures = 0
local tests_run = 0

local function AssertEqual(actual, expected, context)
  if actual ~= expected then
    error(("%s: expected %s, got %s"):format(context or "assertion",
                                             tostring(expected),
                                             tostring(actual)), 2)
  end
end

local function Test(name, func)
  tests_run = tests_run + 1
  local ok, message = pcall(func)
  if ok then
    io.write("ok - ", name, "\n")
  else
    failures = failures + 1
    io.stderr:write("not ok - ", name, ": ", tostring(message), "\n")
  end
end

local function FromHex(hex)
  return (hex:gsub("%x%x",
                   function(pair) return string.char(tonumber(pair, 16)) end))
end

local original_libstub = _G.LibStub
local original_libdeflate = _G.LibDeflate
local original_libdeflateguard = _G.LibDeflateGuard
local original_loaded_libdeflate = package.loaded.LibDeflate
local original_loaded_guard = package.loaded.LibDeflateGuard

local stock_libdeflate = {
  _VERSION = "stock-sentinel",
  DecompressDeflate = function() return "stock" end
}
local libstub_calls = 0
_G.LibDeflate = stock_libdeflate
package.loaded.LibDeflate = stock_libdeflate
_G.LibStub = {
  GetLibrary = function()
    libstub_calls = libstub_calls + 1
    return stock_libdeflate, 999
  end,
  NewLibrary = function()
    libstub_calls = libstub_calls + 1
    return stock_libdeflate
  end
}
package.loaded.LibDeflateGuard = nil

local Guard = require("LibDeflateGuard")

Test("stock LibDeflate and LibStub collision isolation", function()
  AssertEqual(libstub_calls, 0, "LibStub calls")
  AssertEqual(_G.LibDeflate, stock_libdeflate, "global LibDeflate")
  AssertEqual(package.loaded.LibDeflate, stock_libdeflate,
              "package.loaded.LibDeflate")
  AssertEqual(stock_libdeflate._VERSION, "stock-sentinel", "stock metadata")
  AssertEqual(stock_libdeflate:DecompressDeflate(), "stock", "stock method")
  assert(Guard ~= stock_libdeflate, "guard must be a distinct module table")
  AssertEqual(_G.LibDeflateGuard, original_libdeflateguard,
              "global LibDeflateGuard")
  AssertEqual(Guard._NAME, "LibDeflateGuard", "guard name")
  AssertEqual(Guard._MODULE, "LibDeflateGuard", "guard module")
end)

Test("addon-private module export", function()
  local private = {}
  local chunk = assert(loadfile("LibDeflateGuard.lua"))
  local returned = chunk("ConsumerAddon", private)
  assert(type(returned) == "table", "chunk must return the module")
  AssertEqual(private.LibDeflateGuard, returned, "private namespace export")
  AssertEqual(_G.LibDeflateGuard, original_libdeflateguard, "no global export")
end)

local valid_vectors = {
  {name = "stored", compressed = "010100feff41", expected = "A"},
  {name = "fixed", compressed = "330400", expected = "1"},
  {name = "dynamic", compressed = "05c0210d00000080b0fe6d2f916c", expected = ""},
  {
    name = "multiple stored blocks",
    compressed = "000100feff41010100feff42",
    expected = "AB"
  }
}

Test("RFC 1951 stored, fixed, dynamic, and multi-block vectors", function()
  local original_budget_status = _G.budget_status
  local budget_sentinel = {}
  _G.budget_status = budget_sentinel
  for _, vector in ipairs(valid_vectors) do
    local output, decode_error = Guard:DecompressDeflate(
                                   FromHex(vector.compressed))
    AssertEqual(output, vector.expected, vector.name)
    AssertEqual(decode_error, 0, vector.name .. " status")
    AssertEqual(_G.budget_status, budget_sentinel,
                vector.name .. " global isolation")
  end
  _G.budget_status = original_budget_status
end)

Test("zlib wrapper compatibility", function()
  local compressed = FromHex(
                       "78daabcac94c52282f4a2c28482d52284b4d2ec92f02004aac0786")
  local output, decode_error = Guard:DecompressZlib(compressed)
  AssertEqual(output, "zlib wrapper vector", "zlib output")
  AssertEqual(decode_error, 0, "zlib status")

  local corrupted = compressed:sub(1, -2) ..
                      string.char((compressed:byte(-1) + 1) % 256)
  local bad_output, bad_error = Guard:DecompressZlib(corrupted)
  AssertEqual(bad_output, nil, "checksum output")
  AssertEqual(bad_error, Guard.ERRORS.CHECKSUM_MISMATCH, "checksum error")
end)

Test("malformed, truncated, and trailing streams", function()
  local malformed_output, malformed_error =
    Guard:DecompressDeflate(FromHex("06"))
  AssertEqual(malformed_output, nil, "malformed output")
  AssertEqual(malformed_error, Guard.ERRORS.INVALID_STREAM, "malformed error")

  local truncated_output, truncated_error =
    Guard:DecompressDeflate(FromHex("010100feff"))
  AssertEqual(truncated_output, nil, "truncated output")
  AssertEqual(truncated_error, Guard.ERRORS.TRUNCATED_INPUT, "truncated error")

  local trailing_output, trailing_error =
    Guard:DecompressDeflate(FromHex("33040058"))
  AssertEqual(trailing_output, nil, "trailing output")
  AssertEqual(trailing_error, Guard.ERRORS.TRAILING_DATA, "trailing error")
end)

Test("input, output, block, symbol, and work limits", function()
  local fixed = FromHex("330400")
  AssertEqual(Guard:DecompressDeflate(fixed, {max_input_bytes = #fixed}), "1",
              "exact input limit")
  local output, decode_error = Guard:DecompressDeflate(fixed, {
    max_input_bytes = #fixed - 1
  })
  AssertEqual(output, nil, "input limit output")
  AssertEqual(decode_error, Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "input limit error")

  local expansion = FromHex("63186830d00000")
  AssertEqual(#assert(Guard:DecompressDeflate(expansion,
                                              {max_output_bytes = 257})), 257,
              "exact output limit")
  output, decode_error = Guard:DecompressDeflate(expansion,
                                                 {max_output_bytes = 256})
  AssertEqual(output, nil, "output limit output")
  AssertEqual(decode_error, Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "output limit error")

  local multiple_blocks = FromHex("000100feff41010100feff42")
  output, decode_error = Guard:DecompressDeflate(multiple_blocks,
                                                 {max_blocks = 1})
  AssertEqual(output, nil, "block limit output")
  AssertEqual(decode_error, Guard.ERRORS.BLOCK_LIMIT_EXCEEDED,
              "block limit error")

  output, decode_error = Guard:DecompressDeflate(fixed, {max_symbols = 1})
  AssertEqual(output, nil, "symbol limit output")
  AssertEqual(decode_error, Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "symbol limit error")

  output, decode_error = Guard:DecompressDeflate(fixed, {max_work_units = 1})
  AssertEqual(output, nil, "work limit output")
  AssertEqual(decode_error, Guard.ERRORS.WORK_LIMIT_EXCEEDED, "work limit error")
end)

Test("invalid policies and internal exceptions are contained", function()
  local output, decode_error = Guard:DecompressDeflate("x", {unknown = 1})
  AssertEqual(output, nil, "unknown limit output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT, "unknown limit error")

  output, decode_error = Guard:DecompressDeflate("x", {max_blocks = 0})
  AssertEqual(output, nil, "zero limit output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT, "zero limit error")

  output, decode_error =
    Guard:DecompressDeflate("x", {max_output_bytes = false})
  AssertEqual(output, nil, "false limit output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT, "false limit error")

  output, decode_error = Guard:DecompressDeflate("x",
                                                 {max_work_units = math.huge})
  AssertEqual(output, nil, "infinite limit output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT,
              "infinite limit error")

  output, decode_error = Guard:DecompressDeflate({})
  AssertEqual(output, nil, "type output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT, "type error")

  local documented_default = Guard.DEFAULT_LIMITS.max_input_bytes
  Guard.DEFAULT_LIMITS.max_input_bytes = 1
  AssertEqual(Guard:DecompressDeflate(FromHex("330400")), "1",
              "public defaults table cannot weaken policy")
  Guard.DEFAULT_LIMITS.max_input_bytes = documented_default

  local hostile_dictionary = setmetatable({}, {
    __index = function() error("hostile dictionary") end
  })
  output, decode_error = Guard:DecompressDeflateWithDict(FromHex("0300"),
                                                         hostile_dictionary)
  AssertEqual(output, nil, "contained output")
  AssertEqual(decode_error, Guard.ERRORS.INTERNAL_ERROR, "contained error")
end)

Test("zlib dictionary use requires an FDICT binding", function()
  local dictionary_string = "dictionary-backed-payload"
  local dictionary = Guard:CreateDictionary(dictionary_string,
                                            #dictionary_string,
                                            Guard:Adler32(dictionary_string))
  local compressed = Guard:CompressZlibWithDict(dictionary_string, dictionary,
                                                {level = 9})
  local cmf = compressed:byte(1)
  local flg
  for candidate = 0, 255 do
    if math.floor(candidate / 32) % 2 == 0 and (cmf * 256 + candidate) % 31 == 0 then
      flg = candidate
      break
    end
  end
  assert(flg, "could not construct a non-FDICT header")
  local unbound = string.char(cmf, flg) .. compressed:sub(7)
  local output = Guard:DecompressZlibWithDict(unbound, dictionary)
  AssertEqual(output, nil, "unbound dictionary output")
end)

Test("all-byte addon codec and canonical malformed escape rejection", function()
  local bytes = {}
  for byte = 0, 255 do bytes[#bytes + 1] = string.char(byte) end
  local all_bytes = table.concat(bytes)
  local encoded = Guard:EncodeForWoWAddonChannel(all_bytes)
  assert(not encoded:find("\000", 1, true), "encoded data contains NUL")
  AssertEqual(Guard:DecodeForWoWAddonChannel(encoded), all_bytes,
              "all-byte round trip")
  AssertEqual(Guard:EncodeForWoWAddonChannel("\000\001"), "\001\002\001\003",
              "canonical escapes")

  local malformed = {
    "\001", "\001\000", "\001\001", "\001\004", "\001\002\001", "\000"
  }
  for _, value in ipairs(malformed) do
    local output, decode_error = Guard:DecodeForWoWAddonChannel(value)
    AssertEqual(output, nil, "malformed addon output")
    AssertEqual(decode_error, Guard.ERRORS.INVALID_ESCAPE,
                "malformed addon error")
  end

  local custom = assert(Guard:CreateCodec("A", "BC", ""))
  local output, decode_error = custom:Decode("C")
  AssertEqual(output, nil, "unused escape output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ESCAPE, "unused escape error")
end)

Test("RCLootCouncil print-codec fixture", function()
  -- From evil-morfar/RCLootCouncil2 __tests/SavedVariables/ProfileDecode.lua,
  -- licensed LGPL-3.0. See tests/guard-fixtures.md for provenance.
  local encoded =
    "9c5Yonmmqu0VOQA3MqYwskbXIgHWfXUr46mP1Oepb)qaB4Bh7asveXA2znN7m(" ..
      "OlWHdGWRhrk4HwEjdehdEpzCjqh2ldd(4Z25Gw81G2ITKhDqvCr8DpiQ0I17" ..
      "LVq2pF(XPtwzhcXBTz(YZb2RnlGBVaV1Iy3AQV3nHQel7c7GvACJ0P4yHjmw" ..
      "9JzXi(0i3z6nrCR7uKjPJIcgLE4BDf3pi)aTR45LfRy1f3u3W2L063GM86D51n" ..
      "jLwa4xLXy80NT4uLBYA2KbT5l3yBDEfRizMm4PR76EGggMlkl6MIMJ)zR(p2I" ..
      "Z1MuPWj)tN1XSwhCmod(6p"
  local compressed, print_error = Guard:DecodeForPrint(encoded)
  assert(compressed, print_error)
  AssertEqual(#compressed, 245, "RCLootCouncil compressed length")

  local serialized, decode_error = Guard:DecompressDeflate(compressed)
  assert(serialized, decode_error)
  AssertEqual(#serialized, 521, "RCLootCouncil serialized length")
  AssertEqual(serialized:sub(1, 19), "^1^T^Stimeout^N180^", "fixture prefix")
  AssertEqual(serialized:sub(-22), "^SacceptWhispers^b^t^^", "fixture suffix")
  AssertEqual(Guard:EncodeForPrint(compressed), encoded,
              "RCLootCouncil canonical print encoding")
end)

Test("print decoder returns stable non-throwing errors", function()
  local output, decode_error = Guard:DecodeForPrint("!")
  AssertEqual(output, nil, "invalid print output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_PRINT, "invalid print error")
  output, decode_error = Guard:DecodeForPrint({})
  AssertEqual(output, nil, "print type output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT, "print type error")
  for _, noncanonical in ipairs({"AQ", "AAA"}) do
    output, decode_error = Guard:DecodeForPrint(noncanonical)
    AssertEqual(output, nil, "noncanonical print output")
    AssertEqual(decode_error, Guard.ERRORS.INVALID_PRINT,
                "noncanonical print error")
  end
end)

Test("limit presets", function()
  for key, value in pairs(Guard.LIMIT_PRESETS.addon) do
    AssertEqual(Guard.DEFAULT_LIMITS[key], value,
                "default matches addon: " .. key)
  end
  assert(Guard.LIMIT_PRESETS.generous.max_output_bytes >
           Guard.LIMIT_PRESETS.addon.max_output_bytes,
         "generous must be looser than addon")

  -- Both presets must be accepted verbatim as a policy.
  local fixed = FromHex("330400")
  for name, preset in pairs(Guard.LIMIT_PRESETS) do
    AssertEqual(Guard:DecompressDeflate(fixed, preset), "1",
                "preset is a usable policy: " .. name)
  end

  -- The exported tables are inspection copies, not the enforced ones.
  local restore = Guard.LIMIT_PRESETS.addon.max_input_bytes
  Guard.LIMIT_PRESETS.addon.max_input_bytes = 1
  AssertEqual(Guard:DecompressDeflate(fixed), "1",
              "preset table cannot weaken policy")
  Guard.LIMIT_PRESETS.addon.max_input_bytes = restore
end)

Test("codec decoders cap their input", function()
  local channel_cap = Guard.DEFAULT_CODEC_LIMITS.channel_max_input_bytes
  local print_cap = Guard.DEFAULT_CODEC_LIMITS.print_max_input_bytes

  -- The print cap is derived from the decompress input cap, not guessed:
  -- the codec emits 0.75 bytes per input byte, so anything above 4/3 of the
  -- decompress cap cannot produce a member a default decode would accept.
  AssertEqual(print_cap,
              math.floor(Guard.DEFAULT_LIMITS.max_input_bytes * 4 / 3),
              "print cap derivation")
  AssertEqual(channel_cap, Guard.DEFAULT_LIMITS.max_input_bytes,
              "channel cap derivation")

  local over = string.rep("a", print_cap + 1)
  local output, decode_error = Guard:DecodeForPrint(over)
  AssertEqual(output, nil, "print over cap output")
  AssertEqual(decode_error, Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "print over cap error")
  -- Exactly at the cap must still be admitted to the decoder proper.
  local at = string.rep("a", print_cap)
  output, decode_error = Guard:DecodeForPrint(at)
  assert(output ~= nil or decode_error == Guard.ERRORS.INVALID_PRINT,
         "print at cap must reach the decoder, got " .. tostring(decode_error))

  local channel_over = string.rep("x", channel_cap + 1)
  output, decode_error = Guard:DecodeForWoWAddonChannel(channel_over)
  AssertEqual(output, nil, "addon over cap output")
  AssertEqual(decode_error, Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "addon over cap error")
  output, decode_error = Guard:DecodeForWoWChatChannel(channel_over)
  AssertEqual(decode_error, Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "chat over cap error")

  -- An explicit cap overrides the default in both directions.
  AssertEqual(select(2, Guard:DecodeForWoWAddonChannel("ab", 1)),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "explicit tighter cap")
  AssertEqual(Guard:DecodeForWoWAddonChannel(channel_over, channel_cap + 1),
              channel_over, "explicit looser cap")

  for _, bad in ipairs({0, -1, 1.5, math.huge, "64", true}) do
    AssertEqual(select(2, Guard:DecodeForPrint("aaaa", bad)),
                Guard.ERRORS.INVALID_ARGUMENT, "invalid cap: " .. tostring(bad))
  end

  local custom = assert(Guard:CreateCodec("A", "B", ""))
  AssertEqual(select(2, custom:Decode(string.rep("z", channel_cap + 1))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "custom codec cap")
end)

-- Adversarial vectors. FuzzTest mutates valid members, which finds parser
-- bugs but never produces these shapes: both are well-formed RFC 1951 and
-- are built to maximise output-per-input and table-builds-per-input.
-- The assertions are exact budget boundaries rather than wall-clock bounds,
-- so a future optimisation that stops charging for one of these steps fails
-- here deterministically on every interpreter.
local function BitWriter()
  local bytes, cache, cache_bitlen = {}, 0, 0
  local function write(value, bitlen)
    -- DEFLATE packs bits least-significant first within each byte.
    cache = cache + value * 2 ^ cache_bitlen
    cache_bitlen = cache_bitlen + bitlen
    while cache_bitlen >= 8 do
      local byte = cache % 256
      bytes[#bytes + 1] = string.char(byte)
      cache = (cache - byte) / 256
      cache_bitlen = cache_bitlen - 8
    end
  end
  local function finish()
    if cache_bitlen > 0 then bytes[#bytes + 1] = string.char(cache % 256) end
    return table.concat(bytes)
  end
  return write, finish
end

-- Huffman codes are defined most-significant-bit first but written
-- least-significant first, so they are reversed on the way out.
local function Reverse(value, bitlen)
  local out = 0
  for _ = 1, bitlen do
    out = out * 2 + value % 2
    value = math.floor(value / 2)
  end
  return out
end

-- One fixed-Huffman block: a seed literal followed by `pair_count` copies of
-- (length 258, distance 1). Each pair costs 13 bits and emits 258 bytes, so
-- this is a 158:1 amplifier. RFC 1951 permits up to 1032:1; the guard bounds
-- output directly, so the exact ratio only changes how fast the cap is hit.
local function MatchBomb(pair_count)
  local write, finish = BitWriter()
  write(1, 1) -- BFINAL
  write(1, 2) -- BTYPE 01, fixed Huffman
  write(Reverse(0x30, 8), 8) -- literal \000, seeds the window
  for _ = 1, pair_count do
    write(Reverse(0xC5, 8), 8) -- symbol 285, length 258
    write(Reverse(0, 5), 5) -- distance symbol 0, distance 1
  end
  write(Reverse(0, 7), 7) -- symbol 256, end of block
  return finish()
end

-- One minimal dynamic block: a full 19-entry code-length alphabet and 258
-- code lengths, then an immediate end-of-block. Produces zero output while
-- forcing the header path to build Huffman tables.
local function DynamicHeaderBlock(write, is_last)
  write(is_last and 1 or 0, 1)
  write(2, 2) -- BTYPE 10, dynamic
  write(257 - 257, 5) -- HLIT  -> nlen  = 257
  write(1 - 1, 5) -- HDIST -> ndist = 1
  write(19 - 4, 4) -- HCLEN -> ncode = 19
  local order = {
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
  }
  for _, symbol in ipairs(order) do
    -- Give code-length symbols 0 and 1 a one-bit code each.
    write((symbol == 0 or symbol == 1) and 1 or 0, 3)
  end
  for i = 0, 256 do write(Reverse(i == 256 and 1 or 0, 1), 1) end
  write(Reverse(1, 1), 1) -- the single distance code length
  write(Reverse(0, 1), 1) -- body: end-of-block, the only lit/len code
end

local function HeaderFlood(block_count)
  local write, finish = BitWriter()
  for i = 1, block_count do DynamicHeaderBlock(write, i == block_count) end
  return finish()
end

Test("amplification bomb is charged exactly and refused by default", function()
  local pairs_count = 64
  local member = MatchBomb(pairs_count)
  -- Charging model, from the decode path:
  --   symbols = 1 seed + 2 per pair + 1 end-of-block
  --   output  = 1 seed byte + 258 per pair
  --   work    = 1 block + symbols + output
  local expected_output = 1 + 258 * pairs_count
  local expected_symbols = 2 * pairs_count + 2
  local expected_work = 1 + expected_symbols + expected_output

  local generous = {
    max_input_bytes = #member,
    max_output_bytes = expected_output,
    max_blocks = 1,
    max_symbols = expected_symbols,
    max_work_units = expected_work
  }
  local output, decode_error = Guard:DecompressDeflate(member, generous)
  assert(output, "exact budget must decode: " .. tostring(decode_error))
  AssertEqual(#output, expected_output, "bomb output length")

  local function OneLess(key)
    local policy = {}
    for k, v in pairs(generous) do policy[k] = v end
    policy[key] = policy[key] - 1
    return select(2, Guard:DecompressDeflate(member, policy))
  end
  AssertEqual(OneLess("max_output_bytes"), Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "output charged exactly")
  AssertEqual(OneLess("max_symbols"), Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "symbols charged exactly")
  AssertEqual(OneLess("max_work_units"), Guard.ERRORS.WORK_LIMIT_EXCEEDED,
              "work charged exactly")

  -- The shape that matters: small enough to pass the input cap, large enough
  -- to exhaust output. This is the payload an attacker actually sends.
  local hostile = MatchBomb(4096)
  local hostile_output = 1 + 258 * 4096
  assert(#hostile < Guard.DEFAULT_LIMITS.max_input_bytes,
         "hostile payload must clear the input cap to be a real test")
  assert(hostile_output > Guard.DEFAULT_LIMITS.max_output_bytes,
         "hostile payload must exceed the output cap")
  assert(hostile_output / #hostile > 100,
         "hostile payload must actually amplify")
  output, decode_error = Guard:DecompressDeflate(hostile)
  AssertEqual(output, nil, "hostile bomb output")
  AssertEqual(decode_error, Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "hostile bomb error")
end)

Test("dynamic header flood is charged exactly and refused by default",
     function()
  -- Charging model, per block, from the decode path:
  --   work    = 1 block + (ncode + nlen + ndist) header + 258 RLE + 1 EOB
  --   symbols = 258 RLE + 1 end-of-block
  --   output  = 0
  local work_per_block = 1 + (19 + 257 + 1) + 258 + 1
  local symbols_per_block = 258 + 1

  local one = HeaderFlood(1)
  local exact = {
    max_input_bytes = #one,
    max_output_bytes = 1,
    max_blocks = 1,
    max_symbols = symbols_per_block,
    max_work_units = work_per_block
  }
  local output, decode_error = Guard:DecompressDeflate(one, exact)
  assert(output, "exact header budget must decode: " .. tostring(decode_error))
  AssertEqual(output, "", "header flood produces no output")

  exact.max_work_units = work_per_block - 1
  AssertEqual(select(2, Guard:DecompressDeflate(one, exact)),
              Guard.ERRORS.WORK_LIMIT_EXCEEDED, "header work charged exactly")
  exact.max_work_units = work_per_block
  exact.max_symbols = symbols_per_block - 1
  AssertEqual(select(2, Guard:DecompressDeflate(one, exact)),
              Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "header symbols charged exactly")

  -- Zero output means max_output_bytes never binds; the block budget is the
  -- only thing standing between the caller and unbounded table construction.
  local limit = Guard.DEFAULT_LIMITS.max_blocks
  local flood = HeaderFlood(limit + 1)
  assert(#flood < Guard.DEFAULT_LIMITS.max_input_bytes,
         "flood must clear the input cap to be a real test")
  output, decode_error = Guard:DecompressDeflate(flood)
  AssertEqual(output, nil, "flood output")
  AssertEqual(decode_error, Guard.ERRORS.BLOCK_LIMIT_EXCEEDED, "flood error")

  AssertEqual(Guard:DecompressDeflate(HeaderFlood(limit)), "",
              "exactly max_blocks must decode")
end)

_G.LibStub = original_libstub
_G.LibDeflate = original_libdeflate
_G.LibDeflateGuard = original_libdeflateguard
package.loaded.LibDeflate = original_loaded_libdeflate
package.loaded.LibDeflateGuard = original_loaded_guard

if failures > 0 then
  io.stderr:write(("%d of %d tests failed\n"):format(failures, tests_run))
  os.exit(1)
end
io.write(("%d tests passed\n"):format(tests_run))
