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

-- The numbers README.md publishes, transcribed by hand out of the document.
--
-- Every other assertion in this file recomputes a published figure from this
-- module's own tables -- math.floor(base * 4 / 3) in "codec decoders cap their
-- input", DerivedSymbols() near the end of the file -- which pins the
-- derivation and nothing else. Change the 4/3 ratio or the 318 of slack and
-- the whole suite moves with the module, and only README.md is left holding
-- the old numbers. This block is the other half: absolute values copied out of
-- the document, so that a constant changed on purpose surfaces here as a
-- documentation task instead of as a silent divergence.
--
-- Nothing below may be read out of the module or derived from another entry.
-- The two sides are only evidence of each other while they are independent.
-- Line numbers are as of the revision that added this test and will drift; the
-- section headings will not, so each group names its heading too.
local README_NUMBERS = {
  -- `## Safe decoding`, the LIMIT_PRESETS block, README.md lines 318-333.
  presets = {
    addon = {
      max_input_bytes = 65536, -- 64 * 1024
      max_output_bytes = 524288, -- 512 * 1024
      max_blocks = 256,
      max_symbols = 524606,
      max_work_units = 1134910
    },
    generous = {
      max_input_bytes = 1048576, -- 1024 * 1024
      max_output_bytes = 8388608, -- 8 * 1024 * 1024
      max_blocks = 4096,
      max_symbols = 8388926,
      max_work_units = 18153790
    }
  },
  -- `## Compression and codecs`, the DEFAULT_CODEC_LIMITS block, README.md
  -- lines 676-679.
  default_codec_limits = {
    print_max_input_bytes = 87381,
    channel_max_input_bytes = 65536
  },
  -- The three print caps the document quotes as absolute byte counts rather
  -- than as a rule: 87381 at the default 64 KiB, in the DEFAULT_CODEC_LIMITS
  -- block and again in prose at README.md line 109; 1398101 under `generous`'s
  -- 1 MiB at line 140; and 262144 for the 192 KiB policy worked through at
  -- line 145. All three are in `### A paste-sized import string is refused
  -- before it decodes`, which is where a reader meets the cap.
  print_caps = {
    {max_input_bytes = 65536, print_cap = 87381},
    {max_input_bytes = 1048576, print_cap = 1398101},
    {max_input_bytes = 196608, print_cap = 262144} -- 192 * 1024
  },
  -- `### The two derived backstops`, README.md lines 484-485:
  --   max_symbols    = 8 * max_input_bytes + 318
  --   max_work_units = max_symbols + max_output_bytes + 336 * max_blocks
  symbol_bits_per_byte = 8,
  symbol_slack = 318,
  work_per_block = 336,
  -- `## Safe decoding`, README.md lines 298-302. Fifteen of them, described
  -- there as the complete set.
  error_codes = {
    "invalid_argument", "input_limit_exceeded", "output_limit_exceeded",
    "work_limit_exceeded", "block_limit_exceeded", "symbol_limit_exceeded",
    "trailing_data", "truncated_input", "invalid_stream", "checksum_mismatch",
    "dictionary_required", "dictionary_mismatch", "invalid_escape",
    "invalid_print", "internal_error"
  }
}

local function CountKeys(table_value)
  local count = 0
  for _ in pairs(table_value) do count = count + 1 end
  return count
end

Test("every number README.md publishes is the number this module enforces",
     function()
  for name, published in pairs(README_NUMBERS.presets) do
    local shipped = Guard.LIMIT_PRESETS[name]
    assert(type(shipped) == "table", "README names a preset " .. name)
    AssertEqual(CountKeys(shipped), CountKeys(published),
                name .. " publishes every key it has")
    for key, value in pairs(published) do
      AssertEqual(shipped[key], value, ("README %s.%s"):format(name, key))
    end

    -- The two formulas, applied to the *published* budgets rather than to the
    -- module's. Read off the module they would agree with themselves whatever
    -- the rule became.
    local symbols = README_NUMBERS.symbol_bits_per_byte *
                      published.max_input_bytes + README_NUMBERS.symbol_slack
    AssertEqual(published.max_symbols, symbols,
                name .. ": published max_symbols matches the published formula")
    AssertEqual(published.max_work_units,
                symbols + published.max_output_bytes +
                  README_NUMBERS.work_per_block * published.max_blocks, name ..
                  ": published max_work_units matches the published formula")
  end

  -- The block marks addon as the default, so DEFAULT_LIMITS must be it.
  for key, value in pairs(README_NUMBERS.presets.addon) do
    AssertEqual(Guard.DEFAULT_LIMITS[key], value,
                "README DEFAULT_LIMITS." .. key)
  end

  for key, value in pairs(README_NUMBERS.default_codec_limits) do
    AssertEqual(Guard.DEFAULT_CODEC_LIMITS[key], value,
                "README DEFAULT_CODEC_LIMITS." .. key)
  end
  AssertEqual(CountKeys(Guard.DEFAULT_CODEC_LIMITS),
              CountKeys(README_NUMBERS.default_codec_limits),
              "DEFAULT_CODEC_LIMITS publishes every key it has")

  -- The absolute print caps, reached the way the document reaches them: raise
  -- max_input_bytes on a policy and read what the instance derived.
  for _, row in ipairs(README_NUMBERS.print_caps) do
    local policy = {
      max_input_bytes = row.max_input_bytes,
      max_output_bytes = 8 * 1024 * 1024
    }
    local guard = assert(Guard.WithPolicy(policy))
    AssertEqual(guard:GetCodecLimits().print_max_input_bytes, row.print_cap,
                ("README print cap for %d bytes in"):format(row.max_input_bytes))
  end
end)

Test("ERRORS holds exactly the fifteen codes README.md lists", function()
  AssertEqual(#README_NUMBERS.error_codes, 15, "README lists fifteen codes")

  local published = {}
  for _, code in ipairs(README_NUMBERS.error_codes) do
    assert(not published[code], "duplicate in the README list: " .. code)
    published[code] = true
  end

  local shipped = {}
  for key, value in pairs(Guard.ERRORS) do
    AssertEqual(type(value), "string", "ERRORS." .. tostring(key) .. " type")
    assert(not shipped[value], "duplicate value in ERRORS: " .. value)
    shipped[value] = key
  end

  -- Set equality in both directions. One direction alone catches only half of
  -- what goes wrong: a code added without a doc update, and a code the
  -- document still lists after it was removed or renamed.
  for code in pairs(published) do
    assert(shipped[code],
           "README lists " .. code .. " and ERRORS has no such value")
  end
  for value, key in pairs(shipped) do
    assert(published[value],
           ("ERRORS.%s = %q is not in the README list"):format(tostring(key),
                                                               value))
  end
  AssertEqual(CountKeys(Guard.ERRORS), #README_NUMBERS.error_codes,
              "ERRORS is exactly the published set")

  -- Each key is its own value upper-cased, which is what makes the README's
  -- advice -- compare against the literal, not through this table -- something
  -- a reader can follow without a second lookup.
  for value, key in pairs(shipped) do
    AssertEqual(key, value:upper(), "ERRORS key for " .. value)
  end
end)

-- A deterministic high-entropy payload. math.random is not portable between
-- LuaJIT and PUC Lua 5.1 -- the same seed yields different bytes -- so this is
-- a Lehmer generator written out, for the same reason tests/FuzzTest.lua
-- carries its own. 16807 * (2^31 - 2) stays under 2^53, so every product is
-- exact in a double on both interpreters.
local function IncompressibleBytes(seed, count)
  local out, x = {}, seed % 2147483647
  if x == 0 then x = 1 end
  for i = 1, count do
    x = (16807 * x) % 2147483647
    out[i] = string.char(x % 256)
  end
  return table.concat(out)
end

-- The WithPolicy doc comment used to claim that the derived compression cap is
-- "what makes the compressed result fit the same policy's decompress input cap
-- on the way back". It does not, and the claim sat directly above the round
-- trip README.md recommends twice --
-- guard:DecompressDeflate(guard:CompressDeflate(message)). Deflate grows an
-- incompressible input, so the round trip fails on exactly the input the
-- compression cap admits at its boundary. Documented in
-- `## Compression and codecs`; pinned here so the comment cannot come back.
Test("an input at the compression cap can compress past the decompress cap",
     function()
  local guard = assert(Guard.WithPolicy())
  local cap = guard:GetPolicy().max_input_bytes
  AssertEqual(cap, README_NUMBERS.presets.addon.max_input_bytes,
              "the default cap is the published one")

  local payload = IncompressibleBytes(20260816, cap)
  AssertEqual(#payload, cap, "payload is exactly the cap")

  -- Accepted going out: the cap is on the bytes going in.
  local compressed = guard:CompressDeflate(payload)
  assert(type(compressed) == "string",
         "input at exactly the cap must still compress")
  -- The inequality is the claim. The exact length is asserted beside it so a
  -- change in it is visible rather than absorbed, not because seven bytes of
  -- growth is the property.
  assert(#compressed > cap,
         ("incompressible input must grow: %d in, %d out"):format(cap,
                                                                  #compressed))
  AssertEqual(#compressed, 65543, "observed compressed length")

  -- And refused coming back, by the same instance, with no argument passed.
  local output, decode_error = guard:DecompressDeflate(compressed)
  AssertEqual(output, nil, "the round trip must not decode")
  AssertEqual(decode_error, "input_limit_exceeded",
              "and must say why in the documented code")

  -- The member itself is well formed; only the budget refuses it. Without
  -- this the test would also pass if compression had produced garbage.
  local roomy = assert(Guard.WithPolicy({
    max_input_bytes = #compressed,
    max_output_bytes = 1024 * 1024
  }))
  assert(roomy:DecompressDeflate(compressed) == payload,
         "the member is a valid encoding of the payload")
end)

-- README.md `### Arity` publishes the return count of every public entry
-- point, and says the table lives there and nowhere else, so nothing else in
-- the tree pins it. Nesting faults are this repository's recurring bug class:
-- v1.1.2 exists because an encoder returned a second value into a decoder's
-- cap slot. Counts are taken with select("#") rather than by unpacking into
-- locals, because unpacking truncates and is what hid the original fault.
Test("select('#') on every row of README.md `### Arity`", function()
  local function Arity(...) return select("#", ...) end

  local text = "hello world hello world hello world"
  local compressed = Guard:CompressDeflate(text)
  local zlib = Guard:CompressZlib(text)
  local dictionary_text = string.rep("dictionary payload ", 4)
  local dictionary = Guard:CreateDictionary(dictionary_text, #dictionary_text,
                                            Guard:Adler32(dictionary_text))
  local deflate_with_dict = Guard:CompressDeflateWithDict(text, dictionary)
  local zlib_with_dict = Guard:CompressZlibWithDict(text, dictionary)
  local codec = assert(Guard:CreateCodec("\000", "\001", ""))
  local instance = assert(Guard.WithPolicy("addon"))
  local malformed = FromHex("ffffffff")

  -- A reserved set too large for one escape character to suffix. This is the
  -- `nil, text` half of the CreateCodec row, which is the one asymmetric row
  -- in the table and the reason it is worth reading twice.
  local crowded = {}
  for byte = 0, 199 do crowded[#crowded + 1] = string.char(byte) end
  crowded = table.concat(crowded)

  -- Built one call at a time rather than as one table literal, so that the
  -- comment naming each group of README rows stays attached to its group.
  local rows = {}
  local function Row(name, expected, call)
    rows[#rows + 1] = {name = name, expected = expected, call = call}
  end

  -- Compressors: `str, padding` on success, `nil, code` on a cap.
  Row("CompressDeflate success", 2,
      function() return Guard:CompressDeflate(text) end)
  Row("CompressZlib success", 2, function() return Guard:CompressZlib(text) end)
  Row("CompressDeflateWithDict success", 2,
      function() return Guard:CompressDeflateWithDict(text, dictionary) end)
  Row("CompressZlibWithDict success", 2,
      function() return Guard:CompressZlibWithDict(text, dictionary) end)
  Row("CompressDeflate failure", 2,
      function() return Guard:CompressDeflate(text, {max_input_bytes = 1}) end)

  -- Decompressors: `str, 0` on success, `nil, code` on failure.
  Row("DecompressDeflate success", 2,
      function() return Guard:DecompressDeflate(compressed) end)
  Row("DecompressZlib success", 2,
      function() return Guard:DecompressZlib(zlib) end)
  Row("DecompressDeflateWithDict success", 2, function()
    return Guard:DecompressDeflateWithDict(deflate_with_dict, dictionary)
  end)
  Row("DecompressZlibWithDict success", 2, function()
    return Guard:DecompressZlibWithDict(zlib_with_dict, dictionary)
  end)
  Row("DecompressDeflate failure", 2,
      function() return Guard:DecompressDeflate(malformed) end)

  -- Encoders: exactly one value, which is the v1.1.2 fix.
  Row("EncodeForPrint", 1, function() return Guard:EncodeForPrint(text) end)
  Row("EncodeForWoWAddonChannel", 1,
      function() return Guard:EncodeForWoWAddonChannel("a\000b") end)
  Row("EncodeForWoWChatChannel", 1,
      function() return Guard:EncodeForWoWChatChannel("a\000b") end)
  Row("codec:Encode", 1, function() return codec:Encode("a\000b") end)

  -- Codec decoders. The two channel decoders return a trailing nil on success
  -- where DecodeForPrint and codec:Decode return one value, which is the row
  -- the README singles out as the one that matters when a decode result is
  -- forwarded into another call's argument list.
  Row("DecodeForPrint success", 1,
      function() return Guard:DecodeForPrint(Guard:EncodeForPrint(text)) end)
  Row("DecodeForPrint failure", 2,
      function() return Guard:DecodeForPrint("!!!!") end)
  Row("DecodeForWoWAddonChannel success", 2, function()
    return Guard:DecodeForWoWAddonChannel(
             Guard:EncodeForWoWAddonChannel("a\000b"))
  end)
  Row("DecodeForWoWAddonChannel failure", 2,
      function() return Guard:DecodeForWoWAddonChannel("\001") end)
  Row("DecodeForWoWChatChannel success", 2, function()
    return
      Guard:DecodeForWoWChatChannel(Guard:EncodeForWoWChatChannel("a\000b"))
  end)
  Row("DecodeForWoWChatChannel failure", 2,
      function() return Guard:DecodeForWoWChatChannel("\001") end)
  Row("codec:Decode success", 1,
      function() return codec:Decode(codec:Encode("a\000b")) end)
  Row("codec:Decode failure", 2, function() return codec:Decode("\001") end)

  -- Constructors and inspection.
  Row("WithPolicy success", 1, function() return Guard.WithPolicy("addon") end)
  Row("WithPolicy failure", 2, function() return Guard.WithPolicy("nope") end)
  Row("CreateCodec success", 1,
      function() return Guard:CreateCodec("\000", "\001", "") end)
  Row("CreateCodec failure", 2,
      function() return Guard:CreateCodec(crowded, "\255", "") end)
  Row("CreateDictionary success", 1, function()
    return Guard:CreateDictionary(dictionary_text, #dictionary_text,
                                  Guard:Adler32(dictionary_text))
  end)
  Row("Adler32", 1, function() return Guard:Adler32(text) end)
  Row("GetPolicy", 1, function() return instance:GetPolicy() end)
  Row("GetCodecLimits", 1, function() return instance:GetCodecLimits() end)

  -- "The same shapes hold on a WithPolicy instance."
  Row("instance CompressDeflate success", 2,
      function() return instance:CompressDeflate(text) end)
  Row("instance DecompressDeflate success", 2,
      function() return instance:DecompressDeflate(compressed) end)
  Row("instance DecodeForPrint success", 1, function()
    return instance:DecodeForPrint(instance:EncodeForPrint(text))
  end)
  Row("instance DecodeForWoWAddonChannel success", 2, function()
    return instance:DecodeForWoWAddonChannel(
             instance:EncodeForWoWAddonChannel("a\000b"))
  end)

  -- Every row in README.md `### Arity` for an entry point this suite can
  -- reach, and the failure column too.
  AssertEqual(#rows, 34, "the arity table is covered row by row")
  for _, row in ipairs(rows) do
    AssertEqual(Arity(row.call()), row.expected, "README arity: " .. row.name)
  end

  -- The failure rows must actually be failing. An arity table is satisfied by
  -- a call that succeeded when it was meant to fail, and would then be
  -- pinning the wrong row.
  AssertEqual(select(2, Guard:CompressDeflate(text, {max_input_bytes = 1})),
              "input_limit_exceeded", "the compressor failure row failed")
  AssertEqual(select(2, Guard:DecompressDeflate(malformed)), "invalid_stream",
              "the decompressor failure row failed")
  AssertEqual(Guard.WithPolicy("nope"), nil, "the WithPolicy failure row")
  AssertEqual(Guard:CreateCodec(crowded, "\255", ""), nil,
              "the CreateCodec failure row")
  AssertEqual(type(select(2, Guard:CreateCodec(crowded, "\255", ""))), "string",
              "CreateCodec answers English text, not a code from ERRORS")
end)

Test("a successful decompress answers 0, never the compressor's padding",
     function()
  -- README.md `### Arity` publishes `str, 0` for every decompressor and
  -- `## Safe decoding` calls it the numeric status 0. A compressor's own
  -- second value is padding_bitlen, which ranges over 0..7, so a decompressor
  -- that forwarded it would still look like a success tuple.
  local seen_padding = {}
  for n = 1, 64 do
    local text = string.rep("ab", n) .. string.rep("z", n % 7)

    local deflate, padding = Guard:CompressDeflate(text)
    seen_padding[padding] = true
    local output, status = Guard:DecompressDeflate(deflate)
    assert(output == text, "deflate round trip at n = " .. n)
    AssertEqual(status, 0, "deflate status at n = " .. n)

    local zlib = Guard:CompressZlib(text)
    local zlib_output, zlib_status = Guard:DecompressZlib(zlib)
    assert(zlib_output == text, "zlib round trip at n = " .. n)
    AssertEqual(zlib_status, 0, "zlib status at n = " .. n)
  end

  -- The claim names 4 to 6 specifically, so the loop has to have reached
  -- them. Otherwise this test asserts 0 == 0 over a padding of zero.
  for _, padding in ipairs({4, 5, 6}) do
    assert(seen_padding[padding],
           ("this loop must reach padding_bitlen %d, or the claim is empty"):format(
             padding))
  end
end)

-- DecodeForPrint strips leading and trailing control characters and spaces
-- before decoding, which is inherited from upstream and went undocumented
-- until the audit in `## M` of dev_docs/roadmap.md. It is the one lenient
-- decode in a fork whose headline is strict rejection, so it is pinned as
-- well as written down: a later tightening should be a decision, not a
-- silent break for every caller pasting a string with a newline on it.
Test("DecodeForPrint strips the two ends and nothing else", function()
  local payload = "round trip payload"
  local encoded = Guard:EncodeForPrint(payload)

  AssertEqual(Guard:DecodeForPrint(encoded), payload, "unpadded")
  AssertEqual(Guard:DecodeForPrint("  " .. encoded .. "\n"), payload,
              "leading spaces and a trailing newline")
  AssertEqual(Guard:DecodeForPrint("\t\r\n " .. encoded .. " \t\r\n"), payload,
              "tabs and carriage returns at both ends")

  -- Only the ends. An interior space is not forgiven, and the length rule is
  -- not what catches it: this substitution keeps the length unchanged.
  local interior = encoded:sub(1, 4) .. " " .. encoded:sub(6)
  AssertEqual(#interior, #encoded, "the interior case keeps the length")
  AssertEqual(select(2, Guard:DecodeForPrint(interior)), "invalid_print",
              "an interior space is still invalid_print")

  -- The cap is applied to the string as passed, before the strip, so padding
  -- counts against it.
  local cap = #encoded + 1
  AssertEqual(select(2, Guard:DecodeForPrint("  " .. encoded, cap)),
              "input_limit_exceeded", "padding counts against the cap")
  AssertEqual(Guard:DecodeForPrint(" " .. encoded, cap), payload,
              "padding inside the cap still decodes")

  -- The channel decoders strip nothing: a leading space is data there, and
  -- comes back as data.
  AssertEqual(Guard:DecodeForWoWAddonChannel(
                " " .. Guard:EncodeForWoWAddonChannel(payload)), " " .. payload,
              "the addon channel decoder strips nothing")
  AssertEqual(Guard:DecodeForWoWChatChannel(
                " " .. Guard:EncodeForWoWChatChannel(payload)), " " .. payload,
              "the chat channel decoder strips nothing")
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

-- Item J. max_symbols and max_work_units are backstops on the other three
-- budgets rather than budgets a caller picks, so an omitted key derives from
-- what the decoder can reach under the caps the caller did name. The rule is
-- restated here rather than read off the module: a test that asks the module
-- what it derives and then checks it derived that would pass on any rule.
local function DerivedSymbols(max_input_bytes)
  -- Every Huffman decode consumes at least one input bit, plus the decodes
  -- that can still be charged after the input is exhausted -- one dynamic
  -- code-length alphabet, nlen + ndist at most 286 + 30, and one
  -- literal/length plus one distance symbol in the body.
  return 8 * max_input_bytes + 286 + 30 + 2
end

local function DerivedWork(max_symbols, max_output_bytes, max_blocks)
  -- One work unit per symbol, one per output byte, and per block one for the
  -- block plus ncode + nlen + ndist at most 19 + 286 + 30 for a dynamic
  -- header, which is 336.
  return max_symbols + max_output_bytes + 336 * max_blocks
end

-- A dynamic block header cut off the instant its code-length loop begins.
-- That loop does not test ReaderBitlenLeft() at all, so it decodes its whole
-- alphabet -- nlen + ndist = 286 + 30 = 316 symbols -- off the end of a
-- four-byte member. This is the shape the slack term above exists for: the
-- member is malformed, and a backstop on decode volume must not be what
-- reports it.
local function TruncatedDynamicHeader()
  local write, finish = BitWriter()
  write(1, 1) -- BFINAL
  write(2, 2) -- BTYPE 10, dynamic
  write(286 - 257, 5) -- HLIT  -> nlen  = 286
  write(30 - 1, 5) -- HDIST -> ndist = 30
  write(4 - 4, 4) -- HCLEN -> ncode = 4
  -- Four two-bit code-length codes, so every all-zero decode past the end of
  -- the member yields code-length symbol 0 and advances the loop by one.
  for _ = 1, 4 do write(2, 3) end
  return finish()
end

Test("the derived backstops track the policy instead of a constant", function()
  -- The shipped presets carry the derived numbers, so naming a preset and
  -- writing out its three budgets enforce the same two backstops.
  for _, name in ipairs({"addon", "generous"}) do
    local preset = Guard.LIMIT_PRESETS[name]
    local symbols = DerivedSymbols(preset.max_input_bytes)
    AssertEqual(preset.max_symbols, symbols, name .. " max_symbols is derived")
    AssertEqual(preset.max_work_units, DerivedWork(symbols,
                                                   preset.max_output_bytes,
                                                   preset.max_blocks),
                name .. " max_work_units is derived")
  end

  -- The surprise this replaces. Raising input and output alone used to inherit
  -- the addon work cap and refuse a member that both raised budgets admit,
  -- reporting a limit the caller never named and could not see in its policy.
  local payload = string.rep(
                    "the quick brown fox jumps over the lazy dog 0123456789",
                    40000)
  local member = Guard:CompressDeflate(payload)
  local raised = {
    max_input_bytes = 64 * 1024 * 1024,
    max_output_bytes = 64 * 1024 * 1024
  }
  local resolved = assert(Guard.WithPolicy(raised)):GetPolicy()
  AssertEqual(resolved.max_symbols, DerivedSymbols(raised.max_input_bytes),
              "a raised input cap raises the symbol backstop")
  AssertEqual(resolved.max_work_units, DerivedWork(resolved.max_symbols,
                                                   raised.max_output_bytes,
                                                   resolved.max_blocks),
              "a raised partial policy derives its work backstop")
  AssertEqual(Guard:DecompressDeflate(member, raised), payload,
              "a raised partial policy must not trip a backstop it never named")

  -- Both keys stay explicitly settable, and an explicit value is used as
  -- given rather than widened to the derived one.
  AssertEqual(select(2, Guard:DecompressDeflate(member, {
    max_input_bytes = 64 * 1024 * 1024,
    max_output_bytes = 64 * 1024 * 1024,
    max_symbols = 1
  })), Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "an explicit max_symbols below the derived one still binds")
  AssertEqual(select(2, Guard:DecompressDeflate(member, {
    max_input_bytes = 64 * 1024 * 1024,
    max_output_bytes = 64 * 1024 * 1024,
    max_work_units = 1
  })), Guard.ERRORS.WORK_LIMIT_EXCEEDED,
              "an explicit max_work_units below the derived one still binds")

  -- An explicit symbol budget is what the work backstop is derived from, so
  -- tightening one tightens the other rather than leaving work above a bound
  -- symbols can no longer reach.
  local tightened = assert(Guard.WithPolicy({max_symbols = 5})):GetPolicy()
  AssertEqual(tightened.max_symbols, 5, "an explicit symbol budget is kept")
  AssertEqual(tightened.max_work_units,
              DerivedWork(5, tightened.max_output_bytes, tightened.max_blocks),
              "the work backstop follows an explicit symbol budget")

  -- The slack term, at the tight edge. ReaderBitlenLeft() < 0 is tested after
  -- a symbol is decoded, and not at all inside the code-length loop, so this
  -- four-byte member charges 316 symbols against 32 input bits. Without the
  -- slack the derived cap fires here and reports symbol_limit_exceeded on a
  -- member whose fault is that it is malformed.
  local truncated = TruncatedDynamicHeader()
  AssertEqual(#truncated, 4, "the truncated header must stay four bytes")
  for _, policy in ipairs({{max_input_bytes = #truncated}, "addon", "generous"}) do
    local _, decode_error = Guard:DecompressDeflate(truncated, policy)
    assert(decode_error ~= Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
           "a truncated header must not be reported as a symbol budget")
    AssertEqual(decode_error, Guard.ERRORS.INVALID_STREAM,
                "a truncated header is a malformed stream")
  end
end)

-- Item K. Items I and J compose into a defect neither one has on its own.
-- Item I made WithPolicy(name):GetPolicy() -> edit -> WithPolicy(policy) the
-- recommended derivation, because a hand pairs() copy launders a poisoned
-- preset. Item J made the two backstops derive from max_input_bytes when the
-- key is omitted. GetPolicy() returns all five keys as explicit values, so
-- raising max_input_bytes on the copy left the backstops frozen at the source
-- preset's numbers and a member both binding budgets admit was refused by one
-- the caller never named -- exactly what item J existed to remove.
--
-- Provenance is what tells the two cases apart: the module records the
-- backstop numbers it wrote into a table it handed out, and a value still
-- equal to the recorded one is read as an omission and re-derived. Any other
-- number is the caller's and is used as given.
Test("a derived backstop re-derives through a policy copy", function()
  -- huffman_only gives a member with a high symbol-to-byte ratio, so 192 KiB
  -- of input decodes to 700 KB and needs more symbols than the addon preset's
  -- backstop allows. Both budgets a caller would raise admit it.
  local payload = string.rep("aaab", 175000)
  local member = Guard:CompressDeflate(payload,
                                       {level = 6, strategy = "huffman_only"})
  local raised_input = 192 * 1024
  local raised_output = 8 * 1024 * 1024
  assert(#member < raised_input, "the member must fit the raised input cap")
  assert(#payload < raised_output, "the payload must fit the raised output cap")
  assert(#payload > Guard.LIMIT_PRESETS.addon.max_symbols,
         "the member must need more symbols than the addon backstop allows")

  -- The reproduction, over every policy shape a GetPolicy() copy can come
  -- from: a preset name, a registered LIMIT_PRESETS entry, the defaults, and
  -- a caller's own partial table. Item H resolves the first three from private
  -- storage by identity, so provenance has to ride alongside that rather than
  -- through the table's contents.
  local sources = {
    {"a preset name", "addon"}, {"a registered preset table", nil},
    {"the default policy", false}, {
      "a caller's own table",
      {max_input_bytes = 64 * 1024, max_output_bytes = 512 * 1024}
    }
  }
  sources[2][2] = Guard.LIMIT_PRESETS.addon
  for _, source in ipairs(sources) do
    local label, policy = source[1], source[2]
    if policy == false then policy = nil end
    local copy = assert(Guard.WithPolicy(policy)):GetPolicy()
    copy.max_input_bytes = raised_input
    copy.max_output_bytes = raised_output
    local guard = assert(Guard.WithPolicy(copy), "policy from " .. label)
    AssertEqual(guard:GetPolicy().max_symbols, DerivedSymbols(raised_input),
                "the symbol backstop re-derives through a copy of " .. label)
    AssertEqual(guard:GetPolicy().max_work_units, DerivedWork(
                  DerivedSymbols(raised_input), raised_output, copy.max_blocks),
                "the work backstop re-derives through a copy of " .. label)
    AssertEqual(guard:DecompressDeflate(member), payload,
                "a raised copy of " .. label .. " must decode the member")
  end

  -- The hazard. A backstop the caller wrote is a choice, not a leftover, and
  -- re-deriving over it would delete the only budget that charges per decode
  -- rather than per byte. The test is on the value: any number other than the
  -- one this module wrote into that table is the caller's.
  local explicit = assert(Guard.WithPolicy("addon")):GetPolicy()
  explicit.max_input_bytes = raised_input
  explicit.max_output_bytes = raised_output
  explicit.max_symbols = 4242
  local bound = assert(Guard.WithPolicy(explicit))
  AssertEqual(bound:GetPolicy().max_symbols, 4242,
              "an explicit max_symbols on a copy is honoured")
  AssertEqual(bound:GetPolicy().max_work_units,
              DerivedWork(4242, raised_output, explicit.max_blocks),
              "the work backstop follows an explicit max_symbols on a copy")
  AssertEqual(select(2, bound:DecompressDeflate(member)),
              Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "an explicit max_symbols on a copy can still refuse")

  explicit.max_symbols = nil
  explicit.max_work_units = 7
  AssertEqual(select(2, assert(Guard.WithPolicy(explicit)):DecompressDeflate(
                       member)), Guard.ERRORS.WORK_LIMIT_EXCEEDED,
              "an explicit max_work_units on a copy can still refuse")

  -- Provenance survives a round trip. The recommended idiom is a copy, an
  -- edit and a handback, and a caller who sizes a policy in two steps -- or
  -- reads one back out of an instance built from an earlier copy -- must not
  -- find the backstops frozen one step later than they used to be.
  local trip = assert(Guard.WithPolicy("addon")):GetPolicy()
  for _ = 1, 3 do trip = assert(Guard.WithPolicy(trip)):GetPolicy() end
  trip.max_input_bytes = raised_input
  trip.max_output_bytes = raised_output
  AssertEqual(assert(Guard.WithPolicy(trip)):GetPolicy().max_symbols,
              DerivedSymbols(raised_input),
              "a derived backstop survives a GetPolicy round trip")

  -- And so does an explicit one, in the other direction.
  local kept = assert(Guard.WithPolicy({max_symbols = 5})):GetPolicy()
  for _ = 1, 3 do kept = assert(Guard.WithPolicy(kept)):GetPolicy() end
  kept.max_input_bytes = raised_input
  AssertEqual(assert(Guard.WithPolicy(kept)):GetPolicy().max_symbols, 5,
              "an explicit backstop does not decay into a derived one")

  -- Provenance is the module's record of a table it handed out, not a
  -- property of the numbers. A caller's own table holding the same numbers
  -- claims nothing, and is enforced exactly as written.
  local forged = {
    max_input_bytes = raised_input,
    max_output_bytes = raised_output,
    max_blocks = Guard.LIMIT_PRESETS.addon.max_blocks,
    max_symbols = Guard.LIMIT_PRESETS.addon.max_symbols,
    max_work_units = Guard.LIMIT_PRESETS.addon.max_work_units
  }
  AssertEqual(assert(Guard.WithPolicy(forged)):GetPolicy().max_symbols,
              Guard.LIMIT_PRESETS.addon.max_symbols,
              "a caller table holding the preset numbers is used as written")
  AssertEqual(select(2, Guard:DecompressDeflate(member, forged)),
              Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
              "a caller table holding the preset numbers still binds")

  -- A backstop the caller writes is still validated. Provenance decides
  -- whether a value is read, never whether it is checked.
  local invalid = assert(Guard.WithPolicy("addon")):GetPolicy()
  for _, bad in ipairs({-1, 0, 1.5, math.huge}) do
    invalid.max_symbols = bad
    AssertEqual(Guard.WithPolicy(invalid), nil,
                "a caller's malformed backstop on a copy is still refused")
  end
end)

-- Item L. The resolver read a policy with limits[key], which fires __index,
-- and checked for unknown keys with pairs(limits), which does not see an
-- inherited key. Two consequences, both pinned below: a policy whose __index
-- raises took WithPolicy out with it where the docs promise a report, and a
-- policy whose own contents are {} enforced whatever its metatable answered.
-- A metatabled policy is now invalid_argument.
Test("a policy read through a metatable is refused, not half-read", function()
  -- Half one. WithPolicy calls the resolver outside any pcall, so a raising
  -- __index used to propagate out of a call documented to answer nil, code.
  -- The decompressors wrap the same call and answered internal_error, which
  -- named the containment rather than the fault.
  local raiser = setmetatable({max_input_bytes = 4096, max_output_bytes = 8192},
                              {
    __index = function(_, key) error("undeclared " .. tostring(key)) end
  })
  local ok, instance, code = pcall(Guard.WithPolicy, raiser)
  assert(ok, "WithPolicy must answer a raising policy, not raise with it")
  AssertEqual(instance, nil, "a raising policy builds no instance")
  AssertEqual(code, Guard.ERRORS.INVALID_ARGUMENT,
              "a raising policy is an invalid policy")
  AssertEqual(select(2, Guard:DecompressDeflate(FromHex("330400"), raiser)),
              Guard.ERRORS.INVALID_ARGUMENT,
              "the decompressors name the fault, not the containment")

  -- Half two, and the one that mattered: a silent loosening. The visible
  -- content of this policy is {}, and it used to enforce 64x the default
  -- budget -- setmetatable({}, {__index = defaults}) is the saved-variables
  -- idiom, so this is not a contrived table. Asserted on a real decode: the
  -- member is inside the inherited output cap and well past the default one.
  local payload = string.rep("a", 700000)
  local member = Guard:CompressDeflate(payload)
  local budgets = {
    max_input_bytes = 4 * 1024 * 1024,
    max_output_bytes = 8 * 1024 * 1024,
    max_blocks = 4096
  }
  assert(#payload > Guard.DEFAULT_LIMITS.max_output_bytes,
         "the payload must exceed the default output budget")
  assert(#payload < budgets.max_output_bytes,
         "the payload must fit the inherited output budget")
  AssertEqual(select(2, Guard:DecompressDeflate(member)),
              Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "the default budget refuses the member")

  local inherited = setmetatable({}, {__index = budgets})
  AssertEqual(Guard.WithPolicy(inherited), nil,
              "an inherited budget builds no instance")
  local output, decode_error = Guard:DecompressDeflate(member, inherited)
  AssertEqual(output, nil, "an inherited budget decodes nothing")
  AssertEqual(decode_error, Guard.ERRORS.INVALID_ARGUMENT,
              "an inherited budget is refused rather than enforced")

  -- Written out, the same numbers are a policy this module can validate, and
  -- they work. This is the documented migration: the caller performs the
  -- read, so their own defaults apply, and hands over a table whose contents
  -- are all of it. Without this the fix would read as a budget ceiling.
  local flattened = assert(Guard.WithPolicy(
                             {
      max_input_bytes = inherited.max_input_bytes,
      max_output_bytes = inherited.max_output_bytes,
      max_blocks = inherited.max_blocks
    }), "a flattened policy must build an instance")
  AssertEqual(flattened:DecompressDeflate(member), payload,
              "a flattened policy enforces what the caller meant")

  -- The unknown-key check is the other half of the disagreement, and it is
  -- the half that cannot be fixed by reading harder: pairs() cannot enumerate
  -- what an __index would answer, so a budget misspelled on a defaults table
  -- was accepted and then silently ignored.
  AssertEqual(Guard.WithPolicy({max_output_byte = 4096}), nil,
              "a misspelled budget written directly is refused")
  AssertEqual(Guard.WithPolicy(setmetatable({}, {
    __index = {max_output_byte = 4096}
  })), nil, "a misspelled budget inherited is refused too")

  -- Any metatable, not just one carrying __index. __metatable makes the real
  -- metatable unreachable, so a narrower test could be lied to by exactly the
  -- table it most needs to catch.
  for index, hidden in ipairs({
    setmetatable({max_blocks = 1}, {__tostring = function() return "" end}),
    setmetatable({max_blocks = 1}, {__index = budgets, __metatable = "hidden"})
  }) do
    AssertEqual(Guard.WithPolicy(hidden), nil, "metatabled policy " .. index)
    AssertEqual(select(2, Guard:DecompressDeflate(FromHex("330400"), hidden)),
                Guard.ERRORS.INVALID_ARGUMENT,
                "metatabled policy " .. index .. " at the limits parameter")
  end

  -- Composition with item H. A registered table resolves by identity and its
  -- contents are never read, so a metatable stapled onto one is a write like
  -- any other and must stay inert. The check sits after the registry lookup
  -- for this reason: ahead of it, one setmetatable() elsewhere in the state
  -- would turn every consumer's WithPolicy(LIMIT_PRESETS.addon) into
  -- invalid_argument -- a loosening closed by opening a denial.
  local G = FreshGuard()
  setmetatable(G.LIMIT_PRESETS.addon, {__index = budgets})
  setmetatable(G.DEFAULT_LIMITS, {__index = budgets})
  AssertEqual(assert(G.WithPolicy(G.LIMIT_PRESETS.addon),
                     "a metatabled preset must still resolve"):GetPolicy().max_input_bytes,
              64 * 1024, "a metatable on a registered preset is inert")
  AssertEqual(
    assert(G.WithPolicy(G.DEFAULT_LIMITS)):GetPolicy().max_output_bytes,
    512 * 1024, "a metatable on DEFAULT_LIMITS is inert")

  -- Composition with item K. Every table this module hands out is bare, so
  -- the recommended copy-edit-handback idiom never meets the new check and
  -- the backstops still re-derive through it.
  local trip = assert(Guard.WithPolicy("addon")):GetPolicy()
  AssertEqual(getmetatable(trip), nil, "a GetPolicy copy carries no metatable")
  for _ = 1, 3 do trip = assert(Guard.WithPolicy(trip)):GetPolicy() end
  trip.max_input_bytes = 192 * 1024
  AssertEqual(assert(Guard.WithPolicy(trip)):GetPolicy().max_symbols,
              DerivedSymbols(192 * 1024),
              "a backstop still re-derives through a round-tripped copy")
end)

-- Item H. LIMIT_PRESETS and DEFAULT_LIMITS are copies of the private limit
-- tables, so writing to one cannot reach the module's own default path -- the
-- tests above pin that. What it did reach was a policy a caller derives from
-- one, because README documents WithPolicy(LIMIT_PRESETS.generous) and that
-- read returned whatever a consumer had written by then. Each exported table
-- is now registered against the private table it names, and a registered
-- table resolves to that private source rather than to its own contents.
--
-- These poison a module and never put it back, so they build fresh instances
-- with FreshGuard rather than writing to the suite-level Guard.
Test("a mutated preset cannot loosen a derived policy", function()
  local G = FreshGuard()
  local hostile = MatchBomb(4096)
  local hostile_output = 1 + 258 * 4096
  assert(#hostile < G.LIMIT_PRESETS.addon.max_input_bytes,
         "the bomb must clear the input cap to be a real test")
  assert(hostile_output > G.LIMIT_PRESETS.addon.max_output_bytes,
         "the bomb must exceed the addon output cap")

  -- One line, from any other addon in the state, handing an addon-preset
  -- instance a 512 MB output cap. This is the direction that matters.
  G.LIMIT_PRESETS.addon.max_output_bytes = 512 * 1024 * 1024
  local guard = assert(G.WithPolicy(G.LIMIT_PRESETS.addon))
  AssertEqual(guard:GetPolicy().max_output_bytes, 512 * 1024,
              "instance policy after a loosening write")
  AssertEqual(select(2, guard:DecompressDeflate(hostile)),
              G.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "a loosened preset must not decode a bomb")

  -- The same read through the limits parameter, which is the same validator.
  AssertEqual(select(2, G:DecompressDeflate(hostile, G.LIMIT_PRESETS.addon)),
              G.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "limits parameter after a loosening write")

  -- DEFAULT_LIMITS is the same class of object and carries the same anchor.
  G.DEFAULT_LIMITS.max_output_bytes = 512 * 1024 * 1024
  AssertEqual(select(2, G:DecompressDeflate(hostile, G.DEFAULT_LIMITS)),
              G.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "DEFAULT_LIMITS after a loosening write")
end)

Test("a mutated preset cannot tighten a derived policy", function()
  local G = FreshGuard()
  local fixed = FromHex("330400")
  local generous_output = G.LIMIT_PRESETS.generous.max_output_bytes
  local addon_input = G.LIMIT_PRESETS.addon.max_input_bytes

  -- The reproduction from dev_docs/roadmap.md, item H, verbatim.
  G.LIMIT_PRESETS.generous.max_output_bytes = 4096
  local guard = assert(G.WithPolicy(G.LIMIT_PRESETS.generous))
  AssertEqual(guard:GetPolicy().max_output_bytes, generous_output,
              "instance policy after a tightening write")

  G.LIMIT_PRESETS.addon.max_input_bytes = 1
  AssertEqual(G:DecompressDeflate(fixed, G.LIMIT_PRESETS.addon), "1",
              "limits parameter after a tightening write")
  AssertEqual(
    assert(G.WithPolicy(G.LIMIT_PRESETS.addon)):GetPolicy().max_input_bytes,
    addon_input, "instance input cap after a tightening write")

  G.DEFAULT_LIMITS.max_input_bytes = 1
  AssertEqual(G:DecompressDeflate(fixed, G.DEFAULT_LIMITS), "1",
              "DEFAULT_LIMITS after a tightening write")

  -- A key this module has no meaning for is not a policy error either. The
  -- exported table's contents are not read at all, so nothing written to it
  -- can be rejected, any more than it can be enforced.
  G.LIMIT_PRESETS.generous.unknown_key = 1
  assert(G.WithPolicy(G.LIMIT_PRESETS.generous),
         "an exported preset stays a valid policy however it is written to")
end)

Test("exported limit tables stay ordinary tables", function()
  -- The alternative fix -- a fresh copy per access behind __index -- would
  -- have broken every assertion below, silently: pairs() over an empty proxy
  -- yields nothing, and Lua 5.1 and LuaJIT have no __pairs to soften it.
  -- tests/FuzzTest.lua and the "limit presets" test above both iterate these.
  assert(Guard.LIMIT_PRESETS.addon == Guard.LIMIT_PRESETS.addon,
         "a preset must be one table, not a copy per access")
  local by_table = {[Guard.LIMIT_PRESETS.generous] = "generous"}
  AssertEqual(by_table[Guard.LIMIT_PRESETS.generous], "generous",
              "a preset must still work as a table key")
  assert(next(Guard.LIMIT_PRESETS) ~= nil, "LIMIT_PRESETS must be iterable")
  local names = 0
  for _ in pairs(Guard.LIMIT_PRESETS) do names = names + 1 end
  AssertEqual(names, 2, "LIMIT_PRESETS entry count")
  local keys = 0
  for _ in pairs(Guard.LIMIT_PRESETS.addon) do keys = keys + 1 end
  AssertEqual(keys, 5, "preset key count")
  for _ in pairs(Guard.DEFAULT_LIMITS) do keys = keys - 1 end
  AssertEqual(keys, 0, "DEFAULT_LIMITS key count")
  AssertEqual(getmetatable(Guard.LIMIT_PRESETS), nil, "no proxy metatable")
  AssertEqual(getmetatable(Guard.LIMIT_PRESETS.addon), nil,
              "no proxy metatable on a preset")
  assert(Guard.DEFAULT_LIMITS ~= Guard.LIMIT_PRESETS.addon,
         "DEFAULT_LIMITS and the addon preset stay distinct tables")
end)

Test("a caller's own copy of a preset still customises", function()
  -- What the anchor costs, stated as a test: writing to the shipped table no
  -- longer customises anything, and a table of the caller's own is enforced
  -- exactly as written. This is also the benign face of what identity cannot
  -- anchor -- a hand-rolled pairs() copy of a poisoned entry is enforced the
  -- same way, because it is a caller's table. The test below pins the
  -- derivation shape README recommends instead.
  local mine = {}
  for key, value in pairs(Guard.LIMIT_PRESETS.generous) do mine[key] = value end
  mine.max_output_bytes = 4096
  AssertEqual(assert(Guard.WithPolicy(mine)):GetPolicy().max_output_bytes, 4096,
              "a copy is the caller's table and is enforced as written")
end)

Test("a preset named by string is beyond a consumer's reach", function()
  local G = FreshGuard()
  local fixed = FromHex("330400")
  local generous_output = G.LIMIT_PRESETS.generous.max_output_bytes
  local addon_input = G.LIMIT_PRESETS.addon.max_input_bytes

  AssertEqual(assert(G.WithPolicy("generous")):GetPolicy().max_output_bytes,
              generous_output, "named preset policy")
  AssertEqual(assert(G:WithPolicy("addon")):GetPolicy().max_input_bytes,
              addon_input, "named preset, colon call")
  AssertEqual(G:DecompressDeflate(fixed, "generous"), "1",
              "named preset as the limits parameter")

  -- An unrecognised name is an invalid policy, reported the way every other
  -- invalid policy is rather than raised or silently defaulted.
  AssertEqual(select(2, G:DecompressDeflate(fixed, "none")),
              G.ERRORS.INVALID_ARGUMENT, "unknown preset name")
  local instance, code = G.WithPolicy("")
  AssertEqual(instance, nil, "empty preset name builds no instance")
  AssertEqual(code, G.ERRORS.INVALID_ARGUMENT, "empty preset name code")

  -- Identity anchors a table this module handed out. It cannot anchor an
  -- entry a consumer replaced wholesale: that table is indistinguishable from
  -- a policy the caller wrote, and is enforced as written. That is the
  -- boundary the name shape steps around, pinned here so a later change does
  -- not move it quietly.
  G.LIMIT_PRESETS = {generous = {max_output_bytes = 4096}}
  AssertEqual(
    assert(G.WithPolicy(G.LIMIT_PRESETS.generous)):GetPolicy().max_output_bytes,
    4096, "a substituted entry is a caller policy, not a preset")
  AssertEqual(assert(G.WithPolicy("generous")):GetPolicy().max_output_bytes,
              generous_output, "a name resolves past a substituted table")

  -- A substituted entry is not always merely unrecognised. Point one preset at
  -- another and the table there is registered, so it resolves canonically --
  -- to the wrong preset's private numbers. Same class, same answer, worth
  -- pinning because the failure looks like a success.
  local H = FreshGuard()
  local addon_output = H.LIMIT_PRESETS.addon.max_output_bytes
  H.LIMIT_PRESETS.addon = H.LIMIT_PRESETS.generous
  AssertEqual(
    assert(H.WithPolicy(H.LIMIT_PRESETS.addon)):GetPolicy().max_output_bytes,
    generous_output,
    "a preset substituted with another preset resolves to that one")
  AssertEqual(assert(H.WithPolicy("addon")):GetPolicy().max_output_bytes,
              addon_output, "a name resolves past a substituted preset")
end)

Test("the recommended derivation starts from the private numbers", function()
  -- README's ## Safe decoding derives a policy from
  -- WithPolicy(name):GetPolicy() rather than from a pairs() copy of a shipped
  -- table. Identity anchors a table handed back, not values already read out
  -- of one, so the copy has to be made from something no consumer can write
  -- to, and GetPolicy() is that: the private numbers a name resolved to.
  local G = FreshGuard()
  local bomb = MatchBomb(4096)
  local bomb_output = 1 + 258 * 4096
  local addon_input = G.LIMIT_PRESETS.addon.max_input_bytes
  local addon_output = G.LIMIT_PRESETS.addon.max_output_bytes
  assert(#bomb < addon_input, "the bomb must clear the addon input cap")
  assert(bomb_output > addon_output, "the bomb must exceed the addon output cap")

  -- Poisoned both ways at once: the entry is written through to loosen the
  -- output cap and to tighten the input cap, and then replaced wholesale --
  -- the one substitution identity cannot anchor.
  G.LIMIT_PRESETS.addon.max_output_bytes = 512 * 1024 * 1024
  G.LIMIT_PRESETS.addon.max_input_bytes = 1
  G.LIMIT_PRESETS.addon = {
    max_output_bytes = 512 * 1024 * 1024,
    max_input_bytes = 1
  }

  local policy = assert(G.WithPolicy("addon")):GetPolicy()
  AssertEqual(policy.max_output_bytes, addon_output,
              "derived output cap under a poisoned entry")
  AssertEqual(policy.max_input_bytes, addon_input,
              "derived input cap under a poisoned entry")

  -- What a policy built from it enforces, which is the assertion that matters:
  -- a laundered 512 MB output cap decodes the bomb, and a laundered input cap
  -- of 1 rejects the three-byte fixed block.
  local derived = assert(G.WithPolicy(policy))
  AssertEqual(select(2, derived:DecompressDeflate(bomb)),
              G.ERRORS.OUTPUT_LIMIT_EXCEEDED,
              "a derived policy enforces the private output cap")
  AssertEqual(derived:DecompressDeflate(FromHex("330400")), "1",
              "a derived policy enforces the private input cap")

  -- And it is a real derivation rather than an inert one: the caller's own
  -- write to the copy is enforced.
  policy.max_output_bytes = bomb_output
  local raised = assert(assert(G.WithPolicy(policy)):DecompressDeflate(bomb))
  AssertEqual(#raised, bomb_output, "the caller's own raise is enforced")
end)

-- Item I. ERRORS sat in the same ## Security scope sentence as the two limit
-- tables item H anchored, and it did not get -- and cannot get -- the same
-- protection. Identity anchoring works there because this module does the
-- reading: a table handed back to the policy validator is resolved from
-- private storage instead of from its contents. An error code is read by the
-- consumer, and nothing of ours is in the way of that read.
--
-- What survives a hostile write is therefore the returned code, and that is
-- what these assert -- on real decode outcomes, and against string literals,
-- because a code read back out of the poisoned table would assert nothing.
Test("a hostile write to ERRORS cannot change the code a decode returns",
     function()
  local G = FreshGuard()
  local bomb = MatchBomb(4096)
  local bomb_output = 1 + 258 * 4096
  assert(#bomb < G.LIMIT_PRESETS.addon.max_input_bytes,
         "the bomb must clear the input cap to be a real test")
  assert(bomb_output > G.LIMIT_PRESETS.addon.max_output_bytes,
         "the bomb must exceed the addon output cap")

  -- What one line from any other addon in the state can do to the table.
  for key in pairs(G.ERRORS) do G.ERRORS[key] = "poisoned_" .. key end

  local output, code = G:DecompressDeflate(bomb, "addon")
  AssertEqual(output, nil, "a poisoned ERRORS table must not change the outcome")
  AssertEqual(code, "output_limit_exceeded",
              "the returned code comes from the private table")

  -- Every other failure family reads the same private table: argument
  -- validation, the stream paths, the codec decoders, the input cap, and the
  -- contained-exception path's neighbours.
  AssertEqual(select(2, G:DecompressDeflate(42)), "invalid_argument",
              "argument validation code under a poisoned table")
  AssertEqual(select(2, G:DecompressDeflate(FromHex("06"))), "invalid_stream",
              "malformed stream code under a poisoned table")
  AssertEqual(select(2, G:DecompressDeflate(FromHex("010100feff"))),
              "truncated_input", "truncated code under a poisoned table")
  AssertEqual(select(2, G:DecompressDeflate(FromHex("33040058"))),
              "trailing_data", "trailing code under a poisoned table")
  AssertEqual(select(2, G:DecompressDeflate(bomb, {max_input_bytes = 1})),
              "input_limit_exceeded", "input cap code under a poisoned table")
  AssertEqual(select(2, G:DecodeForPrint("!")), "invalid_print",
              "codec decoder code under a poisoned table")

  -- A compressor answers with a code for an over-budget input too, and reads
  -- the same private table to do it.
  AssertEqual(select(2, G:CompressDeflate(string.rep("x", 4096),
                                          {max_input_bytes = 1024})),
              "input_limit_exceeded", "compressor code under a poisoned table")

  -- Replacing the table outright is the cheaper write and is no different.
  G.ERRORS = {}
  AssertEqual(select(2, G:DecompressDeflate(bomb, "addon")),
              "output_limit_exceeded",
              "the returned code survives ERRORS being replaced")

  -- The other half, pinned deliberately rather than left to be discovered:
  -- comparing through the public table is what a write breaks, and this
  -- module cannot stop it. README ### What mutation resistance covers says so
  -- in as many words. If a later change ever makes this equality hold, that is
  -- a strengthening -- update the claim there with it, do not delete the line.
  local H = FreshGuard()
  H.ERRORS.OUTPUT_LIMIT_EXCEEDED = "poisoned"
  local _, live = H:DecompressDeflate(bomb, "addon")
  AssertEqual(live, "output_limit_exceeded", "second module returns the code")
  assert(live ~= H.ERRORS.OUTPUT_LIMIT_EXCEEDED,
         "the public table is writable; the docs must not claim otherwise")
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
