-- The malformed input corpus.
--
-- The fixture catalog proves that specific bad inputs are classified the same
-- way in Lua and in Go. This proves something broader and less precise: that a
-- systematic sweep of damaged, truncated, mutated, and type-confused input
-- produces a stable catalog error every single time -- never a crash, never a
-- Lua error escaping the protocol, and never a state change on the way out.
--
-- Nothing here checks an exact code. That is deliberate: the point is that
-- there is always *an* answer from the catalog, whatever was thrown at it.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local reference = require("tests.lua.support.reference")

local cj1 = protocol.conformance.cj1
local frame = protocol.conformance.frame
local schema = protocol.conformance.schema
local sha256 = protocol.conformance.sha256
local errors = protocol.errors

local SESSION_KEY = sha256.fromHex(string.rep("5a", 32))

local function newSession()
  return frame.newSession({
    relationship_id = "rel-home-alex",
    session_id = "router-home-s1",
    session_key = SESSION_KEY,
  })
end

-- refusal insists that whatever came back is a refusal expressed in the
-- vocabulary the rest of CraftNet speaks.
local function refusal(what, value, code)
  assertTrue(value == nil, what .. ": the input was accepted")
  assertTrue(code ~= nil, what .. ": refused with no code at all")
  assertTrue(errors.isKnown(code),
    what .. ": refused with '" .. tostring(code) .. "', which is not in the catalog")
end

-- survives runs one call and insists the protocol answered rather than raising.
-- A Lua error escaping here would be a crash in world, on a Computer with no
-- console to read it from.
local function survives(what, call)
  local ok, value, code = pcall(call)
  assertTrue(ok, what .. ": raised instead of refusing: " .. tostring(value))
  return value, code
end

--------------------------------------------------------------------------
-- Canonical JSON
--------------------------------------------------------------------------

-- Hand-written damage, each one a shape a decoder is tempted to be lenient
-- about. Leniency here is how two implementations drift apart.
local DOCUMENTS = {
  "", " ", "{", "}", "[", "]", "{}{}", "[][]", "null", "true", "1",
  '{"a"}', '{"a":}', '{:1}', '{"a":1,}', '[1,]', '[,1]', '[1 2]',
  '{"a":1"b":2}', '{"a":01}', '{"a":+1}', '{"a":1.}', '{"a":.1}',
  '{"a":1e}', '{"a":0x1}', '{"a":NaN}', '{"a":Infinity}', '{"a":-Infinity}',
  '{"a":1e999}', '{"a":"\\x"}', '{"a":"\\u12"}', '{"a":"\\ud800"}',
  '{"a":"\\udc00"}', '{"a":"unterminated}', "{'a':1}", '{"a":\'b\'}',
  '{"a":1}\n{"b":2}', '{"a":1} ', ' {"a":1}', '{ "a":1}', '{"a": 1}',
  '{"a":1,"a":2}', '{"\\u0061":1,"a":2}', '{"b":1,"a":2}',
  '\xff\xfe', '{"a":"\xff"}', '{"a":"\x01"}', '{"a":"\t"}',
}

test("no malformed document ever escapes the decoder as an error", function()
  for index, text in ipairs(DOCUMENTS) do
    local what = "document " .. index .. " (" .. string.sub(text, 1, 24) .. ")"
    local ok, value, code = pcall(cj1.decode, text)
    assertTrue(ok, what .. ": raised instead of refusing: " .. tostring(value))
    if value ~= nil then
      -- A few of these are legitimately valid. Whatever was accepted must
      -- re-encode to exactly one canonical form.
      local encoded = assert(cj1.encode(value), what .. ": accepted but not encodable")
      local again = assert(cj1.decode(encoded), what .. ": its own output does not decode")
      assertEqual(assert(cj1.encode(again)), encoded, what .. ": canonical form is not stable")
    else
      assertTrue(errors.isKnown(code),
        what .. ": refused with '" .. tostring(code) .. "', which is not in the catalog")
    end
  end
end)

test("deep nesting is refused rather than exhausting the stack", function()
  for depth = protocol.limits.DEPTH + 1, protocol.limits.DEPTH + 40, 8 do
    local text = string.rep('{"a":', depth) .. "1" .. string.rep("}", depth)
    local value, code = survives("depth " .. depth, function() return cj1.decode(text) end)
    refusal("depth " .. depth, value, code)
  end
end)

test("an oversized string, object, and array are each refused at the limit", function()
  local long = '{"a":"' .. string.rep("x", protocol.limits.STRING_BYTES + 1) .. '"}'
  refusal("an oversized string", survives("string", function() return cj1.decode(long) end))

  local keys = {}
  for index = 1, protocol.limits.OBJECT_KEYS + 1 do
    keys[#keys + 1] = '"k' .. string.format("%04d", index) .. '":1'
  end
  local wide = "{" .. table.concat(keys, ",") .. "}"
  refusal("too many keys", survives("keys", function() return cj1.decode(wide) end))

  local elements = {}
  for index = 1, protocol.limits.ARRAY_ELEMENTS + 1 do elements[index] = "1" end
  local long_array = "[" .. table.concat(elements, ",") .. "]"
  refusal("too many elements", survives("elements", function() return cj1.decode(long_array) end))
end)

--------------------------------------------------------------------------
-- Authenticated frames
--------------------------------------------------------------------------

test("every truncation of a valid frame is refused", function()
  local sealed = assert(newSession():seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 4 })))

  for length = 0, #sealed - 1 do
    local session = newSession()
    local message, code = survives("truncation at " .. length, function()
      return session:open(string.sub(sealed, 1, length))
    end)
    refusal("truncation at " .. length, message, code)
  end
end)

test("a byte flipped anywhere in a valid frame is refused", function()
  local sealed = assert(newSession():seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 4 })))

  local checked = 0
  for position = 1, #sealed do
    local original = string.sub(sealed, position, position)
    -- One flip per position, chosen so the byte really changes.
    local replacement = original == "0" and "1" or "0"
    local mutated = string.sub(sealed, 1, position - 1) .. replacement
      .. string.sub(sealed, position + 1)
    if mutated ~= sealed then
      local session = newSession()
      local message, code = survives("flip at " .. position, function()
        return session:open(mutated)
      end)
      refusal("flip at " .. position, message, code)
      checked = checked + 1
    end
  end
  assertTrue(checked > 100, "the sweep covered " .. checked .. " positions")
end)

test("a refused frame never advances the session", function()
  local session = newSession()
  local peer = newSession()

  local first = assert(peer:seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 1 })))
  assert(session:open(first))

  -- A hundred bad frames in a row change nothing, so a peer cannot desynchronise
  -- a session simply by shouting at it.
  for index = 1, 100 do
    local rubbish = '{"v":1,"kind":"heartbeat","counter":' .. index .. ',"body":{},"mac":"'
      .. string.rep("0", 64) .. '"}'
    refusal("rubbish " .. index, survives("rubbish", function() return session:open(rubbish) end))
  end

  local second = assert(peer:seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 2 })))
  local message = assert(session:open(second), "the session still works afterwards")
  assertEqual(message.counter, 2, "and it is exactly where it should be")
end)

--------------------------------------------------------------------------
-- Message bodies
--------------------------------------------------------------------------

-- A body per kind that is known good, so the corpus below is damage applied to
-- something that would otherwise pass.
local BODIES = {
  heartbeat = { connectivity_state = "ready", revision = 4 },
  dns_query = { name = "harvester.farm.acme.craft" },
  route_register = {
    router_id = "router-home", customer_network_id = "network-home",
    customer_network_name = "home", router_provider_address = "100.64.0.10",
    isp_id = "isp-acme", revision = 3,
  },
  service_request = {
    source = {
      customer_network_id = "network-home", computer_id = "computer-home-alex",
      local_address = "192.168.1.20",
    },
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = {},
  },
  command_result = { command_id = "cmd-0001", status = "applied", revision = 7 },
}

local function asObject(plain)
  local object = protocol.object({})
  for key, value in pairs(plain) do
    if type(value) == "table" then
      rawset(object, key, asObject(value))
    else
      rawset(object, key, value)
    end
  end
  return object
end

test("every required field, removed, is refused with a stable code", function()
  for kind, plain in pairs(BODIES) do
    local ok, problem = schema.validateBody(kind, asObject(plain))
    assertTrue(ok, kind .. ": the known-good body does not validate: " .. tostring(problem))

    for field in pairs(plain) do
      local damaged = {}
      for key, value in pairs(plain) do
        if key ~= field then damaged[key] = value end
      end
      local accepted, _, code = survives(kind .. " without " .. field, function()
        return schema.validateBody(kind, asObject(damaged))
      end)
      if not accepted then
        assertTrue(code == nil or errors.isKnown(code),
          kind .. " without " .. field .. ": '" .. tostring(code) .. "' is not in the catalog")
      end
    end
  end
end)

-- Values of the wrong shape entirely, applied to every field of every kind.
local WRONG = { 0, -1, 1.5, "", "  ", true, false, string.rep("x", 300) }

test("every field, given the wrong kind of value, is refused", function()
  for kind, plain in pairs(BODIES) do
    for field in pairs(plain) do
      for index, value in ipairs(WRONG) do
        local damaged = {}
        for key, held in pairs(plain) do damaged[key] = held end
        damaged[field] = value

        local what = kind .. "." .. field .. " = " .. tostring(value) .. " (" .. index .. ")"
        local accepted, _, code = survives(what, function()
          return schema.validateBody(kind, asObject(damaged))
        end)
        if not accepted then
          assertTrue(code == nil or errors.isKnown(code),
            what .. ": '" .. tostring(code) .. "' is not in the catalog")
        end
      end
    end
  end
end)

test("a kind nobody defined is refused rather than guessed at", function()
  for _, kind in ipairs({ "", "HEARTBEAT", "heartbeat ", "hearbeat", "../heartbeat",
    "service_request\0", "admin", "drop_tables" }) do
    local accepted = survives("kind '" .. kind .. "'", function()
      return schema.validateBody(kind, protocol.object({}))
    end)
    assertTrue(not accepted, "'" .. kind .. "' was accepted as a message kind")
  end
end)

--------------------------------------------------------------------------
-- The engine
--------------------------------------------------------------------------

-- Damage aimed at a running World rather than at the wire. The invariant is
-- stronger here: a refused transition must change nothing at all.
local ENGINE_INPUTS = {
  {},
  { kind = "" },
  { kind = "drop_everything" },
  { kind = "configure" },
  { kind = "configure", settings = {} },
  { kind = "local_request" },
  { kind = "local_request", destination = {} },
  { kind = "local_request", destination = { customer_network_id = "network-farm" } },
  { kind = "resolve" },
  { kind = "resolve", name = "" },
  { kind = "resolve", name = "..." },
  { kind = "resolve", name = string.rep("a", 300) .. ".craft" },
  { kind = "bind_computer" },
  { kind = "bind_computer", computer_id = "", hostname = "" },
  { kind = "bind_computer", computer_id = 7, hostname = 7 },
  { kind = "expose_service" },
  { kind = "register_isp" },
  { kind = "register_isp", isp_id = "isp-acme", isp_name = "" },
  { kind = "register_router", router_id = "router-ghost" },
  { kind = "set_network_status" },
  { kind = "set_network_status", customer_network_id = "network-farm", status = "paused" },
  { kind = "external_request" },
  { kind = "external_request", operation = "" },
  { kind = "gateway_frame" },
  { kind = "gateway_frame", frame_kind = "admin_command" },
  { kind = "message" },
  { kind = "message", relationship_id = "rel-nowhere" },
  { kind = "effect_result" },
  { kind = "application_response" },
}

test("no damaged input crashes a role, and none of them changes anything", function()
  local sim = reference.build(core)

  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    for index, input in ipairs(ENGINE_INPUTS) do
      local what = name .. " input " .. index .. " (" .. tostring(input.kind) .. ")"
      local revisionBefore = engine.state.revision
      local flowsBefore = engine.flows:size()
      local transitBefore = engine.transit:size()

      local ok, outcome = pcall(function() return engine:handle(input, sim.now) end)
      assertTrue(ok, what .. ": raised instead of refusing: " .. tostring(outcome))
      assertTrue(outcome.result ~= nil, what .. ": produced no result")

      if not outcome.result.ok then
        assertTrue(errors.isKnown(outcome.result.code),
          what .. ": refused with '" .. tostring(outcome.result.code)
            .. "', which is not in the catalog")
        assertEqual(engine.state.revision, revisionBefore, what .. ": the revision moved")
        assertEqual(engine.flows:size(), flowsBefore, what .. ": a NAT Flow appeared")
        assertEqual(engine.transit:size(), transitBefore, what .. ": a correlation appeared")
        -- An ephemeral note about the refusal is fine and often useful. What
        -- must never happen is a durable change: that is the one that outlives
        -- the process and gets written to a disk.
        for _, change in ipairs(outcome.state_changes) do
          assertTrue(not change.durable,
            what .. ": it recorded a durable '" .. tostring(change.kind) .. "'")
        end
      end
    end
  end
end)

test("the World still works after the whole corpus has been thrown at it", function()
  local sim = reference.build(core)
  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    for _, input in ipairs(ENGINE_INPUTS) do
      pcall(function() return engine:handle(input, sim.now) end)
    end
  end

  sim:reset()
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({ asked = "after-the-corpus" }),
  })
  local answer = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(answer and answer.ok, "the reference World still carries traffic")
  assertEqual(rawget(answer.payload, "asked"), "after-the-corpus", "and it is the right answer")
end)
