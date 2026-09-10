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

-- How many Traffic Events travel in one batch, and how many wait for a session
-- that is not there. Both come from what the wire and the role already state:
-- the protocol's batch limit, and the Central Server's own buffer capacity.
central.TRAFFIC_BATCH = protocol.limits.TRAFFIC_BATCH_EVENTS
central.TRAFFIC_QUEUE = 2000

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
    -- How this Central Server builds its Gateway. A ready-made adapter may be
    -- handed in instead, which is what a test drives a whole World with; the
    -- factory is what a real Computer uses, because the socket must not be
    -- opened until the World identity is known.
    gateway = adapters.gateway,
    gatewayFactory = options.gateway_factory or runtimePackage.adapters.gateway,
    -- What this World has observed but not yet reported. It fills whether or
    -- not there is a session, and is bounded, so a stopped External Application
    -- costs a Central Server a fixed amount of memory rather than a growing one.
    pendingTraffic = {},
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
  if self:state().world_id then
    self:installListener()
    self:installGateway()
  end
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
  self:installGateway()
  return true
end

--------------------------------------------------------------------------
-- The Gateway Session
--------------------------------------------------------------------------

-- installGateway builds the one outbound WebSocket this World has. It is not
-- opened here: connecting is the loop's job, under backoff, because the
-- External Application not being up is an ordinary condition rather than a
-- reason a Central Server cannot start.
--
-- A World provisioned without a URL simply has no Gateway. Everything internal
-- -- addressing, DNS, routing, NAT, Network Status -- carries on exactly as it
-- does when craftnetd is stopped, and external calls fail with a stable code.
function Central:installGateway()
  local state = self:state()
  if not state.gateway_url or state.gateway_url == "" then return nil end
  if self.gateway then return self.gateway end
  if not self.gatewayFactory then return nil end

  self.gateway = self.gatewayFactory({
    url = state.gateway_url,
    world_id = state.world_id,
    central_id = state.central_id,
    clock = self.clock,
    credential = function()
      return self.secrets:get(state.gateway_credential_ref)
    end,
    -- What this World already holds, so a reconnecting session is answered
    -- against it rather than being resent everything from the beginning.
    revisions = function()
      return self:state().revision or 0, self:state().traffic_sequence or 0
    end,
  })

  -- CraftOS delivers websocket events through the same queue as modem messages,
  -- so the transport this role already polls is where they have to be caught.
  if type(self.transport.observe) == "function" then
    self.transport:observe(function(event, url, message)
      return self.gateway:observe(event, url, message)
    end)
  end

  self.runtime.adapters.gateway = self.gateway
  return self.gateway
end

-- drainGateway hands the External Application's frames to the engine. It is a
-- separate step from receiving them on purpose: the adapter owns the socket,
-- this owns what a frame means, and the engine owns what it does.
function Central:drainGateway()
  if not self.gateway then return 0 end
  local drained = 0
  while self.gateway:pending() > 0 do
    local frame = self.gateway:next()
    if not frame then break end
    self:receiveGateway(frame.kind, frame.body, {
      request_id = frame.request_id, command_id = frame.command_id,
    })
    drained = drained + 1
  end
  return drained
end

function Central:gatewayStatus()
  if not self.gateway then
    return { ready = false, url = self:state().gateway_url }
  end
  return self.gateway:describe()
end

--------------------------------------------------------------------------
-- What this World reports
--------------------------------------------------------------------------

-- publishTopology sends the whole projection. It happens once each time a
-- session opens, because a reconnecting Central Server may have changed while
-- it was away and the External Application has no way to know what it missed.
function Central:publishTopology()
  if not (self.gateway and self.gateway:ready()) then return nil end
  local topology = self:topology()
  if not topology then return nil end
  local ok, problem = self.gateway:send("topology_snapshot", topology)
  if not ok then return nil, "gateway_unavailable", problem end
  return true
end

-- publishTraffic relays what this Central Server observed. Sequences are
-- durable and strictly increasing, so a batch lost to a disconnect shows up at
-- the far end as a gap in the record rather than as a plausible present.
--
-- Events accumulate whether or not there is a session; the queue is bounded by
-- the same capacity the engine's own buffer uses, and past it the oldest are
-- dropped. A World does not grow without limit because craftnetd is down.
function Central:publishTraffic()
  local drained = self.runtime:drainTelemetry()
  for _, event in ipairs(drained) do
    self.pendingTraffic[#self.pendingTraffic + 1] = event
  end
  while #self.pendingTraffic > central.TRAFFIC_QUEUE do
    table.remove(self.pendingTraffic, 1)
    self.trafficDropped = (self.trafficDropped or 0) + 1
  end
  if not (self.gateway and self.gateway:ready()) then return 0 end

  local sentBatches = 0
  while #self.pendingTraffic > 0 do
    local events = protocol.array()
    for _ = 1, math.min(central.TRAFFIC_BATCH, #self.pendingTraffic) do
      rawset(events, #events + 1, table.remove(self.pendingTraffic, 1))
    end

    local state = self:state()
    local first = (state.traffic_sequence or 0) + 1
    local last = first + #events - 1
    local ok = self.gateway:send("traffic_batch", protocol.object({
      first_sequence = first,
      last_sequence = last,
      events = events,
    }))
    if not ok then
      -- The session went away mid-flight. These events are not re-queued: the
      -- sequence they were given is spent, and the far end will record the
      -- hole rather than be handed the same numbers twice.
      return sentBatches
    end

    state.traffic_sequence = last
    self.runtime.store:save(state, self.clock:now())
    sentBatches = sentBatches + 1
  end
  return sentBatches
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

-- serve takes one turn of the loop. The Gateway is drained around it: a frame
-- that arrived while this role was waiting on a modem is acted on here rather
-- than sitting in the adapter until something else happens to wake the World.
function Central:serve(timeoutMs)
  self:drainGateway()
  local outcome = self.runtime:pump(timeoutMs)
  self:drainGateway()
  return outcome
end

-- tick advances everything time drives, the Gateway included: reconnecting
-- under backoff, heartbeating a session that would otherwise be silent while
-- the World is idle, and reporting what this Central Server has observed.
--
-- A session that has just opened is told the whole topology before anything
-- else travels on it, so the External Application never has to place a Traffic
-- Event against a World it has not been shown.
function Central:tick()
  if self.gateway then
    if type(self.gateway.tick) == "function" then self.gateway:tick() end
    local session = self.gateway:session()
    if session and session ~= self.publishedSession then
      if self:publishTopology() then self.publishedSession = session end
    end
    self:publishTraffic()
    self:drainGateway()
  end
  return self.runtime:tick()
end

-- run is the loop a startup program enters. It is written here rather than
-- delegated to the runtime because the Central Server is the one role with two
-- things to wait on, and the wait has to be short enough for both.
function Central:run(options)
  options = options or {}
  local iterations = 0
  self.running = true
  while self.running do
    iterations = iterations + 1
    if options.max_iterations and iterations > options.max_iterations then break end
    if not self:serve(options.idle_timeout_ms or 1000) then
      self:tick()
    end
  end
  return iterations
end

function Central:stop()
  self.running = false
  self.runtime:stop()
  if self.gateway then self.gateway:disconnect() end
  return true
end

return central
