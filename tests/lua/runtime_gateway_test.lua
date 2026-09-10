-- The Gateway transport.
--
-- This is the leg between a Central Server and the External Application, and
-- the only place in CraftNet that speaks HTTP. What it must get right is mostly
-- about failure: a socket that opened but never answered, a frame that does not
-- decode, a far end that went away mid-send, and an application that is simply
-- not running.
--
-- The `http` API is injected, so everything here drives the real adapter over a
-- scripted socket rather than a stand-in for the adapter itself.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local fakes = require("tests.lua.support.fakes")

local URL = "wss://127.0.0.1:8080/gateway"
local CREDENTIAL_HEX = string.rep("b2", 32)
local CREDENTIAL = protocol.conformance.sha256.fromHex(CREDENTIAL_HEX)

local WELCOME = protocol.conformance.cj1.encode(protocol.object({
  v = 1,
  gateway_session_id = "gws-000003",
  accepted_topology_revision = 31,
  accepted_traffic_sequence = 879,
  server_time = "2026-09-09T12:00:00Z",
}))

--------------------------------------------------------------------------
-- A scripted CraftOS http API
--------------------------------------------------------------------------

-- newHttp builds an `http` stand-in and a record of everything that reached it.
-- `options.refuse` is a Go process that is not running; `options.welcome`
-- replaces what the far end answers with; `options.failSend` is a socket that
-- dies under a write.
local function newHttp(options)
  options = options or {}
  local log = { sent = {}, headers = nil, closed = 0, opened = 0 }
  log.http = {
    websocket = function(url, headers)
      log.opened = log.opened + 1
      if options.refuse then return false, "Could not connect" end
      log.headers = headers
      log.url = url
      return {
        send = function(text)
          if options.failSend and #log.sent >= options.failSend then
            error("socket closed", 0)
          end
          log.sent[#log.sent + 1] = text
          return true
        end,
        receive = function() return options.welcome end,
        close = function() log.closed = log.closed + 1 return true end,
      }
    end,
  }
  return log
end

local function newGateway(log, clock, options)
  options = options or {}
  return runtimePackage.adapters.gateway({
    url = URL,
    world_id = "world-overworld",
    central_id = "central-main",
    clock = clock,
    http = log.http,
    credential = options.credential or function() return CREDENTIAL end,
    revisions = options.revisions or function() return 31, 879 end,
  })
end

local function connected()
  local clock = fakes.clock(0)
  local log = newHttp({ welcome = WELCOME })
  local gateway = newGateway(log, clock)
  assert(gateway:connect(), "the fixture gateway did not connect")
  return gateway, log, clock
end

--------------------------------------------------------------------------
-- Opening
--------------------------------------------------------------------------

test("the Gateway Credential travels in the Authorization header, as hex", function()
  local _, log = connected()
  assertEqual(log.headers.Authorization, "Bearer " .. CREDENTIAL_HEX,
    "the secret store holds bytes; the far end digests the hex it printed")
  assertEqual(log.url, URL, "and it dials the configured URL")
end)

test("connecting sends a hello the far end can read", function()
  local _, log = connected()
  local hello = assert(protocol.gateway.decodeFrame and log.sent[1], "no hello was sent")
  local decoded = assert(protocol.conformance.cj1.decode(hello), "the hello did not decode")
  assertEqual(rawget(decoded, "world_id"), "world-overworld", "world")
  assertEqual(rawget(decoded, "central_id"), "central-main", "central")
  assertEqual(rawget(decoded, "last_topology_revision"), 31,
    "a reconnecting World says what it already holds")
  assertEqual(rawget(decoded, "last_traffic_sequence"), 879, "traffic sequence")
end)

test("a session exists only once the welcome decodes", function()
  local gateway = connected()
  assertTrue(gateway:ready(), "the welcome opened a session")
  assertEqual(gateway:session(), "gws-000003", "and named it")
end)

test("a socket that never answers is not a Gateway Session", function()
  local clock = fakes.clock(0)
  local log = newHttp({ welcome = nil })
  local gateway = newGateway(log, clock)

  assertTrue(not gateway:connect(), "connect did not succeed")
  assertTrue(not gateway:ready(), "and there is no session")
  assertEqual(gateway:describe().error.code, "gateway_unavailable", "code")
  assertEqual(log.closed, 1, "the socket was closed rather than left open")
end)

test("a welcome that does not decode is not a Gateway Session", function()
  local clock = fakes.clock(0)
  local log = newHttp({ welcome = '{"v":1,"gateway_session_id":"gws-1"}' })
  local gateway = newGateway(log, clock)

  assertTrue(not gateway:connect(), "an incomplete welcome opens nothing")
  assertTrue(not gateway:ready(), "no session")
  assertEqual(gateway:describe().error.code, "invalid_message", "code")
  assertEqual(log.closed, 1, "the socket was closed")
end)

test("a Central Server holding no Gateway Credential does not dial at all", function()
  local clock = fakes.clock(0)
  local log = newHttp({ welcome = WELCOME })
  local gateway = newGateway(log, clock, { credential = function() return nil end })

  assertTrue(not gateway:connect(), "it did not connect")
  assertEqual(gateway:describe().error.code, "authentication_failed", "code")
  assertEqual(log.opened, 0, "and nothing was opened")
end)

test("a Computer with no HTTP API reports it rather than failing at the socket", function()
  local clock = fakes.clock(0)
  local gateway = runtimePackage.adapters.gateway({
    url = URL, world_id = "world-overworld", central_id = "central-main",
    clock = clock, http = {}, credential = function() return CREDENTIAL end,
  })
  assertTrue(not gateway:connect(), "it did not connect")
  assertEqual(gateway:describe().error.code, "gateway_unavailable", "code")
end)

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------

local function externalRequest()
  return protocol.object({
    ancestry = protocol.object({
      world_id = "world-overworld", isp_id = "isp-acme",
      customer_network_id = "network-farm", router_id = "router-farm",
      computer_id = "cmp-harvester", local_address = "192.168.1.20",
    }),
    source_flow_id = "flow-a1",
    operation = "test.identity",
    access_token = "opaque.bearer.token",
    payload = protocol.object(),
  })
end

test("a frame put on the session arrives as the wire says it should", function()
  local gateway, log = connected()
  assertTrue(gateway:send("external_request", externalRequest(), { request_id = "central-r7" }),
    "the frame was sent")

  local decoded = assert(protocol.gateway.decodeFrame(log.sent[2]), "it did not decode")
  assertEqual(decoded.kind, "external_request", "kind")
  assertEqual(decoded.request_id, "central-r7", "correlation travels with it")
  assertEqual(rawget(rawget(decoded.body, "ancestry"), "computer_id"), "cmp-harvester",
    "and the ancestry the Central Server stamped")
end)

test("a kind the Gateway does not carry is refused before it leaves", function()
  local gateway, log = connected()
  local sent = #log.sent

  local ok, problem = gateway:send("dns_query", protocol.object({ name = "h.farm.acme.craft" }))
  assertTrue(not ok, "dns_query must not travel on the Gateway")
  assertTrue(problem ~= nil, "and it says why")
  assertEqual(#log.sent, sent, "nothing reached the socket")
  assertTrue(gateway:ready(), "a fault in what was asked for is not a fault in the session")
end)

test("nothing travels on a session that is not there", function()
  local clock = fakes.clock(0)
  local log = newHttp({ refuse = true })
  local gateway = newGateway(log, clock)
  gateway:connect()

  local ok, problem = gateway:send("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 0 }))
  assertTrue(not ok, "the send was refused")
  assertTrue(problem ~= nil, "with a reason the Central Server turns into a stable code")
end)

test("a socket that dies under a write drops the session and arms a retry", function()
  local clock = fakes.clock(0)
  -- The hello is the first write; the second one fails.
  local log = newHttp({ welcome = WELCOME, failSend = 1 })
  local gateway = newGateway(log, clock)
  assertTrue(gateway:connect(), "connected")

  local ok = gateway:send("external_request", externalRequest(), { request_id = "central-r7" })
  assertTrue(not ok, "the send failed")
  assertTrue(not gateway:ready(), "and the session went with it")
  assertTrue(gateway:describe().attempts > 0, "a retry is armed")
end)

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

local function answer(requestId)
  return protocol.conformance.cj1.encode(protocol.object({
    v = 1, kind = "external_response", request_id = requestId,
    body = protocol.object({ payload = protocol.object({ verified = "yes" }) }),
  }))
end

test("an answer arriving as a CraftOS event is queued for the Central Server", function()
  local gateway = connected()

  assertTrue(gateway:observe("websocket_message", URL, answer("central-r7")),
    "the adapter claimed the event")
  assertEqual(gateway:pending(), 1, "one frame waiting")

  local frame = gateway:next()
  assertEqual(frame.kind, "external_response", "kind")
  assertEqual(frame.request_id, "central-r7", "correlated")
  assertEqual(rawget(rawget(frame.body, "payload"), "verified"), "yes", "payload")
  assertEqual(gateway:pending(), 0, "and it was taken")
end)

test("one bad frame is not a reason to lose a World", function()
  local gateway = connected()

  assertTrue(gateway:observe("websocket_message", URL, "{not json"), "the event was claimed")
  assertEqual(gateway:pending(), 0, "nothing was queued")
  assertTrue(gateway:ready(), "the session is still there")
  assertEqual(gateway:describe().error.code, "invalid_message", "and the reason was recorded")

  -- And it still works afterwards, which is the whole claim.
  gateway:observe("websocket_message", URL, answer("central-r8"))
  assertEqual(gateway:pending(), 1, "a good frame after a bad one still arrives")
end)

test("a frame the Gateway does not carry inward is refused", function()
  local gateway = connected()
  gateway:observe("websocket_message", URL,
    '{"v":1,"kind":"dns_query","body":{"name":"h.farm.acme.craft"}}')
  assertEqual(gateway:pending(), 0, "nothing was queued")
  assertEqual(gateway:describe().error.code, "invalid_message", "code")
end)

test("an event belonging to something else is left for it", function()
  local gateway = connected()
  assertTrue(not gateway:observe("modem_message", 42000, "..."),
    "a modem event is not the Gateway's")
  assertTrue(not gateway:observe("websocket_message", "wss://elsewhere/gateway", answer("r1")),
    "another socket's message is not the Gateway's either")
  assertEqual(gateway:pending(), 0, "and neither was queued")
end)

--------------------------------------------------------------------------
-- Staying up
--------------------------------------------------------------------------

test("the far end closing drops the session and arms bounded backoff", function()
  local gateway, log, clock = connected()

  assertTrue(gateway:observe("websocket_closed", URL), "the event was claimed")
  assertTrue(not gateway:ready(), "the session is gone")
  assertEqual(gateway:describe().error.code, "gateway_unavailable", "code")

  local opened = log.opened
  clock:advance(500)
  gateway:tick()
  assertEqual(log.opened, opened, "too early to retry")

  clock:advance(5000)
  gateway:tick()
  assertTrue(gateway:ready(), "and once the backoff elapsed it reconnected")
end)

test("backoff grows and stops growing", function()
  local clock = fakes.clock(0)
  local log = newHttp({ refuse = true })
  local gateway = newGateway(log, clock)

  local previous = 0
  for _ = 1, 20 do
    gateway:connect()
    local wait = gateway:nextWakeMs() - clock:now()
    assertTrue(wait >= previous, "each wait is at least the last")
    assertTrue(wait <= 30000, "and none exceeds the ceiling")
    previous = wait
    clock:advance(wait)
  end
  assertEqual(previous, 30000, "it settles at the ceiling rather than growing forever")
end)

test("an idle session heartbeats rather than going silent", function()
  local gateway, log, clock = connected()
  local sent = #log.sent

  clock:advance(5000)
  gateway:tick()
  assertEqual(#log.sent, sent, "not yet due")

  clock:advance(20000)
  gateway:tick()
  assertTrue(#log.sent > sent, "a heartbeat went out")

  local frame = assert(protocol.gateway.decodeFrame(log.sent[#log.sent]), "it decoded")
  assertEqual(frame.kind, "heartbeat", "kind")
  assertEqual(rawget(frame.body, "revision"), 31, "carrying this World's revision")
end)

test("a busy session does not heartbeat on top of its own traffic", function()
  local gateway, log, clock = connected()

  clock:advance(20000)
  gateway:send("external_request", externalRequest(), { request_id = "central-r7" })
  local sent = #log.sent

  clock:advance(5000)
  gateway:tick()
  assertEqual(#log.sent, sent, "the send already proved the session is alive")
end)

test("disconnecting is idempotent and leaves nothing behind", function()
  local gateway, log = connected()
  gateway:disconnect()
  assertTrue(not gateway:ready(), "no session")
  gateway:disconnect()
  assertEqual(log.closed, 1, "closing twice closes the socket once")
end)
