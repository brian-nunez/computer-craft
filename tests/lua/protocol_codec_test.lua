-- Covers canonical-form behaviour the shared fixture catalog cannot express as
-- wire text: Lua values that could never have come from a decode, and the
-- byte-order sort that keeps two hosts signing the same preimage.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local cj1 = protocol.conformance.cj1

local function encodeFails(value, message)
  local text, code = cj1.encode(value)
  assertTrue(text == nil, message .. ": value was encoded")
  assertEqual(code, "invalid_message", message)
end

test("a sparse array is refused rather than silently compacted", function()
  local sparse = cj1.array({ 1, 2, 3 })
  rawset(sparse, 2, nil)
  encodeFails(sparse, "sparse array")

  local gap = cj1.array()
  rawset(gap, 1, "a")
  rawset(gap, 3, "c")
  encodeFails(gap, "array with a hole")
end)

test("a table mixing string and number keys is refused", function()
  encodeFails({ "first", named = "second" }, "mixed keys")
end)

test("an object key that is not a string is refused", function()
  local object = cj1.object()
  rawset(object, true, "value")
  encodeFails(object, "boolean key")
end)

test("a value type the wire has no form for is refused", function()
  encodeFails({ handler = function() end }, "function value")
  encodeFails({ n = 1.5 }, "fractional number")
  encodeFails({ n = 9007199254740992 }, "integer past the exact range")
  encodeFails({ n = -9007199254740992 }, "integer below the exact range")
  encodeFails({ n = 1 / 0 }, "infinity")
  encodeFails({ n = 0 / 0 }, "not a number")
end)

test("keys sort by unsigned byte order rather than by locale", function()
  -- A locale-aware comparison would order these differently. CJ1 is defined on
  -- unsigned bytes so that Lua and Go always sign the same preimage.
  local encoded = assert(cj1.encode(cj1.object({
    a = 1, B = 2, _ = 3, ["\195\161"] = 4, A = 5,
  })))
  assertEqual(encoded, '{"A":5,"B":2,"_":3,"a":1,"\195\161":4}', "byte-order sort")
end)

test("an explicitly tagged array survives even when it looks like an object", function()
  assertEqual(cj1.encode(cj1.array({})), "[]", "empty array keeps its tag")
  assertEqual(cj1.encode(cj1.object({})), "{}", "empty object keeps its tag")
  assertTrue(cj1.isArray(cj1.array({ 1 })), "isArray")
  assertTrue(cj1.isObject(cj1.object({ a = 1 })), "isObject")
end)

test("null round trips as a distinct value rather than as an absent field", function()
  local value = assert(cj1.decode('{"present":null}'))
  assertTrue(rawget(value, "present") == cj1.null, "null decodes to the sentinel")
  assertTrue(rawget(value, "absent") == nil, "an absent field stays absent")
  assertEqual(assert(cj1.encode(value)), '{"present":null}', "re-encode")
end)

test("a decoded string is valid UTF-8 or it is not a string at all", function()
  local value, code = cj1.decode('{"s":"' .. string.char(0xff, 0xfe) .. '"}')
  assertTrue(value == nil, "invalid UTF-8 was decoded")
  assertEqual(code, "invalid_message", "code")
end)

test("structural limits may be narrowed but never widened", function()
  local text = '{"s":"' .. string.rep("a", 64) .. '"}'
  assertTrue(cj1.decode(text) ~= nil, "the default limit accepts this string")

  local value, code = cj1.decode(text, { stringBytes = 32 })
  assertTrue(value == nil, "a narrowed limit was not applied")
  assertEqual(code, "message_too_large", "code")

  local ok = pcall(cj1.decode, text, { stringBytes = protocol.limits.STRING_BYTES + 1 })
  assertTrue(not ok, "a widened limit must be refused")
end)
