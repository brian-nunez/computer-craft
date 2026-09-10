-- Computer state.
--
-- A Computer owns very little: its identity, its chosen hostname, the
-- configuration its Customer Router handed it, and its own application state.
-- Its router remains authoritative for network membership and the address
-- binding, so nothing here ever decides what address it has -- it only
-- remembers what it was told and shows it while disconnected.

local internal = ...
local protocol = internal("protocol")
local engineModule = internal("engine")
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

--------------------------------------------------------------------------
-- Configuration
--------------------------------------------------------------------------

-- configure caches what the router acknowledged. The Computer keeps and
-- displays this while its router is unreachable, and it only ever reconnects to
-- the same router identity -- never to another network with the same name.
function handlers.configure(engine, input, now, out)
  local settings = input.settings
  if type(settings) ~= "table" then
    return out:fail("invalid_message", "configure needs settings")
  end
  if not protocol.validate.identifier(settings.computer_id) then
    return out:fail("invalid_message", "computer_id must be a CraftNet identifier")
  end
  if not protocol.validate.customerAddress(settings.address) then
    return out:fail("invalid_message", "address must be an RFC 1918 address")
  end

  local state = engine.state
  state.computer_id = settings.computer_id
  state.hostname = settings.hostname
  state.address = settings.address
  state.customer_network_id = settings.customer_network_id
  state.customer_network_name = settings.customer_network_name
  state.router_id = settings.router_id
  state.router_address = settings.router_address
  state.dns_address = settings.dns_address
  state.isp_id = settings.isp_id
  state.isp_name = settings.isp_name
  state.world_id = settings.world_id

  out:durable("configured", { computer_id = state.computer_id, address = state.address })
  out:ok({ computer_id = state.computer_id, address = state.address })
end

--------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------

-- applyConfiguration takes the router's authoritative record. The router owns
-- every field of a Computer's network configuration, so all of it is accepted.
function handlers.applyConfiguration(engine, configuration, out)
  local address = rawget(configuration, "address")
  if not protocol.validate.customerAddress(address or "") then
    return nil, "invalid_message", "a Computer configuration needs an RFC 1918 address"
  end
  local state = engine.state
  state.computer_id = rawget(configuration, "computer_id") or state.computer_id
  state.hostname = rawget(configuration, "hostname") or state.hostname
  state.address = address
  state.customer_network_id = rawget(configuration, "customer_network_id") or state.customer_network_id
  state.router_address = rawget(configuration, "router_address") or state.router_address
  state.dns_address = rawget(configuration, "dns_address") or state.dns_address
  out:ephemeral("configuration_applied", { address = state.address })
  return true
end

--------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------

-- resolve classifies a name before any message is sent. api.craft is answered
-- here without a lookup: the External Application is reached through an
-- External Operation and its verified ancestry, never by address, so there is
-- nothing for DNS to return.
function handlers.resolve(engine, input, now, out)
  local state = engine.state
  local scope = {
    customer_network_name = state.customer_network_name,
    isp_name = state.isp_name,
  }
  local parsed, code, problem = names.parse(input.name, scope)
  if not parsed then
    return out:fail(code, problem)
  end
  if parsed.kind == "external" then
    return out:ok({ kind = "external", canonical = parsed.canonical })
  end

  if not engine.parentRelationshipId then
    return out:fail("router_unavailable", "this Computer is not connected to its router")
  end

  local requestId = engine:allocateRequestId()
  local pending = engine.transit:open({
    relationship_id = engine.parentRelationshipId,
    request_id = requestId,
    intent = "resolve",
    name = parsed.normalized,
  }, now)
  if not pending then
    return out:fail("busy", "this Computer already holds its outstanding requests")
  end
  out:send(engine.parentRelationshipId, "dns_query",
    protocol.object({ name = parsed.normalized }), requestId)
  out:ok({ kind = "computer", pending = requestId, name = parsed.normalized })
end

--------------------------------------------------------------------------
-- Application traffic
--------------------------------------------------------------------------

-- local_request is an application on this Computer initiating a call. Every
-- request goes to the Customer Router, local or not: v1 has no subnet mask and
-- no direct Computer-to-Computer path.
function handlers.local_request(engine, input, now, out)
  local state = engine.state
  if not engine.parentRelationshipId then
    return out:fail("router_unavailable", "this Computer is not connected to its router")
  end
  if type(input.destination) ~= "table" then
    return out:fail("invalid_message", "a request needs a scoped destination")
  end
  if not protocol.validate.operationName(input.service) then
    return out:fail("invalid_message", "a service name is 1 to 64 lowercase characters")
  end

  local destination = protocol.object({
    customer_network_id = input.destination.customer_network_id,
  })
  if input.destination.computer_id then
    rawset(destination, "computer_id", input.destination.computer_id)
  elseif input.destination.address then
    rawset(destination, "address", input.destination.address)
  else
    return out:fail("invalid_message", "a destination needs a Computer or an address")
  end

  local requestId = engine:allocateRequestId()
  local outstanding = engine.transit:open({
    relationship_id = engine.parentRelationshipId,
    request_id = requestId,
    intent = "request",
    service = input.service,
  }, now)
  if not outstanding then
    return out:fail("busy", "this Computer already holds its outstanding requests")
  end

  -- The source is stated for completeness, but the router replaces it from the
  -- authenticated session rather than trusting what is written here.
  out:send(engine.parentRelationshipId, "service_request", protocol.object({
    source = protocol.object({
      computer_id = state.computer_id,
      customer_network_id = state.customer_network_id,
      local_address = state.address,
    }),
    destination = destination,
    service = input.service,
    payload = input.payload or protocol.object(),
  }), requestId)
  out:ok({ request_id = requestId })
end

-- application_response answers a request this Computer was asked to serve.
function handlers.application_response(engine, input, now, out)
  local record = engine.transit:byFlowId(input.pending_id)
  if not record then
    return out:fail("nat_flow_missing", "no pending request matches that answer")
  end
  engine.transit:close(record.flow_id)
  out:reply(record.reply_to_relationship_id, "service_response", protocol.object({
    payload = input.payload or protocol.object(),
  }), record.reply_to_request_id)
  out:ok({ answered = record.reply_to_request_id })
end

local messages = {}
handlers.messages = messages

-- service_request hands work to the application. The core has no idea what any
-- service does, so it records what must be answered and asks the runtime to
-- deliver the call.
function messages.service_request(engine, link, message, now, out)
  local body = message.body
  local pending = engine.transit:open({
    relationship_id = link.relationship_id,
    request_id = message.request_id,
    reply_to_relationship_id = link.relationship_id,
    reply_to_request_id = message.request_id,
    intent = "serve",
  }, now)
  if not pending then
    out:replyError(link.relationship_id, message.request_id, "busy",
      "this Computer already holds its outstanding requests")
    return out:fail("busy", "this Computer is at capacity")
  end
  out:ephemeral("request_pending", { pending_id = pending.flow_id })

  engine:record(out, {
    direction = "inbound", kind = "service_request",
    operation = get(body, "service"), outcome = "delivered_local",
    bytes = engine:measure(body), computer_id = engine.state.computer_id,
    customer_network_id = engine.state.customer_network_id,
    request_id = message.request_id,
  }, now)

  out:deliver({
    pending_id = pending.flow_id,
    service = get(body, "service"),
    payload = get(body, "payload"),
    source = get(body, "source"),
  })
  out:ok({ pending_id = pending.flow_id, service = get(body, "service") })
end

function messages.service_response(engine, link, message, now, out)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    return out:fail("nat_flow_missing", "no pending request matches that reply")
  end
  engine.transit:close(record.flow_id)
  engine:record(out, {
    direction = "inbound", kind = "service_response", operation = record.service,
    outcome = "delivered_local", bytes = engine:measure(message.body),
    computer_id = engine.state.computer_id,
    customer_network_id = engine.state.customer_network_id,
    request_id = message.request_id,
  }, now)
  out:ok({
    request_id = message.request_id,
    service = record.service,
    payload = get(message.body, "payload"),
  })
end

function messages.dns_result(engine, link, message, now, out)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if not record then
    return out:fail("nat_flow_missing", "no pending lookup matches that answer")
  end
  engine.transit:close(record.flow_id)
  out:ok({
    canonical_name = get(message.body, "canonical_name"),
    customer_network_id = get(message.body, "customer_network_id"),
    computer_id = get(message.body, "computer_id"),
    address = get(message.body, "address"),
  })
end

function messages.error(engine, link, message, now, out)
  local record = engine.transit:byCorrelation(link.relationship_id, message.request_id)
  if record then engine.transit:close(record.flow_id) end
  local code = get(message.body, "code")
  out:fail(protocol.errors.isKnown(code) and code or "internal_error",
    get(message.body, "message"))
end

return handlers
