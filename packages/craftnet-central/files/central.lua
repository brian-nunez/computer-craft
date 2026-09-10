-- The Central Server composition root.
--
-- The Central Server is world infrastructure, not an ISP. It owns the World
-- identity, the ISP registry, the world-wide RFC 6598 allocator, the exact
-- route directory, and Customer Network Status. Every ISP reaches every other
-- ISP through it and only through it.
--
-- Its root secrets come from the External Application: a World Key it derives
-- ISP Enrollment Tokens from, and a Gateway Credential it will authenticate
-- with when the Gateway arrives in Milestone 6. Nothing in world invents
-- either of them.

local internal = ...
local protocol = internal("protocol")
local runtimePackage = internal("runtime")

local central = {}

central.ISP_DISCOVERY_CHANNEL = 42000
central.ISP_CHANNEL_BASE = 42100

local Central = {}
Central.__index = Central

function central.new(options)
  assert(type(options) == "table", "a Central Server needs options")
  local adapters = options.adapters or {}
  for _, field in ipairs({ "transport", "clock", "storage" }) do
    assert(type(adapters[field]) == "table", "a Central Server needs a " .. field .. " adapter")
  end

  local links = runtimePackage.newLinks({ transport = adapters.transport })
  return setmetatable({
    links = links,
    transport = adapters.transport,
    clock = adapters.clock,
    discoveryChannel = options.discovery_channel or central.ISP_DISCOVERY_CHANNEL,
    runtime = runtimePackage.new({
      role = "central",
      path = options.path or "craftnet/central",
      adapters = {
        clock = adapters.clock, storage = adapters.storage,
        screen = adapters.screen, links = links, gateway = adapters.gateway,
      },
      connectivity = options.connectivity,
    }),
  }, Central)
end

function Central:state() return self.runtime:state() end
function Central:lines() return self.runtime:lines() end

--------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------

function Central:start()
  local ok, source, problem = self.runtime:start()
  if not ok then return nil, source, problem end
  self.secrets = self.runtime:secrets()
  self.secrets:load()
  if self:state().world_id then self:installListener() end
  return true, source
end

-- provision applies the bundle the External Application generated. The World
-- Key and the Gateway Credential go to the secret store; what reaches durable
-- state is a reference to each, never a value.
function Central:provision(bundle)
  assert(type(bundle) == "table", "a provisioning bundle is required")
  for _, field in ipairs({ "world_id", "central_id", "world_key", "gateway_credential" }) do
    assert(type(bundle[field]) == "string" and bundle[field] ~= "",
      "the provisioning bundle needs '" .. field .. "'")
  end

  local outcome = self.runtime:submit({
    kind = "configure",
    settings = {
      world_id = bundle.world_id,
      central_id = bundle.central_id,
      gateway_url = bundle.gateway_url,
      gateway_credential_ref = bundle.gateway_credential_ref or "gateway-credential",
    },
  })
  if not outcome.result.ok then
    return nil, outcome.result.code, outcome.result.message
  end

  local worldKey = protocol.conformance.sha256.fromHex(bundle.world_key)
  local ok, problem = self.secrets:put("world-key", worldKey)
  if not ok then return nil, "internal_error", problem end
  ok, problem = self.secrets:put(
    self:state().gateway_credential_ref,
    protocol.conformance.sha256.fromHex(bundle.gateway_credential))
  if not ok then return nil, "internal_error", problem end

  self:installListener()
  return true
end

--------------------------------------------------------------------------
-- Enrollment tokens
--------------------------------------------------------------------------

function Central:credentialReference(relationshipId)
  return "rel-" .. relationshipId
end

-- issueToken derives the next ISP Enrollment Token from the World Key. Nothing
-- is stored but the counter, which is enough to recognise the token later and
-- to show it again if an Operator loses the screen.
function Central:issueToken()
  local worldKey = self.secrets:get("world-key")
  if not worldKey then
    return nil, "internal_error", "this Central Server has not been provisioned"
  end
  local state = self:state()
  state.tokens_issued = (state.tokens_issued or 0) + 1
  self.runtime.store:save(state, self.clock:now())
  return protocol.tokens.display(worldKey, "isp", state.tokens_issued), state.tokens_issued
end

function Central:outstanding()
  local worldKey = self.secrets:get("world-key")
  if not worldKey then return {} end
  local state = self:state()
  local spent = state.tokens_spent or {}
  local candidates = {}
  for counter = 1, (state.tokens_issued or 0) do
    if not spent[tostring(counter)] then
      candidates[#candidates + 1] = {
        secret = protocol.tokens.issue(worldKey, "isp", counter),
        ref = tostring(counter),
      }
    end
  end
  return candidates
end

--------------------------------------------------------------------------
-- Admitting ISPs
--------------------------------------------------------------------------

function Central:installListener()
  local state = self:state()
  assert(state.world_id, "this Central Server has not been provisioned")

  self.listener = runtimePackage.enroll.newListener({
    transport = self.transport,
    clock = self.clock,
    engine = self.runtime.engine,
    parent_id = state.central_id,
    parent_role = "central",
    child_role = "isp",
    display_name = state.world_id,
    discovery_channel = self.discoveryChannel,
    operational_channel = central.ISP_CHANNEL_BASE,
    candidates = function() return self:outstanding() end,

    assign = function(request)
      local ispId = request.client_id or ("isp-" .. request.requested_name)
      local outcome = self.runtime:submit({
        kind = "register_isp",
        isp_id = ispId,
        isp_name = request.requested_name,
      })
      if not outcome.result.ok then
        return nil, outcome.result.code, outcome.result.message
      end

      local registry = self:state()
      registry.isps_admitted = (registry.isps_admitted or 0) + 1
      local channel = central.ISP_CHANNEL_BASE + registry.isps_admitted - 1
      registry.isps[ispId].operational_channel = channel

      local allocations = protocol.array()
      for index, allocation in ipairs(outcome.result.provider_allocations) do
        rawset(allocations, index, protocol.object({
          first = allocation.first, last = allocation.last,
        }))
      end

      return {
        child_id = ispId,
        operational_channel = channel,
        configuration = protocol.object({
          isp_id = ispId,
          isp_name = request.requested_name,
          provider_allocations = allocations,
          operational_channel = channel,
        }),
      }
    end,

    on_joined = function(joined) self:commitJoin(joined) end,
    credential_for = function(relationshipId)
      return self.secrets:get(self:credentialReference(relationshipId))
    end,
    child_of = function(relationshipId)
      local held = self:state()
      return held.relationships and held.relationships[relationshipId]
    end,
  })

  self.links:onHandshake(function(links, channel, replyChannel, text)
    return self.listener:handleFrame(links, channel, replyChannel, text)
  end)
  return self.listener
end

function Central:commitJoin(joined)
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
-- Administration
--------------------------------------------------------------------------

-- setNetworkStatus is the one administrative command v1 accepts. Disabling a
-- Customer Network refuses its new traffic and keeps every durable
-- registration, so re-enabling needs no re-enrollment.
function Central:setNetworkStatus(customerNetworkId, status, commandId)
  local outcome = self.runtime:submit({
    kind = "set_network_status",
    customer_network_id = customerNetworkId,
    status = status,
    command_id = commandId,
  })
  if not outcome.result.ok then
    return nil, outcome.result.code, outcome.result.message
  end
  return outcome.result
end

-- receiveGateway is what a Gateway adapter calls when a frame arrives from the
-- External Application. The adapter owns the wire; this owns what the frame
-- means, and the engine owns what it does. An Operator's decision made in the
-- dashboard reaches authoritative state through exactly this path.
function Central:receiveGateway(frameKind, body, correlation)
  correlation = correlation or {}
  local outcome = self.runtime:submit({
    kind = "gateway_frame",
    frame_kind = frameKind,
    body = body,
    command_id = correlation.command_id,
    request_id = correlation.request_id,
  })
  return outcome.result
end

-- topology is the projection the External Application receives. It is a view of
-- authoritative state, never an authority, and it carries no secret value.
function Central:topology()
  local outcome = self.runtime:submit({ kind = "topology" })
  return outcome.result.topology
end

--------------------------------------------------------------------------
-- Serving
--------------------------------------------------------------------------

function Central:serve(timeoutMs) return self.runtime:pump(timeoutMs) end
function Central:tick() return self.runtime:tick() end
function Central:run(options) return self.runtime:run(options) end

return central
