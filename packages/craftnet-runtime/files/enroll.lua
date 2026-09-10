-- Enrollment over a transport, from either side.
--
-- Every parent-child boundary in CraftNet enrolls the same way: the child finds
-- a parent, proves it holds the one-time secret, and comes away with an
-- identity, a configuration, and a durable relationship credential. Only the
-- secret differs -- a LAN Password admits a Computer, an ISP Enrollment Token
-- admits an ISP, a Router Enrollment Token admits a Customer Router.
--
-- Because the shape is identical, it lives here once. A role package supplies
-- what is genuinely its own: which secrets are currently valid, what to assign,
-- and what to do with the credential that comes out.

local internal = ...
local protocol = internal("protocol")

local enroll = {}

local keys = protocol.conformance.keys

enroll.DEFAULT_TIMEOUT_MS = 5000
-- How long a half-finished exchange is remembered. Someone who walks away
-- mid-enrollment must not hold a slot open.
enroll.PENDING_MS = 15000

--------------------------------------------------------------------------
-- Nonces
--------------------------------------------------------------------------

-- clientNonce is a best-effort boot nonce. CC:Tweaked offers no secure random
-- source, so this is derived from the child's own number and a durable
-- per-child counter. Two children can still collide in principle; the
-- transcript stays unique because the parent mixes in its own durable counter,
-- which is where the design places that guarantee.
function enroll.clientNonce(secret, role, number, generation)
  local seed = keys.enrollmentSecret(secret, role, number or 0)
  return keys.nonce(seed, role, generation)
end

--------------------------------------------------------------------------
-- The child side
--------------------------------------------------------------------------

local function fail(code, message)
  return nil, code, message
end

-- Codes that mean "this frame was not for us", rather than "this exchange has
-- failed". A wrong secret and a frame belonging to someone else are deliberately
-- indistinguishable, so both are simply skipped and the deadline decides.
local skippable = {
  authentication_failed = true,
  invalid_message = true,
  unsupported_version = true,
  message_too_large = true,
}

-- discover calls out on the shared discovery channel and waits for a parent to
-- answer. It carries no secret, so an unanswered discovery costs nothing.
function enroll.discover(options)
  local transport, clock = options.transport, options.clock
  local channel = options.discovery_channel
  local deadline = clock:now() + (options.timeout_ms or enroll.DEFAULT_TIMEOUT_MS)

  local text = protocol.discovery.seal("discover", protocol.object({
    role = options.role,
    client_nonce = options.client_nonce,
  }))
  if not text then return fail("internal_error", "cannot build a discovery message") end

  transport:open(channel)
  transport:transmit(channel, channel, text)

  while clock:now() < deadline do
    local received, _, body = transport:receive(deadline - clock:now())
    if received == channel and body then
      local message = protocol.discovery.open(body)
      if message and message.kind == "offer"
        and rawget(message.body, "client_nonce") == options.client_nonce then
        -- Two parents can be in range of the same discovery channel. When an
        -- Operator named which one they meant, an offer from anyone else is
        -- ignored rather than taken because it answered first.
        local name = rawget(message.body, "display_name")
        local identity = rawget(message.body, "parent_id")
        local wantedName = options.expect_display_name
        local wantedId = options.expect_parent_id
        if (wantedName == nil or wantedName == name)
          and (wantedId == nil or wantedId == identity) then
          return {
            parent_id = identity,
            parent_role = rawget(message.body, "parent_role"),
            display_name = name,
          }
        end
      end
    end
  end
  return fail("upstream_unavailable", "no parent answered on the discovery channel")
end

-- child performs the whole exchange: discovery, then the challenge-response,
-- then the durable result. It is a wizard-shaped blocking call, because an
-- enrollment is something an Operator stands and watches.
function enroll.child(options)
  assert(type(options) == "table", "an enrollment needs options")
  for _, field in ipairs({ "transport", "clock", "secret", "role", "requested_name" }) do
    assert(options[field] ~= nil, "an enrollment needs '" .. field .. "'")
  end
  assert(protocol.validate.normalizedName(options.requested_name),
    "a name is 1 to 32 lowercase letters, digits, and internal hyphens")
  assert(protocol.validate.channel(options.discovery_channel), "a discovery channel is required")

  local transport, clock = options.transport, options.clock
  local channel = options.discovery_channel
  local generation = options.generation or 1
  local clientNonce = options.client_nonce
    or enroll.clientNonce(options.secret, options.role, options.number, generation)

  local offer, code, problem = enroll.discover({
    transport = transport, clock = clock, discovery_channel = channel,
    role = options.role, client_nonce = clientNonce, timeout_ms = options.timeout_ms,
    expect_display_name = options.expect_display_name,
    expect_parent_id = options.expect_parent_id,
  })
  if not offer then return fail(code, problem) end

  -- A re-enrollment names the identity the parent already knows, so the parent
  -- gives back the same assignment rather than treating it as a new child.
  local child = protocol.childEnrollment({
    enrollment_secret = options.secret,
    role = options.role,
    requested_name = options.requested_name,
    client_nonce = clientNonce,
    client_id = options.client_id,
    request_id = "enroll-" .. generation,
    child_revision = options.child_revision or 0,
    expect_parent_id = offer.parent_id,
  })

  local openText, openCode, openProblem = child:open()
  if not openText then return fail(openCode, openProblem) end
  transport:transmit(channel, channel, openText)

  local deadline = clock:now() + (options.timeout_ms or enroll.DEFAULT_TIMEOUT_MS)
  local confirmed = false

  while clock:now() < deadline do
    local received, _, body = transport:receive(deadline - clock:now())
    if received == channel and body then
      -- A shared discovery channel carries other exchanges: another Computer's
      -- offer, another network's challenge. Anything that is not this
      -- exchange's next step is skipped rather than treated as a refusal.
      if not confirmed then
        local confirmText, confirmCode, confirmProblem = child:receiveChallenge(body)
        if confirmText then
          confirmed = true
          transport:transmit(channel, channel, confirmText)
        elseif confirmCode and not skippable[confirmCode] then
          return fail(confirmCode, confirmProblem)
        end
      else
        local outcome, acceptCode, acceptProblem = child:receiveAccept(body)
        if outcome then
          outcome.parent_display_name = offer.display_name
          return outcome
        elseif acceptCode and not skippable[acceptCode] then
          return fail(acceptCode, acceptProblem)
        end
      end
    end
  end

  if confirmed then
    return fail("request_timeout", "the parent did not finish the enrollment")
  end
  -- Nothing that verified ever came back. Either the secret is wrong or nobody
  -- was listening, and from here those look the same on purpose.
  return fail("authentication_failed", "the enrollment secret was refused")
end

-- session establishes a fresh Authenticated Session from a durable relationship
-- credential. The one-time secret is never used again after the first
-- enrollment.
function enroll.session(options)
  assert(type(options) == "table", "a session needs options")
  for _, field in ipairs({ "transport", "clock", "credential", "relationship_id" }) do
    assert(options[field] ~= nil, "a session needs '" .. field .. "'")
  end

  local generation = options.generation or 1
  local child = protocol.childSession({
    relationship_credential = options.credential,
    relationship_id = options.relationship_id,
    client_nonce = keys.nonce(options.credential, options.role or "computer", generation),
    child_revision = options.child_revision or 0,
    request_id = "session-" .. generation,
  })

  local openText, openCode, openProblem = child:open()
  if not openText then return fail(openCode, openProblem) end

  local transport, clock = options.transport, options.clock
  local channel = options.operational_channel
  transport:open(channel)
  transport:transmit(channel, channel, openText)

  local deadline = clock:now() + (options.timeout_ms or enroll.DEFAULT_TIMEOUT_MS)
  while clock:now() < deadline do
    local received, _, body = transport:receive(deadline - clock:now())
    if received == channel and body then
      local confirmText, session = child:receiveChallenge(body)
      if confirmText and session then
        transport:transmit(channel, channel, confirmText)
        return { session = session, relationship_id = options.relationship_id }
      end
    end
  end
  return fail("upstream_unavailable", "the parent did not answer")
end

--------------------------------------------------------------------------
-- The parent side
--------------------------------------------------------------------------

local Listener = {}
Listener.__index = Listener

-- newListener builds the parent half. `candidates` supplies whichever secrets
-- are currently valid: one LAN Password for a Customer Router, or every
-- outstanding one-time token for an ISP or the Central Server.
function enroll.newListener(options)
  assert(type(options) == "table", "a listener needs options")
  for _, field in ipairs({ "transport", "clock", "engine", "parent_id", "candidates", "assign" }) do
    assert(options[field] ~= nil, "a listener needs '" .. field .. "'")
  end
  assert(protocol.validate.channel(options.discovery_channel), "a discovery channel is required")
  assert(protocol.validate.channel(options.operational_channel), "an operational channel is required")

  local listener = setmetatable({
    transport = options.transport,
    clock = options.clock,
    engine = options.engine,
    parentId = options.parent_id,
    parentRole = options.parent_role or "router",
    displayName = options.display_name or options.parent_id,
    childRole = options.child_role,
    discoveryChannel = options.discovery_channel,
    operationalChannel = options.operational_channel,
    -- A parent may put each child on its own Operational Channel, so it has to
    -- listen on every one it has handed out, not only its default.
    operationalChannels = { [options.operational_channel] = true },
    candidates = options.candidates,
    admit = options.admit,
    refused = options.refused,
    admitted = options.admitted,
    assign = options.assign,
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
  for _, channel in ipairs(options.extra_channels or {}) do
    listener:serveChannel(channel)
  end
  return listener
end

-- serveChannel adds one more Operational Channel this parent answers on. A
-- restart replays every channel it had already assigned.
function Listener:serveChannel(channel)
  if not channel or self.operationalChannels[channel] then return false end
  self.operationalChannels[channel] = true
  self.transport:open(channel)
  return true
end

function Listener:nextGeneration(field)
  local state = self.engine.state
  state[field] = (state[field] or 0) + 1
  return state[field]
end

local function reply(self, channel, text)
  self.transport:transmit(channel, self.discoveryChannel, text)
end

function Listener:expire(now)
  for key, entry in pairs(self.pending) do
    if now - entry.started_ms >= enroll.PENDING_MS then self.pending[key] = nil end
  end
  for key, entry in pairs(self.sessions) do
    if now - entry.started_ms >= enroll.PENDING_MS then self.sessions[key] = nil end
  end
end

-- peek reads the outer envelope far enough to route the frame to the right
-- exchange, without trusting anything it says.
function Listener:peek(text)
  local envelope = protocol.conformance.cj1.decode(text)
  if not envelope then return nil end
  local kind = rawget(envelope, "kind")
  local requestId = rawget(envelope, "request_id")
  if type(kind) ~= "string" or type(requestId) ~= "string" then return nil end
  return { kind = kind, request_id = requestId, body = rawget(envelope, "body") }
end

function Listener:claimedIdentity(text)
  local peeked = self:peek(text)
  local body = peeked and peeked.body
  if not body then return {} end
  return {
    client_id = rawget(body, "client_id"),
    requested_name = rawget(body, "requested_name"),
    role = rawget(body, "role"),
  }
end

-- answerDiscovery says only what a child needs to start enrolling. It proves
-- nothing and reveals no secret.
function Listener:answerDiscovery(replyChannel, discovery)
  local body = protocol.object({
    parent_id = self.parentId,
    parent_role = self.parentRole,
    display_name = self.displayName,
    discovery_channel = self.discoveryChannel,
    client_nonce = rawget(discovery.body, "client_nonce"),
  })
  local text = protocol.discovery.seal("offer", body)
  if text then reply(self, replyChannel, text) end
  return { kind = "offered", role = rawget(discovery.body, "role") }
end

-- beginEnrollment tries the opening frame against every currently valid secret.
-- A frame that verifies under none of them is answered with nothing at all: an
-- authentication failure on a shared channel tells a listener nothing.
function Listener:beginEnrollment(replyChannel, text, now)
  local claimed = self:claimedIdentity(text)
  if self.childRole and claimed.role ~= self.childRole then
    return { kind = "dropped", reason = "not a child of this role" }
  end
  if self.admit then
    local permitted, code = self.admit(claimed)
    if not permitted then
      return { kind = "refused", reason = code or "rate_limited" }
    end
  end

  local generation = self:nextGeneration("enroll_generation")
  local relationshipId = self.parentId .. "-r" .. generation

  for _, candidate in ipairs(self.candidates() or {}) do
    -- Check the proof before anything else. Only once a caller has shown it
    -- holds the secret is it told why an assignment failed; before that, silence
    -- is the whole point.
    local verified = protocol.handshake.open(candidate.secret, text)
    local assignment
    local parent = protocol.parentEnrollment({
      enrollment_secret = candidate.secret,
      parent_id = self.parentId,
      parent_revision = self.engine.state.revision or 0,
      parent_nonce = keys.nonce(candidate.secret, self.parentRole, generation),
      relationship_id = relationshipId,
      -- Called only once the child has proved the whole exchange, so a caller
      -- that walks away after the challenge costs this parent nothing.
      assign = function(request)
        local built, code, problem = self.assign(request, {
          generation = generation,
          relationship_id = relationshipId,
          operational_channel = self.operationalChannel,
          candidate = candidate,
        })
        if not built then return nil, code, problem end
        assignment = built
        if built.operational_channel then self:serveChannel(built.operational_channel) end
        return {
          child_id = built.child_id,
          operational_channel = built.operational_channel or self.operationalChannel,
          configuration = built.configuration,
        }
      end,
    })

    local challenge = parent:receiveOpen(text)
    if challenge then
      self.pending[self:peek(text).request_id] = {
        parent = parent,
        candidate = candidate,
        generation = generation,
        relationship_id = relationshipId,
        assignment = assignment,
        claimed = claimed,
        started_ms = now,
      }
      if self.admitted then self.admitted(claimed) end
      reply(self, replyChannel, challenge)
      return { kind = "challenged", relationship_id = relationshipId }
    end
  end

  if self.refused then self.refused(claimed) end
  return { kind = "refused", reason = "authentication_failed" }
end

function Listener:continueEnrollment(entry, replyChannel, text, now)
  local requestId = self:peek(text).request_id
  local acceptText, outcome, detail = entry.parent:receiveConfirm(text)
  if not acceptText then
    self.pending[requestId] = nil
    if self.refused then self.refused(entry.claimed) end
    -- The child proved the exchange and the assignment still could not be made:
    -- a duplicate name, an exhausted pool. That is worth saying out loud,
    -- because only the holder of the secret can read it.
    if outcome and outcome ~= "authentication_failed" and outcome ~= "replay_rejected" then
      local body = protocol.errors.new(
        protocol.errors.isKnown(outcome) and outcome or "internal_error", detail)
      local errorText = protocol.handshake.seal(
        entry.candidate.secret, "enroll_error", requestId, body)
      if errorText then reply(self, replyChannel, errorText) end
    end
    return { kind = "refused", reason = outcome or "authentication_failed" }
  end
  self.pending[requestId] = nil

  -- Everything the exchange produced is committed before the acceptance
  -- leaves, so a child is never told it enrolled with a parent that has
  -- forgotten it -- and the one-time secret is spent only now.
  local joined = {
    kind = "joined",
    child_id = outcome.child_id,
    relationship_id = outcome.relationship_id,
    relationship_credential = outcome.relationship_credential,
    operational_channel = (entry.assignment and entry.assignment.operational_channel)
      or self.operationalChannel,
    assignment = entry.assignment,
    candidate = entry.candidate,
    claimed = entry.claimed,
  }
  if self.onJoined then self.onJoined(joined) end
  reply(self, replyChannel, acceptText)
  return joined
end

--------------------------------------------------------------------------
-- Reconnection
--------------------------------------------------------------------------

function Listener:serveSession(links, replyChannel, channel, text, now)
  local peeked = self:peek(text)
  if not peeked or peeked.kind ~= "session_open" then return nil end

  local relationshipId = peeked.body and rawget(peeked.body, "relationship_id")
  if not relationshipId then return { kind = "dropped", reason = "no relationship named" } end

  local credential = self.credentialFor and self.credentialFor(relationshipId)
  if not credential then
    return { kind = "dropped", reason = "no credential for that relationship" }
  end

  local generation = self:nextGeneration("session_generation")
  local parent = protocol.parentSession({
    relationship_credential = credential,
    relationship_id = relationshipId,
    parent_nonce = keys.nonce(credential, self.parentRole, generation),
    parent_revision = self.engine.state.revision or 0,
    session_id = self.parentId .. "-s" .. generation,
    used_session_ids = self.usedSessionIds,
    used_nonces = self.usedNonces,
  })

  local challenge, code = parent:receiveOpen(text)
  if not challenge then return { kind = "refused", reason = code } end

  self.sessions[peeked.request_id] = {
    parent = parent,
    relationship_id = relationshipId,
    channel = channel,
    started_ms = now,
  }
  reply(self, replyChannel, challenge)
  return { kind = "session_challenged", relationship_id = relationshipId }
end

function Listener:completeSession(links, channel, text, now)
  local peeked = self:peek(text)
  if not peeked or peeked.kind ~= "session_confirm" then return nil end
  local entry = self.sessions[peeked.request_id]
  if not entry then return { kind = "dropped", reason = "no such session exchange" } end

  local session, problem = entry.parent:receiveConfirm(text)
  self.sessions[peeked.request_id] = nil
  if not session then return { kind = "refused", reason = problem } end

  links:adopt({
    relationship_id = entry.relationship_id,
    channel = entry.channel or self.operationalChannel,
    session = session,
    role = self.childRole,
    id = self.childOf and self.childOf(entry.relationship_id),
    direction = "child",
  })
  return { kind = "session_established", relationship_id = entry.relationship_id }
end

--------------------------------------------------------------------------
-- The single entry point
--------------------------------------------------------------------------

-- handleFrame is what a role package installs on its links adapter: anything
-- that authenticated against no live session arrives here.
function Listener:handleFrame(links, channel, replyChannel, text)
  local now = self.clock:now()
  self:expire(now)

  if channel == self.discoveryChannel then
    local discovery = protocol.discovery.open(text)
    if discovery and discovery.kind == "discover" then
      return self:answerDiscovery(replyChannel, discovery)
    end
    local peeked = self:peek(text)
    if not peeked then return { kind = "dropped", reason = "unreadable" } end
    if peeked.kind == "enroll_open" then
      return self:beginEnrollment(replyChannel, text, now)
    end
    -- Only the frame this exchange is actually waiting for may advance it.
    -- Several parents can hear the same discovery channel, and a sibling's
    -- challenge carries the same Request ID; treating that as this exchange's
    -- next step would tear down a join that was going perfectly well.
    if peeked.kind ~= "enroll_confirm" then
      return { kind = "dropped", reason = "not this exchange's next step" }
    end
    local entry = self.pending[peeked.request_id]
    if not entry then return { kind = "dropped", reason = "no such exchange" } end
    return self:continueEnrollment(entry, replyChannel, text, now)
  end

  if self.operationalChannels[channel] then
    return self:serveSession(links, replyChannel, channel, text, now)
      or self:completeSession(links, channel, text, now)
  end
  return nil
end

enroll.Listener = Listener

return enroll
