-- The role engine: one pure state transition per input.
--
--   engine:handle(input, now) -> { state_changes, effects, result, revision }
--
-- This is the seam the runtime and the tests both drive. The engine owns
-- authoritative state and decides what should happen; it never performs I/O, so
-- an effect is a description and the runtime reports back by feeding the answer
-- in as the next input.
--
-- Authority is not negotiable here. A peer's identity always comes from the
-- authenticated relationship an input arrived on, never from a field inside the
-- message, so a child cannot claim another child's Computer, network, address,
-- or allocation by writing a different value.

local internal = ...
local protocol = internal("protocol")
local outcome = internal("outcome")
local events = internal("events")
local flows = internal("flows")

local engine = {}

local ROLES = {
  computer = "role_computer",
  router = "role_router",
  isp = "role_isp",
  central = "role_central",
}

local Engine = {}
Engine.__index = Engine

-- new builds an engine from durable state. Ephemeral state -- links, flows,
-- correlation, and the diagnostic buffer -- is always rebuilt here, because
-- none of it survives a restart.
function engine.new(options)
  assert(type(options) == "table", "an engine needs options")
  local role = options.role
  assert(ROLES[role], "unknown CraftNet role '" .. tostring(role) .. "'")

  local state = options.state or {}
  state.role = role
  state.revision = state.revision or 0

  local instance = setmetatable({
    role = role,
    state = state,
    links = {},
    parentRelationshipId = nil,
    buffer = events.newBuffer(role),
    -- The bound belongs to the protocol: a role and a link must agree on how
    -- much one relationship may have outstanding, or one of them queues what
    -- the other already refused.
    flows = flows.newTable({
      prefix = options.flow_prefix or (role .. "-flow"),
      idle_ms = options.flow_idle_ms,
      capacity = options.in_flight or protocol.limits.RELATIONSHIP_IN_FLIGHT,
    }),
    transit = flows.newTable({
      prefix = options.transit_prefix or (role .. "-transit"),
      idle_ms = options.flow_idle_ms,
      capacity = options.in_flight or protocol.limits.RELATIONSHIP_IN_FLIGHT,
    }),
    nextRequestNumber = 1,
    nextEventNumber = 1,
  }, Engine)

  instance.handlers = internal(ROLES[role])
  return instance
end

--------------------------------------------------------------------------
-- Identity helpers
--------------------------------------------------------------------------

-- ownId is the identity this role registers its children under and stamps on
-- the Traffic Events it creates.
function Engine:ownId()
  local state = self.state
  return state.computer_id or state.router_id or state.isp_id or state.central_id
end

function Engine:worldId()
  return self.state.world_id
end

-- allocateRequestId draws the correlation identifier for one onward leg. Each
-- hop correlates on its own relationship, so a Request ID is never reused
-- across relationships and never trusted from a peer.
function Engine:allocateRequestId()
  local prefix = self:ownId() or self.role
  local identifier = prefix .. "-r" .. self.nextRequestNumber
  self.nextRequestNumber = self.nextRequestNumber + 1
  return identifier
end

function Engine:allocateEventId()
  local prefix = self:ownId() or self.role
  local identifier = prefix .. "-e" .. self.nextEventNumber
  self.nextEventNumber = self.nextEventNumber + 1
  return identifier
end

--------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------

-- peer returns the authenticated identity behind a relationship. Everything
-- that decides what a message may do starts here.
function Engine:peer(relationshipId)
  return self.links[relationshipId]
end

function Engine:parent()
  if not self.parentRelationshipId then return nil end
  return self.links[self.parentRelationshipId]
end

-- linkFor finds the relationship that reaches a known child identity.
function Engine:linkFor(peerId)
  for relationshipId, link in pairs(self.links) do
    if link.id == peerId then return relationshipId, link end
  end
  return nil
end

--------------------------------------------------------------------------
-- Traffic Events
--------------------------------------------------------------------------

-- record builds a Traffic Event, appends it to the bounded local buffer, and
-- attaches it to the outcome. Redaction lives in events.new, so a caller cannot
-- widen an event by passing extra fields.
function Engine:record(out, fields, now)
  fields.event_id = fields.event_id or self:allocateEventId()
  fields.observed_at_ms = fields.observed_at_ms or now
  fields.world_id = fields.world_id or self:worldId() or "world-unknown"

  local event, problem = events.new(fields)
  assert(event, problem)
  self.buffer:append(event)
  out:event(event)
  return event
end

-- measure approximates a message size for telemetry without ever inspecting or
-- retaining the payload itself.
function Engine:measure(body)
  local text = protocol.conformance.cj1.encode(body)
  return text and #text or 0
end

--------------------------------------------------------------------------
-- Dispatch
--------------------------------------------------------------------------

local function failure(instance, code, message)
  local out = outcome.new()
  out:fail(code, message)
  return out:build(instance)
end

-- handle runs exactly one transition. An unknown input is a protocol failure
-- rather than a crash, because the runtime may receive anything from the wire.
function Engine:handle(input, now)
  if type(input) ~= "table" or type(input.kind) ~= "string" then
    return failure(self, "invalid_message", "an input needs a kind")
  end
  if type(now) ~= "number" or now < 0 or now ~= math.floor(now) then
    return failure(self, "invalid_message", "now must be monotonic milliseconds")
  end

  local handler = self.handlers[input.kind]
  if not handler then
    return failure(self, "invalid_message",
      self.role .. " does not handle input '" .. input.kind .. "'")
  end

  local out = outcome.new()
  handler(self, input, now, out)
  return out:build(self)
end

--------------------------------------------------------------------------
-- Shared handlers
--------------------------------------------------------------------------

-- shared collects the transitions every role implements identically, so a role
-- module only spells out what is actually its own.
engine.shared = {}

-- link_up records an authenticated relationship. The protocol package has
-- already proved the peer's identity by the time this arrives.
function engine.shared.link_up(instance, input, now, out)
  assert(protocol.validate.identifier(input.relationship_id), "relationship_id must be an identifier")
  assert(protocol.validate.role(input.peer_role), "peer_role must be a CraftNet role")

  instance.links[input.relationship_id] = {
    relationship_id = input.relationship_id,
    role = input.peer_role,
    id = input.peer_id,
    direction = input.direction or "child",
    revision = input.peer_revision,
  }
  if input.direction == "parent" then
    instance.parentRelationshipId = input.relationship_id
  end
  out:ephemeral("link_up", { relationship_id = input.relationship_id, peer_id = input.peer_id })
  out:ok({ relationship_id = input.relationship_id })
end

-- link_down forgets a relationship and everything correlated through it.
-- In-flight work is never resumed across a link, so the flows are dropped.
function engine.shared.link_down(instance, input, now, out)
  local link = instance.links[input.relationship_id]
  if not link then
    return out:fail("invalid_message", "no such relationship")
  end
  instance.links[input.relationship_id] = nil
  if instance.parentRelationshipId == input.relationship_id then
    instance.parentRelationshipId = nil
  end
  out:ephemeral("link_down", { relationship_id = input.relationship_id })
  out:ok({ relationship_id = input.relationship_id })
end

-- tick expires idle flows and correlation records. A late reply then has
-- nothing to match and fails with nat_flow_missing rather than being guessed.
function engine.shared.tick(instance, input, now, out)
  local expired = {}
  for _, entry in ipairs(instance.flows:expire(now)) do
    expired[#expired + 1] = entry
    out:ephemeral("flow_expired", { flow_id = entry.flow_id })
  end
  for _, entry in ipairs(instance.transit:expire(now)) do
    out:ephemeral("transit_expired", { flow_id = entry.flow_id })
  end
  out:ok({ expired = #expired })
end

-- effect_result is how the runtime reports what happened when it carried out an
-- effect. Keeping this explicit is the point of the seam: an engine learns that
-- a send failed or a snapshot could not be written, instead of a runtime
-- silently swallowing the problem.
function engine.shared.effect_result(instance, input, now, out)
  if input.ok then
    if input.effect == "send" and input.relationship_id then
      local link = instance.links[input.relationship_id]
      if link then link.last_send_ms = now end
    end
    return out:ok({ effect = input.effect })
  end

  instance.lastFailure = {
    effect = input.effect,
    code = input.code or "internal_error",
    message = input.message,
    at_ms = now,
  }
  out:ephemeral("effect_failed", { effect = input.effect, code = instance.lastFailure.code })

  if input.effect == "send" and input.relationship_id then
    -- A message that could not leave means the relationship is not usable. The
    -- correlation it belonged to is dropped rather than retried: CraftNet never
    -- replays an ordinary request on its own.
    local flow = instance.flows:byCorrelation(input.relationship_id, input.request_id or "")
    if flow then
      instance.flows:close(flow.flow_id)
      out:ephemeral("flow_closed", { flow_id = flow.flow_id, reason = "send_failed" })
    end
    local record = instance.transit:byCorrelation(input.relationship_id, input.request_id or "")
    if record then
      instance.transit:close(record.flow_id)
      out:ephemeral("transit_closed", { flow_id = record.flow_id, reason = "send_failed" })
    end
  end
  out:fail(instance.lastFailure.code, input.message)
end

-- reconcile asks this role's parent whether the configuration it is holding is
-- still current. A child presents the last parent revision it accepted; the
-- parent answers with an acknowledgement or a full replacement.
function engine.shared.reconcile(instance, input, now, out)
  if not instance.parentRelationshipId then
    return out:fail("upstream_unavailable", "this role has no parent relationship")
  end
  local known = instance.state.parent_revision or 0
  local requestId = instance:allocateRequestId()
  local pending = instance.transit:open({
    relationship_id = instance.parentRelationshipId,
    request_id = requestId,
    intent = "reconcile",
  }, now)
  if not pending then
    return out:fail("busy", "this relationship already holds its outstanding requests")
  end
  out:send(instance.parentRelationshipId, "config_request",
    protocol.object({ known_revision = known }), requestId)
  out:ok({ known_revision = known, request_id = requestId })
end

-- message routes a validated protocol message to the role's handler for that
-- kind. The relationship it arrived on is what says who sent it.
function engine.shared.message(instance, input, now, out)
  local link = instance:peer(input.relationship_id)
  if not link then
    return out:fail("authentication_failed", "message arrived on an unknown relationship")
  end
  local message = input.message
  if type(message) ~= "table" or type(message.kind) ~= "string" then
    return out:fail("invalid_message", "a message input needs a message")
  end

  -- Any authenticated traffic proves the relationship is alive, which is what
  -- the runtime watches to decide Connectivity State.
  link.last_seen_ms = now

  local byKind = instance.handlers.messages or {}
  local handler = byKind[message.kind] or engine.shared.messages[message.kind]
  if not handler then
    return out:fail("invalid_message",
      instance.role .. " does not handle '" .. message.kind .. "'")
  end
  return handler(instance, link, message, now, out, input)
end

--------------------------------------------------------------------------
-- Shared messages
--------------------------------------------------------------------------

-- Reconciliation is identical at every parent-child boundary, so it lives here
-- once. Each owner wins for the state the authority model assigns to it;
-- CraftNet never attempts a field-level merge between a parent and a child.
engine.shared.messages = {}

function engine.shared.messages.heartbeat(instance, link, message, now, out)
  link.connectivity_state = rawget(message.body, "connectivity_state")
  link.revision = rawget(message.body, "revision")
  out:ephemeral("heartbeat_seen", {
    relationship_id = link.relationship_id, revision = link.revision,
  })
  out:ok({ relationship_id = link.relationship_id, revision = link.revision })
end

function engine.shared.messages.ack(instance, link, message, now, out)
  local record = instance.transit:byCorrelation(link.relationship_id, message.request_id)
  if record then instance.transit:close(record.flow_id) end
  out:ok({ acknowledged = rawget(message.body, "acked_request_id") })
end

-- config_request comes from a child that wants to know whether its cached
-- configuration is stale.
function engine.shared.messages.config_request(instance, link, message, now, out)
  if link.direction == "parent" then
    return out:fail("forbidden_operation", "a parent does not ask its child for configuration")
  end
  local build = instance.handlers.configurationFor
  if not build then
    return out:fail("invalid_message", instance.role .. " configures no children")
  end

  local configuration, code, problem = build(instance, link)
  if not configuration then
    out:replyError(link.relationship_id, message.request_id, code or "name_not_found", problem)
    return out:fail(code or "name_not_found", problem)
  end

  local known = rawget(message.body, "known_revision")
  if known == instance.state.revision then
    -- Nothing changed, so the child keeps what it has.
    out:reply(link.relationship_id, "ack", protocol.object({
      acked_request_id = message.request_id,
      result_revision = instance.state.revision,
    }), message.request_id)
    return out:ok({ current = true, revision = instance.state.revision })
  end

  out:reply(link.relationship_id, "config_snapshot", protocol.object({
    revision = instance.state.revision,
    role = link.role,
    configuration = configuration,
  }), message.request_id)
  out:ok({ current = false, revision = instance.state.revision })
end

-- config_snapshot is the parent's authoritative replacement. A child applies it
-- wholesale rather than merging: the parent owns these fields outright.
function engine.shared.messages.config_snapshot(instance, link, message, now, out)
  if link.direction ~= "parent" then
    return out:fail("forbidden_operation", "only a parent may replace configuration")
  end
  local apply = instance.handlers.applyConfiguration
  if not apply then
    return out:fail("invalid_message", instance.role .. " accepts no configuration")
  end
  local record = instance.transit:byCorrelation(link.relationship_id, message.request_id)
  if record then instance.transit:close(record.flow_id) end

  local body = message.body
  if rawget(body, "role") ~= instance.role then
    return out:fail("invalid_message", "that configuration is for another role")
  end

  local ok, code, problem = apply(instance, rawget(body, "configuration"), out)
  if not ok then return out:fail(code or "invalid_message", problem) end

  instance.state.parent_revision = rawget(body, "revision")
  out:durable("configuration_reconciled", { parent_revision = instance.state.parent_revision })
  out:ok({ parent_revision = instance.state.parent_revision })
end

engine.Engine = Engine

return engine
