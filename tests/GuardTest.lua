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
