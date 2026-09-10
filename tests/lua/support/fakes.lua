-- Fake adapters for driving a runtime without CraftOS.
--
-- These stand in for the four things the runtime is allowed to touch: a
-- filesystem, a clock, the links that carry messages, and a screen. Each one is
-- deliberately inspectable and controllable -- a test can corrupt a snapshot,
-- move time, fail a send, or drop a link -- because those are exactly the
-- situations a Computer meets when a world unloads or a modem goes quiet.

local fakes = {}

--------------------------------------------------------------------------
-- Storage
--------------------------------------------------------------------------

local Storage = {}
Storage.__index = Storage

function fakes.storage()
  return setmetatable({ files = {}, writes = 0, moves = 0 }, Storage)
end

function Storage:read(path)
  return self.files[path]
end

function Storage:write(path, contents)
  if self.failWrites then return nil, "the disk is full" end
  self.files[path] = contents
  self.writes = self.writes + 1
  return true
end

function Storage:move(from, to)
  if self.failMoves then return nil, "the file is locked" end
  if self.files[from] == nil then return nil, "source does not exist" end
  self.files[to] = self.files[from]
  self.files[from] = nil
  self.moves = self.moves + 1
  return true
end

function Storage:remove(path)
  self.files[path] = nil
  return true
end

function Storage:exists(path)
  return self.files[path] ~= nil
end

-- corrupt truncates a file the way a world unloading mid-write would.
function Storage:corrupt(path)
  local contents = self.files[path]
  assert(contents, "cannot corrupt " .. path .. ": it does not exist")
  self.files[path] = string.sub(contents, 1, math.max(1, math.floor(#contents / 2)))
  return self.files[path]
end

-- tamper edits a file so it stays well-formed but no longer matches its digest.
function Storage:tamper(path, from, to)
  local contents = assert(self.files[path], "cannot tamper with a missing file")
  self.files[path] = (string.gsub(contents, from, to, 1))
  return self.files[path]
end

function Storage:paths()
  local found = {}
  for path in pairs(self.files) do found[#found + 1] = path end
  table.sort(found)
  return found
end

--------------------------------------------------------------------------
-- Clock
--------------------------------------------------------------------------

local Clock = {}
Clock.__index = Clock

function fakes.clock(startMs)
  return setmetatable({ time = startMs or 0, timers = {} }, Clock)
end

function Clock:now()
  return self.time
end

function Clock:advance(milliseconds)
  self.time = self.time + milliseconds
  return self.time
end

function Clock:timer(name, atMs)
  self.timers[#self.timers + 1] = { name = name, at_ms = atMs }
  return #self.timers
end

--------------------------------------------------------------------------
-- Links
--------------------------------------------------------------------------

local Links = {}
Links.__index = Links

function fakes.links()
  return setmetatable({
    sent = {},
    inbox = {},
    connects = {},
    failing = {},
    connectFailure = nil,
  }, Links)
end

function Links:send(relationshipId, messageKind, body, requestId)
  if self.failing[relationshipId] then
    return nil, "the relationship is unreachable"
  end
  self.sent[#self.sent + 1] = {
    relationship_id = relationshipId,
    message_kind = messageKind,
    body = body,
    request_id = requestId,
  }
  return true
end

-- fail makes every send on a relationship report failure, the way a modem that
-- has gone quiet would.
function Links:fail(relationshipId, failing)
  self.failing[relationshipId] = failing ~= false
end

function Links:deliver(event)
  self.inbox[#self.inbox + 1] = event
  return self
end

function Links:poll()
  return table.remove(self.inbox, 1)
end

function Links:connect(relationshipId)
  self.connects[#self.connects + 1] = relationshipId
  if self.connectFailure then return nil, self.connectFailure end
  return true
end

-- sentOf returns everything sent on one relationship, in order.
function Links:sentOf(relationshipId)
  local found = {}
  for _, entry in ipairs(self.sent) do
    if entry.relationship_id == relationshipId then found[#found + 1] = entry end
  end
  return found
end

function Links:sentKinds()
  local kinds = {}
  for index, entry in ipairs(self.sent) do kinds[index] = entry.message_kind end
  return kinds
end

--------------------------------------------------------------------------
-- Screen
--------------------------------------------------------------------------

local Screen = {}
Screen.__index = Screen

function fakes.screen()
  return setmetatable({ renders = 0, last = nil }, Screen)
end

function Screen:render(lines)
  self.renders = self.renders + 1
  self.last = lines
  return true
end

function Screen:text()
  return table.concat(self.last or {}, "\n")
end

--------------------------------------------------------------------------
-- Gateway
--------------------------------------------------------------------------

local Gateway = {}
Gateway.__index = Gateway

function fakes.gateway()
  return setmetatable({ sent = {}, connected = true }, Gateway)
end

function Gateway:send(messageKind, body, correlation)
  if not self.connected then return nil, "the Gateway Session is not ready" end
  self.sent[#self.sent + 1] = {
    message_kind = messageKind, body = body, correlation = correlation,
  }
  return true
end

--------------------------------------------------------------------------
-- A whole set
--------------------------------------------------------------------------

-- set builds every adapter at once, which is what most tests want.
function fakes.set(options)
  options = options or {}
  return {
    storage = fakes.storage(),
    clock = fakes.clock(options.now),
    links = fakes.links(),
    screen = fakes.screen(),
    gateway = options.gateway and fakes.gateway() or nil,
  }
end

return fakes
