-- Central Server authority.
--
-- The Central Server is world infrastructure, not an ISP. It owns the World
-- identity, the ISP registry, the world-wide RFC 6598 allocator, the exact
-- route directory, and Customer Network Status. Its route map holds one entry
-- per Customer Network -- there is no routing protocol and no prefix matching,
-- because a range here organizes allocation, not delivery.

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
}

local get = rawget

-- The whole RFC 6598 shared space, delegated to ISPs a block at a time.
local PROVIDER_SPACE = { first = ipv4.toNumber("100.64.0.0"), last = ipv4.toNumber("100.127.255.255") }
local DEFAULT_BLOCK = 256

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

function handlers.configure(engine, input, now, out)
  local settings = input.settings
  if type(settings) ~= "table" then
    return out:fail("invalid_message", "configure needs settings")
  end
  if not protocol.validate.identifier(settings.world_id)
    or not protocol.validate.identifier(settings.central_id) then
    return out:fail("invalid_message", "identities must be CraftNet identifiers")
  end

  local state = engine.state
  state.world_id = settings.world_id
  state.central_id = settings.central_id
  state.gateway_url = settings.gateway_url
  state.gateway_credential_ref = settings.gateway_credential_ref
  state.isps = state.isps or {}
  state.routes = state.routes or {}
  state.network_status = state.network_status or {}
  state.computers = state.computers or {}

  out:durable("configured", { world_id = state.world_id })
  out:ok({ world_id = state.world_id, central_id = state.central_id })
end

--------------------------------------------------------------------------
-- ISP registry and the RFC 6598 allocator
--------------------------------------------------------------------------

local function delegatedRanges(state)
  local ranges = {}
  for _, isp in pairs(state.isps) do
    for _, allocation in ipairs(isp.provider_allocations) do
      ranges[#ranges + 1] = ipv4.range(allocation.first, allocation.last)
    end
  end
  -- lowestFreeBlock walks this list, so a stable order keeps allocation
  -- deterministic across runs.
  table.sort(ranges, function(left, right) return left.first < right.first end)
  return ranges
end

-- register_isp admits an ISP and delegates it a block of Provider Addresses
-- that overlaps nothing already given out.
function handlers.register_isp(engine, input, now, out)
  local state = engine.state
  if not state.world_id then
    return out:fail("internal_error", "the Central Server is not configured yet")
  end
  if not protocol.validate.identifier(input.isp_id) then
    return out:fail("invalid_message", "isp_id must be a CraftNet identifier")
  end
  if not protocol.validate.normalizedName(input.isp_name) then
    return out:fail("name_conflict", "an ISP name must be a normalized name")
  end
  for ispId, isp in pairs(state.isps) do
    if isp.isp_name == input.isp_name and ispId ~= input.isp_id then
      return out:fail("name_conflict", "'" .. input.isp_name .. "' is already registered in this World")
    end
  end

  local existing = state.isps[input.isp_id]
  if existing then
    return out:ok({
      isp_id = input.isp_id, provider_allocations = existing.provider_allocations, reused = true,
    })
  end

  local block = ipv4.lowestFreeBlock(PROVIDER_SPACE, input.block_size or DEFAULT_BLOCK,
    delegatedRanges(state))
  if not block then
    return out:fail("pool_exhausted", "the World has no free Provider Allocation left")
  end

  local allocation = ipv4.describe(block)
  state.isps[input.isp_id] = {
    isp_id = input.isp_id,
    isp_name = input.isp_name,
    provider_allocations = { allocation },
  }
  out:durable("isp_registered", { isp_id = input.isp_id, allocation = allocation })
  out:ok({ isp_id = input.isp_id, provider_allocations = { allocation }, reused = false })
end

--------------------------------------------------------------------------
-- Network Status
--------------------------------------------------------------------------

-- set_network_status is the one administrative command v1 accepts. It is
-- idempotent by Command ID: repeating it returns the already-applied result
-- rather than applying it twice.
function handlers.set_network_status(engine, input, now, out)
  local state = engine.state
  if not protocol.validate.networkStatus(input.status) then
    return out:fail("invalid_message", "status must be enabled or disabled")
  end
  local route = state.routes[input.customer_network_id]
  if not route then
    return out:fail("route_not_found", "no such Customer Network")
  end

  state.applied_commands = state.applied_commands or {}
  if input.command_id and state.applied_commands[input.command_id] then
    local applied = state.applied_commands[input.command_id]
    return out:ok({
      customer_network_id = applied.customer_network_id,
      status = applied.status, revision = applied.revision, repeated = true,
    })
  end

  state.network_status[input.customer_network_id] = input.status
  if input.command_id then
    state.applied_commands[input.command_id] = {
      customer_network_id = input.customer_network_id,
      status = input.status,
      revision = state.revision + 1,
    }
  end
  out:durable("network_status_set", {
    customer_network_id = input.customer_network_id, status = input.status,
  })
  -- Disabling a Customer Network refuses its new traffic but keeps every
  -- durable registration, so re-enabling needs no re-enrollment.
  out:ok({
    customer_network_id = input.customer_network_id,
    status = input.status, repeated = false,
  })
end

function handlers.status_of(engine, input, now, out)
  local status = engine.state.network_status[input.customer_network_id] or "enabled"
  out:ok({ customer_network_id = input.customer_network_id, status = status })
end

-- configurationFor builds what the Central Server assigns to one ISP: its
-- identity, its name, its Provider Allocations, and its Operational Channel.
function handlers.configurationFor(engine, link)
  local isp = engine.state.isps[link.id]
  if not isp then
    return nil, "name_not_found", "that ISP is not registered"
  end
  local allocations = protocol.array()
  for index, allocation in ipairs(isp.provider_allocations) do
    rawset(allocations, index, protocol.object({
      first = allocation.first, last = allocation.last,
    }))
  end
  return protocol.object({
    isp_id = isp.isp_id,
    isp_name = isp.isp_name,
    provider_allocations = allocations,
    operational_channel = isp.operational_channel or 0,
  })
end

--------------------------------------------------------------------------
-- Route directory
--------------------------------------------------------------------------

local messages = {}
handlers.messages = messages

local function eventBase(engine, extra)
  local fields = {}
  for key, value in pairs(extra or {}) do fields[key] = value end
  return fields
end

-- route_register records one exact Customer Network entry. Only the ISP that
-- owns the route may publish or change it, and the Provider Address must fall
-- inside that ISP's own delegated allocation.
function messages.route_register(engine, link, message, now, out)
  local state = engine.state
  local body = message.body

  if link.role ~= "isp" then
    return out:fail("forbidden_operation", "only an ISP may register a route")
  end
  local isp = state.isps[link.id]
  if not isp then
    return out:fail("forbidden_operation", "that ISP is not registered")
  end
  if get(body, "isp_id") ~= link.id then
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "an ISP may only register its own routes")
    return out:fail("forbidden_operation", "an ISP may not register another ISP's route")
  end

  local networkId = get(body, "customer_network_id")
  local existing = state.routes[networkId]
  if existing and existing.isp_id ~= link.id then
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "that Customer Network belongs to another ISP")
    return out:fail("forbidden_operation", "route belongs to another ISP")
  end

  local providerAddress = get(body, "router_provider_address")
  local inside = false
  for _, allocation in ipairs(isp.provider_allocations) do
    if ipv4.contains(ipv4.range(allocation.first, allocation.last),
      ipv4.toNumber(providerAddress)) then
      inside = true
      break
    end
  end
  if not inside then
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "that Provider Address is outside this ISP's allocation")
    return out:fail("forbidden_operation", "Provider Address is outside the allocation")
  end

  local networkName = get(body, "customer_network_name")
  for otherId, route in pairs(state.routes) do
    if route.isp_id == link.id and route.customer_network_name == networkName
      and otherId ~= networkId then
      out:replyError(link.relationship_id, message.request_id, "name_conflict",
        "that Customer Network name is already registered with this ISP")
      return out:fail("name_conflict", "duplicate Customer Network name")
    end
  end

  state.routes[networkId] = {
    customer_network_id = networkId,
    customer_network_name = networkName,
    router_id = get(body, "router_id"),
    router_provider_address = providerAddress,
    isp_id = link.id,
  }
  if state.network_status[networkId] == nil then
    state.network_status[networkId] = "enabled"
  end
  out:durable("route_registered", { customer_network_id = networkId, isp_id = link.id })
  out:reply(link.relationship_id, "ack", protocol.object({
    acked_request_id = message.request_id,
    result_revision = state.revision + 1,
  }), message.request_id)
  out:ok({ customer_network_id = networkId })
end

-- route_remove withdraws a route. The registration disappears, but nothing
-- about the Customer Network's own durable state does.
function messages.route_remove(engine, link, message, now, out)
  local state = engine.state
  local networkId = get(message.body, "customer_network_id")
  local route = state.routes[networkId]
  if not route then
    return out:fail("route_not_found", "no such route")
  end
  if route.isp_id ~= link.id then
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "that Customer Network belongs to another ISP")
    return out:fail("forbidden_operation", "route belongs to another ISP")
  end
  state.routes[networkId] = nil
  out:durable("route_removed", { customer_network_id = networkId })
  out:reply(link.relationship_id, "ack", protocol.object({
    acked_request_id = message.request_id,
    result_revision = state.revision + 1,
  }), message.request_id)
  out:ok({ customer_network_id = networkId })
end

--------------------------------------------------------------------------
-- Interconnection
--------------------------------------------------------------------------

-- service_request crosses between Customer Networks here, and only here. The
-- Central Server is the sole interconnection point even when both networks
-- belong to the same ISP.
function messages.service_request(engine, link, message, now, out)
  local state = engine.state
  local body = message.body
  local service = get(body, "service")
  local bytes = engine:measure(body)

  if link.role ~= "isp" or not state.isps[link.id] then
    return out:fail("forbidden_operation", "only a registered ISP may send here")
  end

  -- The sending ISP must actually own the source Customer Network.
  local sourceNetwork = get(get(body, "source"), "customer_network_id")
  local sourceRoute = state.routes[sourceNetwork]
  if not sourceRoute or sourceRoute.isp_id ~= link.id then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_request", operation = service,
      outcome = "forbidden_operation", bytes = bytes, isp_id = link.id,
      customer_network_id = sourceNetwork,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "forbidden_operation",
      "an ISP may only carry traffic for its own Customer Networks")
    return out:fail("forbidden_operation", "source network is not served by that ISP")
  end

  local destinationNetwork = get(get(body, "destination"), "customer_network_id")
  local route = state.routes[destinationNetwork]
  if not route then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_request", operation = service,
      outcome = "route_not_found", bytes = bytes, isp_id = link.id,
      customer_network_id = destinationNetwork,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "route_not_found",
      "no route to that Customer Network")
    return out:fail("route_not_found", "no route entry")
  end

  if (state.network_status[destinationNetwork] or "enabled") == "disabled" then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_request", operation = service,
      outcome = "network_disabled", bytes = bytes, isp_id = route.isp_id,
      customer_network_id = destinationNetwork, router_id = route.router_id,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "network_disabled",
      "that Customer Network is disabled")
    return out:fail("network_disabled", "destination network is disabled")
  end

  local relationshipId = engine:linkFor(route.isp_id)
  if not relationshipId then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_request", operation = service,
      outcome = "router_unavailable", bytes = bytes, isp_id = route.isp_id,
      customer_network_id = destinationNetwork,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "router_unavailable",
      "that ISP is not connected")
    return out:fail("router_unavailable", "destination ISP is offline")
  end

  local onwardRequestId = engine:allocateRequestId()
  engine.transit:open({
    relationship_id = relationshipId,
    request_id = onwardRequestId,
    reply_to_relationship_id = link.relationship_id,
    reply_to_request_id = message.request_id,
    service = service,
  }, now)
  out:send(relationshipId, "service_request", body, onwardRequestId)
  engine:record(out, eventBase(engine, {
    direction = "inbound", kind = "service_request", operation = service,
    outcome = "delivered_remote", bytes = bytes, isp_id = route.isp_id,
    customer_network_id = destinationNetwork, router_id = route.router_id,
  }), now)
  out:ok({ forwarded = true, isp_id = route.isp_id })
end

local function relay(engine, link, message, now, out, messageKind)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    return out:fail("nat_flow_missing", "no correlation matches that reply")
  end
  engine.transit:close(record.flow_id)
  out:reply(record.reply_to_relationship_id, messageKind, message.body, record.reply_to_request_id)
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

function messages.ack(engine, link, message, now, out)
  out:ok({ acknowledged = get(message.body, "acked_request_id") })
end

-- topology_change is how the Central Server learns a World's Computers without
-- ever having met one. It is a projection, so it is applied only for a Customer
-- Network the reporting ISP actually owns.
function messages.topology_change(engine, link, message, now, out)
  local state = engine.state
  if link.role ~= "isp" or not state.isps[link.id] then
    return out:fail("forbidden_operation", "only a registered ISP may report here")
  end

  local entity = get(message.body, "entity")
  local networkId = get(entity, "customer_network_id")
  local route = state.routes[networkId]
  if not route or route.isp_id ~= link.id then
    return out:fail("forbidden_operation",
      "an ISP may only report for its own Customer Networks")
  end
  if get(message.body, "entity_type") ~= "computer" then
    return out:ok({ ignored = get(message.body, "entity_type") })
  end

  state.computers = state.computers or {}
  local computerId = get(entity, "computer_id")
  if get(message.body, "change") == "removed" then
    state.computers[computerId] = nil
    out:durable("computer_forgotten", { computer_id = computerId })
  else
    state.computers[computerId] = {
      computer_id = computerId,
      hostname = get(entity, "hostname"),
      address = get(entity, "address"),
      customer_network_id = networkId,
      router_id = route.router_id,
      isp_id = route.isp_id,
    }
    out:durable("computer_recorded", { computer_id = computerId })
  end
  out:ok({ computer_id = computerId })
end

-- dns_query reaches the Central Server only when the name names another ISP.
function messages.dns_query(engine, link, message, now, out)
  local state = engine.state
  local parsed, code, problem = names.parse(get(message.body, "name"), nil)
  if not parsed or parsed.kind ~= "computer" or not parsed.isp_name then
    out:replyError(link.relationship_id, message.request_id, code or "name_not_found",
      problem or "that name is not fully qualified")
    return out:fail(code or "name_not_found", problem or "not a qualified Computer name")
  end

  local targetIspId
  for ispId, isp in pairs(state.isps) do
    if isp.isp_name == parsed.isp_name then targetIspId = ispId end
  end
  if not targetIspId then
    out:replyError(link.relationship_id, message.request_id, "name_not_found",
      "no such ISP in this World")
    return out:fail("name_not_found", "unknown ISP name")
  end

  local relationshipId = engine:linkFor(targetIspId)
  if not relationshipId then
    out:replyError(link.relationship_id, message.request_id, "router_unavailable",
      "that ISP is not connected")
    return out:fail("router_unavailable", "destination ISP is offline")
  end

  local onwardRequestId = engine:allocateRequestId()
  engine.transit:open({
    relationship_id = relationshipId,
    request_id = onwardRequestId,
    reply_to_relationship_id = link.relationship_id,
    reply_to_request_id = message.request_id,
  }, now)
  out:send(relationshipId, "dns_query", message.body, onwardRequestId)
  out:ok({ forwarded = true, isp_id = targetIspId })
end

--------------------------------------------------------------------------
-- The External Application
--------------------------------------------------------------------------

-- external_request hands one call to the Gateway. The Central Server is the
-- only role that ever opens a connection outward, and it stamps the ancestry
-- from what it actually knows rather than from anything the caller wrote.
--
-- When there is no Gateway Session the call fails with gateway_unavailable and
-- nothing else changes: internal addressing, DNS, and cross-network traffic all
-- carry on, because none of them ever needed the External Application.
function handlers.external_request(engine, input, now, out)
  local state = engine.state
  if not state.world_id then
    return out:fail("internal_error", "the Central Server is not configured yet")
  end
  if not protocol.validate.operationName(input.operation or "") then
    return out:fail("invalid_message", "an operation name is required")
  end

  local route = state.routes[input.customer_network_id]
  if not route then
    return out:fail("route_not_found", "no route to that Customer Network")
  end
  if (state.network_status[input.customer_network_id] or "enabled") == "disabled" then
    return out:fail("network_disabled", "that Customer Network is disabled")
  end

  local body = protocol.object({
    ancestry = protocol.object({
      world_id = state.world_id,
      isp_id = route.isp_id,
      customer_network_id = route.customer_network_id,
      router_id = route.router_id,
      computer_id = input.computer_id,
      local_address = input.local_address,
    }),
    source_flow_id = input.source_flow_id or "flow-external",
    operation = input.operation,
    payload = input.payload or protocol.object(),
  })
  if input.access_token then rawset(body, "access_token", input.access_token) end
  if input.device_credential then rawset(body, "device_credential", input.device_credential) end
  if input.registration_nonce then rawset(body, "registration_nonce", input.registration_nonce) end

  out:gateway("external_request", body, { request_id = input.request_id })
  out:ok({ operation = input.operation, forwarded = true })
end

-- reject answers an administrative command the Central Server will not carry
-- out. The answer always goes back, applied or rejected: a command with no
-- answer is one the External Application resends forever under the same Command
-- ID, so refusing one out loud is part of the contract rather than an
-- afterthought.
local function reject(engine, out, commandId, requestId, code, message)
  out:gateway("command_result", protocol.object({
    command_id = commandId,
    status = "rejected",
    revision = engine.state.revision or 0,
    error = protocol.errors.new(code, message),
  }), { request_id = requestId, command_id = commandId })
  return out:fail(code, message)
end

-- gateway_frame is what arrived on the Gateway Session. The only thing v1
-- accepts inward is an administrative command, and the only administrative
-- command is set_network_status: the External Application observes a World and
-- may disable a Customer Network, and that is the whole of its authority.
--
-- Everything an Operator asked for is applied here, by the Central Server, on
-- its own authoritative state. The External Application never edits a World; it
-- asks, and this is where the asking is answered.
function handlers.gateway_frame(engine, input, now, out)
  if input.frame_kind ~= "admin_command" then
    return out:fail("forbidden_operation",
      "the Gateway carries only administrative commands inward")
  end

  local body = input.body or protocol.object()
  local commandId = input.command_id or get(body, "command_id")
  if type(commandId) ~= "string" or not protocol.validate.identifier(commandId) then
    return out:fail("invalid_message", "an administrative command needs a Command ID")
  end
  local requestId = input.request_id or commandId

  if get(body, "action") ~= "set_network_status" then
    return reject(engine, out, commandId, requestId, "forbidden_operation",
      "set_network_status is the only administrative command in v1")
  end

  -- The ordinary handler does the work, so a command that arrives over the
  -- Gateway and one an Operator types at the Central Server take exactly the
  -- same path, including its idempotency by Command ID.
  handlers.set_network_status(engine, {
    customer_network_id = get(body, "customer_network_id"),
    status = get(body, "status"),
    command_id = commandId,
  }, now, out)

  local applied = out.result
  if not applied.ok then
    return reject(engine, out, commandId, requestId, applied.code, applied.message)
  end

  -- A repeat answers with the revision the change was applied at, not with a
  -- fresh one: nothing happened this time round.
  out:gateway("command_result", protocol.object({
    command_id = commandId,
    status = "applied",
    revision = applied.revision or (engine.state.revision or 0) + 1,
  }), { request_id = requestId, command_id = commandId })
  out:ok({
    command_id = commandId,
    customer_network_id = applied.customer_network_id,
    status = applied.status,
    repeated = applied.repeated or false,
  })
end

--------------------------------------------------------------------------
-- Topology
--------------------------------------------------------------------------

-- topology renders the projection the External Application receives. It is a
-- view of authoritative state, never an authority in its own right, and it
-- carries no secret value.
function handlers.topology(engine, input, now, out)
  local state = engine.state
  local isps, routers, statuses = protocol.array(), protocol.array(), protocol.array()

  local ispIds = {}
  for ispId in pairs(state.isps) do ispIds[#ispIds + 1] = ispId end
  table.sort(ispIds)
  for _, ispId in ipairs(ispIds) do
    local isp = state.isps[ispId]
    local allocations = protocol.array()
    for index, allocation in ipairs(isp.provider_allocations) do
      rawset(allocations, index, protocol.object({
        first = allocation.first, last = allocation.last,
      }))
    end
    rawset(isps, #isps + 1, protocol.object({
      isp_id = ispId, display_name = isp.isp_name, provider_allocations = allocations,
    }))
  end

  local computers = protocol.array()
  local computerIds = {}
  for computerId in pairs(state.computers or {}) do computerIds[#computerIds + 1] = computerId end
  table.sort(computerIds)
  for _, computerId in ipairs(computerIds) do
    local computer = state.computers[computerId]
    rawset(computers, #computers + 1, protocol.object({
      computer_id = computer.computer_id,
      hostname = computer.hostname,
      address = computer.address,
      customer_network_id = computer.customer_network_id,
      router_id = computer.router_id,
      isp_id = computer.isp_id,
    }))
  end

  local networkIds = {}
  for networkId in pairs(state.routes) do networkIds[#networkIds + 1] = networkId end
  table.sort(networkIds)
  for _, networkId in ipairs(networkIds) do
    local route = state.routes[networkId]
    rawset(routers, #routers + 1, protocol.object({
      router_id = route.router_id,
      isp_id = route.isp_id,
      customer_network_id = route.customer_network_id,
      customer_network_name = route.customer_network_name,
      router_provider_address = route.router_provider_address,
    }))
    rawset(statuses, #statuses + 1, protocol.object({
      customer_network_id = networkId,
      status = state.network_status[networkId] or "enabled",
    }))
  end

  out:ok({
    topology = protocol.object({
      revision = state.revision,
      world = protocol.object({ world_id = state.world_id, central_id = state.central_id }),
      isps = isps,
      routers = routers,
      computers = computers,
      network_statuses = statuses,
    }),
  })
end

return handlers
