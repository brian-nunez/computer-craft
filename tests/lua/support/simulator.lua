-- A deterministic multi-role simulator built on engine:handle.
--
-- Every node is a real craftnet-core engine holding real authoritative state.
-- The simulator supplies only what the core deliberately does not do: a clock
-- that moves when a test says so, relationships between nodes, and a queue that
-- turns one engine's `send` effect into another engine's `message` input.
--
-- Nothing here is a mock of CraftNet behaviour. If a scenario passes, it passed
-- through the same state transitions the runtime will drive in Minecraft.

local simulator = {}

local Simulator = {}
Simulator.__index = Simulator

-- new builds an empty World. `seed` drives the optional loss and reordering
-- controls, so a failing run can always be reproduced exactly.
function simulator.new(options)
  assert(options and options.core, "the simulator needs the craftnet-core package")
  return setmetatable({
    core = options.core,
    now = options.now or 0,
    nodes = {},
    order = {},
    endpoints = {},
    queue = {},
    delivered = 0,
    dropped = 0,
    trace = {},
    events = {},
    services = {},
    lost = {},
  }, Simulator)
end

--------------------------------------------------------------------------
-- Topology
--------------------------------------------------------------------------

function Simulator:addNode(name, role, state)
  assert(not self.nodes[name], "node '" .. name .. "' already exists")
  local node = {
    name = name,
    role = role,
    engine = self.core.newEngine({ role = role, state = state or {} }),
    outbox = {},
    pending = {},
  }
  self.nodes[name] = node
  self.order[#self.order + 1] = name
  return node
end

function Simulator:node(name)
  local node = self.nodes[name]
  assert(node, "no node named '" .. tostring(name) .. "'")
  return node
end

function Simulator:engine(name)
  return self:node(name).engine
end

function Simulator:state(name)
  return self:node(name).engine.state
end

-- connect establishes one authenticated relationship. Both peers learn the same
-- relationship identifier, which is what the protocol package would have proved
-- during enrollment or a reconnect.
function Simulator:connect(parentName, childName, relationshipId)
  local parent = self:node(parentName)
  local child = self:node(childName)
  self.endpoints[relationshipId] = { [parentName] = childName, [childName] = parentName }

  self:apply(parent, {
    kind = "link_up",
    relationship_id = relationshipId,
    peer_role = child.role,
    peer_id = child.engine:ownId(),
    direction = "child",
  })
  self:apply(child, {
    kind = "link_up",
    relationship_id = relationshipId,
    peer_role = parent.role,
    peer_id = parent.engine:ownId(),
    direction = "parent",
  })
  return relationshipId
end

-- disconnect drops a relationship from both ends, the way a modem going quiet
-- eventually would.
function Simulator:disconnect(relationshipId)
  local pair = self.endpoints[relationshipId]
  assert(pair, "no such relationship")
  for name in pairs(pair) do
    self:apply(self:node(name), { kind = "link_down", relationship_id = relationshipId })
  end
  self.endpoints[relationshipId] = nil
end

--------------------------------------------------------------------------
-- Application services
--------------------------------------------------------------------------

-- serve registers what a Computer's application does with a delivered request.
-- The core never invents application behaviour, so a test says what answers.
function Simulator:serve(nodeName, service, handler)
  self.services[nodeName] = self.services[nodeName] or {}
  self.services[nodeName][service] = handler
end

-- lose makes the next delivery on a relationship vanish, which is how a late
-- reply and an abandoned flow get tested.
function Simulator:lose(relationshipId, count)
  self.lost[relationshipId] = (self.lost[relationshipId] or 0) + (count or 1)
end

--------------------------------------------------------------------------
-- Running
--------------------------------------------------------------------------

local function describe(node, input)
  if input.kind == "message" then
    return node.name .. " <- " .. input.message.kind
  end
  return node.name .. " <- " .. input.kind
end

-- apply runs one input and queues whatever its effects imply.
function Simulator:apply(node, input)
  local outcome = node.engine:handle(input, self.now)
  self.trace[#self.trace + 1] = {
    node = node.name,
    input = describe(node, input),
    result = outcome.result,
    effects = #outcome.effects,
  }

  for _, effect in ipairs(outcome.effects) do
    if effect.kind == "send" or effect.kind == "reply" then
      self:transmit(node, effect)
    elseif effect.kind == "event" then
      self.events[#self.events + 1] = { node = node.name, event = effect.event }
    elseif effect.kind == "deliver" then
      self:dispatchService(node, effect)
    end
    node.outbox[#node.outbox + 1] = effect
  end
  return outcome
end

function Simulator:transmit(node, effect)
  local pair = self.endpoints[effect.relationship_id]
  if not pair then
    self.dropped = self.dropped + 1
    return
  end
  local peerName = pair[node.name]
  if not peerName then
    self.dropped = self.dropped + 1
    return
  end
  if (self.lost[effect.relationship_id] or 0) > 0 then
    self.lost[effect.relationship_id] = self.lost[effect.relationship_id] - 1
    self.dropped = self.dropped + 1
    return
  end

  self.queue[#self.queue + 1] = {
    to = peerName,
    input = {
      kind = "message",
      relationship_id = effect.relationship_id,
      message = {
        kind = effect.message_kind,
        body = effect.body,
        request_id = effect.request_id,
      },
    },
  }
end

function Simulator:dispatchService(node, effect)
  local handlers = self.services[node.name] or {}
  local handler = handlers[effect.service]
  if not handler then
    -- No application is listening. The request simply goes unanswered, which is
    -- what a request_timeout looks like from the caller's side.
    return
  end
  local payload = handler(effect.payload, effect.source)
  self.queue[#self.queue + 1] = {
    to = node.name,
    input = { kind = "application_response", pending_id = effect.pending_id, payload = payload },
  }
end

-- input injects one operator or application action and settles the World.
function Simulator:input(nodeName, input)
  local outcome = self:apply(self:node(nodeName), input)
  self:drain()
  return outcome
end

-- step runs one input without settling, for tests that want to watch a single
-- transition.
function Simulator:step(nodeName, input)
  return self:apply(self:node(nodeName), input)
end

-- drain processes the queue until the World is quiet. The bound is a guard
-- against a routing loop, which should fail a test rather than hang it.
function Simulator:drain(limit)
  limit = limit or 10000
  local processed = 0
  while #self.queue > 0 do
    processed = processed + 1
    assert(processed <= limit, "the simulator did not settle; a message is looping")
    local entry = table.remove(self.queue, 1)
    self.delivered = self.delivered + 1
    self:apply(self:node(entry.to), entry.input)
  end
  return processed
end

-- advance moves the clock and ticks every node, which is what expires idle
-- flows and correlation records.
function Simulator:advance(milliseconds)
  self.now = self.now + milliseconds
  for _, name in ipairs(self.order) do
    self:apply(self.nodes[name], { kind = "tick" })
  end
  self:drain()
end

--------------------------------------------------------------------------
-- Inspection
--------------------------------------------------------------------------

-- eventsAt returns the Traffic Events one node recorded, newest last.
function Simulator:eventsAt(nodeName)
  local found = {}
  for _, entry in ipairs(self.events) do
    if entry.node == nodeName then found[#found + 1] = entry.event end
  end
  return found
end

-- outcomes returns every Traffic Event outcome seen anywhere, in order.
function Simulator:outcomes()
  local found = {}
  for _, entry in ipairs(self.events) do
    found[#found + 1] = rawget(entry.event, "outcome")
  end
  return found
end

function Simulator:sawOutcome(outcome, nodeName)
  for _, entry in ipairs(self.events) do
    if rawget(entry.event, "outcome") == outcome
      and (nodeName == nil or entry.node == nodeName) then
      return true, entry
    end
  end
  return false
end

-- resultsAt returns the results one node produced, optionally narrowed to a
-- single input description such as "service_response".
function Simulator:resultsAt(nodeName, inputDescription)
  local found = {}
  local wanted = inputDescription and (nodeName .. " <- " .. inputDescription)
  for _, entry in ipairs(self.trace) do
    if entry.node == nodeName and (wanted == nil or entry.input == wanted) then
      found[#found + 1] = entry.result
    end
  end
  return found
end

-- lastResultAt is the answer a node most recently produced for one input kind.
function Simulator:lastResultAt(nodeName, inputDescription)
  local found = self:resultsAt(nodeName, inputDescription)
  return found[#found]
end

-- path lists the nodes a Request took, in the order they handled it, which is
-- what scenario 6 asserts about the route through the Central Server.
function Simulator:path(messageKind)
  local visited = {}
  for _, entry in ipairs(self.trace) do
    if entry.input == entry.node .. " <- " .. messageKind then
      visited[#visited + 1] = entry.node
    end
  end
  return visited
end

function Simulator:reset()
  self.trace = {}
  self.events = {}
  for _, name in ipairs(self.order) do
    self.nodes[name].outbox = {}
  end
end

return simulator
