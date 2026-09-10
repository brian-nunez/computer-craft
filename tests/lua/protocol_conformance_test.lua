-- Replays the cross-language protocol fixture catalog in Lua.
--
-- Every case here is also replayed by the Go suite. The two implementations
-- must classify each one identically; that agreement is what makes the catalog
-- a compatibility contract rather than a pair of independent test suites.

local catalog = require("tests.lua.support.catalog")

local protocol = catalog.protocol
local cj1 = protocol.conformance.cj1
local keys = protocol.conformance.keys
local frame = protocol.conformance.frame
local schema = protocol.conformance.schema
local sha256 = protocol.conformance.sha256
local hmac = protocol.conformance.hmac
local limits = protocol.limits
local errors = protocol.errors

local field = catalog.field

local function each(document, key)
  local list = field(document, key)
  local index = 0
  return function()
    index = index + 1
    if index > #list then return nil end
    return rawget(list, index), index
  end
end

--------------------------------------------------------------------------
-- The catalog itself
--------------------------------------------------------------------------

test("the catalog names Lua as a consumer of the shared fixtures", function()
  local manifest = catalog.load("manifest.json")
  assertEqual(field(manifest, "wire_version"), protocol.wireVersion, "wire version")
  local shared = 0
  for entry in each(manifest, "fixtures") do
    if catalog.replayedByLua(entry) then shared = shared + 1 end
  end
  assertTrue(shared > 0, "no fixture is replayed by the Lua implementation")
end)

--------------------------------------------------------------------------
-- Canonical JSON
--------------------------------------------------------------------------

test("every canonical fixture re-encodes byte for byte", function()
  local document = catalog.load("cj1/canonical.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local value, code, message = cj1.decode(field(item, "text"))
    assertTrue(value ~= nil, name .. ": decode failed with " .. tostring(code) .. " " .. tostring(message))
    local encoded, encodeCode = cj1.encode(value)
    assertTrue(encoded ~= nil, name .. ": encode failed with " .. tostring(encodeCode))
    assertEqual(encoded, field(item, "canonical"), name)

    -- Canonical form is a fixed point: re-encoding must not drift.
    local again = assert(cj1.decode(encoded))
    assertEqual(assert(cj1.encode(again)), encoded, name .. " is not stable")
  end
end)

test("every rejected canonical fixture fails with its exact code", function()
  local document = catalog.load("cj1/rejected.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local value, code = cj1.decode(field(item, "text"))
    assertTrue(value == nil, name .. ": input was accepted")
    assertEqual(code, field(item, "error"), name)
  end
end)

--------------------------------------------------------------------------
-- Published hash vectors
--------------------------------------------------------------------------

test("the pure-Lua SHA-256 matches its published vectors", function()
  local document = catalog.load("hash/sha256.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local input
    local inputHex = rawget(item, "input_hex")
    if inputHex ~= nil then
      input = sha256.fromHex(inputHex)
    else
      input = string.rep(field(item, "input_repeat"), field(item, "input_repeat_count"))
    end
    assertEqual(sha256.hex(input), field(item, "digest"), name)
  end
end)

test("the pure-Lua HMAC-SHA-256 matches its published vectors", function()
  local document = catalog.load("hash/hmac-sha256.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local key = sha256.fromHex(field(item, "key_hex"))
    local message = sha256.fromHex(field(item, "message_hex"))
    assertEqual(hmac.hex(key, message), field(item, "mac"), name)
  end
end)

--------------------------------------------------------------------------
-- Key derivation
--------------------------------------------------------------------------

test("the derivation chain reproduces every fixture value", function()
  local document = catalog.load("derivation/keys.json")
  local rootSecret = sha256.fromHex(field(document, "root_secret_hex"))

  local labels = field(document, "labels")
  assertEqual(field(labels, "enrollment"), keys.labels.enrollment, "enrollment label")
  assertEqual(field(labels, "relationship"), keys.labels.relationship, "relationship label")
  assertEqual(field(labels, "session"), keys.labels.session, "session label")
  assertEqual(field(labels, "nonce"), keys.labels.nonce, "nonce label")

  local enrollmentEntry = field(document, "enrollment_secret")
  local enrollmentSecret = keys.enrollmentSecret(
    rootSecret, field(enrollmentEntry, "child_role"), field(enrollmentEntry, "token_use_counter"))
  assertEqual(keys.toHex(enrollmentSecret), field(enrollmentEntry, "value"), "enrollment secret")

  local credentialEntry = field(document, "relationship_credential")
  local credential = assert(keys.relationshipCredential(
    enrollmentSecret, field(credentialEntry, "transcript")))
  assertEqual(keys.toHex(credential), field(credentialEntry, "value"), "relationship credential")

  -- A re-enrolling child carries its identity into the transcript, so the same
  -- secret and nonces must not reproduce the first credential.
  local reEntry = field(document, "re_enrollment_credential")
  local reCredential = assert(keys.relationshipCredential(
    enrollmentSecret, field(reEntry, "transcript")))
  assertEqual(keys.toHex(reCredential), field(reEntry, "value"), "re-enrollment credential")
  assertTrue(keys.toHex(reCredential) ~= keys.toHex(credential),
    "re-enrollment reproduced the first credential")

  local sessionEntry = field(document, "session_key")
  local sessionKey = assert(keys.sessionKey(credential, field(sessionEntry, "transcript")))
  assertEqual(keys.toHex(sessionKey), field(sessionEntry, "value"), "session key")

  for item in each(document, "nonces") do
    assertEqual(
      keys.nonce(credential, field(item, "role"), field(item, "generation")),
      field(item, "value"),
      "nonce for " .. field(item, "role"))
  end
end)

--------------------------------------------------------------------------
-- Message schemas
--------------------------------------------------------------------------

test("every accepted message fixture validates against its kind", function()
  local document = catalog.load("messages/accepted.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local kind = field(item, "kind")
    assertTrue(schema.allows(field(item, "transport"), kind),
      name .. ": transport does not carry " .. kind)
    local body = assert(cj1.decode(field(item, "body")), name .. ": body did not decode")
    local ok, message = schema.validateBody(kind, body)
    assertTrue(ok, name .. ": " .. tostring(message))
  end
end)

test("every rejected message fixture fails with its exact code", function()
  local document = catalog.load("messages/rejected.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local body, decodeCode = cj1.decode(field(item, "body"))
    if body == nil then
      assertEqual(decodeCode, field(item, "error"), name)
    else
      local ok, _, code = schema.validateBody(field(item, "kind"), body)
      assertTrue(not ok, name .. ": body was accepted")
      assertEqual(code, field(item, "error"), name)
    end
  end
end)

--------------------------------------------------------------------------
-- Authenticated frames
--------------------------------------------------------------------------

local function fixtureSession(document)
  return frame.newSession({
    relationship_id = field(document, "relationship_id"),
    session_id = field(document, "session_id"),
    session_key = sha256.fromHex(field(document, "session_key_hex")),
  })
end

test("every accepted frame fixture authenticates", function()
  local document = catalog.load("frames/accepted.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local message, code, detail = fixtureSession(document):open(field(item, "text"))
    assertTrue(message ~= nil, name .. ": " .. tostring(code) .. " " .. tostring(detail))
    assertEqual(message.kind, field(item, "kind"), name .. " kind")
    assertEqual(message.counter, field(item, "counter"), name .. " counter")
    assertEqual(message.request_id or "", field(item, "request_id"), name .. " request_id")
  end
end)

test("every rejected frame fixture fails with its exact code", function()
  local document = catalog.load("frames/rejected.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local message, code = fixtureSession(document):open(field(item, "text"))
    assertTrue(message == nil, name .. ": frame was accepted")
    assertEqual(code, field(item, "error"), name)
  end
end)

test("replayed and out-of-order counters fail closed", function()
  local document = catalog.load("frames/sequences.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local session = fixtureSession(document)
    for step, index in each(item, "steps") do
      local label = name .. " step " .. index
      local expect = field(step, "expect")
      local message, code, detail = session:open(field(step, "text"))
      if expect == "accepted" then
        assertTrue(message ~= nil, label .. ": " .. tostring(code) .. " " .. tostring(detail))
        assertEqual(message.counter, field(step, "counter"), label .. " counter")
      else
        assertTrue(message == nil, label .. ": step was accepted")
        assertEqual(code, expect, label)
      end
    end
  end
end)

--------------------------------------------------------------------------
-- Enrollment and session establishment
--------------------------------------------------------------------------

test("the enrollment exchange verifies and derives its credential", function()
  local document = catalog.load("handshake/enrollment.json")
  local secret = sha256.fromHex(field(document, "enrollment_secret_hex"))
  local requestId = field(document, "request_id")

  for item in each(document, "messages") do
    local kind = field(item, "kind")
    local message, code, detail = frame.openHandshake(secret, field(item, "text"))
    assertTrue(message ~= nil, kind .. ": " .. tostring(code) .. " " .. tostring(detail))
    assertEqual(message.kind, kind, "kind")
    assertEqual(message.request_id, requestId, kind .. " correlation")
  end

  local credential = assert(keys.relationshipCredential(secret, field(document, "transcript")))
  assertEqual(keys.toHex(credential), field(document, "relationship_credential"), "credential")

  for item in each(document, "rejected") do
    local name = field(item, "name")
    local message, code = frame.openHandshake(secret, field(item, "text"))
    assertTrue(message == nil, name .. ": handshake was accepted")
    assertEqual(code, field(item, "error"), name)
  end
end)

test("the session exchange verifies and derives its session key", function()
  local document = catalog.load("handshake/session.json")
  local credential = sha256.fromHex(field(document, "relationship_credential_hex"))

  for item in each(document, "messages") do
    local kind = field(item, "kind")
    local message, code, detail = frame.openHandshake(credential, field(item, "text"))
    assertTrue(message ~= nil, kind .. ": " .. tostring(code) .. " " .. tostring(detail))
    assertEqual(message.kind, kind, "kind")
  end

  local sessionKey = assert(keys.sessionKey(credential, field(document, "transcript")))
  assertEqual(keys.toHex(sessionKey), field(document, "session_key"), "session key")
  assertEqual(frame.FIRST_COUNTER, field(document, "first_counter"), "first counter")
end)

--------------------------------------------------------------------------
-- Limits
--------------------------------------------------------------------------

-- buildLimitInput constructs a limits case from its recipe. Embedding the text
-- literally would make the fixture file itself exceed the string limit.
local function buildLimitInput(item)
  local recipe = field(item, "recipe")
  if recipe == "string" then
    return '{"s":"' .. string.rep(field(item, "filler"), field(item, "length")) .. '"}'
  elseif recipe == "object_keys" then
    local pieces = {}
    for index = 1, field(item, "count") do
      pieces[index] = '"k' .. (index - 1) .. '":0'
    end
    return "{" .. table.concat(pieces, ",") .. "}"
  elseif recipe == "array_elements" then
    local pieces = {}
    for index = 1, field(item, "count") do pieces[index] = "0" end
    return "[" .. table.concat(pieces, ",") .. "]"
  elseif recipe == "depth" then
    local count = field(item, "count")
    return string.rep("[", count) .. string.rep("]", count)
  elseif recipe == "modem_frame" then
    -- The padding is split into chunks because no single string may exceed the
    -- string limit, so a frame at the modem ceiling cannot be one long value.
    local chunks = field(item, "chunks")
    local pieces = {}
    for index = 1, #chunks do
      pieces[index] = '"' .. string.rep("p", rawget(chunks, index)) .. '"'
    end
    local text = '{"pad":[' .. table.concat(pieces, ",") .. "]}"
    assertEqual(#text, field(item, "length"), "modem frame padding")
    return text
  end
  error("unknown limit recipe " .. tostring(recipe))
end

test("the declared limits match the implementation", function()
  local document = catalog.load("limits/edges.json")
  local declared = field(document, "limits")
  assertEqual(field(declared, "modem_frame_bytes"), limits.MODEM_FRAME_BYTES, "modem frame")
  assertEqual(field(declared, "modem_payload_bytes"), limits.MODEM_PAYLOAD_BYTES, "modem payload")
  assertEqual(field(declared, "gateway_frame_bytes"), limits.GATEWAY_FRAME_BYTES, "gateway frame")
  assertEqual(field(declared, "traffic_batch_bytes"), limits.TRAFFIC_BATCH_BYTES, "traffic batch bytes")
  assertEqual(field(declared, "traffic_batch_events"), limits.TRAFFIC_BATCH_EVENTS, "traffic batch events")
  assertEqual(field(declared, "topology_entities"), limits.TOPOLOGY_ENTITIES, "topology entities")
  assertEqual(field(declared, "string_bytes"), limits.STRING_BYTES, "string bytes")
  assertEqual(field(declared, "depth"), limits.DEPTH, "depth")
  assertEqual(field(declared, "object_keys"), limits.OBJECT_KEYS, "object keys")
  assertEqual(field(declared, "array_elements"), limits.ARRAY_ELEMENTS, "array elements")
  assertEqual(field(declared, "relationship_in_flight"), limits.RELATIONSHIP_IN_FLIGHT, "relationship in flight")
  assertEqual(field(declared, "gateway_in_flight"), limits.GATEWAY_IN_FLIGHT, "gateway in flight")
  assertEqual(field(declared, "access_token_seconds"), limits.ACCESS_TOKEN_SECONDS, "access token seconds")
end)

test("inputs exactly at a limit pass and one past it fail", function()
  local document = catalog.load("limits/edges.json")
  for item in each(document, "cases") do
    local name = field(item, "name")
    local text = buildLimitInput(item)
    local expect = field(item, "expect")

    local value, code
    if field(item, "recipe") == "modem_frame" and #text > limits.MODEM_FRAME_BYTES then
      -- A modem receiver discards oversized frames before JSON decoding.
      value, code = nil, "message_too_large"
    else
      value, code = cj1.decode(text)
    end

    if expect == "accepted" then
      assertTrue(value ~= nil, name .. ": refused with " .. tostring(code))
    else
      assertTrue(value == nil, name .. ": accepted past the limit")
      assertEqual(code, expect, name)
    end
  end
end)

--------------------------------------------------------------------------
-- Error catalog
--------------------------------------------------------------------------

test("the error catalog matches the specification exactly", function()
  local document = catalog.load("errors/catalog.json")
  local codes = field(document, "codes")
  assertEqual(#codes, #errors.catalog, "catalog size")
  for index = 1, #codes do
    local item = rawget(codes, index)
    local code = field(item, "code")
    assertEqual(errors.catalog[index].code, code, "catalog order at " .. index)
    assertTrue(errors.isKnown(code), code .. " is not known")
    assertEqual(errors.retryable(code), field(item, "retryable"), code .. " retryability")
  end
end)
