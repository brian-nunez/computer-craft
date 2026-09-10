-- NAT Flows and transit correlation.
--
-- CraftNet has no ports and no connections. A remote request creates a paired,
-- ephemeral flow: the source Customer Router remembers which of its Computers
-- asked, and the destination Customer Router remembers where to send the reply.
-- The pair is what makes overlapping RFC 1918 addresses unambiguous -- both
-- Home and Farm may hold 192.168.1.20, and the flow identifier, not the
-- address, says which one a reply belongs to.
--
-- Intermediate hops keep the same shape of record for request correlation, so a
-- reply retraces the exact path the request took rather than being re-routed.

local flows = {}

-- A flow with no traffic for this long is forgotten. A late reply then fails
-- with nat_flow_missing rather than being guessed at.
flows.IDLE_MS = 30000

-- How many correlated requests one immediate relationship may have outstanding
-- at once. Past it, work is refused with `busy` rather than queued: a queue
-- without a bound is only a slower way of failing, and it fails later, larger,
-- and somewhere less obvious. The number itself belongs to the protocol; this
-- is the fallback for a table built without one.
flows.PER_RELATIONSHIP = 64

local Table = {}
Table.__index = Table

function flows.newTable(options)
  options = options or {}
  return setmetatable({
    prefix = options.prefix or "flow",
    idleMs = options.idle_ms or flows.IDLE_MS,
    capacity = options.capacity or flows.PER_RELATIONSHIP,
    nextNumber = options.first_number or 1,
    byId = {},
    byRequest = {},
    outstanding = {},
    count = 0,
  }, Table)
end

function Table:allocateId()
  local identifier = self.prefix .. "-" .. self.nextNumber
  self.nextNumber = self.nextNumber + 1
  return identifier
end

-- correlationKey scopes a Request ID to the relationship it arrived on. Two
-- children may legitimately choose the same Request ID, so a bare one is never
-- a key.
local function correlationKey(relationshipId, requestId)
  return relationshipId .. "\0" .. requestId
end

-- outstandingOn reports how much of one relationship's capacity is in use.
function Table:outstandingOn(relationshipId)
  return self.outstanding[relationshipId] or 0
end

-- open records a new flow. `record` carries whatever the owning role needs to
-- send a reply back: for a source router that is the Computer and its address;
-- for a forwarding hop it is the relationship the request arrived on.
--
-- It answers nil when the relationship already holds its capacity, and the
-- caller turns that into `busy`. Refusing here rather than at the wire is
-- deliberate: this is where the memory would actually accumulate.
function Table:open(record, now)
  assert(type(record) == "table", "a flow needs a record")
  assert(record.relationship_id, "a flow needs the relationship it arrived on")
  assert(record.request_id, "a flow needs a Request ID")

  local held = self.outstanding[record.relationship_id] or 0
  if held >= self.capacity then return nil end

  local identifier = record.flow_id or self:allocateId()
  local entry = {}
  for key, value in pairs(record) do entry[key] = value end
  entry.flow_id = identifier
  entry.opened_at_ms = now
  entry.touched_at_ms = now

  self.byId[identifier] = entry
  self.byRequest[correlationKey(record.relationship_id, record.request_id)] = entry
  self.outstanding[record.relationship_id] = held + 1
  self.count = self.count + 1
  return entry
end

-- release gives one relationship's capacity back. Every removal goes through
-- it, so the count can never drift away from what is actually held.
local function release(self, entry)
  local held = (self.outstanding[entry.relationship_id] or 1) - 1
  if held <= 0 then
    self.outstanding[entry.relationship_id] = nil
  else
    self.outstanding[entry.relationship_id] = held
  end
  self.count = self.count - 1
end

function Table:byFlowId(identifier)
  return self.byId[identifier]
end

function Table:byCorrelation(relationshipId, requestId)
  return self.byRequest[correlationKey(relationshipId, requestId)]
end

-- pair records the far half of a flow, which is what lets a reply carry both
-- references and be matched without trusting any address.
function Table:pair(identifier, peerFlowId, now)
  local entry = self.byId[identifier]
  if not entry then return nil end
  entry.peer_flow_id = peerFlowId
  entry.touched_at_ms = now
  return entry
end

function Table:touch(identifier, now)
  local entry = self.byId[identifier]
  if entry then entry.touched_at_ms = now end
  return entry
end

function Table:close(identifier)
  local entry = self.byId[identifier]
  if not entry then return nil end
  self.byId[identifier] = nil
  self.byRequest[correlationKey(entry.relationship_id, entry.request_id)] = nil
  release(self, entry)
  return entry
end

-- expire removes every flow idle past the limit and returns them, so the caller
-- can emit one Traffic Event per abandoned request instead of losing it.
function Table:expire(now)
  local expired = {}
  for identifier, entry in pairs(self.byId) do
    if now - entry.touched_at_ms >= self.idleMs then
      expired[#expired + 1] = entry
      self.byId[identifier] = nil
      self.byRequest[correlationKey(entry.relationship_id, entry.request_id)] = nil
      release(self, entry)
    end
  end
  -- Deterministic order, because pairs() is not and a simulator compares runs.
  table.sort(expired, function(left, right) return left.flow_id < right.flow_id end)
  return expired
end

function Table:size()
  return self.count
end

-- capacityOf is what a test and a diagnostic screen both read, so neither
-- carries a second copy of the number.
function Table:capacityOf()
  return self.capacity
end

return flows
