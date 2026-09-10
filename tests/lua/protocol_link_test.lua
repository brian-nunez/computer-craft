-- Exercises the enrolled link: correlation, timeouts, bounded in-flight work,
-- and error propagation.
--
-- The transport and clock are injected fakes. Milestone 3 supplies the real
-- modem adapter; nothing in this file knows what a modem is, which is the point
-- of the seam.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local frame = protocol.conformance.frame

local SESSION_KEY = string.rep("\42", 32)

local function newSessionPair()
  local function build()
    return frame.newSession({
      relationship_id = "rel-farm-0007",
      session_id = "ses-000042",
      session_key = SESSION_KEY,
    })
  end
  return build(), build()
end

-- fakeClock advances only when a test says so, so a timeout is deterministic
-- rather than wall-clock dependent.
local function fakeClock()
  return {
    time = 0,
    now = function(self) return self.time end,
    advance = function(self, milliseconds) self.time = self.time + milliseconds end,
  }
end

-- fakeTransport records what the link sent and replays a scripted inbox. A
-- scripted entry may be a frame string, or a function called with the clock so
-- a test can make time pass while the link waits.
local function fakeTransport(clock)
  return {
    sent = {},
    inbox = {},
    closed = false,
    clock = clock,
    send = function(self, text)
      self.sent[#self.sent + 1] = text
      return true
    end,
    receive = function(self)
      local entry = table.remove(self.inbox, 1)
      if entry == nil then return nil end
      if type(entry) == "function" then return entry(self.clock) end
      return entry
    end,
    close = function(self) self.closed = true end,
  }
end

local function newLink(options)
  options = options or {}
  local clock = fakeClock()
  local transport = fakeTransport(clock)
  local session, peer = newSessionPair()
  local link = protocol.open({
    session = session,
    transport = transport,
    clock = clock,
    request_id_prefix = "req",
    default_timeout_ms = options.default_timeout_ms or 5000,
    maximum_in_flight = options.maximum_in_flight,
  })
  return link, transport, peer, clock
end

test("a request is correlated with its reply", function()
  local link, transport, peer = newLink()
  transport.inbox[1] = assert(peer:seal("dns_result", protocol.object({
    canonical_name = "harvester.farm.acme.craft",
    customer_network_id = "net-farm",
    computer_id = "cmp-harvester",
    address = "192.168.1.20",
  }), "req-1"))

  local result = assert(link:request("dns_query",
    protocol.object({ name = "harvester.farm.acme.craft" })))
  assertEqual(result.kind, "dns_result", "kind")
  assertEqual(rawget(result.body, "address"), "192.168.1.20", "address")
  assertEqual(#transport.sent, 1, "exactly one frame was sent")
end)

test("an unrelated inbound message reaches the handler instead of the caller", function()
  local link, transport, peer = newLink()
  local served = {}
  link:serve(function(message)
    served[#served + 1] = message.kind
    return nil
  end)

  transport.inbox[1] = assert(peer:seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 4 })))
  transport.inbox[2] = assert(peer:seal("ack", protocol.object({ acked_request_id = "req-1" }), "req-1"))

  local result = assert(link:request("config_request", protocol.object({ known_revision = 0 })))
  assertEqual(result.kind, "ack", "the awaited reply is returned")
  assertEqual(#served, 1, "the unrelated message was served")
  assertEqual(served[1], "heartbeat", "served kind")
end)

test("a request without a reply times out", function()
  local link, transport, _, clock = newLink({ default_timeout_ms = 250 })
  transport.inbox[1] = function(fake)
    fake:advance(250)
    return nil
  end

  local result, code = link:request("config_request", protocol.object({ known_revision = 0 }))
  assertTrue(result == nil, "a timed-out request must not return a message")
  assertEqual(code, "request_timeout", "code")
  assertEqual(clock:now(), 250, "the clock advanced to the deadline")
end)

test("a catalog error reply is returned as its code", function()
  local link, transport, peer = newLink()
  transport.inbox[1] = assert(peer:seal("error", protocol.errors.new(
    "name_not_found", "No computer answers to that name."), "req-1"))

  local result, code, message = link:request("dns_query", protocol.object({ name = "ghost.farm.acme.craft" }))
  assertTrue(result == nil, "an error reply is not a result")
  assertEqual(code, "name_not_found", "code")
  assertEqual(message, "No computer answers to that name.", "player-safe message")
end)

test("excess in-flight work fails with busy rather than queueing", function()
  local link = newLink({ maximum_in_flight = 0 })
  local result, code = link:request("config_request", protocol.object({ known_revision = 0 }))
  assertTrue(result == nil, "work past the bound must not be accepted")
  assertEqual(code, "busy", "code")
end)

test("a forged frame is dropped rather than answered", function()
  local link, transport, peer = newLink({ default_timeout_ms = 100 })
  local forged = string.gsub(
    assert(peer:seal("heartbeat", protocol.object({ connectivity_state = "ready", revision = 4 }))),
    '"mac":"%x+"', '"mac":"' .. string.rep("0", 64) .. '"', 1)
  transport.inbox[1] = forged
  transport.inbox[2] = function(fake)
    fake:advance(100)
    return nil
  end

  local result, code = link:request("config_request", protocol.object({ known_revision = 0 }))
  assertTrue(result == nil, "a forged frame must not satisfy a request")
  assertEqual(code, "request_timeout", "the link waited rather than answering the forgery")
  assertEqual(link.lastRejection.code, "authentication_failed", "the forgery was recorded")
  assertEqual(#transport.sent, 1, "no response was sent to the forgery")
end)

test("request identifiers advance and never repeat on one link", function()
  local link, transport, peer = newLink({ default_timeout_ms = 0 })
  local seen = {}
  for _ = 1, 8 do
    transport.inbox = {}
    link:request("config_request", protocol.object({ known_revision = 0 }))
  end
  for _, text in ipairs(transport.sent) do
    local message = assert(peer:open(text))
    assertTrue(seen[message.request_id] == nil, "request identifier " .. message.request_id .. " repeated")
    seen[message.request_id] = true
  end
  assertEqual(#transport.sent, 8, "every request was sent")
end)

test("a closed link refuses further work and closes its transport", function()
  local link, transport = newLink()
  assertTrue(link:close(), "close reports success")
  assertTrue(transport.closed, "the transport was closed")

  local result, code = link:request("config_request", protocol.object({ known_revision = 0 }))
  assertTrue(result == nil, "a closed link must not send")
  assertEqual(code, "upstream_unavailable", "code")

  local notified, notifyCode = link:notify("heartbeat",
    protocol.object({ connectivity_state = "disconnected", revision = 4 }))
  assertTrue(notified == nil, "a closed link must not notify")
  assertEqual(notifyCode, "upstream_unavailable", "notify code")
end)

test("a notification is sent without a request identifier", function()
  local link, transport, peer = newLink()
  assertTrue(link:notify("heartbeat", protocol.object({ connectivity_state = "ready", revision = 4 })))
  local message = assert(peer:open(transport.sent[1]))
  assertEqual(message.kind, "heartbeat", "kind")
  assertTrue(message.request_id == nil, "an uncorrelated message omits request_id")
end)

test("a message the schema refuses is never put on the wire", function()
  local link, transport = newLink()
  local ok, code = link:notify("heartbeat", protocol.object({ connectivity_state = "online", revision = 4 }))
  assertTrue(ok == nil, "an invalid body must not be sent")
  assertEqual(code, "invalid_message", "code")
  assertEqual(#transport.sent, 0, "nothing reached the transport")
end)
