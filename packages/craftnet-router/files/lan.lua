-- The Customer Router's LAN listener.
--
-- This is where a Computer becomes part of a Customer Network. It answers
-- discovery, runs the LAN Password challenge-response, and hands back the
-- configuration and the durable LAN Credential that come out of it.
--
-- The password is never transmitted. Both sides prove they know it by signing
-- the exchange, which means a captured exchange still allows an offline
-- dictionary attack against a weak password -- an accepted limit of a
-- gameplay-grade admission secret. What is not accepted is guessing at it
-- online, so failures are rate limited by the engine before they cost anything.

local internal = ...
local protocol = internal("protocol")

local lan = {}

-- How long a half-finished join is remembered. A Computer that walks away
-- mid-exchange must not hold a slot open.
lan.PENDING_MS = 15000

local Listener = {}
Listener.__index = Listener

function lan.newListener(options)
  assert(type(options) == "table", "a LAN listener needs options")
  for _, field in ipairs({ "transport", "clock", "password", "router_id", "engine" }) do
    assert(options[field] ~= nil, "a LAN listener needs '" .. field .. "'")
  end
  assert(protocol.validate.channel(options.discovery_channel), "a discovery channel is required")
  assert(protocol.validate.channel(options.operational_channel), "an operational channel is required")

  local listener = setmetatable({
    transport = options.transport,
    clock = options.clock,
    engine = options.engine,
    password = options.password,
    routerId = options.router_id,
    displayName = options.display_name or options.router_id,
    discoveryChannel = options.discovery_channel,
    operationalChannel = options.operational_channel,
    onJoined = options.on_joined,
    credentialFor = options.credential_for,
    childOf = options.child_of,
    pending = {},
    sessions = {},
    usedSessionIds = {},
    usedNonces = {},
  }, Listener)

  listener.transport:open(options.discovery_channel)
  listener.transport:open(options.operational_channel)
  return listener
end

--------------------------------------------------------------------------
-- Nonces and identities
--------------------------------------------------------------------------

-- nextGeneration draws and commits the router's durable counter. Uniqueness of
-- the exchange comes from this counter, not from any claim of randomness on a
-- Computer's part -- a LAN join does not pretend to have a secure random
-- source, and does not need one.
function Listener:nextGeneration()
  local state = self.engine.state
  state.lan_generation = (state.lan_generation or 0) + 1
  return state.lan_generation
end

-- parentNonce is derived from the LAN Password and the durable counter, so two
-- joins never share a transcript even when two Computers offer the same nonce.
function Listener:parentNonce(generation)
  return protocol.conformance.keys.nonce(self.password, "router", generation)
end

--------------------------------------------------------------------------
-- Serving
--------------------------------------------------------------------------

local function reply(self, channel, text)
  self.transport:transmit(channel, self.discoveryChannel, text)
end

function Listener:expire(now)
  for key, entry in pairs(self.pending) do
    if now - entry.started_ms >= lan.PENDING_MS then
      self.pending[key] = nil
    end
  end
end

-- step handles at most one inbound frame and reports what it meant. Returning
-- nil means nothing arrived before the timeout.
function Listener:step(timeoutMs)
  local channel, replyChannel, text = self.transport:receive(timeoutMs)
  if not channel then return nil end
  local now = self.clock:now()
  self:expire(now)

  if channel == self.discoveryChannel then
    local discovery = protocol.discovery.open(text)
    if discovery and discovery.kind == "discover" then
      return self:answerDiscovery(replyChannel, discovery, now)
    end
    return self:answerEnrollment(replyChannel, text, now)
  end
  return { kind = "ignored", channel = channel }
end

-- answerDiscovery says only what a Computer needs to start enrolling: who this
-- router is and where to talk. It proves nothing and reveals no secret.
function Listener:answerDiscovery(replyChannel, discovery, now)
  local body = protocol.object({
    parent_id = self.routerId,
    parent_role = "router",
    display_name = self.displayName,
    discovery_channel = self.discoveryChannel,
    client_nonce = rawget(discovery.body, "client_nonce"),
  })
  local text = protocol.discovery.seal("offer", body)
  if text then reply(self, replyChannel, text) end
  return { kind = "offered", role = rawget(discovery.body, "role") }
end

-- answerEnrollment drives one step of the challenge-response. A frame that does
-- not verify is answered with nothing at all: an authentication failure on a
-- shared channel tells an attacker nothing.
function Listener:answerEnrollment(replyChannel, text, now)
  -- The exchange is proved under a secret derived from a generation this router
  -- has not yet drawn, so an opening frame is tried against a fresh one and a
  -- continuing frame against the one its exchange already holds.
  local peeked = self:peek(text)
  if not peeked then return { kind = "dropped", reason = "unreadable" } end

  if peeked.kind == "enroll_open" then
    return self:beginEnrollment(replyChannel, text, now)
  end

  local entry = self.pending[peeked.request_id]
  if not entry then return { kind = "dropped", reason = "no such exchange" } end
  return self:continueEnrollment(entry, replyChannel, text, now)
end

-- peek reads the outer envelope without verifying it, only far enough to route
-- the frame to the right exchange. Nothing it returns is trusted.
function Listener:peek(text)
  local envelope = protocol.conformance.cj1.decode(text)
  if not envelope then return nil end
  local kind = rawget(envelope, "kind")
  local requestId = rawget(envelope, "request_id")
  if type(kind) ~= "string" or type(requestId) ~= "string" then return nil end
  return { kind = kind, request_id = requestId }
end

function Listener:beginEnrollment(replyChannel, text, now)
  local claimed = self:claimedIdentity(text)
  local admission = self.engine:handle({
    kind = "lan_admission",
    client_id = claimed.client_id,
    requested_name = claimed.requested_name,
  }, now)
  if not admission.result.ok then
    -- Rate limited. The caller is told nothing, which is the point.
    return { kind = "refused", reason = "rate_limited" }
  end

  local generation = self:nextGeneration()
  -- The LAN Password itself is the enrollment secret: both sides prove they
  -- know it by signing the exchange, and it is never transmitted.
  local secret = self.password
  local relationshipId = self.routerId .. "-r" .. generation

  local assignment
  local parent = protocol.parentEnrollment({
    enrollment_secret = secret,
    parent_id = self.routerId,
    parent_revision = self.engine.state.revision or 0,
    parent_nonce = self:parentNonce(generation),
    assign = function(request)
      local outcome = self.engine:handle({
        kind = "bind_computer",
        computer_id = request.client_id or self:identityFor(request.requested_name),
        hostname = request.requested_name,
      }, now)
      if not outcome.result.ok then
        return nil, outcome.result.code, outcome.result.message
      end
      assignment = outcome.result
      return {
        child_id = outcome.result.computer_id,
        relationship_id = relationshipId,
        operational_channel = self.operationalChannel,
        configuration = self:configurationFor(outcome.result),
      }
    end,
  })

  local challenge, code, problem = parent:receiveOpen(text)
  if not challenge then
    self.engine:handle({
      kind = "lan_failure",
      client_id = claimed.client_id,
      requested_name = claimed.requested_name,
    }, now)
    return { kind = "refused", reason = code or "authentication_failed", detail = problem }
  end

  self.pending[self:peek(text).request_id] = {
    parent = parent,
    secret = secret,
    generation = generation,
    relationship_id = relationshipId,
    claimed = claimed,
    started_ms = now,
  }
  reply(self, replyChannel, challenge)
  return { kind = "challenged", relationship_id = relationshipId }
end

function Listener:continueEnrollment(entry, replyChannel, text, now)
  local acceptText, outcome = entry.parent:receiveConfirm(text)
  if not acceptText then
    self.pending[self:peek(text).request_id] = nil
    self.engine:handle({
      kind = "lan_failure",
      client_id = entry.claimed.client_id,
      requested_name = entry.claimed.requested_name,
    }, now)
    return { kind = "refused", reason = outcome or "authentication_failed" }
  end

  self.pending[self:peek(text).request_id] = nil
  self.engine:handle({
    kind = "lan_success",
    client_id = entry.claimed.client_id,
    requested_name = entry.claimed.requested_name,
  }, now)

  -- The credential is committed before the acceptance leaves, so a Computer is
  -- never told it has joined a network that has forgotten it.
  local joined = {
    kind = "joined",
    child_id = outcome.child_id,
    relationship_id = outcome.relationship_id,
    relationship_credential = outcome.relationship_credential,
    operational_channel = self.operationalChannel,
  }
  if self.onJoined then self.onJoined(joined) end
  reply(self, replyChannel, acceptText)
  return joined
end

--------------------------------------------------------------------------
-- Reconnection
--------------------------------------------------------------------------

-- nextSessionGeneration draws the durable counter that names a session and
-- seeds this router's nonce for it. A session identifier is never reused with
-- the same credential, so the counter has to survive a restart.
function Listener:nextSessionGeneration()
  local state = self.engine.state
  state.session_generation = (state.session_generation or 0) + 1
  return state.session_generation
end

-- serveSession answers a Computer reconnecting with its LAN Credential. The
-- password plays no part: after the first join it is never used again.
function Listener:serveSession(links, replyChannel, text, now)
  local peeked = self:peek(text)
  if not peeked or peeked.kind ~= "session_open" then return nil end

  local relationshipId = self:relationshipInFrame(text)
  if not relationshipId then return { kind = "dropped", reason = "no relationship named" } end

  local credential = self.credentialFor and self.credentialFor(relationshipId)
  if not credential then return { kind = "dropped", reason = "no credential for that relationship" } end

  local generation = self:nextSessionGeneration()
  local parent = protocol.parentSession({
    relationship_credential = credential,
    relationship_id = relationshipId,
    parent_nonce = protocol.conformance.keys.nonce(credential, "router", generation),
    parent_revision = self.engine.state.revision or 0,
    session_id = self.routerId .. "-s" .. generation,
    used_session_ids = self.usedSessionIds,
    used_nonces = self.usedNonces,
  })

  local challenge, code = parent:receiveOpen(text)
  if not challenge then return { kind = "refused", reason = code } end

  self.sessions[peeked.request_id] = {
    parent = parent,
    relationship_id = relationshipId,
    reply_channel = replyChannel,
    started_ms = now,
  }
  reply(self, replyChannel, challenge)
  return { kind = "session_challenged", relationship_id = relationshipId }
end

function Listener:completeSession(links, text, now)
  local peeked = self:peek(text)
  if not peeked or peeked.kind ~= "session_confirm" then return nil end
  local entry = self.sessions[peeked.request_id]
  if not entry then return { kind = "dropped", reason = "no such session exchange" } end

  local session, transcript = entry.parent:receiveConfirm(text)
  self.sessions[peeked.request_id] = nil
  if not session then return { kind = "refused", reason = transcript } end

  links:adopt({
    relationship_id = entry.relationship_id,
    channel = self.operationalChannel,
    session = session,
    role = "computer",
    id = self.childOf and self.childOf(entry.relationship_id),
    direction = "child",
  })
  return { kind = "session_established", relationship_id = entry.relationship_id }
end

-- relationshipInFrame reads which relationship a handshake names, without
-- trusting it: the credential lookup and the proof are what decide.
function Listener:relationshipInFrame(text)
  local envelope = protocol.conformance.cj1.decode(text)
  local body = envelope and rawget(envelope, "body")
  return body and rawget(body, "relationship_id") or nil
end

-- handleFrame is the single entry point the links adapter installs: anything
-- that authenticated against no live session comes here.
function Listener:handleFrame(links, channel, replyChannel, text)
  local now = self.clock:now()
  self:expire(now)

  if channel == self.discoveryChannel then
    local discovery = protocol.discovery.open(text)
    if discovery and discovery.kind == "discover" then
      return self:answerDiscovery(replyChannel, discovery, now)
    end
    return self:answerEnrollment(replyChannel, text, now)
  end

  if channel == self.operationalChannel then
    return self:serveSession(links, replyChannel, text, now)
      or self:completeSession(links, text, now)
  end
  return nil
end

--------------------------------------------------------------------------
-- Assignment helpers
--------------------------------------------------------------------------

-- claimedIdentity reads what an opening frame says about itself, for rate
-- limiting only. It is never used to decide anything the caller benefits from.
function Listener:claimedIdentity(text)
  local envelope = protocol.conformance.cj1.decode(text)
  local body = envelope and rawget(envelope, "body")
  if not body then return {} end
  return {
    client_id = rawget(body, "client_id"),
    requested_name = rawget(body, "requested_name"),
  }
end

-- identityFor names a Computer that has never joined before. The router assigns
-- it, so a Computer cannot choose an identity that collides with a neighbour.
-- It is derived from the hostname the Operator chose, which is unique within
-- this Customer Network, and it does not follow a later rename: an identity is
-- not a name.
function Listener:identityFor(requestedName)
  return self.engine.state.customer_network_id .. "-" .. requestedName
end

function Listener:configurationFor(binding)
  local state = self.engine.state
  return protocol.object({
    computer_id = binding.computer_id,
    hostname = binding.hostname,
    address = binding.address,
    customer_network_id = state.customer_network_id,
    router_address = state.router_address,
    dns_address = state.dns_address or state.router_address,
  })
end

return lan
