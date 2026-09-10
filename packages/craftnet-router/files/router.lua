-- The Customer Router composition root.
--
-- A role package is deliberately thin: it wires the three shared packages
-- together and supplies the one thing that is genuinely its own -- in this case
-- the LAN, its password, and who is allowed onto it. It must not grow a second
-- implementation of protocol, persistence, or routing behaviour.

local internal = ...
local protocol = internal("protocol")
local runtimePackage = internal("runtime")
local lan = internal("lan")

local router = {}

-- The shared discovery channels: the one a Computer calls out on, and the one
-- this router calls out to an ISP on. Fixture values from the reference
-- topology; a wizard may choose others.
router.LAN_DISCOVERY_CHANNEL = 42002
router.ISP_DISCOVERY_CHANNEL = 42001

local Router = {}
Router.__index = Router

function router.new(options)
  assert(type(options) == "table", "a router needs options")
  local adapters = options.adapters or {}
  assert(type(adapters.transport) == "table", "a router needs a transport adapter")
  assert(type(adapters.clock) == "table", "a router needs a clock adapter")
  assert(type(adapters.storage) == "table", "a router needs a storage adapter")

  local links = runtimePackage.newLinks({ transport = adapters.transport })

  local instance = setmetatable({
    links = links,
    transport = adapters.transport,
    clock = adapters.clock,
    discoveryChannel = options.discovery_channel or router.LAN_DISCOVERY_CHANNEL,
    runtime = runtimePackage.new({
      role = "router",
      path = options.path or "craftnet/router",
      adapters = {
        clock = adapters.clock,
        storage = adapters.storage,
        screen = adapters.screen,
        links = links,
      },
      connectivity = options.connectivity,
    }),
    joins = {},
  }, Router)
  return instance
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

-- start loads durable state and secrets, then installs the LAN listener. The
-- listener needs the engine, and the engine only exists once the runtime has
-- started, which is why the wiring happens in this order rather than in new().
function Router:start()
  local ok, source, problem = self.runtime:start()
  if not ok then return nil, source, problem end
  self.secrets = self.runtime:secrets()
  self.secrets:load()

  local state = self.runtime:state()
  if state.router_id then self:installListener() end
  return true, source
end

function Router:installListener()
  local state = self.runtime:state()
  assert(state.router_id, "the router is not configured yet")

  local password = self.secrets:get("lan-password")
  assert(password, "this router has no LAN Password; run the setup wizard")

  self.listener = lan.newListener({
    transport = self.transport,
    clock = self.clock,
    engine = self.runtime.engine,
    password = password,
    router_id = state.router_id,
    display_name = state.customer_network_name,
    discovery_channel = self.discoveryChannel,
    operational_channel = state.lan_operational_channel,
    -- A LAN Credential is committed before the acceptance leaves, so a Computer
    -- is never told it joined a network that has forgotten it.
    on_joined = function(joined) self:commitJoin(joined) end,
    credential_for = function(relationshipId)
      return self.secrets:get(self:secretReference(relationshipId))
    end,
    child_of = function(relationshipId)
      return self.runtime:state().relationships
        and self.runtime:state().relationships[relationshipId]
    end,
  })

  self.links:onHandshake(function(links, channel, replyChannel, text)
    return self.listener:handleFrame(links, channel, replyChannel, text)
  end)
  return self.listener
end

-- secretReference names where one relationship's credential is kept. The
-- reference appears in state; only the secret store holds the value.
function Router:secretReference(relationshipId)
  return "rel-" .. relationshipId
end

-- commitJoin durably records everything a completed join produced, before the
-- Computer is told it succeeded.
function Router:commitJoin(joined)
  local state = self.runtime:state()
  state.relationships = state.relationships or {}
  state.relationships[joined.relationship_id] = joined.child_id
  state.credential_refs = state.credential_refs or {}
  state.credential_refs[joined.relationship_id] = self:secretReference(joined.relationship_id)

  self.secrets:put(self:secretReference(joined.relationship_id), joined.relationship_credential)
  self.runtime.store:save(state, self.clock:now())
  self.joins[#self.joins + 1] = joined
  return joined
end

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

-- configure applies the setup wizard's answers and stores the LAN Password.
-- The password is a secret, so it goes to the secret store and never into the
-- state snapshot.
function Router:configure(settings, password)
  assert(type(password) == "string" and #password > 0, "a LAN Password is required")
  local outcome = self.runtime:submit({ kind = "configure", settings = settings })
  if not outcome.result.ok then
    return nil, outcome.result.code, outcome.result.message
  end
  local ok, problem = self.secrets:put("lan-password", password)
  if not ok then return nil, "internal_error", problem end
  self:installListener()
  return true
end

-- changePassword affects future joins only. Computers that already joined hold
-- their own LAN Credentials and stay enrolled until individually revoked.
function Router:changePassword(password)
  assert(type(password) == "string" and #password > 0, "a LAN Password is required")
  local ok, problem = self.secrets:put("lan-password", password)
  if not ok then return nil, "internal_error", problem end
  if self.listener then self.listener.password = password end
  return true
end

-- revoke removes one Computer's LAN Credential and its binding. Its identity is
-- not reused, and it must be re-enrolled explicitly to return.
function Router:revoke(relationshipId)
  local state = self.runtime:state()
  local childId = state.relationships and state.relationships[relationshipId]
  self.secrets:remove(self:secretReference(relationshipId))
  if state.relationships then state.relationships[relationshipId] = nil end
  if state.credential_refs then state.credential_refs[relationshipId] = nil end
  self.links:forget(relationshipId)
  if childId then
    self.runtime:submit({ kind = "release_binding", computer_id = childId })
  end
  return true
end

--------------------------------------------------------------------------
-- Enrolling with an ISP
--------------------------------------------------------------------------

-- enrollUpstream spends a one-time Router Enrollment Token. What comes back is
-- the Provider Address and Operational Channel the ISP assigned, and the
-- durable Router Credential every later reconnect uses.
--
-- A Customer Network works perfectly well without this: Milestone 4 built one
-- that never had an ISP. Enrolling is what makes it reachable from the rest of
-- CraftNet.
function Router:enrollUpstream(options)
  assert(type(options) == "table" and options.token, "a Router Enrollment Token is required")
  local state = self:state()
  assert(state.router_id, "run the router wizard before enrolling with an ISP")

  local secret = protocol.tokens.secret(options.token)
  if not secret then
    return nil, "invalid_message", "that is not a CraftNet enrollment token"
  end

  local generation = (state.enroll_attempt or 0) + 1
  state.enroll_attempt = generation

  local result, code, problem = runtimePackage.enroll.child({
    transport = self.transport,
    clock = self.clock,
    discovery_channel = options.discovery_channel or router.ISP_DISCOVERY_CHANNEL,
    secret = secret,
    role = "router",
    requested_name = state.customer_network_name,
    -- This Customer Network already has an identity, earned when its Operator
    -- set it up. The ISP decides whether to accept it, not what it is.
    client_id = state.router_id,
    number = options.number or 0,
    generation = generation,
    timeout_ms = options.timeout_ms,
    expect_display_name = options.isp_name,
    expect_parent_id = state.isp_id,
  })
  if not result then return nil, code, problem end

  local assigned = result.configuration
  if rawget(assigned, "customer_network_id") ~= state.customer_network_id then
    return nil, "name_conflict",
      "that ISP already serves a different Customer Network by this name"
  end

  self:applyAssignment(assigned, result)
  return {
    isp_id = rawget(assigned, "isp_id"),
    provider_address = rawget(assigned, "provider_address"),
    operational_channel = result.operational_channel,
    relationship_id = result.relationship_id,
  }
end

-- applyAssignment takes only the fields an ISP is authoritative for. This
-- router's own LAN address, pool, and channel are not among them.
function Router:applyAssignment(assigned, result)
  local state = self:state()
  state.isp_id = rawget(assigned, "isp_id")
  state.provider_address = rawget(assigned, "provider_address")
  state.customer_network_name = rawget(assigned, "customer_network_name")
    or state.customer_network_name
  state.upstream_relationship_id = result.relationship_id
  state.upstream_channel = result.operational_channel
  state.upstream_credential_ref = self:secretReference(result.relationship_id)
  state.parent_revision = result.parent_revision

  self.secrets:put(state.upstream_credential_ref, result.relationship_credential)
  self.runtime.store:save(state, self.clock:now())
  return state
end

function Router:establishUpstream()
  local state = self:state()
  local credential = self.secrets:get(state.upstream_credential_ref or "")
  if not credential then return nil, "this router has no Router Credential" end
  state.upstream_session_generation = (state.upstream_session_generation or 0) + 1

  local result, code, problem = runtimePackage.enroll.session({
    transport = self.transport,
    clock = self.clock,
    credential = credential,
    relationship_id = state.upstream_relationship_id,
    operational_channel = state.upstream_channel,
    role = "router",
    generation = state.upstream_session_generation,
    child_revision = state.revision or 0,
  })
  if not result then return nil, problem or code end
  return result.session
end

-- connectUpstream brings this Customer Network onto CraftNet.
function Router:connectUpstream()
  local state = self:state()
  if not state.upstream_relationship_id then
    return nil, "upstream_unavailable", "this Customer Router has not enrolled with an ISP"
  end
  local session, problem = self:establishUpstream()
  if not session then return nil, "upstream_unavailable", problem end

  self.links:adopt({
    relationship_id = state.upstream_relationship_id,
    channel = state.upstream_channel,
    credential = self.secrets:get(state.upstream_credential_ref),
    session = session,
    role = "isp",
    id = state.isp_id,
    direction = "parent",
  })
  self.runtime:drain()
  return true
end

--------------------------------------------------------------------------
-- Serving
--------------------------------------------------------------------------

-- serve advances the router by one step: either a message the runtime handles
-- or a LAN exchange the listener drives.
function Router:serve(timeoutMs)
  return self.runtime:pump(timeoutMs)
end

function Router:tick()
  return self.runtime:tick()
end

function Router:run(options)
  return self.runtime:run(options)
end

function Router:state()
  return self.runtime:state()
end

function Router:lines()
  return self.runtime:lines()
end

return router
