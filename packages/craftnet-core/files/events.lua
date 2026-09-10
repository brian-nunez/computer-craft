-- Traffic Events and the rolling diagnostic buffers that hold them.
--
-- A Traffic Event is metadata about an attempted communication: who, where,
-- what kind, how big, and how it ended. It never carries a payload body, a
-- credential, a proof, a MAC, or an Access Token. Redaction happens here, at
-- creation, rather than being cleaned up later by whatever reads the event --
-- a field that is never constructed cannot leak.

local internal = ...
local protocol = internal("protocol")

local events = {}

-- Buffers are unsampled and bounded. Infrastructure keeps only enough history
-- to diagnose what just happened; the External Application keeps the long tail.
events.CAPACITY = {
  router = 100,
  isp = 500,
  central = 2000,
  computer = 100,
}

-- The complete set of fields a Traffic Event may carry. Anything absent from
-- this table cannot reach an event, which is what keeps payloads and secrets
-- out by construction rather than by review.
local ALLOWED = {
  event_id = "identifier",
  observed_at_ms = "milliseconds",
  request_id = "identifier",
  command_id = "identifier",
  world_id = "identifier",
  isp_id = "identifier",
  customer_network_id = "identifier",
  router_id = "identifier",
  computer_id = "identifier",
  direction = "direction",
  kind = "operationName",
  operation = "operationName",
  outcome = "operationName",
  bytes = "milliseconds",
}

local REQUIRED = {
  "event_id", "observed_at_ms", "world_id", "direction", "kind", "outcome", "bytes",
}

local DIRECTIONS = { inbound = true, outbound = true, ["local"] = true }

-- Outcomes are either a successful delivery shape or a stable error code, so a
-- dashboard can group failures without a second vocabulary.
events.OUTCOMES = {
  delivered_local = true,
  delivered_remote = true,
  delivered_external = true,
}

function events.isOutcome(value)
  return events.OUTCOMES[value] == true or protocol.errors.isKnown(value)
end

local function check(field, value)
  local rule = ALLOWED[field]
  if rule == "direction" then return DIRECTIONS[value] == true end
  if rule == "milliseconds" then
    return type(value) == "number" and value == math.floor(value) and value >= 0
  end
  return protocol.validate[rule](value)
end

-- new builds one Traffic Event. It refuses an unknown field rather than
-- dropping it, because a caller that tries to attach a payload should find out
-- immediately instead of shipping an event that quietly lost information.
function events.new(fields)
  local event = protocol.object()
  for field, value in pairs(fields) do
    if ALLOWED[field] == nil then
      return nil, "a Traffic Event may not carry '" .. tostring(field) .. "'"
    end
    if value ~= nil then
      if not check(field, value) then
        return nil, "Traffic Event field '" .. field .. "' is not valid"
      end
      rawset(event, field, value)
    end
  end
  for index = 1, #REQUIRED do
    if rawget(event, REQUIRED[index]) == nil then
      return nil, "a Traffic Event requires '" .. REQUIRED[index] .. "'"
    end
  end
  if not events.isOutcome(rawget(event, "outcome")) then
    return nil, "'" .. tostring(rawget(event, "outcome")) .. "' is not a known outcome"
  end
  return event
end

--------------------------------------------------------------------------
-- Rolling buffers
--------------------------------------------------------------------------

local Buffer = {}
Buffer.__index = Buffer

function events.newBuffer(role)
  local capacity = events.CAPACITY[role]
  assert(capacity, "no buffer capacity is defined for role '" .. tostring(role) .. "'")
  return setmetatable({ capacity = capacity, entries = {}, dropped = 0 }, Buffer)
end

-- append keeps the newest events and counts what it discarded, so a busy period
-- shows up as a visible gap rather than as silence.
function Buffer:append(event)
  self.entries[#self.entries + 1] = event
  while #self.entries > self.capacity do
    table.remove(self.entries, 1)
    self.dropped = self.dropped + 1
  end
  return event
end

function Buffer:count()
  return #self.entries
end

function Buffer:latest(limit)
  local total = #self.entries
  local wanted = math.min(limit or total, total)
  local slice = {}
  for index = total - wanted + 1, total do
    slice[#slice + 1] = self.entries[index]
  end
  return slice
end

-- drain removes and returns everything buffered, which is what the Central
-- Server does when its Gateway Session comes back.
function Buffer:drain()
  local entries = self.entries
  self.entries = {}
  return entries
end

return events
