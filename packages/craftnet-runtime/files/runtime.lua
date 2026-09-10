-- One configured role, running.
--
-- The runtime is the only place in CraftNet that performs I/O. It loads durable
-- state, feeds inputs to the engine, carries out the effects the engine asks
-- for, and reports each result back as the next input -- which is what keeps a
-- failed write or a failed send visible to the authority that cared about it,
-- instead of disappearing into an adapter.
--
-- Everything it touches arrives injected: clock, storage, links, screen, and
-- for the Central Server a gateway. That is what lets a whole World be driven
-- with fakes and still exercise the real state transitions.

local internal = ...
local protocol = internal("protocol")
local snapshot = internal("snapshot")
local secrets = internal("secrets")
local connectivity = internal("connectivity")
local screen = internal("screen")

local runtime = {}

local Runtime = {}
Runtime.__index = Runtime

local function requireAdapter(adapters, name, methods)
  local adapter = adapters[name]
  assert(type(adapter) == "table", "the runtime needs a '" .. name .. "' adapter")
  for _, method in ipairs(methods) do
    assert(type(adapter[method]) == "function",
      "the '" .. name .. "' adapter needs " .. method .. "()")
  end
  return adapter
end

-- new wires a role together. Nothing is read or written yet: start() does that,
-- so a caller can inspect a runtime before it touches the disk.
function runtime.new(core, options)
  assert(type(options) == "table", "a runtime needs options")
  assert(protocol.validate.role(options.role), "a runtime needs a CraftNet role")
  local adapters = options.adapters or {}

  local instance = setmetatable({
    core = core,
    role = options.role,
    adapters = {
      clock = requireAdapter(adapters, "clock", { "now" }),
      storage = requireAdapter(adapters, "storage", { "read", "write", "move", "remove", "exists" }),
      links = requireAdapter(adapters, "links", { "send", "poll" }),
      screen = adapters.screen,
      gateway = adapters.gateway,
    },
    store = snapshot.new({
      storage = requireAdapter(adapters, "storage", { "read" }),
      path = options.path or ("craftnet/" .. options.role),
      role = options.role,
    }),
    -- Secrets live in their own file. A state snapshot never contains a secret
    -- value, so it can be read, relayed, projected, and shown without anyone
    -- having to remember which field was sensitive.
    secretStore = secrets.new({
      storage = adapters.storage,
      path = (options.path or ("craftnet/" .. options.role)) .. ".secrets",
    }),
    monitor = connectivity.new(options.connectivity),
    application = options.application or {},
    telemetry = {},
    running = false,
    started = false,
    lastError = nil,
    snapshotSource = nil,
    persistCount = 0,
    screenLines = nil,
  }, Runtime)
  return instance
end

--------------------------------------------------------------------------
-- Starting
--------------------------------------------------------------------------

-- start loads durable state and builds the engine around it. Everything the
-- engine treats as ephemeral -- sessions, counters, NAT Flows, correlation,
-- diagnostic buffers -- is rebuilt empty, because none of it survived.
function Runtime:start()
  assert(not self.started, "this runtime has already started")
  local state, source, meta = self.store:load()
  if not state then
    if self.store:exists() then
      -- Both copies are unreadable. v1 does not invent a state to continue
      -- from; the Operator is told, and nothing is silently overwritten.
      self.lastError = { code = "internal_error", message = "snapshot is unreadable: " .. tostring(meta) }
      self.snapshotSource = "unreadable"
      return nil, "internal_error", meta
    end
    state = {}
    source = "fresh"
  end

  self.snapshotSource = source
  self.snapshotRevision = meta and meta.revision
  self.engine = self.core.newEngine({ role = self.role, state = state })
  self.started = true
  self:refreshScreen()
  return true, source
end

function Runtime:state()
  return self.engine and self.engine.state
end

-- secrets is the durable credential store. Configuration refers to a secret by
-- name; only this store ever holds the value.
function Runtime:secrets()
  return self.secretStore
end

function Runtime:revision()
  return self.engine and self.engine.state.revision or 0
end

--------------------------------------------------------------------------
-- Inputs and effects
--------------------------------------------------------------------------

local function now(self)
  return self.adapters.clock:now()
end

-- observeInput keeps Connectivity State in step with whatever the engine is
-- about to see. It lives on the submit path rather than on the poll path,
-- because a relationship is just as real when a wizard hands it over as when a
-- modem event brings it in.
function Runtime:observeInput(input, moment)
  local relationshipId = input.relationship_id
  if not relationshipId then return end
  if input.kind == "link_up" then
    self.monitor:track(relationshipId, moment, input.direction)
    self.monitor:observe(relationshipId, moment)
  elseif input.kind == "link_down" then
    self.monitor:lost(relationshipId, moment)
  elseif input.kind == "message" then
    -- Any authenticated message proves the relationship is alive.
    self.monitor:observe(relationshipId, moment)
  end
end

-- submit runs one input and carries out everything it implies, including any
-- follow-up inputs the effects produce.
function Runtime:submit(input)
  assert(self.started, "the runtime has not started")
  local moment = now(self)
  self:observeInput(input, moment)

  local outcome = self.engine:handle(input, moment)
  -- The error is recorded before the effects run, so the screen redrawn during
  -- execution already shows what just went wrong.
  if outcome.result and outcome.result.ok == false then
    self.lastError = { code = outcome.result.code, message = outcome.result.message }
  end
  self:execute(outcome)
  return outcome
end

-- execute performs the effects in order and feeds each result back in. The
-- feedback is deliberately a separate input rather than a return value: the
-- engine decides what a failure means, not the adapter that hit it.
function Runtime:execute(outcome)
  local followUps = {}
  for _, effect in ipairs(outcome.effects) do
    local followUp = self:perform(effect)
    if followUp then followUps[#followUps + 1] = followUp end
  end
  for _, followUp in ipairs(followUps) do
    self:submit(followUp)
  end
  self:refreshScreen()
end

function Runtime:perform(effect)
  local kind = effect.kind
  if kind == "persist" then
    return self:performPersist(effect)
  elseif kind == "send" or kind == "reply" then
    return self:performSend(effect)
  elseif kind == "event" then
    self.telemetry[#self.telemetry + 1] = effect.event
    return nil
  elseif kind == "deliver" then
    return self:performDeliver(effect)
  elseif kind == "gateway" then
    return self:performGateway(effect)
  elseif kind == "timer" then
    if self.adapters.clock.timer then
      self.adapters.clock:timer(effect.name, effect.at_ms)
    end
    return nil
  elseif kind == "screen" then
    self:refreshScreen(effect.fields)
    return nil
  end
  return nil
end

function Runtime:performPersist(effect)
  local ok, code, problem = self.store:save(self.engine.state, now(self))
  if ok then
    self.persistCount = self.persistCount + 1
    return { kind = "effect_result", effect = "persist", ok = true, revision = effect.revision }
  end
  return {
    kind = "effect_result", effect = "persist", ok = false,
    code = code, message = problem,
  }
end

function Runtime:performSend(effect)
  local ok, problem = self.adapters.links:send(
    effect.relationship_id, effect.message_kind, effect.body, effect.request_id)
  if ok then
    self.monitor:heartbeatSent(effect.relationship_id, now(self))
    return { kind = "effect_result", effect = "send", ok = true,
      relationship_id = effect.relationship_id, request_id = effect.request_id }
  end
  -- The message never left. The engine drops the correlation rather than
  -- retrying: CraftNet never replays an ordinary request on its own.
  self.monitor:lost(effect.relationship_id, now(self))
  return {
    kind = "effect_result", effect = "send", ok = false,
    relationship_id = effect.relationship_id, request_id = effect.request_id,
    code = "upstream_unavailable", message = problem or "the message could not be sent",
  }
end

-- performDeliver hands a request to this Computer's application. An
-- unimplemented service simply goes unanswered, which the caller sees as a
-- timeout rather than as a false success.
function Runtime:performDeliver(effect)
  local handler = self.application[effect.service]
  if not handler then return nil end
  local ok, payload = pcall(handler, effect.payload, effect.source)
  if not ok then
    self.lastError = { code = "internal_error", message = "the application failed" }
    return nil
  end
  return { kind = "application_response", pending_id = effect.pending_id, payload = payload }
end

function Runtime:performGateway(effect)
  local gateway = self.adapters.gateway
  if not gateway then
    return { kind = "effect_result", effect = "gateway", ok = false,
      code = "gateway_unavailable", message = "this role has no Gateway Session" }
  end
  local ok, problem = gateway:send(effect.message_kind, effect.body, {
    request_id = effect.request_id, command_id = effect.command_id,
  })
  if ok then
    return { kind = "effect_result", effect = "gateway", ok = true }
  end
  return { kind = "effect_result", effect = "gateway", ok = false,
    code = "gateway_unavailable", message = problem or "the Gateway Session is not ready" }
end

--------------------------------------------------------------------------
-- The event loop
--------------------------------------------------------------------------

-- pump waits for one event from the links adapter and turns it into inputs. A
-- CraftOS event never reaches the engine directly; the adapter has already
-- authenticated and validated whatever arrives.
function Runtime:pump(timeoutMs)
  assert(self.started, "the runtime has not started")
  local event = self.adapters.links:poll(timeoutMs)
  if not event then return nil end

  if event.kind == "revoked" then
    -- Revocation is terminal, so it is recorded before the link is released;
    -- nothing about the clock will clear it afterwards.
    self.monitor:revoke(event.relationship_id, now(self))
    return self:submit({ kind = "link_down", relationship_id = event.relationship_id })
  end
  return self:submit(event)
end

-- drain settles every lifecycle event the links adapter has queued. A wizard
-- calls it after establishing a relationship so the engine knows about it
-- before control returns, rather than on some later trip round the loop.
function Runtime:drain()
  local links = self.adapters.links
  if type(links.pending) ~= "function" then return 0 end
  local processed = 0
  while links:pending() > 0 do
    self:pump(0)
    processed = processed + 1
    assert(processed < 1000, "the links adapter kept queueing events")
  end
  return processed
end

-- tick advances time: expiring idle flows, re-judging Connectivity State,
-- sending due heartbeats, and retrying a disconnected parent under backoff.
function Runtime:tick()
  assert(self.started, "the runtime has not started")
  local moment = now(self)
  local outcome = self:submit({ kind = "tick" })

  local changed = self.monitor:evaluateAll(moment)
  for _, change in ipairs(changed) do
    if change.to == "disconnected" then
      -- The relationship went quiet past the threshold. In-flight work on it is
      -- abandoned rather than resumed.
      self:submit({ kind = "link_down", relationship_id = change.relationship_id })
    end
  end

  for _, relationshipId in ipairs(self.monitor:dueForHeartbeat(moment)) do
    if self.engine.links[relationshipId] then
      self:sendHeartbeat(relationshipId, moment)
    end
  end

  self:reconnectDue(moment)
  self:refreshScreen()
  return outcome, changed
end

-- sendHeartbeat states this role's own liveness and revision, which is what
-- lets a peer reconcile without a full exchange.
function Runtime:sendHeartbeat(relationshipId, moment)
  local body = protocol.object({
    connectivity_state = self.monitor:stateOf(relationshipId),
    revision = self.engine.state.revision or 0,
  })
  local ok = self.adapters.links:send(relationshipId, "heartbeat", body, nil)
  if ok then
    self.monitor:heartbeatSent(relationshipId, moment)
  else
    self.monitor:lost(relationshipId, moment)
  end
  return ok
end

-- reconnectDue asks the links adapter to establish a fresh session for any
-- parent relationship whose backoff has elapsed. Only the upstream side is
-- retried: a child reconnects to its own parent, so this role waits to be found
-- rather than chasing every Computer that went quiet. A new session is always
-- created; an old one is never resumed.
function Runtime:reconnectDue(moment)
  if type(self.adapters.links.connect) ~= "function" then return 0 end
  local attempts = 0
  for _, relationshipId in ipairs(self.monitor:dueForReconnect(moment)) do
    local entry = self.monitor:get(relationshipId)
    if entry and entry.direction == "parent" then
      attempts = attempts + 1
      self.monitor:attempted(relationshipId, moment)
      local ok, problem = self.adapters.links:connect(relationshipId)
      if not ok then
        self.lastError = { code = "upstream_unavailable", message = problem or "reconnect failed" }
      end
    end
  end
  return attempts
end

-- run is the loop a startup program enters. It waits only as long as the next
-- deadline, so an idle role costs nothing.
function Runtime:run(options)
  options = options or {}
  self.running = true
  local iterations = 0
  while self.running do
    iterations = iterations + 1
    if options.max_iterations and iterations > options.max_iterations then break end

    local moment = now(self)
    local wake = self.monitor:nextWakeMs(moment)
    local timeout = options.idle_timeout_ms or 1000
    if wake then timeout = math.max(0, math.min(timeout, wake - moment)) end

    if not self:pump(timeout) then
      self:tick()
    end
  end
  return iterations
end

function Runtime:stop()
  self.running = false
end

--------------------------------------------------------------------------
-- Telemetry and screen
--------------------------------------------------------------------------

-- drainTelemetry hands over the Traffic Events recorded since the last drain.
-- The engine's own rolling buffer stays bounded regardless; this is what a
-- Gateway or a parent relationship relays upstream from Milestone 6 onward.
function Runtime:drainTelemetry()
  local drained = self.telemetry
  self.telemetry = {}
  return drained
end

function Runtime:bufferedEvents()
  return self.engine and self.engine.buffer:count() or 0
end

function Runtime:connectivityState(relationshipId)
  if relationshipId then return self.monitor:stateOf(relationshipId) end
  if self.engine and self.engine.parentRelationshipId then
    return self.monitor:stateOf(self.engine.parentRelationshipId)
  end
  return "connecting"
end

function Runtime:refreshScreen(extra)
  if not self.started then return nil end
  local status = {
    connectivity_state = self:connectivityState(),
    error = self.lastError,
  }
  for key, value in pairs(extra or {}) do status[key] = value end
  self.screenLines = screen.lines(self.role, self.engine.state, status)
  if self.adapters.screen and self.adapters.screen.render then
    self.adapters.screen:render(self.screenLines)
  end
  return self.screenLines
end

function Runtime:lines()
  return self.screenLines
end

runtime.Runtime = Runtime

return runtime
