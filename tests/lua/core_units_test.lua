-- Unit coverage for the pure pieces the scenarios lean on.
--
-- The scenarios prove behaviour end to end; these prove the parts behave at
-- their edges, where a scenario would not notice.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local ipv4 = core.ipv4
local names = core.names
local events = core.events

local get = rawget

--------------------------------------------------------------------------
-- IPv4 arithmetic
--------------------------------------------------------------------------

test("an address round trips through its numeric form", function()
  for _, text in ipairs({ "0.0.0.0", "10.0.0.1", "192.168.1.20", "100.64.0.255", "255.255.255.255" }) do
    assertEqual(ipv4.fromNumber(ipv4.toNumber(text)), text, text)
  end
end)

test("a malformed address has no numeric form", function()
  for _, text in ipairs({ "192.168.1", "192.168.1.256", "192.168.01.1", "192.168.1.1.1",
    "192.168.1.-1", "", "localhost", "192.168.1.a" }) do
    assertTrue(ipv4.toNumber(text) == nil, "'" .. text .. "' must not parse")
  end
end)

test("a range must not end before it begins", function()
  assertTrue(ipv4.range("192.168.1.20", "192.168.1.39") ~= nil, "a forward range is fine")
  assertTrue(ipv4.range("192.168.1.39", "192.168.1.20") == nil, "a reversed range is not")
  assertEqual(ipv4.size(ipv4.range("192.168.1.20", "192.168.1.39")), 20, "size")
end)

test("overlap is symmetric and touching ranges do not overlap", function()
  local left = ipv4.range("100.64.0.0", "100.64.0.255")
  local right = ipv4.range("100.64.1.0", "100.64.1.255")
  local straddle = ipv4.range("100.64.0.128", "100.64.1.128")
  assertTrue(not ipv4.overlaps(left, right), "adjacent blocks do not overlap")
  assertTrue(ipv4.overlaps(left, straddle), "a straddling range does")
  assertTrue(ipv4.overlaps(straddle, left), "and symmetrically")
end)

test("lowestFree walks the range in order and stops when it is full", function()
  local range = ipv4.range("192.168.1.20", "192.168.1.22")
  assertEqual(ipv4.lowestFree(range, {}), "192.168.1.20", "the first free address")
  assertEqual(ipv4.lowestFree(range, { ["192.168.1.20"] = true }), "192.168.1.21", "the next one")
  assertEqual(ipv4.lowestFree(range, {
    ["192.168.1.20"] = true, ["192.168.1.21"] = true,
  }), "192.168.1.22", "the last one")
  assertTrue(ipv4.lowestFree(range, {
    ["192.168.1.20"] = true, ["192.168.1.21"] = true, ["192.168.1.22"] = true,
  }) == nil, "a full range has no free address")
end)

test("lowestFreeBlock skips past what is already delegated", function()
  local space = ipv4.range("100.64.0.0", "100.64.3.255")
  local first = ipv4.lowestFreeBlock(space, 256, {})
  assertEqual(ipv4.fromNumber(first.first), "100.64.0.0", "the first block")

  local second = ipv4.lowestFreeBlock(space, 256, { first })
  assertEqual(ipv4.fromNumber(second.first), "100.64.1.0", "the next block")

  local third = ipv4.lowestFreeBlock(space, 256, { second })
  assertEqual(ipv4.fromNumber(third.first), "100.64.0.0", "a gap below is reused")

  local full = { ipv4.range("100.64.0.0", "100.64.3.255") }
  assertTrue(ipv4.lowestFreeBlock(space, 256, full) == nil, "an exhausted space has no block")
end)

--------------------------------------------------------------------------
-- Names
--------------------------------------------------------------------------

local SCOPE = { customer_network_name = "home", isp_name = "acme" }

test("names are case-insensitive and normalize to lowercase", function()
  assertEqual(names.normalize("Alex-PC.Home.ACME.Craft"), "alex-pc.home.acme.craft", "normalized")
  assertEqual(names.parse("ALEX-PC", SCOPE).hostname, "alex-pc", "a bare name too")
end)

test("a name is rejected when any label is not a normalized label", function()
  for _, text in ipairs({ "", ".", "alex..pc", ".alex", "alex.", "alex_pc", "-alex", "alex-",
    string.rep("a", 33) }) do
    assertTrue(names.normalize(text) == nil, "'" .. text .. "' must not normalize")
  end
end)

test("the hierarchy widens one label at a time", function()
  assertEqual(names.parse("alex-pc", SCOPE).scope, "local", "bare")
  assertEqual(names.parse("alex-pc.home", SCOPE).scope, "isp", "network qualified")
  assertEqual(names.parse("alex-pc.home.acme", SCOPE).scope, "world", "world qualified")
  assertEqual(names.parse("alex-pc.home.acme.craft", SCOPE).scope, "world", "explicit suffix")
  assertTrue(names.parse("a.b.c.d.craft", SCOPE) == nil, "four labels is too many")
end)

test("a bare name inherits the asking Computer's scope", function()
  local parsed = names.parse("wall-display", SCOPE)
  assertEqual(parsed.customer_network_name, "home", "network")
  assertEqual(parsed.isp_name, "acme", "isp")
  assertTrue(names.isLocal(parsed, SCOPE), "and it is local")
end)

test("a qualified name is local only when both labels agree", function()
  assertTrue(names.isLocal(names.parse("alex-pc.home", SCOPE), SCOPE), "same network")
  assertTrue(names.isLocal(names.parse("alex-pc.home.acme", SCOPE), SCOPE), "same network and isp")
  assertTrue(not names.isLocal(names.parse("harvester.farm", SCOPE), SCOPE), "another network")
  assertTrue(not names.isLocal(names.parse("alex-pc.home.bolt", SCOPE), SCOPE), "another isp")
end)

test("api.craft is the External Application and the bare suffix is nothing", function()
  assertEqual(names.parse("api.craft", SCOPE).kind, "external", "external")
  assertEqual(names.parse("API.CRAFT", SCOPE).canonical, "api.craft", "canonical")
  -- The suffix is reserved, so a bare "craft" is ambiguous and names nothing.
  -- A Computer actually called craft stays reachable once it is qualified.
  local bare, bareCode = names.parse("craft", SCOPE)
  assertTrue(bare == nil, "a bare suffix names nothing")
  assertEqual(bareCode, "name_not_found", "code")
  assertEqual(names.parse("craft.home", SCOPE).hostname, "craft",
    "a Computer named craft is reachable when qualified")

  local leading, leadingCode = names.parse(".craft", SCOPE)
  assertTrue(leading == nil, "a leading dot is not a name")
  assertEqual(leadingCode, "invalid_message", "code")
end)

test("canonical always renders the fully qualified form", function()
  assertEqual(names.canonical("harvester", "farm", "acme"), "harvester.farm.acme.craft", "canonical")
end)

--------------------------------------------------------------------------
-- Traffic Events
--------------------------------------------------------------------------

local function sampleEvent(extra)
  local fields = {
    event_id = "router-home-e1", observed_at_ms = 1000, world_id = "world-overworld",
    direction = "outbound", kind = "service_request", outcome = "delivered_remote", bytes = 240,
  }
  for key, value in pairs(extra or {}) do fields[key] = value end
  return fields
end

test("a Traffic Event carries only metadata", function()
  local event = assert(events.new(sampleEvent()))
  assertEqual(get(event, "outcome"), "delivered_remote", "outcome")
  assertEqual(get(event, "bytes"), 240, "bytes")
end)

test("a Traffic Event refuses anything that could carry a secret", function()
  for _, field in ipairs({ "payload", "body", "mac", "proof", "access_token",
    "device_credential", "password", "session_key" }) do
    local event, problem = events.new(sampleEvent({ [field] = "sensitive" }))
    assertTrue(event == nil, "'" .. field .. "' must be refused, not dropped")
    assertTrue(problem:find(field, 1, true) ~= nil, "the refusal names the field")
  end
end)

test("a Traffic Event requires the fields a dashboard cannot do without", function()
  for _, field in ipairs({ "event_id", "observed_at_ms", "world_id", "direction",
    "kind", "outcome", "bytes" }) do
    local fields = sampleEvent()
    fields[field] = nil
    assertTrue(events.new(fields) == nil, "'" .. field .. "' is required")
  end
end)

test("an outcome is a delivery shape or a stable error code", function()
  assertTrue(events.isOutcome("delivered_local"), "delivery")
  assertTrue(events.isOutcome("nat_flow_missing"), "a catalog code")
  assertTrue(not events.isOutcome("probably_fine"), "and nothing else")
  assertTrue(events.new(sampleEvent({ outcome = "probably_fine" })) == nil, "refused")
end)

test("a rolling buffer keeps the newest events and counts what it dropped", function()
  local buffer = events.newBuffer("router")
  local capacity = events.CAPACITY.router
  for index = 1, capacity + 25 do
    buffer:append(assert(events.new(sampleEvent({ event_id = "e" .. index }))))
  end
  assertEqual(buffer:count(), capacity, "the buffer stays at its capacity")
  assertEqual(buffer.dropped, 25, "and reports the overflow rather than hiding it")

  local latest = buffer:latest(3)
  assertEqual(#latest, 3, "latest returns what was asked for")
  assertEqual(get(latest[3], "event_id"), "e" .. (capacity + 25), "newest last")

  assertEqual(#buffer:drain(), capacity, "drain empties the buffer")
  assertEqual(buffer:count(), 0, "and leaves it empty")
end)

test("each role has its own buffer capacity", function()
  assertEqual(events.CAPACITY.router, 100, "router")
  assertEqual(events.CAPACITY.isp, 500, "isp")
  assertEqual(events.CAPACITY.central, 2000, "central")
end)

--------------------------------------------------------------------------
-- Revisions
--------------------------------------------------------------------------

test("a durable change bumps the revision once and asks for one persist", function()
  local engine = core.newEngine({ role = "router" })
  assertEqual(engine.state.revision, 0, "a fresh engine starts at zero")

  local outcome = engine:handle({
    kind = "configure",
    settings = {
      router_id = "router-home", customer_network_id = "network-home",
      customer_network_name = "home", router_address = "192.168.1.1",
      pool_first = "192.168.1.20", pool_last = "192.168.1.39",
    },
  }, 0)
  assertEqual(outcome.revision, 1, "the revision advanced")

  local persists = 0
  for _, effect in ipairs(outcome.effects) do
    if effect.kind == "persist" then persists = persists + 1 end
  end
  assertEqual(persists, 1, "exactly one persist, so a transition is never half saved")
  assertEqual(outcome.effects[1].kind, "persist", "and it comes first")
end)

test("an ephemeral change leaves the revision alone", function()
  local engine = core.newEngine({ role = "router" })
  engine:handle({
    kind = "configure",
    settings = {
      router_id = "router-home", customer_network_id = "network-home",
      customer_network_name = "home", router_address = "192.168.1.1",
      pool_first = "192.168.1.20", pool_last = "192.168.1.39",
    },
  }, 0)
  local before = engine.state.revision

  local outcome = engine:handle({
    kind = "link_up", relationship_id = "rel-1", peer_role = "computer",
    peer_id = "computer-a", direction = "child",
  }, 0)
  assertEqual(outcome.revision, before, "a relationship is not durable state")
  for _, effect in ipairs(outcome.effects) do
    assertTrue(effect.kind ~= "persist", "and nothing was persisted")
  end
end)

test("a refused transition changes nothing", function()
  local engine = core.newEngine({ role = "router" })
  local outcome = engine:handle({ kind = "configure", settings = {
    router_id = "Router-Home", customer_network_id = "network-home",
    customer_network_name = "home", router_address = "192.168.1.1",
    pool_first = "192.168.1.20", pool_last = "192.168.1.39",
  } }, 0)
  assertTrue(not outcome.result.ok, "an uppercase identity is refused")
  assertEqual(engine.state.revision, 0, "and the revision did not move")
  assertEqual(#outcome.effects, 0, "and nothing was asked for")
end)

test("a pool that contains the router's own address is refused", function()
  local engine = core.newEngine({ role = "router" })
  local outcome = engine:handle({ kind = "configure", settings = {
    router_id = "router-home", customer_network_id = "network-home",
    customer_network_name = "home", router_address = "192.168.1.25",
    pool_first = "192.168.1.20", pool_last = "192.168.1.39",
  } }, 0)
  assertTrue(not outcome.result.ok, "refused")
  assertEqual(outcome.result.code, "address_conflict", "code")
end)

test("an address outside RFC 1918 is refused for a Customer Network", function()
  local engine = core.newEngine({ role = "router" })
  local outcome = engine:handle({ kind = "configure", settings = {
    router_id = "router-home", customer_network_id = "network-home",
    customer_network_name = "home", router_address = "8.8.8.8",
    pool_first = "192.168.1.20", pool_last = "192.168.1.39",
  } }, 0)
  assertTrue(not outcome.result.ok, "refused")
  assertEqual(outcome.result.code, "invalid_message", "code")
end)

test("an unknown input is a stable failure rather than a crash", function()
  local engine = core.newEngine({ role = "router" })
  local outcome = engine:handle({ kind = "reboot_the_world" }, 0)
  assertTrue(not outcome.result.ok, "refused")
  assertEqual(outcome.result.code, "invalid_message", "code")

  local malformed = engine:handle({}, 0)
  assertEqual(malformed.result.code, "invalid_message", "an input without a kind")

  local badClock = engine:handle({ kind = "tick" }, -1)
  assertEqual(badClock.result.code, "invalid_message", "time must be monotonic milliseconds")
end)
