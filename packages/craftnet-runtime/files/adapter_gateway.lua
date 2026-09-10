-- The Gateway transport: one outbound WebSocket per World.
--
-- This is the leg between a Central Server and the External Application, and
-- the only place in CraftNet that speaks HTTP. Everything above it -- the
-- envelope, the schemas, the limits, the correlation -- belongs to
-- craftnet-protocol; this opens a socket, puts text on it, takes text off it,
-- and says when it is ready.
--
-- It is deliberately the dumbest layer in the package, for the same reason the
-- modem transport is: what travels here is decided by an authority that has
-- never heard of a socket.
--
-- CraftOS delivers websocket events through the same queue as modem messages,
-- so a Central Server cannot simply block on one or the other. The transport it
-- already polls offers this adapter every event it does not recognise, and the
-- frames that arrive are queued for the composition root to drain.

local internal = ...
local protocol = internal("protocol")

local adapter = {}

local Gateway = {}
Gateway.__index = Gateway

-- Reconnection is bounded exponential backoff, the same shape the connectivity
-- monitor uses for a parent relationship. A World whose External Application is
-- down does not hammer it, and does not give up on it either.
adapter.BACKOFF_FIRST_MS = 1000
adapter.BACKOFF_LIMIT_MS = 30000

-- How long the Central Server waits for the welcome that opens a session. A
-- socket that connected but never answered is not a Gateway Session.
adapter.WELCOME_TIMEOUT_MS = 10000

-- A heartbeat states liveness on a socket that would otherwise be silent while
-- a World is idle.
adapter.HEARTBEAT_MS = 15000

-- new wires the adapter to its dependencies. `http` is injected so the whole
-- thing can be driven without CraftOS; on a real Computer it is the `http`
-- global, and this is the only file in CraftNet that reaches for it.
function adapter.new(options)
  assert(type(options) == "table", "a Gateway adapter needs options")
  assert(type(options.url) == "string" and options.url ~= "",
    "a Gateway adapter needs the External Application's URL")
  assert(type(options.world_id) == "string", "a Gateway adapter needs the World identity")
  assert(type(options.central_id) == "string", "a Gateway adapter needs the Central Server identity")
  local clock = options.clock
  assert(type(clock) == "table" and type(clock.now) == "function",
    "a Gateway adapter needs a clock adapter")

  return setmetatable({
    url = options.url,
    worldId = options.world_id,
    centralId = options.central_id,
    -- credential is a function rather than a value, so a rotated Gateway
    -- Credential is picked up by the next reconnect and no copy of it is held
    -- here between attempts.
    credential = options.credential,
    http = options.http,
    clock = clock,
    revisions = options.revisions or function() return 0, 0 end,
    log = options.log,
    socket = nil,
    sessionId = nil,
    inbound = {},
    attempts = 0,
    nextAttemptMs = 0,
    lastSendMs = 0,
    lastError = nil,
  }, Gateway)
end

--------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------

-- ready reports whether there is a Gateway Session. Until the welcome has been
-- read there is a socket but no session, and an External Operation offered in
-- that window fails with gateway_unavailable rather than being held.
function Gateway:ready()
  return self.socket ~= nil and self.sessionId ~= nil
end

function Gateway:session()
  return self.sessionId
end

function Gateway:describe()
  return {
    url = self.url,
    ready = self:ready(),
    gateway_session_id = self.sessionId,
    attempts = self.attempts,
    error = self.lastError,
  }
end

function Gateway:note(code, message)
  self.lastError = { code = code, message = message }
  if self.log then self.log(code, message) end
  return nil, message
end

--------------------------------------------------------------------------
-- Connecting
--------------------------------------------------------------------------

-- header is the one thing that authenticates this socket. The credential is
-- carried in a header rather than in the URL so it never lands in a log, a
-- proxy, or a browser history.
function Gateway:header()
  local credential = self.credential and self.credential()
  if not credential then return nil end
  -- The secret store holds raw bytes; the External Application digests the
  -- lowercase hexadecimal form it printed at provisioning time.
  return { Authorization = "Bearer " .. protocol.conformance.sha256.toHex(credential) }
end

-- backoff arms the next attempt. Failing to connect is ordinary -- the External
-- Application may simply not be running -- so it is recorded and retried rather
-- than raised.
function Gateway:backoff(now)
  self.attempts = self.attempts + 1
  local delay = adapter.BACKOFF_FIRST_MS * (2 ^ math.min(self.attempts - 1, 10))
  self.nextAttemptMs = now + math.min(delay, adapter.BACKOFF_LIMIT_MS)
end

-- connect opens the socket and completes the opening exchange. Both halves
-- happen here: a socket without a welcome is not something the rest of CraftNet
-- should ever be handed.
function Gateway:connect()
  local now = self.clock:now()
  if self.socket then self:disconnect() end

  local headers = self:header()
  if not headers then
    self:backoff(now)
    return self:note("authentication_failed", "this Central Server holds no Gateway Credential")
  end

  local http = self.http or _G.http
  if type(http) ~= "table" or type(http.websocket) ~= "function" then
    self:backoff(now)
    return self:note("gateway_unavailable", "this Computer has no HTTP API")
  end

  local socket, problem = http.websocket(self.url, headers)
  if not socket then
    self:backoff(now)
    -- The far end refused, or there is nothing there. Either way the World
    -- carries on: nothing internal ever needed the External Application.
    return self:note("gateway_unavailable", tostring(problem or "the Gateway refused the connection"))
  end

  local topologyRevision, trafficSequence = self.revisions()
  local hello, code, detail = protocol.gateway.encodeHello({
    world_id = self.worldId,
    central_id = self.centralId,
    last_topology_revision = topologyRevision,
    last_traffic_sequence = trafficSequence,
  })
  if not hello then
    self:closeSocket(socket)
    self:backoff(now)
    return self:note(code, detail)
  end

  local sent = pcall(socket.send, hello, false)
  if not sent then
    self:closeSocket(socket)
    self:backoff(now)
    return self:note("gateway_unavailable", "the Gateway closed before the hello was sent")
  end

  local received = select(2, pcall(socket.receive, adapter.WELCOME_TIMEOUT_MS / 1000))
  if type(received) ~= "string" then
    self:closeSocket(socket)
    self:backoff(now)
    return self:note("gateway_unavailable", "the Gateway never sent a welcome")
  end

  local welcome, welcomeCode, welcomeProblem = protocol.gateway.decodeWelcome(received)
  if not welcome then
    self:closeSocket(socket)
    self:backoff(now)
    return self:note(welcomeCode, welcomeProblem)
  end

  self.socket = socket
  self.sessionId = welcome.gateway_session_id
  self.welcome = welcome
  self.attempts = 0
  self.nextAttemptMs = 0
  self.lastSendMs = now
  self.lastError = nil
  return true, welcome
end

function Gateway:closeSocket(socket)
  if socket then pcall(socket.close) end
end

-- disconnect drops the session. Nothing in flight is replayed on the next one:
-- CraftNet never resends an ordinary request on its own, and the Central Server
-- has already answered whoever was waiting.
function Gateway:disconnect()
  self:closeSocket(self.socket)
  self.socket = nil
  self.sessionId = nil
  self.welcome = nil
  return true
end

--------------------------------------------------------------------------
-- Sending
--------------------------------------------------------------------------

-- send is the seam the runtime performs a gateway effect through. It answers
-- nil and a reason rather than raising, because the Central Server turns that
-- into `gateway_unavailable` for whoever asked.
function Gateway:send(messageKind, body, correlation)
  if not self:ready() then
    return nil, "the Gateway Session is not ready"
  end
  local text, code, problem = protocol.gateway.encodeFrame(messageKind, body, correlation)
  if not text then
    -- The frame was refused before it left. This is a fault in what was asked
    -- for, not in the socket, so the session stays up.
    self:note(code, problem)
    return nil, problem
  end

  local ok = pcall(self.socket.send, text, false)
  if not ok then
    self:disconnect()
    self:backoff(self.clock:now())
    return nil, "the Gateway Session closed"
  end
  self.lastSendMs = self.clock:now()
  return true
end

--------------------------------------------------------------------------
-- Receiving
--------------------------------------------------------------------------

-- observe takes one CraftOS event the modem transport did not recognise. It
-- answers whether the event was this adapter's, so the transport knows whether
-- to keep waiting.
--
-- A frame that does not decode is dropped with its reason recorded rather than
-- closing the session: one bad message is not a reason to lose a World.
function Gateway:observe(event, url, message)
  if event == "websocket_closed" then
    if self.socket and url == self.url then
      self:disconnect()
      self:backoff(self.clock:now())
      self:note("gateway_unavailable", "the External Application closed the session")
    end
    return true
  end
  if event ~= "websocket_message" or url ~= self.url then return false end
  if type(message) ~= "string" then return true end

  local frame, code, problem = protocol.gateway.decodeFrame(message)
  if not frame then
    self:note(code, problem)
    return true
  end
  self.inbound[#self.inbound + 1] = frame
  return true
end

-- pending reports how many frames are waiting, so a composition root can drain
-- them before it hands control back.
function Gateway:pending()
  return #self.inbound
end

-- next takes the oldest frame the External Application sent.
function Gateway:next()
  if #self.inbound == 0 then return nil end
  return table.remove(self.inbound, 1)
end

--------------------------------------------------------------------------
-- Keeping it up
--------------------------------------------------------------------------

-- tick reconnects when the backoff has elapsed and heartbeats an idle session.
-- The Central Server calls it from its own loop, so the Gateway is maintained
-- by the same clock as everything else rather than by a thread of its own.
function Gateway:tick()
  local now = self.clock:now()
  if not self.socket then
    if now >= self.nextAttemptMs then self:connect() end
    return self:ready()
  end
  if self:ready() and (now - self.lastSendMs) >= adapter.HEARTBEAT_MS then
    self:send("heartbeat", protocol.object({
      connectivity_state = "ready",
      revision = select(1, self.revisions()),
    }))
  end
  return self:ready()
end

-- nextWakeMs is when this adapter next needs to be asked something, so an idle
-- Central Server sleeps until then instead of spinning.
function Gateway:nextWakeMs()
  if not self.socket then return self.nextAttemptMs end
  return self.lastSendMs + adapter.HEARTBEAT_MS
end

adapter.Gateway = Gateway

return adapter
