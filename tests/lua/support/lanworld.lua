-- A cooperative fake LAN.
--
-- Enrollment is a conversation: the Computer cannot finish its join until the
-- router answers, and the router cannot answer until it is asked. CC:Tweaked
-- solves this with coroutines, and so does this -- each node runs in one, a
-- transport yields when it has nothing to receive, and a small scheduler
-- resumes whoever can make progress.
--
-- Nothing here stands in for CraftNet. The real links adapter, the real
-- protocol package, and the real engines run on top of it; only the modem is
-- imaginary.

local lanworld = {}

local World = {}
World.__index = World

local Transport = {}
Transport.__index = Transport

-- new builds an empty LAN. `clock` is a fake clock the scheduler advances only
-- when nothing else can happen, so a timeout fires exactly when the World has
-- genuinely gone quiet rather than after real seconds.
function lanworld.new(options)
  assert(options and options.clock, "a LAN world needs a clock")
  return setmetatable({
    clock = options.clock,
    stepMs = options.step_ms or 100,
    nodes = {},
    order = {},
    deliveries = 0,
    transmissions = 0,
  }, World)
end

--------------------------------------------------------------------------
-- Transports
--------------------------------------------------------------------------

-- attach returns a transport for one node. Every transport shares the same air:
-- a transmission reaches every other node listening on that channel, which is
-- what a modem actually does.
function World:attach(name)
  local transport = setmetatable({
    world = self,
    name = name,
    inbox = {},
    openChannels = {},
  }, Transport)
  self.nodes[name] = self.nodes[name] or { name = name }
  self.nodes[name].transport = transport
  return transport
end

function Transport:open(channel)
  self.openChannels[channel] = true
  return true
end

function Transport:close(channel)
  self.openChannels[channel] = nil
  return true
end

function Transport:transmit(channel, replyChannel, text)
  local world = self.world
  world.transmissions = world.transmissions + 1
  if world.jam then return true end
  for name, node in pairs(world.nodes) do
    local peer = node.transport
    if peer and peer ~= self and peer.openChannels[channel] then
      peer.inbox[#peer.inbox + 1] = {
        channel = channel, reply_channel = replyChannel, text = text,
      }
      world.deliveries = world.deliveries + 1
    end
  end
  return true
end

-- receive hands over the next frame, or yields until one arrives or the
-- deadline passes. Yielding is what lets the peer run.
function Transport:receive(timeoutMs)
  local deadline = self.world.clock:now() + (timeoutMs or 0)
  while true do
    local entry = table.remove(self.inbox, 1)
    if entry then
      return entry.channel, entry.reply_channel, entry.text
    end
    if self.world.clock:now() >= deadline then return nil end
    coroutine.yield()
  end
end

function Transport:pending()
  return #self.inbox
end

--------------------------------------------------------------------------
-- Scheduling
--------------------------------------------------------------------------

-- spawn adds a node's program. It runs until it returns or the World stops.
function World:spawn(name, body)
  local node = self.nodes[name] or { name = name }
  self.nodes[name] = node
  node.thread = coroutine.create(body)
  node.done = false
  self.order[#self.order + 1] = name
  return node
end

-- run resumes every node in turn until they have all finished or the World has
-- gone quiet for long enough that every timeout has fired. The bound is a guard
-- against a program that never yields, which should fail a test rather than
-- hang it.
function World:run(options)
  options = options or {}
  local limit = options.max_rounds or 2000
  local rounds = 0

  while rounds < limit do
    rounds = rounds + 1
    local before = self.deliveries
    local alive = 0

    for _, name in ipairs(self.order) do
      local node = self.nodes[name]
      if node.thread and coroutine.status(node.thread) == "suspended" then
        alive = alive + 1
        local ok, problem = coroutine.resume(node.thread)
        if not ok then
          error("node '" .. name .. "' failed: " .. tostring(problem), 0)
        end
        if coroutine.status(node.thread) == "dead" then
          node.done = true
        end
      end
    end

    if alive == 0 then return rounds end
    if self.deliveries == before then
      -- Nobody moved. Advance time so that whatever is waiting can give up.
      self.clock:advance(self.stepMs)
    end
  end
  error("the LAN world did not settle after " .. limit .. " rounds", 0)
end

-- stop marks a node finished, for a server loop that would otherwise run
-- forever.
function World:finish(name)
  local node = self.nodes[name]
  if node then node.done = true end
end

function World:isDone(name)
  local node = self.nodes[name]
  return node and node.done or false
end

-- jamAir drops every transmission, which is how a test makes a join time out.
function World:jamAir(jam)
  self.jam = jam ~= false
end

return lanworld
