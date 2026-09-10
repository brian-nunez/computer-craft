-- Joining a Customer Network.
--
-- A Computer finds a router, proves it knows the LAN Password without ever
-- sending it, and comes away with three durable things: its identity, its
-- configuration, and the LAN Credential it will authenticate with from then on.
--
-- After the first join the password is never used again. A Computer reconnects
-- with its own credential, and only ever to the router identity it originally
-- joined -- never to another network that happens to share a name or a
-- password.

local internal = ...
local protocol = internal("protocol")

local join = {}

join.DEFAULT_TIMEOUT_MS = 5000

local keys = protocol.conformance.keys

--------------------------------------------------------------------------
-- Nonces
--------------------------------------------------------------------------

-- clientNonce is a best-effort boot nonce. CC:Tweaked offers no secure random
-- source, so this is derived from the Computer's own identity number and a
-- durable per-Computer counter. Two Computers can still collide in principle;
-- the transcript stays unique because the router mixes in its own durable
-- counter, which is where the design places that guarantee.
function join.clientNonce(password, computerNumber, generation)
  local seed = keys.enrollmentSecret(password, "computer", computerNumber)
  return keys.nonce(seed, "computer", generation)
end

--------------------------------------------------------------------------
-- The exchange
--------------------------------------------------------------------------

local function fail(code, message)
  return nil, code, message
end

-- discover broadcasts on the LAN discovery channel and waits for a router to
-- answer. It carries no secret, so an unanswered discovery costs nothing.
function join.discover(options)
  local transport = options.transport
  local clock = options.clock
  local channel = options.discovery_channel
  local deadline = clock:now() + (options.timeout_ms or join.DEFAULT_TIMEOUT_MS)

  local text = protocol.discovery.seal("discover", protocol.object({
    role = "computer",
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
        return {
          parent_id = rawget(message.body, "parent_id"),
          display_name = rawget(message.body, "display_name"),
          discovery_channel = rawget(message.body, "discovery_channel"),
        }
      end
    end
  end
  return fail("router_unavailable", "no Customer Router answered")
end

-- run performs the whole join: discovery, then the LAN Password
-- challenge-response, then the durable result. It is a wizard-shaped blocking
-- call, because a join is something an Operator stands and watches.
function join.run(options)
  assert(type(options) == "table", "a join needs options")
  for _, field in ipairs({ "transport", "clock", "password", "requested_name" }) do
    assert(options[field] ~= nil, "a join needs '" .. field .. "'")
  end
  assert(protocol.validate.normalizedName(options.requested_name),
    "a hostname is 1 to 32 lowercase letters, digits, and internal hyphens")
  assert(protocol.validate.channel(options.discovery_channel), "a discovery channel is required")

  local clock = options.clock
  local transport = options.transport
  local channel = options.discovery_channel
  local generation = options.generation or 1
  local clientNonce = join.clientNonce(options.password, options.computer_number or 0, generation)

  local offer, code, problem = join.discover({
    transport = transport, clock = clock, discovery_channel = channel,
    client_nonce = clientNonce, timeout_ms = options.timeout_ms,
  })
  if not offer then return fail(code, problem) end

  -- A rejoin names the identity the router already knows, so the router gives
  -- back the same address rather than treating it as a new Computer.
  local child = protocol.childEnrollment({
    enrollment_secret = options.password,
    role = "computer",
    requested_name = options.requested_name,
    client_nonce = clientNonce,
    client_id = options.client_id,
    request_id = "join-" .. generation,
    child_revision = options.child_revision or 0,
  })

  local openText, openCode, openProblem = child:open()
  if not openText then return fail(openCode, openProblem) end
  transport:transmit(channel, channel, openText)

  local deadline = clock:now() + (options.timeout_ms or join.DEFAULT_TIMEOUT_MS)
  local confirmed = false

  while clock:now() < deadline do
    local received, _, body = transport:receive(deadline - clock:now())
    if received == channel and body then
      if not confirmed then
        local confirmText, confirmCode, confirmProblem = child:receiveChallenge(body)
        if confirmText then
          confirmed = true
          transport:transmit(channel, channel, confirmText)
        elseif confirmCode == "authentication_failed" then
          -- Either the password is wrong or that frame was not for us. Both
          -- look the same from here, which is deliberate.
          return fail("authentication_failed", confirmProblem or "the LAN Password was refused")
        end
      else
        local outcome, acceptCode, acceptProblem = child:receiveAccept(body)
        if outcome then
          return {
            child_id = outcome.child_id,
            parent_id = outcome.parent_id,
            relationship_id = outcome.relationship_id,
            relationship_credential = outcome.relationship_credential,
            operational_channel = outcome.operational_channel,
            configuration = outcome.configuration,
            parent_revision = outcome.parent_revision,
          }
        elseif acceptCode and acceptCode ~= "authentication_failed" then
          return fail(acceptCode, acceptProblem)
        end
      end
    end
  end

  return fail("request_timeout", "the Customer Router did not finish the join")
end

--------------------------------------------------------------------------
-- Reconnecting
--------------------------------------------------------------------------

-- reconnect establishes a fresh Authenticated Session with the credential a
-- join produced. It never uses the LAN Password again, and it refuses a router
-- that is not the one this Computer joined.
function join.reconnect(options)
  assert(type(options) == "table", "a reconnect needs options")
  for _, field in ipairs({ "transport", "clock", "credential", "relationship_id" }) do
    assert(options[field] ~= nil, "a reconnect needs '" .. field .. "'")
  end

  local generation = options.generation or 1
  local child = protocol.childSession({
    relationship_credential = options.credential,
    relationship_id = options.relationship_id,
    client_nonce = keys.nonce(options.credential, "computer", generation),
    child_revision = options.child_revision or 0,
    request_id = "session-" .. generation,
  })

  local openText, openCode, openProblem = child:open()
  if not openText then return fail(openCode, openProblem) end

  local transport = options.transport
  local clock = options.clock
  local channel = options.operational_channel
  transport:open(channel)
  transport:transmit(channel, channel, openText)

  local deadline = clock:now() + (options.timeout_ms or join.DEFAULT_TIMEOUT_MS)
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
  return fail("router_unavailable", "the Customer Router did not answer")
end

return join
