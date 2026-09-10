-- Durable state on disk.
--
-- Every CraftOS role persists its authoritative state as a versioned snapshot,
-- written through a temporary file and a rename so that a world that unloads
-- mid-write never leaves a half-written file behind. One previous snapshot is
-- kept as a backup, and a corrupt primary falls back to it.
--
-- What is written is exactly the engine's durable state. Sessions, counters,
-- NAT Flows, pending requests, presence, and diagnostic buffers live on the
-- engine rather than in its state, so they cannot reach disk by accident --
-- and after a restart they are simply rebuilt.

local internal = ...
local protocol = internal("protocol")

local snapshot = {}

local SCHEMA = 1
snapshot.SCHEMA = SCHEMA

local Store = {}
Store.__index = Store

-- new binds a store to one role's snapshot path. `storage` is the injected
-- filesystem adapter; nothing here calls `fs` directly.
function snapshot.new(options)
  assert(type(options) == "table", "a snapshot store needs options")
  local storage = options.storage
  assert(type(storage) == "table" and type(storage.read) == "function"
    and type(storage.write) == "function" and type(storage.move) == "function",
    "a snapshot store needs a storage adapter with read, write, and move")
  assert(type(options.path) == "string" and options.path ~= "", "a snapshot needs a path")
  assert(protocol.validate.role(options.role), "a snapshot needs a CraftNet role")

  return setmetatable({
    storage = storage,
    role = options.role,
    primary = options.path .. ".json",
    backup = options.path .. ".bak.json",
    temporary = options.path .. ".tmp.json",
  }, Store)
end

--------------------------------------------------------------------------
-- Encoding
--------------------------------------------------------------------------

-- toWire converts a role's Lua state into a canonical document. Arrays are
-- tagged explicitly, because an empty table would otherwise come back as an
-- object and silently change shape across a restart.
local function toWire(value)
  if type(value) ~= "table" then return value end
  local isArray = #value > 0
  local hasStringKey = false
  for key in pairs(value) do
    if type(key) == "string" then hasStringKey = true end
  end
  if isArray and not hasStringKey then
    local list = protocol.array()
    for index = 1, #value do rawset(list, index, toWire(value[index])) end
    return list
  end
  local object = protocol.object()
  for key, entry in pairs(value) do
    rawset(object, tostring(key), toWire(entry))
  end
  return object
end

-- fromWire converts a decoded document back into plain Lua state, dropping the
-- canonical tags so the engine works with ordinary tables again.
local function fromWire(value)
  if type(value) ~= "table" then return value end
  if value == protocol.null then return nil end
  local result = {}
  for key, entry in pairs(value) do
    local converted = fromWire(entry)
    if converted ~= nil then result[key] = converted end
  end
  return result
end

snapshot.toWire = toWire
snapshot.fromWire = fromWire

local function digest(text)
  return protocol.conformance.sha256.hex(text)
end

-- encode wraps the state in its envelope and stamps a digest, which is what
-- makes a truncated or edited snapshot detectable rather than merely wrong.
function Store:encode(state, savedAtMs)
  local body, code, problem = protocol.conformance.cj1.encode(toWire(state))
  if not body then return nil, code, problem end
  return protocol.conformance.cj1.encode(protocol.object({
    schema = SCHEMA,
    wire_version = protocol.wireVersion,
    role = self.role,
    revision = state.revision or 0,
    saved_at_ms = savedAtMs or 0,
    digest = digest(body),
    state = toWire(state),
  }))
end

-- decode validates the envelope and the digest before returning any state.
function Store:decode(text)
  if type(text) ~= "string" or text == "" then
    return nil, "snapshot is empty"
  end
  local document, code, problem = protocol.conformance.cj1.decode(text)
  if not document then return nil, "snapshot is not canonical: " .. tostring(problem or code) end

  if rawget(document, "schema") ~= SCHEMA then
    return nil, "snapshot schema is " .. tostring(rawget(document, "schema"))
  end
  if rawget(document, "wire_version") ~= protocol.wireVersion then
    return nil, "snapshot wire version is " .. tostring(rawget(document, "wire_version"))
  end
  if rawget(document, "role") ~= self.role then
    return nil, "snapshot belongs to role " .. tostring(rawget(document, "role"))
  end

  local state = rawget(document, "state")
  if state == nil then return nil, "snapshot carries no state" end

  local body = protocol.conformance.cj1.encode(state)
  if not body then return nil, "snapshot state is not canonical" end
  if digest(body) ~= rawget(document, "digest") then
    return nil, "snapshot digest does not cover its state"
  end

  return fromWire(state), nil, {
    revision = rawget(document, "revision"),
    saved_at_ms = rawget(document, "saved_at_ms"),
  }
end

--------------------------------------------------------------------------
-- Saving and loading
--------------------------------------------------------------------------

-- save writes the snapshot atomically. The order matters: a temporary file is
-- fully written first, the previous primary becomes the backup, and only then
-- does the temporary take its place. At no point are both copies missing.
function Store:save(state, savedAtMs)
  local text, code, problem = self:encode(state, savedAtMs)
  if not text then return nil, code or "internal_error", problem end

  local ok, writeError = self.storage:write(self.temporary, text)
  if not ok then return nil, "internal_error", writeError or "cannot write the snapshot" end

  if self.storage:exists(self.primary) then
    self.storage:remove(self.backup)
    local moved, moveError = self.storage:move(self.primary, self.backup)
    if not moved then
      return nil, "internal_error", moveError or "cannot rotate the snapshot"
    end
  end

  local promoted, promoteError = self.storage:move(self.temporary, self.primary)
  if not promoted then
    return nil, "internal_error", promoteError or "cannot promote the snapshot"
  end
  return true
end

-- load prefers the primary and falls back to the backup when the primary is
-- missing or corrupt. Recovery when both copies are corrupt is outside v1: the
-- failure is reported rather than papered over with an empty state.
function Store:load()
  local attempts = {
    { source = "primary", path = self.primary },
    { source = "backup", path = self.backup },
  }
  local problems = {}
  for _, attempt in ipairs(attempts) do
    local text = self.storage:read(attempt.path)
    if text then
      local state, problem, meta = self:decode(text)
      if state then
        return state, attempt.source, meta
      end
      problems[#problems + 1] = attempt.source .. ": " .. problem
    else
      problems[#problems + 1] = attempt.source .. ": missing"
    end
  end
  return nil, "unreadable", table.concat(problems, "; ")
end

function Store:exists()
  return self.storage:exists(self.primary) or self.storage:exists(self.backup)
end

-- forget removes every copy. Only an Operator resetting a role should call it.
function Store:forget()
  self.storage:remove(self.temporary)
  self.storage:remove(self.primary)
  self.storage:remove(self.backup)
  return true
end

return snapshot
