-- The Computer composition root.
--
-- A Computer owns very little, and this file is correspondingly small: it joins
-- a Customer Network once, remembers what came back, and reconnects with its
-- own credential from then on. Every request it makes goes to its Customer
-- Router -- there is no subnet mask and no direct Computer-to-Computer path.

local internal = ...
local protocol = internal("protocol")
local runtimePackage = internal("runtime")
local join = internal("join")

local computer = {}

computer.LAN_DISCOVERY_CHANNEL = 42002

-- Where the Device Credential is kept. It is a secret, so it lives in the
-- secret store and never in a state snapshot.
computer.DEVICE_CREDENTIAL_REF = "device-credential"

local Computer = {}
Computer.__index = Computer

function computer.new(options)
  assert(type(options) == "table", "a Computer needs options")
  local adapters = options.adapters or {}
  assert(type(adapters.transport) == "table", "a Computer needs a transport adapter")
  assert(type(adapters.clock) == "table", "a Computer needs a clock adapter")
  assert(type(adapters.storage) == "table", "a Computer needs a storage adapter")

  local links = runtimePackage.newLinks({ transport = adapters.transport })

  return setmetatable({
    links = links,
    transport = adapters.transport,
    clock = adapters.clock,
    number = options.computer_number or 0,
    discoveryChannel = options.discovery_channel or computer.LAN_DISCOVERY_CHANNEL,
    runtime = runtimePackage.new({
      role = "computer",
      path = options.path or "craftnet/computer",
      application = options.application,
      adapters = {
        clock = adapters.clock,
        storage = adapters.storage,
        screen = adapters.screen,
        links = links,
      },
      connectivity = options.connectivity,
    }),
  }, Computer)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Computer:start()
  local ok, source, problem = self.runtime:start()
  if not ok then return nil, source, problem end
  self.secrets = self.runtime:secrets()
  self.secrets:load()

  -- Reconnection uses the credential a previous join produced, and only ever to
  -- the router identity this Computer originally joined.
  self.links:onConnect(function(links, entry)
    return self:establish(entry)
  end)
  return true, source
end

function Computer:state()
  return self.runtime:state()
end

function Computer:isJoined()
  local state = self:state()
  return state.computer_id ~= nil and state.relationship_id ~= nil
end

--------------------------------------------------------------------------
-- Joining
--------------------------------------------------------------------------

-- joinNetwork runs the wizard's exchange and commits everything it produced.
-- The LAN Password is used exactly once and is never stored.
function Computer:joinNetwork(options)
  assert(type(options) == "table", "a join needs options")
  local state = self:state()
  local generation = (state.join_generation or 0) + 1

  local result, code, problem = join.run({
    transport = self.transport,
    clock = self.clock,
    discovery_channel = self.discoveryChannel,
    password = options.password,
    requested_name = options.hostname,
    computer_number = self.number,
    generation = generation,
    -- A rejoin names the identity the router already knows, so it comes back to
    -- the same address rather than being treated as a new Computer.
    client_id = state.computer_id,
    timeout_ms = options.timeout_ms,
    customer_network_name = options.customer_network_name,
    -- A Computer that has joined before returns only to the router identity it
    -- joined, never to another network that shares a name or a password.
    router_id = state.router_id,
  })
  if not result then return nil, code, problem end

  state.join_generation = generation
  state.relationship_id = result.relationship_id
  state.router_id = result.parent_id
  state.operational_channel = result.operational_channel
  state.credential_ref = "lan-credential"
  state.parent_revision = result.parent_revision

  -- The credential is committed before the configuration, so a Computer never
  -- believes it is a member of a network it cannot authenticate to.
  local stored, storeProblem = self.secrets:put("lan-credential", result.relationship_credential)
  if not stored then return nil, "internal_error", storeProblem end

  local applied = self.runtime:submit({
    kind = "configure",
    settings = {
      computer_id = result.child_id,
      hostname = rawget(result.configuration, "hostname"),
      address = rawget(result.configuration, "address"),
      customer_network_id = rawget(result.configuration, "customer_network_id"),
      customer_network_name = options.customer_network_name,
      router_id = result.parent_id,
      router_address = rawget(result.configuration, "router_address"),
      dns_address = rawget(result.configuration, "dns_address"),
      isp_name = options.isp_name,
      world_id = options.world_id,
    },
  })
  if not applied.result.ok then
    return nil, applied.result.code, applied.result.message
  end

  return {
    computer_id = result.child_id,
    hostname = rawget(result.configuration, "hostname"),
    address = rawget(result.configuration, "address"),
    router_address = rawget(result.configuration, "router_address"),
    dns_address = rawget(result.configuration, "dns_address"),
    relationship_id = result.relationship_id,
  }
end

--------------------------------------------------------------------------
-- Sessions
--------------------------------------------------------------------------

-- establish builds a fresh Authenticated Session from the durable LAN
-- Credential. An old session is never resumed.
function Computer:establish()
  local state = self:state()
  local credential = self.secrets:get("lan-credential")
  if not credential then return nil, "this Computer has no LAN Credential" end

  -- The generation is durable on purpose. It is what makes each session's
  -- nonce different from the last, so a Computer that restarts must not start
  -- counting again: its parent would see the same nonce twice and refuse it as
  -- a replay, and the Computer would sit there unable to reconnect.
  state.session_generation = (state.session_generation or 0) + 1
  self.runtime.store:save(state, self.clock:now())

  local result, code, problem = join.reconnect({
    transport = self.transport,
    clock = self.clock,
    credential = credential,
    relationship_id = state.relationship_id,
    operational_channel = state.operational_channel,
    generation = state.session_generation,
    child_revision = state.revision or 0,
  })
  if not result then return nil, problem or code end
  return result.session
end

-- connect brings the Computer online after a join or a restart.
function Computer:connect()
  local state = self:state()
  if not self:isJoined() then
    return nil, "router_unavailable", "this Computer has not joined a Customer Network"
  end

  -- The handshake runs first, so the relationship is adopted once, already
  -- carrying a live session, rather than briefly existing without one.
  local session, problem = self:establish()
  if not session then
    return nil, "router_unavailable", problem
  end
  self.links:adopt({
    relationship_id = state.relationship_id,
    channel = state.operational_channel,
    credential = self.secrets:get("lan-credential"),
    session = session,
    role = "router",
    id = state.router_id,
    direction = "parent",
  })
  -- Settle the relationship into the engine before returning, so a wizard that
  -- connects and immediately sends is not racing its own link.
  self.runtime:drain()
  return true
end

--------------------------------------------------------------------------
-- Using the network
--------------------------------------------------------------------------

-- resolve turns a CraftNet Name into an address. api.craft is answered without
-- a lookup: the External Application is reached through an External Operation
-- and its verified ancestry, never by address.
function Computer:resolve(name)
  return self.runtime:submit({ kind = "resolve", name = name })
end

-- request sends one call to another Computer. Local or remote, it goes to this
-- Computer's Customer Router.
function Computer:request(destination, service, payload)
  return self.runtime:submit({
    kind = "local_request",
    destination = destination,
    service = service,
    payload = payload or protocol.object(),
  })
end

function Computer:serve(timeoutMs)
  return self.runtime:pump(timeoutMs)
end

-- await serves this Computer until the thing it just asked for comes back. A
-- CraftNet call is one request and one answer; there is nothing to poll.
function Computer:await(options)
  options = options or {}
  for _ = 1, options.attempts or 60 do
    local outcome = self.runtime:pump(options.timeout_ms or 200)
    if outcome and outcome.result then
      local result = outcome.result
      if result.ok == false then return nil, result.code, result.message end
      if result.payload ~= nil or result.address ~= nil or result.canonical_name ~= nil then
        return result
      end
    end
  end
  return nil, "request_timeout", "no answer arrived"
end

--------------------------------------------------------------------------
-- The External Application
--------------------------------------------------------------------------

-- A token is refused one second past its life. A Computer stops trusting its
-- own a little early rather than discovering at the far end that it was late,
-- and it measures the life as a duration: the wall clock is not something
-- CraftNet security is ever allowed to depend on.
local TOKEN_MARGIN_MS = 5000

-- externalCall names an External Operation on the in-world wire. It carries no
-- destination, because `api.craft` is not a Customer Network; the message kind
-- is the destination. The Customer Router NATs it, the ISP carries it, and the
-- Central Server is the only role that holds a Gateway Session.
function Computer:externalCall(operation, payload, credential)
  credential = credential or {}
  return self.runtime:submit({
    kind = "external_call",
    operation = operation,
    payload = payload or protocol.object(),
    access_token = credential.access_token,
    device_credential = credential.device_credential,
    registration_nonce = credential.registration_nonce,
  })
end

-- registerDevice presents this Computer's verified ancestry and keeps the
-- Device Credential that comes back. There is no secret to present: every hop
-- between here and the External Application derived who is asking rather than
-- believing it, and that path is the attestation.
--
-- The nonce is derived from the LAN Credential and a durable counter, never
-- drawn from math.random, and the counter is committed before the nonce is
-- sent, so a restart cannot produce the same one twice.
function Computer:registerDevice()
  local state = self:state()
  local credential = self.secrets:get("lan-credential")
  if not credential then
    return nil, "authentication_failed", "this Computer has no LAN Credential"
  end

  state.registration_generation = (state.registration_generation or 0) + 1
  self.runtime.store:save(state, self.clock:now())
  local nonce = protocol.registration.nonce(credential, state.registration_generation)

  local sent = self:externalCall("device.register", protocol.object(),
    { registration_nonce = nonce })
  if not sent.result.ok then return nil, sent.result.code, sent.result.message end

  local answer, code, problem = self:await()
  if not answer then return nil, code, problem end

  local issued = rawget(answer.payload or protocol.object(), "device_credential")
  if type(issued) ~= "string" or issued == "" then
    return nil, "internal_error", "the External Application issued no Device Credential"
  end
  local stored, storeProblem = self.secrets:put(computer.DEVICE_CREDENTIAL_REF, issued)
  if not stored then return nil, "internal_error", storeProblem end
  return { device_id = rawget(answer.payload, "device_id") }
end

-- accessToken exchanges the Device Credential for a two-minute Access Token,
-- and holds the one it has until it is nearly spent. The token itself is
-- opaque here: CraftOS never reads a claim out of it, and never decides
-- anything on what it might say.
function Computer:accessToken()
  local held = self.token
  if held and (self.clock:now() - held.issued_at_ms)
    < (protocol.limits.ACCESS_TOKEN_SECONDS * 1000) - TOKEN_MARGIN_MS then
    return held.access_token
  end

  local credential = self.secrets:get(computer.DEVICE_CREDENTIAL_REF)
  if not credential then
    return nil, "authentication_failed", "this Computer has not registered a device"
  end

  local issuedAt = self.clock:now()
  local sent = self:externalCall("token.issue", protocol.object(),
    { device_credential = credential })
  if not sent.result.ok then return nil, sent.result.code, sent.result.message end

  local answer, code, problem = self:await()
  if not answer then return nil, code, problem end

  local token = rawget(answer.payload or protocol.object(), "access_token")
  if type(token) ~= "string" or token == "" then
    return nil, "internal_error", "the External Application issued no Access Token"
  end
  self.token = { access_token = token, issued_at_ms = issuedAt }
  return token
end

-- call is the whole external path as one thing an application asks for: a
-- device registered once, a token held until it is nearly spent, and the
-- operation itself. A caller that has never registered does not have to know
-- that it has not.
function Computer:call(operation, payload)
  if operation == "device.register" then
    return self:registerDevice()
  end

  if not self.secrets:get(computer.DEVICE_CREDENTIAL_REF) then
    local registered, code, problem = self:registerDevice()
    if not registered then return nil, code, problem end
  end
  if operation == "token.issue" then
    local token, code, problem = self:accessToken()
    if not token then return nil, code, problem end
    return { access_token = token }
  end

  local token, code, problem = self:accessToken()
  if not token then return nil, code, problem end

  local sent = self:externalCall(operation, payload, { access_token = token })
  if not sent.result.ok then return nil, sent.result.code, sent.result.message end

  local answer, failure, detail = self:await()
  if not answer then
    -- A token this Computer still believed in was refused. Dropping it means
    -- the next call fetches a fresh one instead of failing the same way again.
    if failure == "access_token_expired" then self.token = nil end
    return nil, failure, detail
  end
  return answer.payload or protocol.object()
end

function Computer:tick()
  return self.runtime:tick()
end

function Computer:run(options)
  return self.runtime:run(options)
end

function Computer:lines()
  return self.runtime:lines()
end

return computer
