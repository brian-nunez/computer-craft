-- Connectivity State and reconnection timing.
--
-- A relationship is judged by when authenticated traffic last arrived on it,
-- never by whether a modem is present. Roles heartbeat every ten seconds; an
-- upstream relationship that has been silent for thirty is disconnected.
-- Reconnection uses bounded exponential backoff and always establishes a fresh
-- Authenticated Session -- an old one is never resumed.

local connectivity = {}

connectivity.HEARTBEAT_MS = 10000
connectivity.DISCONNECT_MS = 30000
connectivity.BACKOFF_FIRST_MS = 1000
connectivity.BACKOFF_LIMIT_MS = 30000

-- The five states a relationship can be in, in the order they degrade.
connectivity.STATES = {
  connecting = true,
  ready = true,
  degraded = true,
  disconnected = true,
  revoked = true,
}

local Monitor = {}
Monitor.__index = Monitor

function connectivity.new(options)
  options = options or {}
  return setmetatable({
    heartbeatMs = options.heartbeat_ms or connectivity.HEARTBEAT_MS,
    disconnectMs = options.disconnect_ms or connectivity.DISCONNECT_MS,
    backoffFirstMs = options.backoff_first_ms or connectivity.BACKOFF_FIRST_MS,
    backoffLimitMs = options.backoff_limit_ms or connectivity.BACKOFF_LIMIT_MS,
    relationships = {},
  }, Monitor)
end

--------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------

-- track begins watching a relationship. It starts in `connecting`: nothing has
-- been heard on it yet, which is not the same as having lost it. The direction
-- is remembered because it decides which side reconnects.
function Monitor:track(relationshipId, now, direction)
  local entry = {
    relationship_id = relationshipId,
    state = "connecting",
    direction = direction or "child",
    last_seen_ms = nil,
    established_at_ms = now,
    attempts = 0,
    next_attempt_ms = now,
  }
  self.relationships[relationshipId] = entry
  return entry
end

function Monitor:forget(relationshipId)
  self.relationships[relationshipId] = nil
end

function Monitor:get(relationshipId)
  return self.relationships[relationshipId]
end

-- observe records authenticated traffic. Any authenticated message counts, not
-- only a heartbeat, so a busy relationship never needs one.
function Monitor:observe(relationshipId, now)
  local entry = self.relationships[relationshipId] or self:track(relationshipId, now)
  if entry.state == "revoked" then return entry end
  entry.last_seen_ms = now
  entry.state = "ready"
  entry.attempts = 0
  entry.next_attempt_ms = now
  return entry
end

-- revoke is terminal until an Operator re-enrolls the same identity. It is not
-- a timing state, so nothing about the clock clears it.
function Monitor:revoke(relationshipId, now)
  local entry = self.relationships[relationshipId] or self:track(relationshipId, now)
  entry.state = "revoked"
  return entry
end

-- lost marks a relationship whose transport is gone, without waiting for the
-- silence threshold that would have found it anyway.
function Monitor:lost(relationshipId, now)
  local entry = self.relationships[relationshipId] or self:track(relationshipId, now)
  if entry.state ~= "revoked" and entry.state ~= "disconnected" then
    -- Only the transition arms a retry. Being told twice that a relationship is
    -- down must not push the next attempt further away.
    entry.state = "disconnected"
    entry.attempts = entry.attempts + 1
    entry.next_attempt_ms = now + self:backoff(entry.attempts)
  end
  return entry
end

--------------------------------------------------------------------------
-- Evaluation
--------------------------------------------------------------------------

-- evaluate recomputes one relationship's state from how long it has been quiet.
-- A relationship that has never been heard from stays `connecting` until the
-- disconnect threshold, because it was never up to begin with.
function Monitor:evaluate(relationshipId, now)
  local entry = self.relationships[relationshipId]
  if not entry then return nil end
  if entry.state == "revoked" then return entry end

  local since = entry.last_seen_ms and (now - entry.last_seen_ms)
    or (now - entry.established_at_ms)
  local previous = entry.state

  if since >= self.disconnectMs then
    entry.state = "disconnected"
  elseif entry.last_seen_ms == nil then
    entry.state = "connecting"
  elseif since >= self.heartbeatMs then
    -- One missed heartbeat is not yet a loss, but it is worth showing.
    entry.state = "degraded"
  else
    entry.state = "ready"
  end

  if entry.state == "disconnected" and previous ~= "disconnected" then
    entry.attempts = entry.attempts + 1
    entry.next_attempt_ms = now + self:backoff(entry.attempts)
  end
  return entry, previous
end

-- evaluateAll returns every relationship whose state changed, so the runtime
-- can act on a transition rather than polling for a level.
function Monitor:evaluateAll(now)
  local changed = {}
  local names = {}
  for relationshipId in pairs(self.relationships) do names[#names + 1] = relationshipId end
  -- Deterministic order: a simulator compares runs, and pairs() is not stable.
  table.sort(names)
  for _, relationshipId in ipairs(names) do
    local entry, previous = self:evaluate(relationshipId, now)
    if entry and entry.state ~= previous then
      changed[#changed + 1] = { relationship_id = relationshipId, from = previous, to = entry.state }
    end
  end
  return changed
end

function Monitor:stateOf(relationshipId)
  local entry = self.relationships[relationshipId]
  return entry and entry.state or "connecting"
end

--------------------------------------------------------------------------
-- Heartbeats and backoff
--------------------------------------------------------------------------

-- dueForHeartbeat lists the relationships that have gone quiet long enough that
-- this role should say something, so the peer's own threshold does not fire.
function Monitor:dueForHeartbeat(now)
  local due = {}
  local names = {}
  for relationshipId in pairs(self.relationships) do names[#names + 1] = relationshipId end
  table.sort(names)
  for _, relationshipId in ipairs(names) do
    local entry = self.relationships[relationshipId]
    local last = entry.last_heartbeat_ms or entry.established_at_ms
    if entry.state ~= "revoked" and (now - last) >= self.heartbeatMs then
      due[#due + 1] = relationshipId
    end
  end
  return due
end

function Monitor:heartbeatSent(relationshipId, now)
  local entry = self.relationships[relationshipId]
  if entry then entry.last_heartbeat_ms = now end
end

-- backoff is bounded exponential, from the first delay up to the limit. It
-- never grows without end, because a role that has been offline for an hour
-- should still try again within the limit.
function Monitor:backoff(attempt)
  if attempt <= 0 then return self.backoffFirstMs end
  local delay = self.backoffFirstMs * (2 ^ (attempt - 1))
  if delay > self.backoffLimitMs then return self.backoffLimitMs end
  return math.floor(delay)
end

-- dueForReconnect lists relationships whose backoff has elapsed.
function Monitor:dueForReconnect(now)
  local due = {}
  local names = {}
  for relationshipId in pairs(self.relationships) do names[#names + 1] = relationshipId end
  table.sort(names)
  for _, relationshipId in ipairs(names) do
    local entry = self.relationships[relationshipId]
    if entry.state == "disconnected" and now >= entry.next_attempt_ms then
      due[#due + 1] = relationshipId
    end
  end
  return due
end

-- attempted records a reconnection try and schedules the next one. A fresh
-- session is always established; nothing about the old one is carried over.
function Monitor:attempted(relationshipId, now)
  local entry = self.relationships[relationshipId]
  if not entry then return nil end
  entry.attempts = entry.attempts + 1
  entry.next_attempt_ms = now + self:backoff(entry.attempts)
  return entry
end

-- nextWakeMs is when the runtime should look again: the soonest heartbeat or
-- reconnection deadline. The runtime waits rather than spinning.
function Monitor:nextWakeMs(now)
  local soonest
  for _, entry in pairs(self.relationships) do
    local candidates = {}
    if entry.state == "disconnected" then
      candidates[#candidates + 1] = entry.next_attempt_ms
    elseif entry.state ~= "revoked" then
      candidates[#candidates + 1] = (entry.last_heartbeat_ms or entry.established_at_ms)
        + self.heartbeatMs
      if entry.last_seen_ms then
        candidates[#candidates + 1] = entry.last_seen_ms + self.disconnectMs
      end
    end
    for _, candidate in ipairs(candidates) do
      if soonest == nil or candidate < soonest then soonest = candidate end
    end
  end
  if soonest == nil then return nil end
  if soonest < now then return now end
  return soonest
end

return connectivity
