-- The ISP composition root.
--
-- An ISP sits between the Central Server and its Customer Routers, and does two
-- things neither of them does: it hands out Provider Addresses from the
-- allocation the Central Server delegated to it, and it publishes an exact
-- Route Registration for every Customer Network it serves.
--
-- It never talks to another ISP. Even traffic between two of its own Customer
-- Networks goes up to the Central Server and back down, because one route map
-- being authoritative is worth more than a shortcut.

local internal = ...
local protocol = internal("protocol")
local runtimePackage = internal("runtime")

local isp = {}

-- The channel an ISP calls out to the Central Server on, and the one its
-- Customer Routers call out to it on.
isp.CENTRAL_DISCOVERY_CHANNEL = 42000
isp.ROUTER_DISCOVERY_CHANNEL = 42001

-- Downstream channels are derived from the channel the Central Server assigned,
-- so two ISPs in one World can never hand their routers the same channel
-- without anyone having to coordinate.
isp.DOWNSTREAM_BASE = 43000
isp.DOWNSTREAM_STRIDE = 100

local ISP = {}
ISP.__index = ISP

function isp.new(options)
  assert(type(options) == "table", "an ISP needs options")
  local adapters = options.adapters or {}
  for _, field in ipairs({ "transport", "clock", "storage" }) do
    assert(type(adapters[field]) == "table", "an ISP needs a " .. field .. " adapter")
  end

  local links = runtimePackage.newLinks({ transport = adapters.transport })
  return setmetatable({
    links = links,
    transport = adapters.transport,
    clock = adapters.clock,
    centralDiscovery = options.central_discovery_channel or isp.CENTRAL_DISCOVERY_CHANNEL,
    routerDiscovery = options.router_discovery_channel or isp.ROUTER_DISCOVERY_CHANNEL,
    runtime = runtimePackage.new({
      role = "isp",
      path = options.path or "craftnet/isp",
      adapters = {
        clock = adapters.clock, storage = adapters.storage,
        screen = adapters.screen, links = links,
      },
      connectivity = options.connectivity,
    }),
  }, ISP)
end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function ISP:start()
  local ok, source, problem = self.runtime:start()
  if not ok then return nil, source, problem end
  self.secrets = self.runtime:secrets()
  self.secrets:load()

  self.links:onConnect(function(_, entry) return self:establish(entry) end)
  if self:state().isp_id then self:installListener() end
  return true, source
end

function ISP:state() return self.runtime:state() end
function ISP:lines() return self.runtime:lines() end

-- configure applies the wizard's answers. An ISP knows its own name before it
-- has an identity, because the Central Server is what assigns the identity.
function ISP:configure(settings)
  local outcome = self.runtime:submit({ kind = "configure", settings = settings })
  if not outcome.result.ok then
    return nil, outcome.result.code, outcome.result.message
  end
  return true
end

--------------------------------------------------------------------------
-- Enrolling with the Central Server
--------------------------------------------------------------------------

function ISP:credentialReference(relationshipId)
  return "rel-" .. relationshipId
end

-- enrollUpstream spends a one-time ISP Enrollment Token. What comes back is an
-- identity, a Provider Allocation, an Operational Channel, and the durable ISP
-- Credential every later reconnect uses.
function ISP:enrollUpstream(options)
  assert(type(options) == "table" and options.token, "an ISP Enrollment Token is required")
  local state = self:state()
  local secret = protocol.tokens.secret(options.token)
  if not secret then
    return nil, "invalid_message", "that is not a CraftNet enrollment token"
  end

  local generation = (state.enroll_attempt or 0) + 1
  state.enroll_attempt = generation

  local result, code, problem = runtimePackage.enroll.child({
    transport = self.transport,
    clock = self.clock,
    discovery_channel = self.centralDiscovery,
    secret = secret,
    role = "isp",
    requested_name = state.isp_name,
    client_id = state.isp_id,
    number = options.number or 0,
    generation = generation,
    timeout_ms = options.timeout_ms,
  })
  if not result then return nil, code, problem end

  local assigned = result.configuration
  local applied = self.runtime:submit({
    kind = "configure",
    settings = {
      isp_id = result.child_id,
      isp_name = rawget(assigned, "isp_name") or state.isp_name,
      world_id = options.world_id or state.world_id,
      central_id = result.parent_id,
      operational_channel = result.operational_channel,
      provider_allocations = self:allocationsFrom(assigned),
    },
  })
  if not applied.result.ok then
    return nil, applied.result.code, applied.result.message
  end

  local committed = self:state()
  committed.relationship_id = result.relationship_id
  committed.central_id = result.parent_id
  committed.credential_ref = self:credentialReference(result.relationship_id)
  committed.parent_revision = result.parent_revision

  -- The credential is committed before anything reports success, so this ISP is
  -- never told it enrolled with a World it cannot authenticate to.
  local stored, storeProblem =
    self.secrets:put(committed.credential_ref, result.relationship_credential)
  if not stored then return nil, "internal_error", storeProblem end
  self.runtime.store:save(committed, self.clock:now())

  self:installListener()
  return {
    isp_id = result.child_id,
    central_id = result.parent_id,
    provider_allocations = committed.provider_allocations,
    provider_address = committed.provider_address,
    operational_channel = result.operational_channel,
  }
end

function ISP:allocationsFrom(assigned)
  local ranges = {}
  local list = rawget(assigned, "provider_allocations")
  for index = 1, #(list or {}) do
    local entry = rawget(list, index)
    ranges[index] = { first = rawget(entry, "first"), last = rawget(entry, "last") }
  end
  return ranges
end

function ISP:establish()
  local state = self:state()
  local credential = self.secrets:get(state.credential_ref or "")
  if not credential then return nil, "this ISP has no Credential" end
  -- Durable, so a restart never repeats a nonce its parent already saw.
  state.session_generation = (state.session_generation or 0) + 1
  self.runtime.store:save(state, self.clock:now())

  local result, code, problem = runtimePackage.enroll.session({
    transport = self.transport,
    clock = self.clock,
    credential = credential,
    relationship_id = state.relationship_id,
    operational_channel = state.operational_channel,
    role = "isp",
    generation = state.session_generation,
    child_revision = state.revision or 0,
  })
  if not result then return nil, problem or code end
  return result.session
end

-- connectUpstream brings the ISP online against the Central Server.
function ISP:connectUpstream()
  local state = self:state()
  if not state.relationship_id then
    return nil, "upstream_unavailable", "this ISP has not enrolled with a Central Server"
  end
  local session, problem = self:establish()
  if not session then return nil, "upstream_unavailable", problem end

  self.links:adopt({
    relationship_id = state.relationship_id,
    channel = state.operational_channel,
    credential = self.secrets:get(state.credential_ref),
    session = session,
    role = "central",
    id = state.central_id,
    direction = "parent",
  })
  self.runtime:drain()
  return true
end

--------------------------------------------------------------------------
-- Admitting Customer Routers
--------------------------------------------------------------------------

-- downstreamBase derives where this ISP's router channels start, from the
-- channel the Central Server gave it. Two ISPs therefore never collide.
function ISP:downstreamBase()
  local assigned = self:state().operational_channel or isp.CENTRAL_DISCOVERY_CHANNEL
  return isp.DOWNSTREAM_BASE + (assigned % isp.DOWNSTREAM_STRIDE) * isp.DOWNSTREAM_STRIDE
end

-- issueToken derives the next Router Enrollment Token from this ISP's own
-- Credential. Nothing is stored: the counter is enough to recognise it later,
-- and to show it again if an Operator loses the screen.
function ISP:issueToken()
  local state = self:state()
  local credential = self.secrets:get(state.credential_ref or "")
  if not credential then
    return nil, "upstream_unavailable", "enroll with a Central Server before issuing tokens"
  end
  state.tokens_issued = (state.tokens_issued or 0) + 1
  self.runtime.store:save(state, self.clock:now())
  return protocol.tokens.display(credential, "router", state.tokens_issued), state.tokens_issued
end

-- outstanding lists the tokens that have been issued and not yet spent. A
-- parent never stores a token; it stores which counters remain unspent.
function ISP:outstanding()
  local state = self:state()
  local credential = self.secrets:get(state.credential_ref or "")
  if not credential then return {} end
  local spent = state.tokens_spent or {}
  local candidates = {}
  for counter = 1, (state.tokens_issued or 0) do
    if not spent[tostring(counter)] then
      candidates[#candidates + 1] = {
        secret = protocol.tokens.issue(credential, "router", counter),
        ref = tostring(counter),
      }
    end
  end
  return candidates
end

function ISP:installListener()
  local state = self:state()
  assert(state.isp_id, "this ISP has no identity yet")

  -- Every Customer Router already registered has a channel of its own, and a
  -- restart has to start answering on all of them again.
  local assigned = {}
  for _, router in pairs(state.routers or {}) do
    if router.operational_channel then assigned[#assigned + 1] = router.operational_channel end
  end
  table.sort(assigned)

  self.listener = runtimePackage.enroll.newListener({
    transport = self.transport,
    clock = self.clock,
    engine = self.runtime.engine,
    parent_id = state.isp_id,
    parent_role = "isp",
    child_role = "router",
    display_name = state.isp_name,
    discovery_channel = self.routerDiscovery,
    -- Every Customer Router gets its own channel, so one router's traffic is
    -- never carried on another's.
    operational_channel = self:downstreamBase(),
    extra_channels = assigned,
    candidates = function() return self:outstanding() end,

    assign = function(request, context)
      local routerId = request.client_id
        or (self:state().isp_id .. "-" .. request.requested_name)
      local channel = self:downstreamBase() + ((self:state().routers_admitted or 0) + 1)
      local outcome = self.runtime:submit({
        kind = "register_router",
        router_id = routerId,
        customer_network_id = "network-" .. request.requested_name,
        customer_network_name = request.requested_name,
      })
      if not outcome.result.ok then
        return nil, outcome.result.code, outcome.result.message
      end

      local registry = self:state()
      registry.routers_admitted = (registry.routers_admitted or 0) + 1
      registry.routers[routerId].operational_channel = channel

      return {
        child_id = routerId,
        operational_channel = channel,
        configuration = protocol.object({
          customer_network_id = outcome.result.customer_network_id,
          customer_network_name = request.requested_name,
          provider_address = outcome.result.provider_address,
          isp_id = registry.isp_id,
          operational_channel = channel,
        }),
      }
    end,

    on_joined = function(joined) self:commitJoin(joined) end,
    credential_for = function(relationshipId)
      return self.secrets:get(self:credentialReference(relationshipId))
    end,
    child_of = function(relationshipId)
      local state = self:state()
      return state.relationships and state.relationships[relationshipId]
    end,
  })

  self.links:onHandshake(function(links, channel, replyChannel, text)
    return self.listener:handleFrame(links, channel, replyChannel, text)
  end)
  return self.listener
end

-- commitJoin records the credential and spends the one-time token, in that
-- order, before the acceptance leaves.
function ISP:commitJoin(joined)
  local state = self:state()
  state.relationships = state.relationships or {}
  state.relationships[joined.relationship_id] = joined.child_id
  state.tokens_spent = state.tokens_spent or {}
  if joined.candidate and joined.candidate.ref then
    state.tokens_spent[joined.candidate.ref] = true
  end
  self.secrets:put(self:credentialReference(joined.relationship_id), joined.relationship_credential)
  self.runtime.store:save(state, self.clock:now())
  return joined
end

--------------------------------------------------------------------------
-- Serving
--------------------------------------------------------------------------

function ISP:serve(timeoutMs) return self.runtime:pump(timeoutMs) end
function ISP:tick() return self.runtime:tick() end
function ISP:run(options) return self.runtime:run(options) end

return isp
