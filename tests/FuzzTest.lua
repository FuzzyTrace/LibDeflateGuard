-- Randomized decode-path tests for LibDeflateGuard.
-- Run from the repository root: lua tests/FuzzTest.lua
--
-- Every decoder is driven with valid, truncated, mutated, trailing, and
-- wrongly typed input, and with tight and invalid limit policies. The
-- decoders must never throw and must always answer with either a decoded
-- string or a stable code from LibDeflateGuard.ERRORS.
--
-- Set LIBDEFLATEGUARD_FUZZ_REFERENCE to the path of another copy of
-- LibDeflateGuard.lua to additionally compare the two modules call for call.
-- That turns this file into a differential harness for decode-path changes:
-- check out the known good revision somewhere, point the variable at it, and
-- every public decode entry point must return identical tuples.
--
-- Environment:
--   LIBDEFLATEGUARD_FUZZ_SEED       PRNG seed (default 1234)
--   LIBDEFLATEGUARD_FUZZ_ITERATIONS scale factor, 1 = default workload
--   LIBDEFLATEGUARD_FUZZ_REFERENCE  path to a reference LibDeflateGuard.lua
package.path = "?.lua;" .. (package.path or "")

local failures = 0
local tests_run = 0
local comparisons = 0

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

local Guard = require("LibDeflateGuard")

local reference_path = os.getenv("LIBDEFLATEGUARD_FUZZ_REFERENCE")
local Reference
if reference_path and reference_path ~= "" then
  Reference = assert(dofile(reference_path),
                     "reference module did not return a table")
end

local seed = tonumber(os.getenv("LIBDEFLATEGUARD_FUZZ_SEED") or "") or 1234
local scale = tonumber(os.getenv("LIBDEFLATEGUARD_FUZZ_ITERATIONS") or "") or 1

-- A private generator, because math.random is not portable across 5.1-5.4.
--
-- This is MINSTD: state = state * 16807 % (2^31 - 1). The multiplier matters.
-- Lua 5.1 and LuaJIT do this arithmetic in doubles while 5.3 and 5.4 use
-- 64-bit integers, so any intermediate above 2^53 rounds on the former and
-- not on the latter, and the two would silently diverge. MINSTD peaks near
-- 2^45, which is exact in both. AssertGeneratorIsPortable below pins it.
-- A seed at or above 2^53 would itself be rounded differently on the two
-- arithmetics, which would defeat the whole point, so reject one rather than
-- quietly run a workload that does not match anyone else's.
if not (seed == math.floor(seed) and seed >= 0 and seed < 2147483647) then
  io.stderr:write("LIBDEFLATEGUARD_FUZZ_SEED must be a whole number below ",
                  "2147483647, got ", tostring(seed), "\n")
  os.exit(1)
end
local rng_state = seed % 2147483647
if rng_state == 0 then rng_state = 1 end -- 0 is MINSTD's fixed point
local function Random(upper)
  rng_state = rng_state * 16807 % 2147483647
  -- math.floor keeps this an integer on 5.3+, where "/" yields a float.
  return math.floor(rng_state / 2147483647 * upper)
end

-- The generator is only useful if a seed means the same thing everywhere, so
-- check it rather than trusting the reasoning above. These values were taken
-- from Lua 5.1, and 5.2, 5.3, 5.4 and LuaJIT must agree with them.
local function AssertGeneratorIsPortable()
  local saved = rng_state
  rng_state = 1234
  local expected = {19, 635, 833, 1948, 869, 391, 106, 1438, 503, 822}
  for index = 1, #expected do
    local drawn = Random(2000)
    assert(drawn == expected[index],
           ("generator is not portable on %s: draw %d gave %s, expected %d"):format(
             _VERSION, index, tostring(drawn), expected[index]))
  end
  rng_state = saved
end

-- Random integer in [lower, upper].
local function RandomBetween(lower, upper)
  return lower + Random(upper - lower + 1)
end

local function Scaled(count)
  local scaled = math.floor(count * scale)
  return scaled < 1 and 1 or scaled
end

local error_codes = {}
for _, code in pairs(Guard.ERRORS) do error_codes[code] = true end

local function AssertStableFailure(output, code, context)
  assert(output == nil, context .. ": expected nil output on failure")
  assert(error_codes[code],
         context .. ": unstable error code " .. tostring(code))
end

-- Every decode answer must be a decoded string or nil plus a stable code.
-- The two families differ on success: the decompressors document a numeric
-- status 0 alongside the output, while the codec decoders return the string
-- on its own. Both must never pair output with an error code.
local function AssertDecodeContract(output, code, context, status_is_zero)
  if output == nil then
    AssertStableFailure(output, code, context)
  else
    assert(type(output) == "string", context .. ": output must be a string")
    assert(not error_codes[code],
           context .. ": success reported error code " .. tostring(code))
    if status_is_zero then
      assert(code == 0, context .. ": success must report status 0, got " ..
               tostring(code))
    else
      assert(code == nil, context .. ": success must report no status, got " ..
               tostring(code))
    end
  end
end

-- Compares a full return tuple from Guard against the reference module.
-- Callers pass the packed tuples so multiple returns are never truncated.
local function Pack(...) return {n = select("#", ...), ...} end

local function Describe(value)
  if type(value) == "string" then return ("<string len=%d>"):format(#value) end
  return tostring(value)
end

local function CompareToReference(context, actual, expected)
  if not Reference then return end
  comparisons = comparisons + 1
  local same = (actual.n == expected.n)
  if same then
    for i = 1, actual.n do
      if actual[i] ~= expected[i] then
        same = false
        break
      end
    end
  end
  if not same then
    error(("%s: reference mismatch, got (%s, %s), reference (%s, %s)"):format(
            context, Describe(actual[1]), Describe(actual[2]),
            Describe(expected[1]), Describe(expected[2])), 2)
  end
end

-- Runs "method" on Guard and, when configured, on the reference module, then
-- checks the decode contract and that both modules agree.
local function Decode(method, context, ...)
  local actual = Pack(Guard[method](Guard, ...))
  AssertDecodeContract(actual[1], actual[2], context,
                       method:sub(1, 10) == "Decompress")
  if Reference then
    CompareToReference(context, actual, Pack(Reference[method](Reference, ...)))
  end
  return actual
end

local function RandomString(length, alphabet)
  local parts = {}
  for i = 1, length do
    if alphabet then
      local index = RandomBetween(1, #alphabet)
      parts[i] = alphabet:sub(index, index)
    else
      parts[i] = string.char(Random(256))
    end
  end
  return table.concat(parts)
end

-- Three payload shapes: incompressible, highly repetitive, and small alphabet.
local function RandomPayload(iteration)
  local length = Random(3000)
  if iteration % 3 == 0 then return RandomString(length) end
  if iteration % 3 == 1 then
    return string.rep(RandomString(RandomBetween(1, 12)), math.ceil(length / 6))
  end
  return RandomString(length, "abcdef \n{}")
end

local function Mutate(str)
  if #str == 0 then return str end
  local index = RandomBetween(1, #str)
  return str:sub(1, index - 1) .. string.char(Random(256)) .. str:sub(index + 1)
end

-- Build a raw DEFLATE stream of fixed-Huffman blocks, each holding "literals"
-- copies of "A". The compressor never emits this shape, because it prefers
-- dynamic blocks, and a dynamic block charges the symbol budget through its
-- code-length header as well as through the literal loop. A fixed block has no
-- header, so this is the only shape where the literal loop is the sole thing
-- charging that budget, and therefore the only one that can prove the
-- per-block symbol counter carries into the stream total.
local function BuildFixedBlockStream(blocks, literals)
  local out, acc, nbits = {}, 0, 0
  local function PutBits(value, count) -- RFC 1951 packs bits low end first
    acc = acc + value * 2 ^ nbits
    nbits = nbits + count
    while nbits >= 8 do
      out[#out + 1] = string.char(acc % 256)
      acc = math.floor(acc / 256)
      nbits = nbits - 8
    end
  end
  local function PutCode(code, count) -- Huffman codes go high bit first
    for i = count - 1, 0, -1 do PutBits(math.floor(code / 2 ^ i) % 2, 1) end
  end
  for block = 1, blocks do
    PutBits(block == blocks and 1 or 0, 1) -- BFINAL
    PutBits(1, 2) -- BTYPE 01, fixed Huffman
    -- Literal "A" is 65, and fixed codes 0-143 are 8 bits at 0x30 + literal.
    for _ = 1, literals do PutCode(0x30 + 65, 8) end
    PutCode(0, 7) -- end of block, symbol 256, is seven zero bits
  end
  if nbits > 0 then out[#out + 1] = string.char(acc % 256) end
  return table.concat(out)
end

local deflate_case = {
  name = "deflate",
  Compress = "CompressDeflate",
  Decompress = "DecompressDeflate",
  CompressWithDict = "CompressDeflateWithDict",
  DecompressWithDict = "DecompressDeflateWithDict"
}
local zlib_case = {
  name = "zlib",
  Compress = "CompressZlib",
  Decompress = "DecompressZlib",
  CompressWithDict = "CompressZlibWithDict",
  DecompressWithDict = "DecompressZlibWithDict"
}

Test("the workload generator is identical on every interpreter",
     function() AssertGeneratorIsPortable() end)

Test("round trips survive every compression level and payload shape", function()
  for iteration = 1, Scaled(120) do
    local payload = RandomPayload(iteration)
    local level = Random(10)
    for _, case in ipairs({deflate_case, zlib_case}) do
      local compressed = Guard[case.Compress](Guard, payload, {level = level})
      local result = Decode(case.Decompress, case.name .. " round trip",
                            compressed)
      assert(result[1] == payload,
             case.name .. " round trip did not restore the payload")
      assert(result[2] == 0, case.name .. " round trip status must be 0")
    end
  end
end)

Test("truncated, mutated, and trailing members never throw", function()
  for iteration = 1, Scaled(120) do
    local payload = RandomPayload(iteration)
    local compressed = Guard[deflate_case.Compress](Guard, payload,
                                                    {level = Random(10)})
    local zcompressed = Guard[zlib_case.Compress](Guard, payload,
                                                  {level = Random(10)})
    for _, pair in
      ipairs({{deflate_case, compressed}, {zlib_case, zcompressed}}) do
      local case, member = pair[1], pair[2]
      for _ = 1, 3 do
        Decode(case.Decompress, case.name .. " truncated",
               member:sub(1, Random(#member + 1)))
        Decode(case.Decompress, case.name .. " mutated", Mutate(member))
      end
      local extended = member .. RandomString(RandomBetween(1, 4))
      local result = Decode(case.Decompress, case.name .. " trailing", extended)
      assert(result[1] == nil,
             case.name .. " must reject complete trailing bytes")
      assert(result[2] == Guard.ERRORS.TRAILING_DATA,
             case.name .. " trailing bytes must report trailing_data")
    end
  end
end)

Test("limit policies are enforced and reported", function()
  for iteration = 1, Scaled(120) do
    local payload = RandomPayload(iteration)
    local compressed = Guard[deflate_case.Compress](Guard, payload,
                                                    {level = Random(10)})
    for _, case in ipairs({deflate_case, zlib_case}) do
      local member = Guard[case.Compress](Guard, payload, {level = Random(10)})
      for _ = 1, 4 do
        local limits = {
          max_input_bytes = RandomBetween(1, #member + 8),
          max_output_bytes = RandomBetween(1,
                                           (#payload > 0 and #payload or 1) + 4),
          max_blocks = RandomBetween(1, 4),
          max_symbols = RandomBetween(1, (#payload > 1 and #payload or 2)),
          max_work_units = RandomBetween(1, (#payload > 1 and #payload * 2 or 2))
        }
        local result = Decode(case.Decompress, case.name .. " tight limits",
                              member, limits)
        if result[1] then
          assert(#result[1] <= limits.max_output_bytes,
                 case.name .. " produced more output than max_output_bytes")
          assert(#member <= limits.max_input_bytes,
                 case.name .. " accepted input over max_input_bytes")
        end
      end

      -- An input one byte over the cap must always be refused.
      local result = Decode(case.Decompress, case.name .. " input cap", member,
                            {max_input_bytes = #member - 1})
      if #member > 1 then
        assert(result[2] == Guard.ERRORS.INPUT_LIMIT_EXCEEDED,
               case.name .. " must report input_limit_exceeded")
      end

      -- An output cap below the true output must always be refused.
      if #payload > 1 then
        result = Decode(case.Decompress, case.name .. " output cap", member,
                        {max_output_bytes = #payload - 1})
        assert(result[2] == Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
               case.name .. " must report output_limit_exceeded")
      end
    end

    -- Defaults must accept what a tight policy refused.
    local baseline = Decode(deflate_case.Decompress, "default policy",
                            compressed)
    assert(baseline[1] == payload, "default policy must decode the payload")

    -- Omitting the policy shares one private defaults table rather than
    -- copying it, so nothing may write through it. If it ever drifted, the
    -- no-policy path would stop agreeing with an explicit copy of the same
    -- numbers, and every caller in the process would silently inherit it.
    local explicit = {}
    for key, value in pairs(Guard.DEFAULT_LIMITS) do explicit[key] = value end
    local shared =
      Decode(deflate_case.Decompress, "shared defaults", compressed)
    local copied = Decode(deflate_case.Decompress, "copied defaults",
                          compressed, explicit)
    assert(shared[1] == copied[1] and shared[2] == copied[2],
           "omitting the policy must match an explicit copy of the defaults")
  end
end)

Test("every budget fires when it is set below what the member needs", function()
  -- A payload large enough to need many symbols, many output bytes, and,
  -- when stored uncompressed, more than one block.
  local payload = string.rep("abcdefgh0123456789", 8000)
  local member = Guard:CompressDeflate(payload)
  local stored = Guard:CompressDeflate(payload, {level = 0})

  -- A short payload with no repeats compresses to a single fixed block of
  -- pure literals. It carries no dynamic header and no distance codes, so
  -- the literal path is the only thing that can charge the symbol budget.
  local literals = {}
  for i = 1, 40 do literals[i] = string.char(i * 7 % 256) end
  literals = table.concat(literals)
  local fixed_member = Guard:CompressDeflate(literals, {level = 1})

  local floors = {
    {member, {max_symbols = 1}, Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED},
    {member, {max_work_units = 1}, Guard.ERRORS.WORK_LIMIT_EXCEEDED},
    {member, {max_output_bytes = 1}, Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED},
    {member, {max_input_bytes = 1}, Guard.ERRORS.INPUT_LIMIT_EXCEEDED},
    {stored, {max_blocks = 1}, Guard.ERRORS.BLOCK_LIMIT_EXCEEDED},
    {fixed_member, {max_symbols = 1}, Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED},
    {fixed_member, {max_output_bytes = 1}, Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED}
  }
  for _, floor in ipairs(floors) do
    local target, policy, expected = floor[1], floor[2], floor[3]
    local key = next(policy)
    local result = Decode(deflate_case.Decompress, key .. " floor", target,
                          policy)
    assert(result[1] == nil, key .. " = 1 must refuse the member")
    assert(result[2] == expected, ("%s = 1 must report %s, got %s"):format(key,
                                                                           expected,
                                                                           tostring(
                                                                             result[2])))
  end

  -- RFC 1951 lets one length symbol stand for at most 258 output bytes, so
  -- a member that produced N bytes must have decoded at least N/258
  -- symbols. A budget under that floor has to be refused no matter how the
  -- member is split into blocks, which is what keeps per-block accounting
  -- from silently failing to accumulate into the stream total.
  local spread = {}
  for i = 1, 200000 do spread[i] = string.char(i * 7 % 256) end
  spread = table.concat(spread)
  local multiblock = Guard:CompressDeflate(spread, {level = 5})
  local symbol_floor = math.floor(#spread / 258)
  local result = Decode(deflate_case.Decompress, "symbol floor", multiblock,
                        {max_symbols = symbol_floor})
  assert(result[1] == nil,
         "a budget below the RFC 1951 symbol floor must be refused")
  assert(result[2] == Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED,
         "the symbol floor must report symbol_limit_exceeded")

  -- Every budget, on a shape the compressor cannot produce, with exact
  -- boundaries. Eight fixed-Huffman blocks of 4000 literals each gives a
  -- hand-computable total for all five: one under must be refused and the
  -- exact total accepted. Exact boundaries matter here. A cap picked with a
  -- comfortable margin still passes when a counter silently under-charges,
  -- which is the failure this whole section exists to catch.
  --
  -- The shape matters too. A dynamic block also charges symbols and work
  -- through its code-length header, which masks a per-block counter; a fixed
  -- block has no header, so the block loop is the only thing charging.
  local fixed_blocks = BuildFixedBlockStream(8, 4000)
  local fixed_output = string.rep("A", 32000)
  local decoded = Decode(deflate_case.Decompress, "fixed block stream",
                         fixed_blocks)
  assert(decoded[1] == fixed_output,
         "the hand-built fixed-block stream must decode to its literals")

  local exact_totals = {
    {"max_symbols", 32008, Guard.ERRORS.SYMBOL_LIMIT_EXCEEDED}, -- 8 * 4001
    {"max_output_bytes", 32000, Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED}, -- 8 * 4000
    {"max_work_units", 64016, Guard.ERRORS.WORK_LIMIT_EXCEEDED}, -- symbols + output + blocks
    {"max_blocks", 8, Guard.ERRORS.BLOCK_LIMIT_EXCEEDED},
    {"max_input_bytes", 32010, Guard.ERRORS.INPUT_LIMIT_EXCEEDED}
  }
  for _, total in ipairs(exact_totals) do
    local key, needed, expected = total[1], total[2], total[3]
    result = Decode(deflate_case.Decompress, key .. " one under the total",
                    fixed_blocks, {[key] = needed - 1})
    assert(result[1] == nil,
           ("%s = %d must be refused, one under the true total"):format(key,
                                                                        needed -
                                                                          1))
    assert(result[2] == expected,
           ("%s one under must report %s, got %s"):format(key, expected,
                                                          tostring(result[2])))

    result = Decode(deflate_case.Decompress, key .. " exactly the total",
                    fixed_blocks, {[key] = needed})
    assert(result[1] == fixed_output,
           ("%s = %d is exactly the total and must be accepted"):format(key,
                                                                        needed))
  end

  -- Stored blocks charge output from a different call site, through the
  -- state rather than through a local, so they need their own carry case.
  -- Without this a counter that fails to carry in DecompressStoreBlock is an
  -- undetected output bypass, exactly as it was in the block loop.
  result = Decode(deflate_case.Decompress, "stored blocks carry output", stored,
                  {max_output_bytes = 100000})
  assert(result[1] == nil,
         "stored output must carry across blocks and refuse the member")
  assert(result[2] == Guard.ERRORS.OUTPUT_LIMIT_EXCEEDED,
         "stored output carry must report output_limit_exceeded")

  -- The same member must decode once the budgets are lifted.
  local ok = Decode(deflate_case.Decompress, "lifted budgets", member)
  assert(ok[1] == payload, "the member must decode under the defaults")
  ok = Decode(deflate_case.Decompress, "lifted budgets multiblock", multiblock)
  assert(ok[1] == spread, "the multi-block member must decode by default")
end)

Test("invalid policies and argument types are refused, not raised", function()
  local sample = Guard:CompressDeflate("hello world hello world")
  local bad_policies = {
    {max_blocks = 0}, {max_blocks = -1}, {max_blocks = 1.5}, {unknown_key = 1},
    {max_input_bytes = math.huge}, {max_symbols = "10"},
    {max_output_bytes = 0 / 0}, {max_work_units = -0.5}, "not a table", 42, true
  }
  for _, policy in ipairs(bad_policies) do
    for _, case in ipairs({deflate_case, zlib_case}) do
      local result = Decode(case.Decompress, case.name .. " bad policy", sample,
                            policy)
      AssertStableFailure(result[1], result[2], case.name .. " bad policy")
      assert(result[2] == Guard.ERRORS.INVALID_ARGUMENT,
             case.name .. " bad policy must report invalid_argument")
    end
  end

  -- An empty table means "use every default".
  local result = Decode(deflate_case.Decompress, "empty policy", sample, {})
  assert(result[1] ~= nil, "an empty policy table must use the defaults")

  for _, bad in ipairs({42, true, {}, print}) do
    for _, method in ipairs({
      "DecompressDeflate", "DecompressZlib", "DecodeForPrint",
      "DecodeForWoWAddonChannel", "DecodeForWoWChatChannel"
    }) do
      local answer = Decode(method, method .. " bad argument", bad)
      AssertStableFailure(answer[1], answer[2], method .. " bad argument")
      assert(answer[2] == Guard.ERRORS.INVALID_ARGUMENT,
             method .. " must report invalid_argument")
    end
  end
end)

Test("channel codecs round trip and reject malformed input", function()
  local all_bytes = {}
  for byte = 0, 255 do all_bytes[byte + 1] = string.char(byte) end
  all_bytes = table.concat(all_bytes)

  local codecs = {
    {"addon", "EncodeForWoWAddonChannel", "DecodeForWoWAddonChannel"},
    {"chat", "EncodeForWoWChatChannel", "DecodeForWoWChatChannel"}
  }
  for _, codec in ipairs(codecs) do
    local name, Encode, DecodeName = codec[1], codec[2], codec[3]

    local encoded = Guard[Encode](Guard, all_bytes)
    local result = Decode(DecodeName, name .. " all bytes", encoded)
    assert(result[1] == all_bytes, name .. " must round trip every byte")

    -- Every single byte on its own, most of which are malformed.
    for byte = 0, 255 do
      Decode(DecodeName, name .. " single byte", string.char(byte))
    end

    -- Canonicality, checked without a reference module: the encoders only
    -- ever emit canonical escape sequences, so anything the decoder
    -- accepts must encode back to exactly the bytes it was given. A
    -- decoder that tolerates a dangling or non-canonical escape shows up
    -- here as a re-encode that differs from the input.
    for _ = 1, Scaled(1500) do
      local candidate = RandomString(Random(7))
      local answer = Decode(DecodeName, name .. " random bytes", candidate)
      if answer[1] ~= nil then
        assert(Guard[Encode](Guard, answer[1]) == candidate,
               name .. " accepted a non-canonical encoding")
      end
    end

    for _ = 1, Scaled(150) do
      local payload = RandomString(Random(400))
      local member = Guard[Encode](Guard, payload)
      local decoded = Decode(DecodeName, name .. " round trip", member)
      assert(decoded[1] == payload, name .. " round trip failed")
      if #member > 0 then
        Decode(DecodeName, name .. " mutated", Mutate(member))
        Decode(DecodeName, name .. " truncated",
               member:sub(1, Random(#member + 1)))
      end
    end
  end
end)

Test("custom codecs round trip and reject malformed input", function()
  local specs = {
    {"\000", "\001", ""}, {"\000\001\002", "\003", "\004"}, {"abc", "%", "x"},
    {"sS\000\010\013\124%", "\029\031", "\015\020"}
  }
  for _, spec in ipairs(specs) do
    local codec = assert(Guard:CreateCodec(spec[1], spec[2], spec[3]))
    local reference_codec
    if Reference then
      reference_codec = assert(Reference:CreateCodec(spec[1], spec[2], spec[3]))
    end
    for _ = 1, Scaled(250) do
      local payload = RandomString(Random(41))
      -- codec:Encode forwards string.gsub, so it answers with the
      -- encoded string and a substitution count. Pack the whole tuple
      -- rather than a truncated local, or the comparison below would
      -- measure the harness instead of the codec.
      local encoded = Pack(codec:Encode(payload))
      local decoded = Pack(codec:Decode(encoded[1]))
      assert(decoded[1] == payload, "custom codec round trip failed")

      local raw = RandomString(Random(9))
      local raw_decoded = Pack(codec:Decode(raw))
      AssertDecodeContract(raw_decoded[1], raw_decoded[2],
                           "custom codec raw input")
      if raw_decoded[1] ~= nil then
        assert(codec:Encode(raw_decoded[1]) == raw,
               "custom codec accepted a non-canonical encoding")
      end

      if reference_codec then
        CompareToReference("custom codec encode", encoded,
                           Pack(reference_codec:Encode(payload)))
        CompareToReference("custom codec decode", decoded,
                           Pack(reference_codec:Decode(encoded[1])))
        CompareToReference("custom codec raw", raw_decoded,
                           Pack(reference_codec:Decode(raw)))
      end
    end
  end
end)

Test("print codec round trips and rejects malformed input", function()
  for _ = 1, Scaled(600) do
    local payload = RandomString(Random(61))
    local encoded = Guard:EncodeForPrint(payload)
    local decoded = Decode("DecodeForPrint", "print round trip", encoded)
    assert(decoded[1] == payload, "print codec round trip failed")

    -- Same canonicality check as the channel codecs. DecodeForPrint
    -- deliberately strips surrounding control characters and spaces, so
    -- only candidates without that padding can be re-encoded exactly.
    local candidate = RandomString(Random(11))
    local answer = Decode("DecodeForPrint", "print random", candidate)
    if answer[1] ~= nil and not candidate:find("^[%c ]") and
      not candidate:find("[%c ]$") then
      assert(Guard:EncodeForPrint(answer[1]) == candidate,
             "print codec accepted a non-canonical encoding")
    end

    if #encoded > 0 then
      Decode("DecodeForPrint", "print mutated", Mutate(encoded))
    end
  end
end)

Test("dictionary decoding round trips and refuses mismatches", function()
  local dictionary_string = "the quick brown fox jumps over the lazy dog"
  local dictionary = Guard:CreateDictionary(dictionary_string,
                                            #dictionary_string,
                                            Guard:Adler32(dictionary_string))
  local reference_dictionary
  if Reference then
    reference_dictionary = Reference:CreateDictionary(dictionary_string,
                                                      #dictionary_string,
                                                      Reference:Adler32(
                                                        dictionary_string))
  end

  -- Decode() cannot be reused here: the dictionary argument differs between
  -- the two modules, so the reference call is built by hand.
  local function DecodeWithDict(method, context, member)
    local actual = Pack(Guard[method](Guard, member, dictionary))
    -- Both dictionary entry points are Decompress*, so status 0 on success.
    AssertDecodeContract(actual[1], actual[2], context, true)
    if Reference then
      CompareToReference(context, actual, Pack(
                           Reference[method](Reference, member,
                                             reference_dictionary)))
    end
    return actual
  end

  for _ = 1, Scaled(60) do
    local payload = RandomString(Random(301), "the quick brown fox jumps")
    local level = Random(10)

    local raw = Guard:CompressDeflateWithDict(payload, dictionary,
                                              {level = level})
    local decoded = DecodeWithDict("DecompressDeflateWithDict",
                                   "deflate dictionary round trip", raw)
    assert(decoded[1] == payload, "deflate dictionary round trip failed")

    local wrapped = Guard:CompressZlibWithDict(payload, dictionary,
                                               {level = level})
    decoded = DecodeWithDict("DecompressZlibWithDict",
                             "zlib dictionary round trip", wrapped)
    assert(decoded[1] == payload, "zlib dictionary round trip failed")

    -- A member that never declared FDICT must not silently consume the
    -- caller's dictionary.
    local plain = Guard:CompressZlib(payload, {level = level})
    decoded = DecodeWithDict("DecompressZlibWithDict", "zlib without FDICT",
                             plain)
    assert(decoded[1] == payload,
           "a member without FDICT must decode without the dictionary")

    DecodeWithDict("DecompressDeflateWithDict", "wrong container", wrapped)
  end

  local sample = Guard:CompressDeflate("hello world hello world")
  for _, bad in ipairs({42, "string", {}, {strlen = 1}}) do
    local result = Decode("DecompressDeflateWithDict", "bad dictionary", sample,
                          bad)
    AssertStableFailure(result[1], result[2], "bad dictionary")
    assert(result[2] == Guard.ERRORS.INVALID_ARGUMENT,
           "a bad dictionary must report invalid_argument")
  end
end)

if Reference then
  io.write(("# compared %d calls against %s\n"):format(comparisons,
                                                       reference_path))
end

if failures > 0 then
  io.stderr:write(("%d of %d tests failed\n"):format(failures, tests_run))
  os.exit(1)
end
io.write(("%d tests passed\n"):format(tests_run))
