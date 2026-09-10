-- ISP authority.
--
-- An ISP owns its Customer Router registry and the Provider Addresses it hands
-- out from the allocations the Central Server delegated to it. It never talks
-- to another ISP: the Central Server is the only interconnection point, so even
-- traffic between two Customer Networks on this same ISP goes up and comes back
-- down. That is deliberate -- it keeps one route map authoritative instead of
-- letting each ISP grow a private shortcut.

local internal = ...
local protocol = internal("protocol")
local engineModule = internal("engine")
local ipv4 = internal("ipv4")
local names = internal("names")

local shared = engineModule.shared
local handlers = {
  link_up = shared.link_up,
  link_down = shared.link_down,
  tick = shared.tick,
  message = shared.message,
  effect_result = shared.effect_result,
  reconcile = shared.reconcile,
}

local get = rawget

local function allocations(state)
  local ranges = {}
  for index, entry in ipairs(state.provider_allocations or {}) do
    ranges[index] = ipv4.range(entry.first, entry.last)
  end
  return ranges
end

local function takenProviderAddresses(state)
  local taken = {}
  if state.provider_address then taken[state.provider_address] = true end
  for _, router in pairs(state.routers) do taken[router.provider_address] = true end
  return taken
end

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

function handlers.configure(engine, input, now, out)
  local settings = input.settings
  if type(settings) ~= "table" then
    return out:fail("invalid_message", "configure needs settings")
  end
  if not protocol.validate.identifier(settings.isp_id) then
    return out:fail("invalid_message", "isp_id must be a CraftNet identifier")
  end
  if not protocol.validate.normalizedName(settings.isp_name) then
    return out:fail("name_conflict", "an ISP name must be a normalized name")
  end

  local state = engine.state
  state.isp_id = settings.isp_id
  state.isp_name = settings.isp_name
  state.world_id = settings.world_id
  state.central_id = settings.central_id
  state.operational_channel = settings.operational_channel
  state.provider_allocations = settings.provider_allocations or {}
  state.routers = state.routers or {}

  -- The ISP takes the lowest address in its own allocation, unless the Operator
  -- named one. An explicit choice must still fall inside the allocation the
  -- Central Server delegated -- an ISP cannot widen its own range by asking.
  if not state.provider_address and #state.provider_allocations > 0 then
    local ranges = allocations(state)
    if settings.provider_address then
      if not protocol.validate.providerAddress(settings.provider_address) then
        return out:fail("invalid_message", "provider_address must be in 100.64.0.0/10")
      end
      local value = ipv4.toNumber(settings.provider_address)
      local inside = false
      for _, range in ipairs(ranges) do
        if ipv4.contains(range, value) then inside = true break end
      end
      if not inside then
        return out:fail("forbidden_operation", "that address is outside this ISP's allocation")
      end
      state.provider_address = settings.provider_address
    else
      state.provider_address = ipv4.lowestFree(ranges[1], {})
    end
  end

  out:durable("configured", { isp_id = state.isp_id })
  out:ok({ isp_id = state.isp_id, provider_address = state.provider_address })
end

--------------------------------------------------------------------------
-- Customer Router registry
--------------------------------------------------------------------------

-- register_router assigns a Customer Router its Provider Address and publishes
-- an exact Route Registration to the Central Server. The Customer Network name
-- must be unique within this ISP; the Central Server separately enforces that
-- the ISP name is unique within the World.
function handlers.register_router(engine, input, now, out)
  local state = engine.state
  if not state.isp_id then
    return out:fail("internal_error", "the ISP is not configured yet")
  end
  if not protocol.validate.identifier(input.router_id)
    or not protocol.validate.identifier(input.customer_network_id) then
    return out:fail("invalid_message", "identities must be CraftNet identifiers")
  end
  if not protocol.validate.normalizedName(input.customer_network_name) then
    return out:fail("name_conflict", "a Customer Network name must be a normalized name")
  end

  for routerId, router in pairs(state.routers) do
    if router.customer_network_name == input.customer_network_name and routerId ~= input.router_id then
      return out:fail("name_conflict",
        "'" .. input.customer_network_name .. "' is already registered with this ISP")
    end
  end

  local existing = state.routers[input.router_id]
  local providerAddress = existing and existing.provider_address
  if not providerAddress then
    local taken = takenProviderAddresses(state)
    if input.provider_address then
      -- An Operator may name the address, but only one inside this ISP's own
      -- delegated allocation and only one nobody else holds.
      if not protocol.validate.providerAddress(input.provider_address) then
        return out:fail("invalid_message", "provider_address must be in 100.64.0.0/10")
      end
      if taken[input.provider_address] then
        return out:fail("address_conflict", "that Provider Address is already assigned")
      end
      local value = ipv4.toNumber(input.provider_address)
      local inside = false
      for _, range in ipairs(allocations(state)) do
        if ipv4.contains(range, value) then inside = true break end
      end
      if not inside then
        return out:fail("forbidden_operation", "that address is outside this ISP's allocation")
      end
      providerAddress = input.provider_address
    else
      for _, range in ipairs(allocations(state)) do
        providerAddress = ipv4.lowestFree(range, taken)
        if providerAddress then break end
      end
    end
    if not providerAddress then
      return out:fail("pool_exhausted", "this ISP has no free Provider Address")
    end
  end

  -- A registering router also declares its own LAN configuration. The ISP
  -- keeps it for topology and for reconciliation, but never becomes its owner:
  -- the router remains authoritative for every one of those fields.
  local declared = existing and existing.declared or {}
  for _, field in ipairs({ "router_address", "dns_address", "pool_first",
    "pool_last", "lan_operational_channel" }) do
    if input[field] ~= nil then declared[field] = input[field] end
  end

  state.routers[input.router_id] = {
    router_id = input.router_id,
    customer_network_id = input.customer_network_id,
    customer_network_name = input.customer_network_name,
    provider_address = providerAddress,
    declared = declared,
  }
  out:durable("router_registered", {
    router_id = input.router_id,
    customer_network_id = input.customer_network_id,
    provider_address = providerAddress,
  })

  -- The registration travels to the Central Server through this ISP's own
  -- authenticated relationship, which is what proves the ISP owns the route.
  if engine.parentRelationshipId then
    out:send(engine.parentRelationshipId, "route_register", protocol.object({
      customer_network_id = input.customer_network_id,
      customer_network_name = input.customer_network_name,
      router_id = input.router_id,
      router_provider_address = providerAddress,
      isp_id = state.isp_id,
      revision = state.revision + 1,
    }), engine:allocateRequestId())
  end

  out:ok({
    router_id = input.router_id,
    provider_address = providerAddress,
    customer_network_id = input.customer_network_id,
  })
end

function handlers.deregister_router(engine, input, now, out)
  local state = engine.state
  local router = state.routers[input.router_id]
  if not router then
    return out:fail("name_not_found", "no such Customer Router")
  end
  state.routers[input.router_id] = nil
  out:durable("router_deregistered", { router_id = input.router_id })
  if engine.parentRelationshipId then
    out:send(engine.parentRelationshipId, "route_remove", protocol.object({
      customer_network_id = router.customer_network_id,
      revision = state.revision + 1,
    }), engine:allocateRequestId())
  end
  out:ok({ router_id = input.router_id, customer_network_id = router.customer_network_id })
end

--------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------

-- configurationFor builds the record for one Customer Router. The ISP is
-- authoritative only for the identity, the name it registered, and the Provider
-- Address; the LAN fields are echoed back exactly as the router declared them.
function handlers.configurationFor(engine, link)
  local router = engine.state.routers[link.id]
  if not router then
    return nil, "name_not_found", "that Customer Router is not registered"
  end
  local declared = router.declared or {}
  return protocol.object({
    customer_network_id = router.customer_network_id,
    customer_network_name = router.customer_network_name,
    provider_address = router.provider_address,
    isp_id = engine.state.isp_id,
    router_address = declared.router_address or "192.168.1.1",
    dns_address = declared.dns_address or declared.router_address or "192.168.1.1",
    pool_first = declared.pool_first or "192.168.1.20",
    pool_last = declared.pool_last or "192.168.1.39",
    lan_operational_channel = declared.lan_operational_channel or 0,
  })
end

-- applyConfiguration takes what the Central Server owns for this ISP.
function handlers.applyConfiguration(engine, configuration, out)
  local state = engine.state
  local allocations = rawget(configuration, "provider_allocations")
  if allocations == nil then
    return nil, "invalid_message", "an ISP configuration needs its Provider Allocations"
  end
  state.isp_id = rawget(configuration, "isp_id") or state.isp_id
  state.isp_name = rawget(configuration, "isp_name") or state.isp_name
  state.operational_channel = rawget(configuration, "operational_channel") or state.operational_channel

  local ranges = {}
  for index = 1, #allocations do
    local entry = rawget(allocations, index)
    ranges[index] = { first = rawget(entry, "first"), last = rawget(entry, "last") }
  end
  state.provider_allocations = ranges
  out:ephemeral("allocations_replaced", { count = #ranges })
  return true
end

--------------------------------------------------------------------------
-- Forwarding
--------------------------------------------------------------------------

local messages = {}
handlers.messages = messages

local function routerForNetwork(state, customerNetworkId)
  for _, router in pairs(state.routers) do
    if router.customer_network_id == customerNetworkId then return router end
  end
  return nil
end

local function routerForNetworkName(state, customerNetworkName)
  for _, router in pairs(state.routers) do
    if router.customer_network_name == customerNetworkName then return router end
  end
  return nil
end

local function eventBase(engine, extra)
  local fields = { isp_id = engine.state.isp_id }
  for key, value in pairs(extra or {}) do fields[key] = value end
  return fields
end

-- forward relays a request onward and remembers how to retrace it. The record
-- is keyed by the outgoing leg, so the reply that comes back on that leg finds
-- exactly one way home.
local function forward(engine, out, now, options)
  local onwardRequestId = engine:allocateRequestId()
  engine.transit:open({
    relationship_id = options.to_relationship_id,
    request_id = onwardRequestId,
    reply_to_relationship_id = options.from_relationship_id,
    reply_to_request_id = options.from_request_id,
    service = options.service,
  }, now)
  out:send(options.to_relationship_id, options.message_kind, options.body, onwardRequestId)
  return onwardRequestId
end

function messages.service_request(engine, link, message, now, out)
  local state = engine.state
  local body = message.body
  local service = get(body, "service")
  local bytes = engine:measure(body)

  if link.direction == "parent" then
    -- Coming down from the Central Server towards one of our Customer Routers.
    local destination = get(body, "destination")
    local router = routerForNetwork(state, get(destination, "customer_network_id"))
    if not router then
      out:replyError(link.relationship_id, message.request_id, "route_not_found",
        "this ISP serves no such Customer Network")
      return out:fail("route_not_found", "no registered router for that network")
    end
    local relationshipId = engine:linkFor(router.router_id)
    if not relationshipId then
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_request", operation = service,
        outcome = "router_unavailable", bytes = bytes,
        customer_network_id = router.customer_network_id, router_id = router.router_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, "router_unavailable",
        "that Customer Router is not connected")
      return out:fail("router_unavailable", "destination router is offline")
    end
    forward(engine, out, now, {
      to_relationship_id = relationshipId,
      from_relationship_id = link.relationship_id,
      from_request_id = message.request_id,
      message_kind = "service_request",
      body = body,
      service = service,
    })
    return out:ok({ forwarded = "down", router_id = router.router_id })
  end

  -- Going up from one of our Customer Routers.
  local router = state.routers[link.id]
  if link.role ~= "router" or not router then
    return out:fail("forbidden_operation", "only a registered Customer Router may send here")
  end

  -- A router may speak only for its own Customer Network. This is where a child
  -- claiming another network's identity is stopped.
  local claimed = get(get(body, "source"), "customer_network_id")
  if claimed ~= router.customer_network_id then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_request", operation = service,
      outcome = "forbidden_operation", bytes = bytes,
      customer_network_id = router.customer_network_id, router_id = router.router_id,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "a Customer Router may only speak for its own Customer Network")
    return out:fail("forbidden_operation", "source network does not belong to that router")
  end

  if not engine.parentRelationshipId then
    out:replyError(link.relationship_id, message.request_id, "upstream_unavailable",
      "this ISP has no connection to the Central Server")
    return out:fail("upstream_unavailable", "no parent relationship")
  end

  forward(engine, out, now, {
    to_relationship_id = engine.parentRelationshipId,
    from_relationship_id = link.relationship_id,
    from_request_id = message.request_id,
    message_kind = "service_request",
    body = body,
    service = service,
  })
  out:ok({ forwarded = "up" })
end

-- relay sends a terminal message back along the leg the request came in on.
local function relay(engine, link, message, now, out, messageKind)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    return out:fail("nat_flow_missing", "no correlation matches that reply")
  end
  engine.transit:close(record.flow_id)
  out:reply(record.reply_to_relationship_id, messageKind, message.body, record.reply_to_request_id)
  if messageKind == "service_response" then
    engine:record(out, eventBase(engine, {
      direction = "outbound", kind = messageKind, operation = record.service,
      outcome = "delivered_remote", bytes = engine:measure(message.body),
    }), now)
  end
  out:ok({ relayed = true })
end

function messages.service_response(engine, link, message, now, out)
  return relay(engine, link, message, now, out, "service_response")
end

function messages.dns_result(engine, link, message, now, out)
  return relay(engine, link, message, now, out, "dns_result")
end

function messages.error(engine, link, message, now, out)
  return relay(engine, link, message, now, out, "error")
end

-- dns_query is delegated to the Customer Router that owns the name when this
-- ISP serves it, and passed to the Central Server otherwise.
function messages.dns_query(engine, link, message, now, out)
  local state = engine.state
  local parsed, code, problem = names.parse(get(message.body, "name"),
    { isp_name = state.isp_name })
  if not parsed or parsed.kind ~= "computer" then
    out:replyError(link.relationship_id, message.request_id, code or "name_not_found",
      problem or "that name has no record")
    return out:fail(code or "name_not_found", problem or "not a Computer name")
  end

  local servedHere = parsed.isp_name == nil or parsed.isp_name == state.isp_name
  local router = servedHere and routerForNetworkName(state, parsed.customer_network_name)
  if router then
    local relationshipId = engine:linkFor(router.router_id)
    if not relationshipId then
      out:replyError(link.relationship_id, message.request_id, "router_unavailable",
        "that Customer Router is not connected")
      return out:fail("router_unavailable", "destination router is offline")
    end
    forward(engine, out, now, {
      to_relationship_id = relationshipId,
      from_relationship_id = link.relationship_id,
      from_request_id = message.request_id,
      message_kind = "dns_query",
      body = message.body,
    })
    return out:ok({ forwarded = "down" })
  end

  if link.direction == "parent" then
    out:replyError(link.relationship_id, message.request_id, "name_not_found",
      "this ISP serves no such Customer Network")
    return out:fail("name_not_found", "not served by this ISP")
  end
  if not engine.parentRelationshipId then
    out:replyError(link.relationship_id, message.request_id, "upstream_unavailable",
      "this ISP has no connection to the Central Server")
    return out:fail("upstream_unavailable", "no parent relationship")
  end
  forward(engine, out, now, {
    to_relationship_id = engine.parentRelationshipId,
    from_relationship_id = link.relationship_id,
    from_request_id = message.request_id,
    message_kind = "dns_query",
    body = message.body,
  })
  out:ok({ forwarded = "up" })
end

return handlers
