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

-- The shared discovery channel a Computer calls out on. Fixture value from the
-- reference topology; a wizard may choose another.
router.LAN_DISCOVERY_CHANNEL = 42002

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
