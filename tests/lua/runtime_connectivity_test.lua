-- Connectivity State and reconnection timing.
--
-- A relationship is judged by silence, not by whether a modem is plugged in.
-- These tests walk the clock across each threshold and check that the state
-- changes exactly where the design says it does.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })

local connectivity = runtimePackage.connectivity
local REL = "rel-acme-home"

test("the thresholds are the ones the design states", function()
  assertEqual(connectivity.HEARTBEAT_MS, 10000, "heartbeats every ten seconds")
  assertEqual(connectivity.DISCONNECT_MS, 30000, "disconnected after thirty")
  assertEqual(connectivity.BACKOFF_FIRST_MS, 1000, "backoff starts at one second")
  assertEqual(connectivity.BACKOFF_LIMIT_MS, 30000, "and never exceeds thirty")
end)

test("a relationship that has never been heard from is connecting, not lost", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  assertEqual(monitor:stateOf(REL), "connecting", "at the start")

  monitor:evaluate(REL, 5000)
  assertEqual(monitor:stateOf(REL), "connecting", "still connecting while it is young")

  monitor:evaluate(REL, 20000)
  assertEqual(monitor:stateOf(REL), "connecting", "and past the heartbeat interval too")
end)

test("state walks ready, degraded, disconnected as silence grows", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 1000)
  assertEqual(monitor:stateOf(REL), "ready", "traffic makes it ready")

  monitor:evaluate(REL, 1000 + 9999)
  assertEqual(monitor:stateOf(REL), "ready", "just under one heartbeat is still ready")

  monitor:evaluate(REL, 1000 + 10000)
  assertEqual(monitor:stateOf(REL), "degraded", "at one missed heartbeat it degrades")

  monitor:evaluate(REL, 1000 + 29999)
  assertEqual(monitor:stateOf(REL), "degraded", "just under the limit it is still degraded")

  monitor:evaluate(REL, 1000 + 30000)
  assertEqual(monitor:stateOf(REL), "disconnected", "at thirty seconds it is disconnected")
end)

test("any authenticated traffic restores ready, not only a heartbeat", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)
  monitor:evaluate(REL, 40000)
  assertEqual(monitor:stateOf(REL), "disconnected", "it went quiet")

  monitor:observe(REL, 41000)
  assertEqual(monitor:stateOf(REL), "ready", "and one message brought it back")
  assertEqual(monitor:get(REL).attempts, 0, "the backoff was reset")
end)

test("revoked is terminal and no amount of time clears it", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)
  monitor:revoke(REL, 1000)
  assertEqual(monitor:stateOf(REL), "revoked", "revoked")

  monitor:evaluate(REL, 100000)
  assertEqual(monitor:stateOf(REL), "revoked", "time does not clear it")

  monitor:observe(REL, 101000)
  assertEqual(monitor:stateOf(REL), "revoked", "and neither does traffic")
end)

test("backoff doubles from one second and stops at thirty", function()
  local monitor = connectivity.new()
  local expected = { 1000, 2000, 4000, 8000, 16000, 30000, 30000, 30000 }
  for attempt = 1, #expected do
    assertEqual(monitor:backoff(attempt), expected[attempt], "attempt " .. attempt)
  end
end)

test("a disconnection schedules a retry and each failure pushes the next one out", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)

  monitor:evaluate(REL, 30000)
  assertEqual(monitor:stateOf(REL), "disconnected", "disconnected")
  assertEqual(monitor:get(REL).next_attempt_ms, 31000, "the first retry is a second later")

  assertEqual(#monitor:dueForReconnect(30500), 0, "nothing is due yet")
  assertEqual(#monitor:dueForReconnect(31000), 1, "and then it is")

  monitor:attempted(REL, 31000)
  assertEqual(monitor:get(REL).next_attempt_ms, 33000, "the next wait is two seconds")
  monitor:attempted(REL, 33000)
  assertEqual(monitor:get(REL).next_attempt_ms, 37000, "then four")
end)

test("only one disconnection is counted per silence, not one per evaluation", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)
  for moment = 30000, 35000, 1000 do
    monitor:evaluate(REL, moment)
  end
  assertEqual(monitor:get(REL).attempts, 1, "repeated checks do not inflate the backoff")
end)

test("heartbeats come due every interval and reset when one is sent", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  assertEqual(#monitor:dueForHeartbeat(9999), 0, "not yet")
  assertEqual(#monitor:dueForHeartbeat(10000), 1, "now")

  monitor:heartbeatSent(REL, 10000)
  assertEqual(#monitor:dueForHeartbeat(19999), 0, "not again yet")
  assertEqual(#monitor:dueForHeartbeat(20000), 1, "and then again")
end)

test("a revoked relationship is never heartbeated", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:revoke(REL, 0)
  assertEqual(#monitor:dueForHeartbeat(60000), 0, "nothing is sent to a revoked peer")
end)

test("evaluateAll reports transitions rather than levels", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)

  assertEqual(#monitor:evaluateAll(1000), 0, "nothing changed")
  local changed = monitor:evaluateAll(10000)
  assertEqual(#changed, 1, "one transition")
  assertEqual(changed[1].from, "ready", "from")
  assertEqual(changed[1].to, "degraded", "to")
  assertEqual(#monitor:evaluateAll(11000), 0, "and it is not reported twice")
end)

test("the next wake is the soonest deadline across every relationship", function()
  local monitor = connectivity.new()
  monitor:track("rel-a", 0)
  monitor:observe("rel-a", 0)
  monitor:track("rel-b", 0)
  monitor:observe("rel-b", 5000)

  -- rel-a was heard at 0, so its heartbeat is due at 10000; rel-b's at 10000
  -- too, since neither has sent one yet.
  assertEqual(monitor:nextWakeMs(0), 10000, "the soonest heartbeat")

  monitor:heartbeatSent("rel-a", 0)
  monitor:heartbeatSent("rel-b", 5000)
  assertEqual(monitor:nextWakeMs(0), 10000, "rel-a is still first")

  assertTrue(monitor:nextWakeMs(60000) == 60000,
    "a deadline already past wakes immediately rather than going negative")
end)

test("a relationship whose transport vanished does not wait for the threshold", function()
  local monitor = connectivity.new()
  monitor:track(REL, 0)
  monitor:observe(REL, 0)
  monitor:lost(REL, 500)
  assertEqual(monitor:stateOf(REL), "disconnected", "a lost link is disconnected at once")
  assertEqual(monitor:get(REL).next_attempt_ms, 1500, "and a retry is already scheduled")
end)
