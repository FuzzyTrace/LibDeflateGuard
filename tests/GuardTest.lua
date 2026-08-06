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

Test("print decoder rejects lengths no encoder can emit", function()
  -- Found by the nightly fuzz soak, seed 2089977218 at 1000 iterations.
  -- "Hj2ya" is one symbol longer than any encoding can be, and it used to
  -- decode to the same value as its own 4-symbol prefix: the trailing group
  -- of one symbol carries 6 bits, too few to emit a byte, so it was dropped
  -- rather than refused. Inherited from upstream LibDeflate 1.0.2-release,
  -- so v1.1.0 and v1.1.2 carry it too. This is not a probabilistic check --
  -- the fuzz suite reaches it at roughly 1.4e-6 per candidate, which is why
  -- it took a scheduled soak to surface.
  AssertEqual(Guard:DecodeForPrint("Hj2y"), "abc", "canonical print vector")
  local output, decode_error = Guard:DecodeForPrint("Hj2ya")
  AssertEqual(output, nil, "one-symbol tail output")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_PRINT, "one-symbol tail error")

  -- The rule is structural, so pinning that one string would not state it.
  -- EncodeForPrint packs 3 bytes into 4 symbols, so n bytes always become
  -- ceil(4n/3) symbols: 0, 2, 3, 4, 6, 7, 8, 10, 11, 12 ... That sequence
  -- never hits a length congruent to 1 modulo 4, so lengths 5 and 9 must be
  -- refused however they are spelled. Every symbol below is a real member of
  -- the 64-symbol alphabet, so the refusal is the length rule and not an
  -- unknown character.
  for _, strlen in ipairs({5, 9}) do
    for _, symbol in ipairs({"a", "b", "H", "j", "2", "y", "(", ")"}) do
      local label = symbol .. " x " .. strlen
      assert(Guard:DecodeForPrint(string.rep(symbol, 4)) ~= nil,
             "alphabet precondition: " .. symbol)
      output, decode_error = Guard:DecodeForPrint(string.rep(symbol, strlen))
      AssertEqual(output, nil, "unreachable length output: " .. label)
      AssertEqual(decode_error, Guard.ERRORS.INVALID_PRINT,
                  "unreachable length error: " .. label)
    end
    -- The decoder strips leading and trailing control characters and spaces
    -- first, so the length that must be judged is the stripped one. Padding
    -- must not launder an unreachable length into an accepted one.
    AssertEqual(Guard:DecodeForPrint("  " .. string.rep("a", strlen) .. " \n"),
                nil, "padding does not excuse length " .. strlen)
  end

  -- The other side of the rule: every length the encoder CAN emit still round
  -- trips, so the new test refuses no more than it should. Fixed bytes, not
  -- random ones, so a failure here is reproducible.
  local residues_seen = {}
  for n = 0, 32 do
    local bytes = {}
    for i = 1, n do bytes[i] = string.char((i * 37 + 11) % 256) end
    local plain = table.concat(bytes)
    local encoded = Guard:EncodeForPrint(plain)
    AssertEqual(#encoded, math.ceil(4 * n / 3), "encoded length for n=" .. n)
    assert(#encoded % 4 ~= 1, "encoder emitted an unreachable length at n=" .. n)
    AssertEqual(Guard:DecodeForPrint(encoded), plain, "round trip n=" .. n)
    residues_seen[#encoded % 4] = true
  end
  -- Those round trips only mean something if they covered the three residues
  -- the rule leaves accepted.
  for _, residue in ipairs({0, 2, 3}) do
    assert(residues_seen[residue],
           "no round trip covered length % 4 == " .. residue)
  end

  -- Length 0 is 0 modulo 4, so the empty input keeps decoding to the empty
  -- string, before and after the strip.
  AssertEqual(Guard:DecodeForPrint(""), "", "empty print input")
  AssertEqual(Guard:DecodeForPrint("  \n"), "", "whitespace-only print input")
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

-- Regression for the v1.1.0/v1.1.1 nesting break. codec:Encode forwarded
-- string.gsub's substitution count as a second return value, and the codec
-- decoders had just gained an optional input cap as their last argument, so
-- decoding an encode result inline passed the count as the cap.
--
-- Every call in this suite, in FuzzTest, and in examples/example.lua stores
-- the encode result in a local first, which truncates to one value and hides
-- the fault. These assertions must therefore stay in the nested form, and
-- must cover both failure modes: a payload with nothing to escape yields
-- count 0, which was rejected as an invalid cap rather than an oversized
-- input.
Test("encoders return exactly one value and nest inside their decoders",
     function()
  local codecs = {
    {"addon", "EncodeForWoWAddonChannel", "DecodeForWoWAddonChannel", "\000"},
    {"chat", "EncodeForWoWChatChannel", "DecodeForWoWChatChannel", "s"}
  }
  for _, entry in ipairs(codecs) do
    local name, Encode, Decode, escapable = entry[1], entry[2], entry[3],
                                            entry[4]

    -- Nothing to escape: substitution count 0, which failed as
    -- invalid_argument because a cap below 1 is not a valid cap.
    local plain = "abcdef"
    AssertEqual(Guard[Decode](Guard, Guard[Encode](Guard, plain)), plain,
                name .. " nested round trip, nothing escaped")

    -- Something to escape: substitution count above 0, which failed as
    -- input_limit_exceeded because an encoding is always longer than its
    -- own substitution count.
    local escaped = string.rep(escapable .. "x", 40)
    AssertEqual(Guard[Decode](Guard, Guard[Encode](Guard, escaped)), escaped,
                name .. " nested round trip, bytes escaped")

    AssertEqual(select("#", Guard[Encode](Guard, escaped)), 1,
                name .. " encoder arity")
  end

  local codec = assert(Guard:CreateCodec("\000", "\001", ""))
  AssertEqual(codec:Decode(codec:Encode("abcdef")), "abcdef",
              "custom codec nested round trip, nothing escaped")
  AssertEqual(codec:Decode(codec:Encode("a\000b\000c")), "a\000b\000c",
              "custom codec nested round trip, bytes escaped")
  AssertEqual(select("#", codec:Encode("a\000b")), 1, "custom codec arity")

  -- The cap is still reachable as a real argument. Losing the count must not
  -- mean losing the parameter.
  AssertEqual(select(2, codec:Decode(codec:Encode("a\000b"), 1)),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "explicit cap still applies through a nested encode")
end)

-- Regression for the channel-codec constructor seam. Both channel codecs are
-- cached lazily and used to be built by reading LibDeflateGuard:CreateCodec
-- back off the public module table, so the read happened at first use, which
-- is after any consumer has had the chance to write to that table. The
-- type(codec.Decode) check in the channel decoders does not close it: a
-- substituted codec satisfies that check. InternalClearCache is public and
-- nils both cached codecs, so the window re-opened on demand even after first
-- use.
--
-- These need a module whose codec cache is cold, so they build fresh
-- instances with loadfile rather than reusing the suite-level Guard.
local function FreshGuard()
  local chunk = assert(loadfile("LibDeflateGuard.lua"))
  local module = chunk("ConsumerAddon", {})
  assert(type(module) == "table", "chunk must return the module")
  return module
end

-- Both halves of the codec are poisoned, because both halves were open. The
-- channel encoders read the same lazily cached codec the decoders do, so
-- before the fix a replaced CreateCodec chose the codec
-- EncodeForWoWAddonChannel emitted bytes through as well -- a tampered
-- message going out is the same defect as a tampered message coming in, and
-- only the decode direction had a test.
local INJECTED_DECODE = "injected"
local TAMPERED_ENCODE = "tampered"

local function PoisonCreateCodec(module)
  local real = module.CreateCodec
  module.CreateCodec = function(self, reserved_chars, escape_chars, map_chars)
    local codec, reason = real(self, reserved_chars, escape_chars, map_chars)
    if type(codec) == "table" then
      codec.Decode = function() return INJECTED_DECODE end
      codec.Encode = function() return TAMPERED_ENCODE end
    end
    return codec, reason
  end
end

Test("channel codecs ignore a replaced public CreateCodec", function()
  local payload = "payload\000with sS|% and \029\031\015\020 bytes\255"
  local pairs_to_check = {
    {"addon", "EncodeForWoWAddonChannel", "DecodeForWoWAddonChannel"},
    {"chat", "EncodeForWoWChatChannel", "DecodeForWoWChatChannel"}
  }

  -- The bytes an untampered module emits, so the encoder assertions below
  -- compare against the real encoding rather than merely against the poison.
  local clean = FreshGuard()
  local clean_encoded = {}
  for _, entry in ipairs(pairs_to_check) do
    local Encode = entry[2]
    clean_encoded[entry[1]] = clean[Encode](clean, payload)
  end

  -- 1. Cold cache. The poison is in place before the codec is ever built.
  for _, entry in ipairs(pairs_to_check) do
    local name, Encode, Decode = entry[1], entry[2], entry[3]
    local guard = FreshGuard()
    PoisonCreateCodec(guard)
    AssertEqual(guard[Encode](guard, payload), clean_encoded[name],
                name .. " cold cache encoder emits untampered bytes")
    AssertEqual(guard[Decode](guard, guard[Encode](guard, payload)), payload,
                name .. " cold cache round trip")
  end

  -- 2. Warm cache re-opened. Build the codec, assert the baseline, then poison
  -- and clear the cache so the next call has to rebuild.
  for _, entry in ipairs(pairs_to_check) do
    local name, Encode, Decode = entry[1], entry[2], entry[3]
    local guard = FreshGuard()
    local encoded = guard[Encode](guard, payload)
    AssertEqual(guard[Decode](guard, encoded), payload,
                name .. " warm cache baseline")
    PoisonCreateCodec(guard)
    guard.internals.InternalClearCache()
    AssertEqual(guard[Encode](guard, payload), clean_encoded[name],
                name .. " warm cache encoder after ClearCache")
    AssertEqual(guard[Decode](guard, encoded), payload,
                name .. " warm cache round trip after ClearCache")
  end

  -- 3. Caller-owned codec. A codec a caller asks for is the caller's object,
  -- and reshaping it is legitimate, so the poison must take effect here, in
  -- both directions. This pins that boundary as intentional.
  local owned = FreshGuard()
  PoisonCreateCodec(owned)
  local codec = assert(owned:CreateCodec("\000", "\001", ""))
  AssertEqual(codec:Encode(payload), TAMPERED_ENCODE,
              "caller-owned codec keeps a caller's encoder replacement")
  AssertEqual(codec:Decode(codec:Encode(payload)), INJECTED_DECODE,
              "caller-owned codec keeps a caller's replacement")
end)

Test("compression input cap refuses over-budget input", function()
  local payload = string.rep("compressible payload ", 40)
  local dictionary_string = "the quick brown fox jumps over the lazy dog"
  local dictionary = Guard:CreateDictionary(dictionary_string,
                                            #dictionary_string,
                                            Guard:Adler32(dictionary_string))

  -- Every entry point, with and without a dictionary. The third field is the
  -- extra argument each one takes before "configs".
  local entries = {
    {"CompressDeflate"}, {"CompressZlib"},
    {"CompressDeflateWithDict", dictionary},
    {"CompressZlibWithDict", dictionary}
  }
  for _, entry in ipairs(entries) do
    local name, dict = entry[1], entry[2]
    local function Compress(configs)
      if dict then return Guard[name](Guard, payload, dict, configs) end
      return Guard[name](Guard, payload, configs)
    end

    -- No cap at all is the pre-1.2 behaviour and must be untouched.
    local uncapped, padding = Compress(nil)
    assert(type(uncapped) == "string", name .. " must compress without a cap")
    AssertEqual(type(padding), "number", name .. " uncapped second return")

    -- Exactly at the cap is admitted.
    local exact = Compress({max_input_bytes = #payload})
    AssertEqual(exact, uncapped, name .. " at the cap must compress")

    -- One byte under is refused, with the same shape the decode path uses.
    local refused, code = Compress({max_input_bytes = #payload - 1})
    AssertEqual(refused, nil, name .. " over the cap output")
    AssertEqual(code, Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
                name .. " over the cap error")

    -- Arity is two on both paths, so no caller's argument list changes shape.
    AssertEqual(select("#", Compress({max_input_bytes = #payload})), 2,
                name .. " success arity")
    AssertEqual(select("#", Compress({max_input_bytes = 1})), 2,
                name .. " failure arity")

    -- The cap coexists with the pre-existing keys.
    local with_level = Compress({level = 9, max_input_bytes = #payload})
    assert(type(with_level) == "string", name .. " cap alongside level")
    AssertEqual(select(2, Compress({
      level = 9,
      strategy = "fixed",
      max_input_bytes = 1
    })), Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
                name .. " cap alongside level and strategy")

    -- A malformed cap is a programmer error, so it raises, exactly as every
    -- other malformed compression argument does. It must NOT return a code:
    -- silently compressing, or silently refusing, on a typo'd cap is how a
    -- budget stops being a budget.
    for _, bad in ipairs({0, -1, 1.5, math.huge, "64", true, 0 / 0}) do
      local ok, message = pcall(Compress, {max_input_bytes = bad})
      assert(not ok,
             name .. " must raise on cap " .. tostring(bad) .. ", returned " ..
               tostring(message))
      assert(tostring(message):find("max_input_bytes", 1, true), name ..
               " raise must name the offending key, got " .. tostring(message))
    end

    -- An unknown key still raises. Adding one key must not open the table.
    assert(not pcall(Compress, {max_output_bytes = 10}),
           name .. " must still raise on an unknown configs key")
  end
end)

-- Nesting. The v1.1.2 regression survived every test in this repository
-- because each of them stored an encode result in a local first, which
-- truncates multiple returns. A compressor has always returned two values,
-- and now returns two on the failure path as well, so these assertions are
-- written in the shape a caller actually types.
Test("Decompress(Compress(x)) nesting is safe on both compress paths",
     function()
  local payload = string.rep("nested round trip ", 30)

  -- Unbound: the compressor's padding_bitlen lands in the decompressor's
  -- "limits" slot. It is not a policy, so this is refused rather than decoded
  -- under some accidental budget. Nothing here may be a success.
  local output, code = Guard:DecompressDeflate(Guard:CompressDeflate(payload))
  AssertEqual(output, nil, "nested unbound deflate output")
  AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT, "nested unbound deflate code")
  output, code = Guard:DecompressZlib(Guard:CompressZlib(payload))
  AssertEqual(output, nil, "nested unbound zlib output")
  AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT, "nested unbound zlib code")

  -- The new failure arity, nested. Compress answers (nil, "input_limit
  -- _exceeded"), so the decompressor is handed a nil string and a string
  -- policy. It must still answer with a stable code and never throw.
  output, code = Guard:DecompressDeflate(
                   Guard:CompressDeflate(payload, {max_input_bytes = 1}))
  AssertEqual(output, nil, "nested refused compress output")
  AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT,
              "nested refused compress code")

  -- Bound: the instance is the policy, so the extra value is ignored and the
  -- nested form is the one that works. This is the shape the API now
  -- recommends.
  local guard = assert(Guard.WithPolicy(Guard.LIMIT_PRESETS.generous))
  AssertEqual(guard:DecompressDeflate(guard:CompressDeflate(payload)), payload,
              "nested bound deflate round trip")
  AssertEqual(guard:DecompressZlib(guard:CompressZlib(payload)), payload,
              "nested bound zlib round trip")
  AssertEqual(
    select(2, guard:DecompressDeflate(guard:CompressDeflate(payload))), 0,
    "nested bound status")

  local dictionary_string = "the quick brown fox jumps over the lazy dog"
  local dictionary = Guard:CreateDictionary(dictionary_string,
                                            #dictionary_string,
                                            Guard:Adler32(dictionary_string))
  AssertEqual(guard:DecompressDeflateWithDict(
                guard:CompressDeflateWithDict(payload, dictionary), dictionary),
              payload, "nested bound deflate dictionary round trip")
  AssertEqual(guard:DecompressZlibWithDict(
                guard:CompressZlibWithDict(payload, dictionary), dictionary),
              payload, "nested bound zlib dictionary round trip")

  -- A bound compress that its own cap refuses feeds nil to a bound decode.
  local tight = assert(Guard.WithPolicy({max_input_bytes = 8}))
  output, code = tight:DecompressDeflate(tight:CompressDeflate(payload))
  AssertEqual(output, nil, "nested bound refused output")
  AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT, "nested bound refused code")

  -- The whole pipeline, nested end to end, which is what an addon writes.
  AssertEqual(guard:DecompressDeflate(guard:DecodeForPrint(
                                        guard:EncodeForPrint(
                                          guard:CompressDeflate(payload)))),
              payload, "nested bound print pipeline")
  AssertEqual(guard:DecompressDeflate(guard:DecodeForWoWAddonChannel(
                                        guard:EncodeForWoWAddonChannel(
                                          guard:CompressDeflate(payload)))),
              payload, "nested bound addon channel pipeline")
  AssertEqual(guard:DecompressDeflate(guard:DecodeForWoWChatChannel(
                                        guard:EncodeForWoWChatChannel(
                                          guard:CompressDeflate(payload)))),
              payload, "nested bound chat channel pipeline")
end)

Test("a policy instance derives every cap from max_input_bytes", function()
  local generous = assert(Guard.WithPolicy(Guard.LIMIT_PRESETS.generous))
  local derived = generous:GetCodecLimits()
  local base = Guard.LIMIT_PRESETS.generous.max_input_bytes
  AssertEqual(derived.print_max_input_bytes, math.floor(base * 4 / 3),
              "print cap derivation")
  AssertEqual(derived.channel_max_input_bytes, base, "channel cap derivation")
  AssertEqual(derived.compress_max_input_bytes, base, "compress cap derivation")
  for key, value in pairs(Guard.LIMIT_PRESETS.generous) do
    AssertEqual(generous:GetPolicy()[key], value, "policy passthrough: " .. key)
  end

  -- A default instance must derive exactly the numbers the module publishes
  -- as its load-time defaults, which is the coupling this removes.
  local default_instance = assert(Guard.WithPolicy())
  AssertEqual(default_instance:GetCodecLimits().print_max_input_bytes,
              Guard.DEFAULT_CODEC_LIMITS.print_max_input_bytes,
              "default print cap")
  AssertEqual(default_instance:GetCodecLimits().channel_max_input_bytes,
              Guard.DEFAULT_CODEC_LIMITS.channel_max_input_bytes,
              "default channel cap")

  -- Behaviour, not just arithmetic. A small policy so the strings stay small.
  local small = assert(Guard.WithPolicy({max_input_bytes = 300}))
  local caps = small:GetCodecLimits()
  AssertEqual(caps.print_max_input_bytes, 400, "small print cap")
  AssertEqual(caps.channel_max_input_bytes, 300, "small channel cap")

  AssertEqual(select(2, small:DecodeForPrint(string.rep("a", 401))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "print cap fires at 401")
  assert(small:DecodeForPrint(string.rep("a", 400)) ~= nil,
         "print cap must admit exactly 400")
  -- The unbound entry point still uses the load-time default, so a string
  -- past the instance's 400 proves the instance cap is the thing being
  -- applied. 404 rather than 401 because a length congruent to 1 modulo 4 is
  -- one the encoder can never emit and the decoder now refuses outright,
  -- which would make this assert fail for a reason it is not about.
  assert(Guard:DecodeForPrint(string.rep("a", 404)) ~= nil,
         "the unbound print decoder must be unaffected by an instance")

  for _, method in ipairs({
    "DecodeForWoWAddonChannel", "DecodeForWoWChatChannel"
  }) do
    AssertEqual(select(2, small[method](small, string.rep("x", 301))),
                Guard.ERRORS.INPUT_LIMIT_EXCEEDED, method .. " cap fires at 301")
    AssertEqual(small[method](small, string.rep("x", 300)),
                string.rep("x", 300), method .. " admits exactly 300")
    assert(Guard[method](Guard, string.rep("x", 301)) ~= nil,
           "the unbound " .. method .. " must be unaffected by an instance")
  end

  -- Compression, same derivation.
  AssertEqual(select(2, small:CompressDeflate(string.rep("y", 301))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "compress cap fires at 301")
  assert(small:CompressDeflate(string.rep("y", 300)) ~= nil,
         "compress cap must admit exactly 300")
  -- An explicit configs cap is the more specific statement and wins.
  AssertEqual(select(2, small:CompressDeflate(string.rep("y", 200),
                                              {max_input_bytes = 100})),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "explicit configs cap is used")
  assert(
    small:CompressDeflate(string.rep("y", 400), {max_input_bytes = 500}) ~= nil,
    "an explicit configs cap can widen the instance cap")
  -- Merging the derived cap must not write into the caller's table.
  local configs = {level = 9}
  small:CompressDeflate("payload", configs)
  AssertEqual(configs.max_input_bytes, nil,
              "the instance must not write a cap into the caller's configs")
  AssertEqual(next(configs), "level", "the caller's configs must be untouched")

  -- A codec built by the instance inherits the instance's channel cap.
  local codec = assert(small:CreateCodec("\000", "\001", ""))
  AssertEqual(select(2, codec:Decode(string.rep("z", 301))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "instance codec cap")
  AssertEqual(codec:Decode(codec:Encode("a\000b")), "a\000b",
              "instance codec nested round trip")
  local module_codec = assert(Guard:CreateCodec("\000", "\001", ""))
  assert(module_codec:Decode(string.rep("z", 301)) ~= nil,
         "a module codec must keep the load-time default cap")

  -- And the point of the whole thing: a raised policy actually decodes a
  -- member the default policy refuses, without a second cap being set.
  local big = {}
  local state = 1
  for i = 1, 200000 do
    -- MINSTD, so the bytes do not compress. A simple i * 7 % 256 ramp has a
    -- 256-byte period and deflates to almost nothing.
    state = state * 16807 % 2147483647
    big[i] = string.char(state % 256)
  end
  big = table.concat(big)
  local member = Guard:CompressDeflate(big)
  assert(#member > Guard.DEFAULT_LIMITS.max_input_bytes,
         "the member must exceed the default input cap to be a real test")
  AssertEqual(select(2, Guard:DecompressDeflate(member)),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "default policy refuses")
  AssertEqual(generous:DecompressDeflate(member), big,
              "the generous instance decodes it")
end)

Test("a policy instance cannot be weakened after it is built", function()
  local policy = {max_input_bytes = 300}
  local guard = assert(Guard.WithPolicy(policy))

  -- Mutating the table the caller handed in must not move the budget.
  policy.max_input_bytes = 1024 * 1024
  policy.max_output_bytes = 1024 * 1024
  AssertEqual(guard:GetPolicy().max_input_bytes, 300, "policy table capture")
  AssertEqual(guard:GetCodecLimits().channel_max_input_bytes, 300,
              "derived cap capture")
  AssertEqual(select(2, guard:DecodeForWoWAddonChannel(string.rep("x", 301))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED, "enforced cap after mutation")
  AssertEqual(select(2, guard:CompressDeflate(string.rep("y", 301))),
              Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
              "enforced compress cap after mutation")

  -- The accessors hand back copies, so writing to what they return is inert.
  local seen = guard:GetPolicy()
  seen.max_input_bytes = 1024 * 1024
  AssertEqual(guard:GetPolicy().max_input_bytes, 300, "GetPolicy returns a copy")
  local seen_caps = guard:GetCodecLimits()
  seen_caps.channel_max_input_bytes = 1024 * 1024
  AssertEqual(guard:GetCodecLimits().channel_max_input_bytes, 300,
              "GetCodecLimits returns a copy")

  -- Building from a preset must copy it, and must not alias the module's
  -- private defaults either.
  local restore = Guard.LIMIT_PRESETS.addon.max_input_bytes
  local from_preset = assert(Guard.WithPolicy(Guard.LIMIT_PRESETS.addon))
  Guard.LIMIT_PRESETS.addon.max_input_bytes = 1
  AssertEqual(from_preset:GetPolicy().max_input_bytes, restore,
              "preset table capture")
  Guard.LIMIT_PRESETS.addon.max_input_bytes = restore

  local from_default = assert(Guard.WithPolicy())
  from_default:GetPolicy().max_input_bytes = 1
  AssertEqual(Guard:DecompressDeflate(FromHex("330400")), "1",
              "an instance must not alias the module defaults")
  AssertEqual(from_default:GetPolicy().max_input_bytes,
              Guard.DEFAULT_LIMITS.max_input_bytes, "default instance policy")
end)

Test("WithPolicy validates a policy exactly as the limits parameter does",
     function()
  local bad_policies = {
    {max_blocks = 0}, {max_blocks = -1}, {max_blocks = 1.5}, {unknown_key = 1},
    {max_input_bytes = math.huge}, {max_symbols = "10"},
    {max_output_bytes = 0 / 0}, {max_work_units = -0.5}, "not a table", 42, true
  }
  local fixed = FromHex("330400")
  for index, policy in ipairs(bad_policies) do
    -- The same answer the decompressors give for the same policy, so there is
    -- one validator and not two.
    AssertEqual(select(2, Guard:DecompressDeflate(fixed, policy)),
                Guard.ERRORS.INVALID_ARGUMENT, "reference rejection " .. index)
    local instance, code = Guard.WithPolicy(policy)
    AssertEqual(instance, nil, "rejected policy instance " .. index)
    AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT,
                "rejected policy code " .. index)
  end

  -- Every shape the limits parameter accepts must build an instance.
  for _, policy in ipairs({
    {}, {max_blocks = 1}, Guard.LIMIT_PRESETS.addon,
    Guard.LIMIT_PRESETS.generous, Guard.DEFAULT_LIMITS
  }) do
    local instance = assert(Guard.WithPolicy(policy),
                            "a valid policy must build an instance")
    AssertEqual(instance:DecompressDeflate(fixed), "1",
                "a built instance must decode")
  end

  -- Documented as a dot call. The rest of the module is colon-called, so the
  -- colon spelling must not silently resolve the module table as a policy.
  local dotted = assert(Guard.WithPolicy(Guard.LIMIT_PRESETS.generous))
  local coloned = assert(Guard:WithPolicy(Guard.LIMIT_PRESETS.generous))
  AssertEqual(coloned:GetPolicy().max_input_bytes,
              dotted:GetPolicy().max_input_bytes, "colon call spelling")
  AssertEqual(assert(Guard:WithPolicy()):GetPolicy().max_input_bytes,
              Guard.DEFAULT_LIMITS.max_input_bytes, "colon call with no policy")
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
