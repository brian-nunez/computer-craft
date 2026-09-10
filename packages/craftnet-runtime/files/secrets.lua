-- Durable secrets, kept apart from durable state.
--
-- A snapshot never contains a secret value: configuration and topology carry a
-- reference like `gateway_credential_ref`, and the secret itself lives here.
-- Keeping them in separate files means the state snapshot can be read, relayed,
-- projected, and shown on a screen without anyone having to remember which
-- field was sensitive.
--
-- The same atomic write and one-backup rotation protects this file, because
-- losing a relationship credential means an Operator has to re-enroll a
-- Computer by hand.

local internal = ...
local protocol = internal("protocol")

local secrets = {}

local SCHEMA = 1
secrets.SCHEMA = SCHEMA

local Store = {}
Store.__index = Store

function secrets.new(options)
  assert(type(options) == "table", "a secret store needs options")
  local storage = options.storage
  assert(type(storage) == "table" and type(storage.read) == "function",
    "a secret store needs a storage adapter")
  assert(type(options.path) == "string" and options.path ~= "", "a secret store needs a path")

  local store = setmetatable({
    storage = storage,
    primary = options.path .. ".json",
    backup = options.path .. ".bak.json",
    temporary = options.path .. ".tmp.json",
    entries = {},
    loaded = false,
  }, Store)
  return store
end

local function digest(text)
  return protocol.conformance.sha256.hex(text)
end

function Store:encode()
  local held = protocol.object()
  local names = {}
  for name in pairs(self.entries) do names[#names + 1] = name end
  table.sort(names)
  for _, name in ipairs(names) do
    -- Values are stored as lowercase hexadecimal so that raw credential bytes
    -- never have to survive a JSON string round trip.
    rawset(held, name, protocol.conformance.sha256.toHex(self.entries[name]))
  end
  local body = protocol.conformance.cj1.encode(held)
  if not body then return nil, "secrets are not canonical" end
  return protocol.conformance.cj1.encode(protocol.object({
    schema = SCHEMA,
    wire_version = protocol.wireVersion,
    digest = digest(body),
    secrets = held,
  }))
end

function Store:decode(text)
  if type(text) ~= "string" or text == "" then return nil, "the secret store is empty" end
  local document, code, problem = protocol.conformance.cj1.decode(text)
  if not document then
    return nil, "the secret store is not canonical: " .. tostring(problem or code)
  end
  if rawget(document, "schema") ~= SCHEMA then
    return nil, "the secret store schema is " .. tostring(rawget(document, "schema"))
  end
  local held = rawget(document, "secrets")
  if held == nil then return nil, "the secret store holds nothing" end

  local body = protocol.conformance.cj1.encode(held)
  if not body or digest(body) ~= rawget(document, "digest") then
    return nil, "the secret store digest does not cover its contents"
  end

  local entries = {}
  for name, hexValue in pairs(held) do
    local ok, raw = pcall(protocol.conformance.sha256.fromHex, hexValue)
    if not ok then return nil, "secret '" .. name .. "' is not lowercase hexadecimal" end
    entries[name] = raw
  end
  return entries
end

-- load reads the store, preferring the primary and falling back to the backup.
-- A missing store is an empty one: a role that has enrolled nothing yet holds
-- no secrets, which is not a failure.
function Store:load()
  for _, attempt in ipairs({ self.primary, self.backup }) do
    local text = self.storage:read(attempt)
    if text then
      local entries, problem = self:decode(text)
      if entries then
        self.entries = entries
        self.loaded = true
        return true, attempt == self.primary and "primary" or "backup"
      end
      self.lastProblem = problem
    end
  end
  if self.storage:exists(self.primary) or self.storage:exists(self.backup) then
    return nil, "unreadable", self.lastProblem
  end
  self.entries = {}
  self.loaded = true
  return true, "fresh"
end

function Store:save()
  local text, problem = self:encode()
  if not text then return nil, problem end

  local ok, writeProblem = self.storage:write(self.temporary, text)
  if not ok then return nil, writeProblem or "cannot write the secret store" end

  if self.storage:exists(self.primary) then
    self.storage:remove(self.backup)
    local moved, moveProblem = self.storage:move(self.primary, self.backup)
    if not moved then return nil, moveProblem or "cannot rotate the secret store" end
  end
  local promoted, promoteProblem = self.storage:move(self.temporary, self.primary)
  if not promoted then return nil, promoteProblem or "cannot promote the secret store" end
  return true
end

--------------------------------------------------------------------------
-- Access
--------------------------------------------------------------------------

-- put stores one secret under a reference and commits immediately. The parent
-- of an enrollment invalidates its one-time token only after the durable
-- credential is committed, so this must not be deferred.
function Store:put(reference, value)
  assert(protocol.validate.identifier(reference), "a secret reference must be a CraftNet identifier")
  assert(type(value) == "string" and #value > 0, "a secret must be raw bytes")
  if not self.loaded then self:load() end
  self.entries[reference] = value
  return self:save()
end

function Store:get(reference)
  if not self.loaded then self:load() end
  return self.entries[reference]
end

function Store:has(reference)
  return self:get(reference) ~= nil
end

function Store:remove(reference)
  if not self.loaded then self:load() end
  if self.entries[reference] == nil then return true end
  self.entries[reference] = nil
  return self:save()
end

-- references lists what is held, never what it holds. This is what a screen or
-- a diagnostic may show.
function Store:references()
  if not self.loaded then self:load() end
  local names = {}
  for name in pairs(self.entries) do names[#names + 1] = name end
  table.sort(names)
  return names
end

function Store:count()
  return #self:references()
end

return secrets
