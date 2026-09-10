-- The value every state transition returns.
--
-- engine:handle(input, now) answers with three things: the state changes it
-- made, the effects the runtime must carry out, and the result for whoever
-- asked. Nothing here touches a peripheral, a file, a timer, or the network --
-- an effect is a description, and the runtime reports back what happened by
-- feeding the answer in as the next input.

local internal = ...
local protocol = internal("protocol")

local outcome = {}

local Builder = {}
Builder.__index = Builder

function outcome.new()
  return setmetatable({
    state_changes = {},
    effects = {},
    durableChanges = 0,
  }, Builder)
end

--------------------------------------------------------------------------
-- State changes
--------------------------------------------------------------------------

-- durable records a change to authoritative state. Every durable change bumps
-- the owner's revision, which is how a reconnecting child learns that its
-- cached configuration is stale.
function Builder:durable(kind, detail)
  self.state_changes[#self.state_changes + 1] = {
    kind = kind, durable = true, detail = detail or {},
  }
  self.durableChanges = self.durableChanges + 1
  return self
end

-- ephemeral records a change that must not survive a restart: a NAT Flow, a
-- correlation record, a diagnostic buffer entry.
function Builder:ephemeral(kind, detail)
  self.state_changes[#self.state_changes + 1] = {
    kind = kind, durable = false, detail = detail or {},
  }
  return self
end

--------------------------------------------------------------------------
-- Effects
--------------------------------------------------------------------------

local function effect(self, value)
  self.effects[#self.effects + 1] = value
  return self
end

-- send asks the runtime to put one message on an established relationship.
function Builder:send(relationshipId, messageKind, body, requestId)
  return effect(self, {
    kind = "send",
    relationship_id = relationshipId,
    message_kind = messageKind,
    body = body,
    request_id = requestId,
  })
end

-- reply answers a correlated request on the relationship it arrived on.
function Builder:reply(relationshipId, messageKind, body, requestId)
  return effect(self, {
    kind = "reply",
    relationship_id = relationshipId,
    message_kind = messageKind,
    body = body,
    request_id = requestId,
  })
end

-- replyError answers with a stable catalog error.
function Builder:replyError(relationshipId, requestId, code, message, details)
  return self:reply(relationshipId, "error",
    protocol.errors.new(code, message, details), requestId)
end

-- gateway asks the Central Server's runtime to carry a message over its one
-- Gateway Session. Only the Central role ever emits this.
function Builder:gateway(messageKind, body, correlation)
  correlation = correlation or {}
  return effect(self, {
    kind = "gateway",
    message_kind = messageKind,
    body = body,
    request_id = correlation.request_id,
    command_id = correlation.command_id,
  })
end

-- timer asks for a wake-up. The core never sleeps or polls; it says when it
-- next needs to be asked something.
function Builder:timer(name, atMs)
  return effect(self, { kind = "timer", name = name, at_ms = atMs })
end

-- screen asks for a terse status update on the local terminal.
function Builder:screen(fields)
  return effect(self, { kind = "screen", fields = fields })
end

-- deliver hands a request to the application running on this Computer. The core
-- has no idea what any service does; it only says that something must answer.
function Builder:deliver(fields)
  return effect(self, {
    kind = "deliver",
    pending_id = fields.pending_id,
    service = fields.service,
    payload = fields.payload,
    source = fields.source,
  })
end

-- event records one Traffic Event: both into the local rolling buffer and as an
-- effect, so the runtime can relay it upstream.
function Builder:event(value)
  self:ephemeral("event_recorded", { event_id = rawget(value, "event_id") })
  return effect(self, { kind = "event", event = value })
end

--------------------------------------------------------------------------
-- Results
--------------------------------------------------------------------------

function Builder:ok(fields)
  local result = { ok = true }
  for key, value in pairs(fields or {}) do result[key] = value end
  self.result = result
  return self
end

-- fail sets a stable catalog failure. It does not by itself send anything: a
-- caller decides whether the failure travels back to a peer as an error message
-- or stays local.
function Builder:fail(code, message, details)
  assert(protocol.errors.isKnown(code), "unknown error code '" .. tostring(code) .. "'")
  self.result = {
    ok = false,
    code = code,
    message = message or protocol.errors.meaning(code),
    retryable = protocol.errors.retryable(code),
    details = details,
  }
  return self
end

--------------------------------------------------------------------------
-- Sealing
--------------------------------------------------------------------------

-- build finalizes the outcome against the engine. A durable change bumps the
-- revision exactly once per transition and asks for one persist, so a single
-- input can never leave half its consequences on disk.
function Builder:build(engine)
  if self.durableChanges > 0 then
    engine.state.revision = (engine.state.revision or 0) + 1
    table.insert(self.effects, 1, { kind = "persist", revision = engine.state.revision })
  end
  return {
    state_changes = self.state_changes,
    effects = self.effects,
    result = self.result or { ok = true },
    revision = engine.state.revision,
  }
end

return outcome
