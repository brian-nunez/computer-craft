-- Customer Router authority.
--
-- A Customer Router owns its Customer Network: the RFC 1918 pool and its
-- Address Bindings, local DNS, which services are exposed to the rest of
-- CraftNet, and the NAT Flows that let a reply find its way home. It is the
-- only role that sees a Computer, and every Computer's traffic passes through
-- it, so it is also where "who is asking" stops being a claim and becomes a
-- fact derived from the authenticated session.

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

local function pool(state)
  return { first = ipv4.toNumber(state.pool_first), last = ipv4.toNumber(state.pool_last) }
end

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

-- configure applies the Customer Router wizard's answers. CraftNet v1 has no
-- subnet mask: every Computer sends through its router, so a pool is simply a
-- first and last address that must exclude the router's own.
function handlers.configure(engine, input, now, out)
  local settings = input.settings
  if type(settings) ~= "table" then
    return out:fail("invalid_message", "configure needs settings")
  end

  for _, field in ipairs({ "router_id", "customer_network_id", "customer_network_name" }) do
    if settings[field] == nil then
      return out:fail("invalid_message", field .. " is required")
    end
  end
  if not protocol.validate.identifier(settings.router_id)
    or not protocol.validate.identifier(settings.customer_network_id) then
    return out:fail("invalid_message", "identities must be CraftNet identifiers")
  end
  if not protocol.validate.normalizedName(settings.customer_network_name) then
    return out:fail("name_conflict", "a Customer Network name must be a normalized name")
  end
  for _, field in ipairs({ "router_address", "pool_first", "pool_last" }) do
    if not protocol.validate.customerAddress(settings[field]) then
      return out:fail("invalid_message", field .. " must be an RFC 1918 address")
    end
  end

  local range, problem = ipv4.range(settings.pool_first, settings.pool_last)
  if not range then return out:fail("invalid_message", problem) end
  local routerValue = ipv4.toNumber(settings.router_address)
  if ipv4.contains(range, routerValue) then
    return out:fail("address_conflict", "the pool must exclude the router's own address")
  end

  local state = engine.state
  state.router_id = settings.router_id
  state.customer_network_id = settings.customer_network_id
  state.customer_network_name = settings.customer_network_name
  state.router_address = settings.router_address
  state.dns_address = settings.dns_address or settings.router_address
  state.pool_first = settings.pool_first
  state.pool_last = settings.pool_last
  state.lan_operational_channel = settings.lan_operational_channel
  state.isp_id = settings.isp_id
  state.isp_name = settings.isp_name
  state.provider_address = settings.provider_address
  state.world_id = settings.world_id
  state.bindings = state.bindings or {}
  state.exposed = state.exposed or {}

  out:durable("configured", { customer_network_id = state.customer_network_id })
  out:ok({ customer_network_id = state.customer_network_id })
end

--------------------------------------------------------------------------
-- Address Bindings
--------------------------------------------------------------------------

local function takenAddresses(state)
  local taken = {}
  for _, binding in pairs(state.bindings) do taken[binding.address] = true end
  return taken
end

local function hostnameOwner(state, hostname)
  for computerId, binding in pairs(state.bindings) do
    if binding.hostname == hostname then return computerId end
  end
  return nil
end

-- bind_computer gives a joining Computer the lowest free address in the pool.
-- The binding is permanent: it survives restarts and a returning Computer gets
-- the same address back. The router never evicts one Computer to make room for
-- another, so an exhausted pool is an answer, not a reason to reuse.
function handlers.bind_computer(engine, input, now, out)
  local state = engine.state
  if not state.customer_network_id then
    return out:fail("internal_error", "the router is not configured yet")
  end
  if not protocol.validate.identifier(input.computer_id) then
    return out:fail("invalid_message", "computer_id must be a CraftNet identifier")
  end

  local hostname = input.hostname
  if hostname == nil then
    -- A Computer that chose no hostname gets a suggestion derived from its
    -- identity rather than a generated name it cannot predict.
    hostname = "computer-" .. input.computer_id
  end
  if not protocol.validate.normalizedName(hostname) then
    return out:fail("name_conflict", "'" .. tostring(hostname) .. "' is not a usable hostname")
  end

  local existing = state.bindings[input.computer_id]
  if existing then
    -- A returning Computer is not a new join. Its address is unchanged, and a
    -- rename is only accepted when the new hostname is free.
    if hostname ~= existing.hostname then
      local owner = hostnameOwner(state, hostname)
      if owner and owner ~= input.computer_id then
        return out:fail("name_conflict", "'" .. hostname .. "' is already taken on this network")
      end
      existing.hostname = hostname
      out:durable("binding_renamed", { computer_id = input.computer_id, hostname = hostname })
    end
    return out:ok({
      computer_id = input.computer_id, hostname = existing.hostname,
      address = existing.address, reused = true,
    })
  end

  local owner = hostnameOwner(state, hostname)
  if owner then
    return out:fail("name_conflict", "'" .. hostname .. "' is already taken on this network")
  end

  local address = ipv4.lowestFree(pool(state), takenAddresses(state))
  if not address then
    return out:fail("pool_exhausted", "every address in the pool is bound")
  end

  state.bindings[input.computer_id] = {
    computer_id = input.computer_id, hostname = hostname, address = address,
  }
  out:durable("binding_created", {
    computer_id = input.computer_id, hostname = hostname, address = address,
  })
  out:ok({ computer_id = input.computer_id, hostname = hostname, address = address, reused = false })
end

-- release_binding is the Operator's answer to an exhausted pool. Nothing else
-- ever removes a binding.
function handlers.release_binding(engine, input, now, out)
  local state = engine.state
  local binding = state.bindings[input.computer_id]
  if not binding then
    return out:fail("name_not_found", "no binding for that Computer")
  end
  state.bindings[input.computer_id] = nil
  state.exposed[input.computer_id] = nil
  out:durable("binding_released", { computer_id = input.computer_id, address = binding.address })
  out:ok({ computer_id = input.computer_id, address = binding.address })
end

-- expose_service is the only way a Computer becomes reachable from another
-- Customer Network. Everything not exposed is refused with inbound_denied.
function handlers.expose_service(engine, input, now, out)
  local state = engine.state
  if not state.bindings[input.computer_id] then
    return out:fail("name_not_found", "no binding for that Computer")
  end
  if not protocol.validate.operationName(input.service) then
    return out:fail("invalid_message", "a service name is 1 to 64 lowercase characters")
  end
  state.exposed[input.computer_id] = state.exposed[input.computer_id] or {}
  state.exposed[input.computer_id][input.service] = input.exposed ~= false
  out:durable("service_exposed", {
    computer_id = input.computer_id, service = input.service,
    exposed = state.exposed[input.computer_id][input.service],
  })
  out:ok({ computer_id = input.computer_id, service = input.service })
end

--------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------

-- configurationFor builds what this router assigns to one of its Computers.
-- The router owns every field of it outright.
function handlers.configurationFor(engine, link)
  local state = engine.state
  local binding = state.bindings[link.id]
  if not binding then
    return nil, "name_not_found", "that Computer has no binding on this network"
  end
  return protocol.object({
    computer_id = binding.computer_id,
    hostname = binding.hostname,
    address = binding.address,
    customer_network_id = state.customer_network_id,
    router_address = state.router_address,
    dns_address = state.dns_address,
  })
end

-- The fields an ISP owns on a Customer Router. Everything else in a router
-- configuration -- the LAN address, the pool, the LAN channel -- belongs to the
-- router itself, so a snapshot from upstream may not move it.
local PARENT_OWNED = {
  customer_network_id = true,
  customer_network_name = true,
  provider_address = true,
  isp_id = true,
}

-- applyConfiguration takes only what the ISP is authoritative for. A snapshot
-- that tries to rewrite this router's own pool is not merged and not obeyed;
-- each owner wins for the state the authority model assigns to it.
function handlers.applyConfiguration(engine, configuration, out)
  if not protocol.validate.identifier(rawget(configuration, "customer_network_id") or "") then
    return nil, "invalid_message", "a router configuration needs a Customer Network identity"
  end
  local state = engine.state
  local ignored = {}
  for field, value in pairs(configuration) do
    if PARENT_OWNED[field] then
      state[field] = value
    else
      ignored[#ignored + 1] = field
    end
  end
  table.sort(ignored)
  out:ephemeral("configuration_fields_ignored", { fields = ignored })
  return true
end

--------------------------------------------------------------------------
-- Local resolution
--------------------------------------------------------------------------

local function bindingByHostname(state, hostname)
  for _, binding in pairs(state.bindings) do
    if binding.hostname == hostname then return binding end
  end
  return nil
end

local function bindingByDestination(state, destination)
  local computerId = get(destination, "computer_id")
  if computerId then return state.bindings[computerId] end
  local address = get(destination, "address")
  if address then
    for _, binding in pairs(state.bindings) do
      if binding.address == address then return binding end
    end
  end
  return nil
end

local function scopeOf(state)
  return { customer_network_name = state.customer_network_name, isp_name = state.isp_name }
end

--------------------------------------------------------------------------
-- Traffic
--------------------------------------------------------------------------

local messages = {}
handlers.messages = messages

local function eventBase(engine, extra)
  local state = engine.state
  local fields = {
    isp_id = state.isp_id,
    customer_network_id = state.customer_network_id,
    router_id = state.router_id,
  }
  for key, value in pairs(extra or {}) do fields[key] = value end
  return fields
end

-- deliverLocally forwards a request to a Computer on this Customer Network. No
-- Provider Address and no NAT Flow are involved: the traffic never leaves.
local function deliverLocally(engine, out, now, options)
  local state = engine.state
  local target = options.target
  local targetRelationship = engine:linkFor(target.computer_id)
  if not targetRelationship then
    return false, "router_unavailable", "that Computer is not connected"
  end

  local onwardRequestId = engine:allocateRequestId()
  engine.transit:open({
    relationship_id = targetRelationship,
    request_id = onwardRequestId,
    reply_to_relationship_id = options.reply_to_relationship_id,
    reply_to_request_id = options.reply_to_request_id,
    delivery = options.delivery,
    peer_flow_id = options.peer_flow_id,
    flow_id = options.flow_id,
    computer_id = target.computer_id,
    service = options.service,
  }, now)
  out:ephemeral("transit_opened", { request_id = onwardRequestId })

  local body = protocol.object({
    source = options.source,
    destination = protocol.object({
      customer_network_id = state.customer_network_id,
      computer_id = target.computer_id,
    }),
    service = options.service,
    payload = options.payload,
  })
  out:send(targetRelationship, "service_request", body, onwardRequestId)
  return true
end

-- service_request arrives either from one of this router's Computers, on its
-- way out, or from the ISP, on its way in.
function messages.service_request(engine, link, message, now, out)
  local state = engine.state
  local body = message.body
  local destination = get(body, "destination")
  local service = get(body, "service")
  local payload = get(body, "payload")
  local bytes = engine:measure(body)

  if link.direction == "parent" then
    -- Inbound from the rest of CraftNet. The destination must be this network,
    -- and the service must be explicitly exposed.
    if get(destination, "customer_network_id") ~= state.customer_network_id then
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_request", operation = service,
        outcome = "route_not_found", bytes = bytes, request_id = message.request_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, "route_not_found",
        "that Customer Network is not served by this router")
      return out:fail("route_not_found", "destination is not this Customer Network")
    end

    local target = bindingByDestination(state, destination)
    if not target then
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_request", operation = service,
        outcome = "name_not_found", bytes = bytes, request_id = message.request_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, "name_not_found",
        "no Computer answers to that destination")
      return out:fail("name_not_found", "no binding for that destination")
    end

    local exposed = state.exposed[target.computer_id]
    if not (exposed and exposed[service]) then
      -- An unsolicited remote request to a service nobody published is refused
      -- before it ever reaches the Computer.
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_request", operation = service,
        outcome = "inbound_denied", bytes = bytes, request_id = message.request_id,
        computer_id = target.computer_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, "inbound_denied",
        "that service is not exposed")
      return out:fail("inbound_denied", "service is not exposed")
    end

    -- The far half of the pair. Its identifier travels back on the reply and is
    -- what makes the flow unambiguous despite overlapping addresses.
    local flow = engine.flows:open({
      relationship_id = link.relationship_id,
      request_id = message.request_id,
      peer_flow_id = get(body, "source_flow_id"),
      computer_id = target.computer_id,
      local_address = target.address,
      role = "destination",
    }, now)
    out:ephemeral("flow_opened", { flow_id = flow.flow_id, role = "destination" })

    local ok, code, problem = deliverLocally(engine, out, now, {
      target = target,
      source = get(body, "source"),
      service = service,
      payload = payload,
      reply_to_relationship_id = link.relationship_id,
      reply_to_request_id = message.request_id,
      delivery = "remote",
      peer_flow_id = get(body, "source_flow_id"),
      flow_id = flow.flow_id,
    })
    if not ok then
      engine.flows:close(flow.flow_id)
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_request", operation = service,
        outcome = code, bytes = bytes, request_id = message.request_id,
        computer_id = target.computer_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, code, problem)
      return out:fail(code, problem)
    end
    return out:ok({ delivery = "remote", flow_id = flow.flow_id })
  end

  -- Outbound from one of this router's own Computers.
  local binding = state.bindings[link.id]
  if link.role ~= "computer" or not binding then
    return out:fail("forbidden_operation", "only a bound Computer may send through this router")
  end

  -- The source is derived from the authenticated session, never taken from the
  -- message, so a Computer cannot pose as one of its neighbours.
  local source = protocol.object({
    computer_id = binding.computer_id,
    customer_network_id = state.customer_network_id,
    local_address = binding.address,
  })

  local destinationNetwork = get(destination, "customer_network_id")
  if destinationNetwork == state.customer_network_id then
    local target = bindingByDestination(state, destination)
    if not target then
      engine:record(out, eventBase(engine, {
        direction = "local", kind = "service_request", operation = service,
        outcome = "name_not_found", bytes = bytes, request_id = message.request_id,
        computer_id = binding.computer_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, "name_not_found",
        "no Computer answers to that destination")
      return out:fail("name_not_found", "no binding for that destination")
    end

    local ok, code, problem = deliverLocally(engine, out, now, {
      target = target,
      source = source,
      service = service,
      payload = payload,
      reply_to_relationship_id = link.relationship_id,
      reply_to_request_id = message.request_id,
      delivery = "local",
    })
    if not ok then
      engine:record(out, eventBase(engine, {
        direction = "local", kind = "service_request", operation = service,
        outcome = code, bytes = bytes, request_id = message.request_id,
        computer_id = binding.computer_id,
      }), now)
      out:replyError(link.relationship_id, message.request_id, code, problem)
      return out:fail(code, problem)
    end
    return out:ok({ delivery = "local" })
  end

  -- Remote. Everything leaves through the ISP, even for a Customer Network on
  -- the same ISP: the Central Server is the only interconnection point.
  if not engine.parentRelationshipId then
    engine:record(out, eventBase(engine, {
      direction = "outbound", kind = "service_request", operation = service,
      outcome = "upstream_unavailable", bytes = bytes, request_id = message.request_id,
      computer_id = binding.computer_id,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "upstream_unavailable",
      "this router has no connection to its ISP")
    return out:fail("upstream_unavailable", "no parent relationship")
  end

  local onwardRequestId = engine:allocateRequestId()
  local flow = engine.flows:open({
    relationship_id = engine.parentRelationshipId,
    request_id = onwardRequestId,
    reply_to_relationship_id = link.relationship_id,
    reply_to_request_id = message.request_id,
    computer_id = binding.computer_id,
    local_address = binding.address,
    destination_network = destinationNetwork,
    service = service,
    role = "source",
  }, now)
  out:ephemeral("flow_opened", { flow_id = flow.flow_id, role = "source" })

  out:send(engine.parentRelationshipId, "service_request", protocol.object({
    source = source,
    destination = destination,
    service = service,
    payload = payload,
    source_flow_id = flow.flow_id,
  }), onwardRequestId)
  out:ok({ delivery = "remote", flow_id = flow.flow_id })
end

-- service_response completes a request in either direction.
function messages.service_response(engine, link, message, now, out)
  local body = message.body
  local bytes = engine:measure(body)

  if link.direction == "parent" then
    -- The reply to something one of our Computers asked. The paired flow
    -- identifier, not the address, says which Computer that was.
    local sourceFlowId = get(body, "source_flow_id")
    local flow = sourceFlowId and engine.flows:byFlowId(sourceFlowId)
    if not flow or flow.role ~= "source" then
      engine:record(out, eventBase(engine, {
        direction = "inbound", kind = "service_response",
        outcome = "nat_flow_missing", bytes = bytes, request_id = message.request_id,
      }), now)
      return out:fail("nat_flow_missing", "no open flow matches that reply")
    end

    engine.flows:close(flow.flow_id)
    out:ephemeral("flow_closed", { flow_id = flow.flow_id })
    out:reply(flow.reply_to_relationship_id, "service_response", protocol.object({
      payload = get(body, "payload"),
    }), flow.reply_to_request_id)
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_response", operation = flow.service,
      outcome = "delivered_remote", bytes = bytes, computer_id = flow.computer_id,
      request_id = flow.reply_to_request_id,
    }), now)
    return out:ok({ delivery = "remote", computer_id = flow.computer_id })
  end

  -- A reply from one of our own Computers.
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "service_response",
      outcome = "nat_flow_missing", bytes = bytes, request_id = message.request_id,
    }), now)
    return out:fail("nat_flow_missing", "no correlation matches that reply")
  end
  engine.transit:close(record.flow_id)

  if record.delivery == "local" then
    out:reply(record.reply_to_relationship_id, "service_response", protocol.object({
      payload = get(body, "payload"),
    }), record.reply_to_request_id)
    engine:record(out, eventBase(engine, {
      direction = "local", kind = "service_response", operation = record.service,
      outcome = "delivered_local", bytes = bytes, computer_id = record.computer_id,
      request_id = record.reply_to_request_id,
    }), now)
    return out:ok({ delivery = "local" })
  end

  -- The reply to a remote request: both halves of the pair travel back so the
  -- source router can find its Computer.
  local replyBody = protocol.object({ payload = get(body, "payload") })
  if record.peer_flow_id then rawset(replyBody, "source_flow_id", record.peer_flow_id) end
  if record.flow_id then rawset(replyBody, "destination_flow_id", record.flow_id) end

  if record.flow_id then
    engine.flows:close(record.flow_id)
    out:ephemeral("flow_closed", { flow_id = record.flow_id })
  end
  out:reply(record.reply_to_relationship_id, "service_response", replyBody, record.reply_to_request_id)
  engine:record(out, eventBase(engine, {
    direction = "outbound", kind = "service_response", operation = record.service,
    outcome = "delivered_remote", bytes = bytes, computer_id = record.computer_id,
    request_id = record.reply_to_request_id,
  }), now)
  out:ok({ delivery = "remote" })
end

--------------------------------------------------------------------------
-- DNS
--------------------------------------------------------------------------

local function answerLocally(engine, out, link, message, parsed, now)
  local state = engine.state
  local binding = bindingByHostname(state, parsed.hostname)
  if not binding then
    engine:record(out, eventBase(engine, {
      direction = "local", kind = "dns_query", outcome = "name_not_found",
      bytes = 0, request_id = message.request_id,
    }), now)
    out:replyError(link.relationship_id, message.request_id, "name_not_found",
      "no Computer answers to that name")
    return out:fail("name_not_found", parsed.normalized .. " has no record")
  end
  out:reply(link.relationship_id, "dns_result", protocol.object({
    canonical_name = names.canonical(binding.hostname, state.customer_network_name, state.isp_name),
    customer_network_id = state.customer_network_id,
    computer_id = binding.computer_id,
    address = binding.address,
  }), message.request_id)
  return out:ok({ address = binding.address, computer_id = binding.computer_id })
end

-- dns_query is answered here when the name belongs to this Customer Network,
-- and delegated upward otherwise. Each role is authoritative only for the names
-- immediately beneath it.
function messages.dns_query(engine, link, message, now, out)
  local state = engine.state
  local parsed, code, problem = names.parse(get(message.body, "name"), scopeOf(state))
  if not parsed then
    out:replyError(link.relationship_id, message.request_id, code, problem)
    return out:fail(code, problem)
  end
  if parsed.kind == "external" then
    -- api.craft names the External Application, which is reached through an
    -- External Operation and its verified ancestry, never by address.
    out:replyError(link.relationship_id, message.request_id, "name_not_found",
      "api.craft is reached through an External Operation, not by address")
    return out:fail("name_not_found", "api.craft has no address")
  end

  if names.isLocal(parsed, scopeOf(state)) then
    return answerLocally(engine, out, link, message, parsed, now)
  end

  if link.direction == "parent" then
    -- A delegated lookup that does not belong here is a routing mistake
    -- upstream, not a name we should guess at.
    out:replyError(link.relationship_id, message.request_id, "name_not_found",
      "that name is not served by this Customer Network")
    return out:fail("name_not_found", "not this Customer Network")
  end

  if not engine.parentRelationshipId then
    out:replyError(link.relationship_id, message.request_id, "upstream_unavailable",
      "this router has no connection to its ISP")
    return out:fail("upstream_unavailable", "no parent relationship")
  end

  local onwardRequestId = engine:allocateRequestId()
  engine.transit:open({
    relationship_id = engine.parentRelationshipId,
    request_id = onwardRequestId,
    reply_to_relationship_id = link.relationship_id,
    reply_to_request_id = message.request_id,
    delivery = "dns",
  }, now)
  out:send(engine.parentRelationshipId, "dns_query",
    protocol.object({ name = parsed.normalized }), onwardRequestId)
  out:ok({ delegated = true })
end

-- dns_result relays an answer back down the path the question took.
function messages.dns_result(engine, link, message, now, out)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    return out:fail("nat_flow_missing", "no correlation matches that answer")
  end
  engine.transit:close(record.flow_id)
  out:reply(record.reply_to_relationship_id, "dns_result", message.body, record.reply_to_request_id)
  out:ok({ relayed = true })
end

-- error relays a failure back to whoever is still waiting for an answer.
function messages.error(engine, link, message, now, out)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if record then
    engine.transit:close(record.flow_id)
    out:reply(record.reply_to_relationship_id, "error", message.body, record.reply_to_request_id)
    return out:ok({ relayed = true })
  end

  local flow = engine.flows:byCorrelation(link.relationship_id, message.request_id)
  if flow then
    engine.flows:close(flow.flow_id)
    out:ephemeral("flow_closed", { flow_id = flow.flow_id })
    out:reply(flow.reply_to_relationship_id, "error", message.body, flow.reply_to_request_id)
    engine:record(out, eventBase(engine, {
      direction = "inbound", kind = "error", operation = flow.service,
      outcome = get(message.body, "code"), bytes = engine:measure(message.body),
      computer_id = flow.computer_id, request_id = flow.reply_to_request_id,
    }), now)
    return out:ok({ relayed = true })
  end
  out:fail("nat_flow_missing", "no correlation matches that failure")
end

return handlers
