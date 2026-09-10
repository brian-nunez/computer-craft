-- The CraftOS clock adapter.
--
-- CraftNet security never depends on a Computer's wall clock: this supplies
-- monotonic milliseconds for durations and observations only. os.epoch("utc")
-- is used because it advances steadily while the world runs, unlike the in-game
-- day cycle.

local adapter = {}

local Clock = {}
Clock.__index = Clock

function adapter.new()
  return setmetatable({ origin = os.epoch("utc"), timers = {} }, Clock)
end

-- now is milliseconds since this runtime started, so a value always fits well
-- inside the exact integer range and never depends on the absolute date.
function Clock:now()
  return os.epoch("utc") - self.origin
end

-- timer schedules a CraftOS wake-up. The identifier comes back as a `timer`
-- event, which the links adapter turns into a poll timeout.
function Clock:timer(name, atMs)
  local delaySeconds = math.max(0, (atMs - self:now())) / 1000
  local identifier = os.startTimer(delaySeconds)
  self.timers[identifier] = name
  return identifier
end

function Clock:claim(identifier)
  local name = self.timers[identifier]
  self.timers[identifier] = nil
  return name
end

return adapter
