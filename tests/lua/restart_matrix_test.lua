-- Scenario 12 -- restart every role.
--
-- A restart is the honest test of what is durable. Every node here is torn down
-- and rebuilt from nothing but its own snapshot: no state is handed across in
-- memory, and the new instance knows only what it read back off its disk.
--
-- What has to survive is identity, address, name, route, Network Status, and
-- credential. What must not survive is a session, a counter, a NAT Flow, or an
-- interrupted request -- because replaying one of those is how a restart turns
-- into a duplicated action.

local worlds = require("tests.lua.support.world")

local protocol = worlds.protocol
local fullWorld = worlds.full

local get = rawget

local function ask(world, from, destination, service, payload)
  local answer = world:ask(from, destination, service, payload or protocol.object())
  assert(answer, from .. " received no answer at all")
  return answer
end

-- reaches proves the World still works end to end: Home to Farm, around the
-- Central Server, and back to the Computer that asked.
local function reaches(world, note)
  local answer = ask(world, "alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = note }))
  assert(answer.payload, note .. ": no payload came back: " .. tostring(answer.code))
  assertEqual(get(answer.payload, "answered_by"), "harvester", note .. ": who answered")
  assertEqual(get(answer.payload, "token"), note, note .. ": which request it belongs to")
  return answer
end

--------------------------------------------------------------------------
-- Each role in turn
--------------------------------------------------------------------------

test("scenario 12: a Computer restarts with the same identity and address", function()
  local world = fullWorld()
  reaches(world, "before")

  local before = world.nodes["alex-pc"]:state()
  world:restart("alex-pc")
  local after = world.nodes["alex-pc"]:state()

  assertEqual(after.computer_id, before.computer_id, "identity")
  assertEqual(after.hostname, before.hostname, "hostname")
  assertEqual(after.address, before.address, "address")
  assertEqual(after.customer_network_id, before.customer_network_id, "Customer Network")
  assertEqual(after.router_id, before.router_id, "router")

  -- It rejoined on the credential it already had. Nobody typed the LAN Password
  -- again, and no address was handed out a second time.
  local binding = world.nodes["router-home"]:state().bindings[before.computer_id]
  assertEqual(binding.address, before.address, "the router still holds the same binding")

  reaches(world, "after-computer")
end)

test("scenario 12: a Customer Router restarts with its network intact", function()
  local world = fullWorld()
  reaches(world, "before")

  local before = world.nodes["router-home"]:state()
  local bindingsBefore = {}
  for computerId, binding in pairs(before.bindings) do bindingsBefore[computerId] = binding.address end

  world:restart("router-home")
  local after = world.nodes["router-home"]:state()

  assertEqual(after.router_id, before.router_id, "identity")
  assertEqual(after.customer_network_id, before.customer_network_id, "Customer Network")
  assertEqual(after.customer_network_name, before.customer_network_name, "name")
  assertEqual(after.router_provider_address, before.router_provider_address, "Provider Address")
  assertEqual(after.isp_id, before.isp_id, "ISP")

  local count = 0
  for computerId, address in pairs(bindingsBefore) do
    assertEqual(after.bindings[computerId].address, address,
      computerId .. " kept its permanent Address Binding")
    count = count + 1
  end
  assertEqual(count, 2, "both of Home's Computers are still bound")

  -- Its Computers come back to the router they already knew, on the credential
  -- they already held.
  world:restart("alex-pc")
  world:restart("wall-display")
  reaches(world, "after-router")
end)

test("scenario 12: an ISP restarts with its allocation and its routes", function()
  local world = fullWorld()
  reaches(world, "before")

  local before = world.nodes["acme"]:state()
  world:restart("acme")
  local after = world.nodes["acme"]:state()

  assertEqual(after.isp_id, before.isp_id, "identity")
  assertEqual(#after.provider_allocations, #before.provider_allocations, "allocation count")
  assertEqual(after.provider_allocations[1].first, before.provider_allocations[1].first,
    "the allocation itself")
  for routerId, router in pairs(before.routers) do
    assertTrue(after.routers[routerId] ~= nil, routerId .. " is still registered")
    assertEqual(after.routers[routerId].router_provider_address, router.router_provider_address,
      routerId .. " kept its Provider Address")
  end

  world:restart("router-home")
  world:restart("router-farm")
  world:restart("alex-pc")
  world:restart("harvester")
  reaches(world, "after-isp")
end)

test("scenario 12: the Central Server restarts with the whole route directory", function()
  local world = fullWorld()
  reaches(world, "before")

  local before = world.central:state()
  world:restart("central")
  local after = world.central:state()

  assertEqual(after.world_id, before.world_id, "World identity")
  assertEqual(after.central_id, before.central_id, "Central Server identity")
  for networkId, route in pairs(before.routes) do
    assertTrue(after.routes[networkId] ~= nil, networkId .. " is still routed")
    assertEqual(after.routes[networkId].router_provider_address, route.router_provider_address,
      networkId .. " kept its Provider Address")
    assertEqual(after.routes[networkId].isp_id, route.isp_id, networkId .. " kept its ISP")
  end
  for ispId in pairs(before.isps) do
    assertTrue(after.isps[ispId] ~= nil, ispId .. " is still registered")
  end

  -- The Gateway Credential is a digest on disk and a secret in the secret
  -- store, and both came back.
  assertTrue(world.central.secrets:get("gateway-credential") ~= nil,
    "the Gateway Credential survived")

  world:restart("acme")
  world:restart("router-home")
  world:restart("router-farm")
  world:restart("alex-pc")
  world:restart("harvester")
  reaches(world, "after-central")
end)

--------------------------------------------------------------------------
-- What must not survive
--------------------------------------------------------------------------

test("scenario 12: a Network Status survives a Central Server restart", function()
  local world = fullWorld()
  assert(world.central:setNetworkStatus("network-farm", "disabled", "cmd-restart-1"))

  world:restart("central")
  assertEqual(world.central:state().network_status["network-farm"], "disabled",
    "a disabled Customer Network stays disabled across a restart")

  -- And re-enabling it afterwards still needs no re-enrollment.
  assert(world.central:setNetworkStatus("network-farm", "enabled", "cmd-restart-2"))
  world:restart("acme")
  world:restart("router-home")
  world:restart("router-farm")
  world:restart("alex-pc")
  world:restart("harvester")
  reaches(world, "after-status")
end)

test("scenario 12: a restart discards every NAT Flow and correlation record", function()
  local world = fullWorld()
  reaches(world, "before")

  -- Leave work outstanding on purpose: a request nobody will ever answer.
  world.nodes["alex-pc"].runtime:submit({
    kind = "local_request",
    destination = {
      customer_network_id = "network-farm",
      computer_id = world.bindings["harvester"].computer_id,
    },
    service = "nobody.answers",
    payload = protocol.object({ token = "interrupted" }),
  })
  assertTrue(world.nodes["alex-pc"].runtime.engine.transit:size() > 0,
    "the request really is outstanding before the restart")

  world:restart("alex-pc")
  local engine = world.nodes["alex-pc"].runtime.engine
  assertEqual(engine.transit:size(), 0, "no correlation record came back")
  assertEqual(engine.flows:size(), 0, "no NAT Flow came back")

  -- Nor does the interrupted request get replayed. It is gone, which is the
  -- right answer: retrying it would be this Computer deciding on its own to do
  -- something a player asked for once.
  local snapshot = world:disk("alex-pc"):read("state/computer.json") or ""
  assertTrue(not snapshot:find("nobody.answers", 1, true),
    "an interrupted request must not be written to durable state")
  assertTrue(not snapshot:find("interrupted", 1, true),
    "and neither must its payload")

  -- The abandoned exchange's late error is dropped by the new instance rather
  -- than being matched to something: there is no correlation left to match.
  world:settle()
  reaches(world, "after-interrupted")
end)

test("scenario 12: a restart starts fresh sessions and fresh counters", function()
  local world = fullWorld()
  reaches(world, "before")
  reaches(world, "again")

  local before = world.nodes["router-home"].runtime.engine
  local beforeRequests = before.nextRequestNumber
  assertTrue(beforeRequests > 1, "the router really did allocate Request IDs before the restart")

  world:restart("router-home")
  world:restart("alex-pc")
  world:restart("wall-display")

  local after = world.nodes["router-home"].runtime.engine
  assertEqual(after.nextRequestNumber, 1, "Request ID allocation starts again from one")
  assertEqual(after.buffer:count(), 0, "the diagnostic buffer is not durable")

  -- A fresh counter is safe precisely because the session is fresh too: a peer
  -- that remembered the old counters would reject the new ones, so both ends
  -- re-establish rather than resume.
  reaches(world, "after-fresh")
end)

--------------------------------------------------------------------------
-- The whole matrix at once
--------------------------------------------------------------------------

test("scenario 12: every role restarts and the World still works", function()
  local world = fullWorld()
  reaches(world, "before")

  local addressBefore = world.nodes["alex-pc"]:state().address
  local providerBefore = world.nodes["router-farm"]:state().router_provider_address

  -- Top down, the way an Operator would bring a World back after a server
  -- restart: the Central Server first, then its ISPs, routers, and Computers.
  for _, name in ipairs({
    "central", "acme", "router-home", "router-farm",
    "alex-pc", "wall-display", "harvester", "silo-monitor",
  }) do
    world:restart(name)
  end

  assertEqual(world.nodes["alex-pc"]:state().address, addressBefore, "alex-pc kept its address")
  assertEqual(world.nodes["router-farm"]:state().router_provider_address, providerBefore,
    "Farm kept its Provider Address")

  -- Overlapping addressing is still unambiguous after everything restarted.
  assertEqual(world.nodes["harvester"]:state().address, addressBefore,
    "harvester holds the same RFC 1918 address in its own Customer Network")

  reaches(world, "after-everything")

  -- And the reply came home to Home's .20, not Farm's.
  local answer = ask(world, "harvester", {
    customer_network_id = "network-home",
    computer_id = world.bindings["wall-display"].computer_id,
  }, "display.update", protocol.object({ token = "reverse" }))
  assertEqual(get(answer.payload, "answered_by"), "wall-display", "the reverse direction works too")
end)

--------------------------------------------------------------------------
-- Regression
--------------------------------------------------------------------------

-- Found by the restart matrix: a role bumped its session generation in memory
-- but never wrote it down, so a restart started counting from one again. Its
-- parent had already seen that nonce, refused the repeat as a replay, and the
-- child sat there unable to reconnect to a parent that had not itself
-- restarted. The counter is durable now, and this is what says so.
test("scenario 12: a session generation is durable across repeated restarts", function()
  local world = fullWorld()
  reaches(world, "before")

  local first = world.nodes["alex-pc"]:state().session_generation
  assertTrue(first and first >= 1, "the Computer has a session generation at all")

  for round = 1, 3 do
    world:restart("alex-pc")
    local after = world.nodes["alex-pc"]:state().session_generation
    assertTrue(after > first,
      "restart " .. round .. ": the generation went backwards (" .. tostring(after)
        .. " after " .. tostring(first) .. ")")
    first = after
    reaches(world, "restart-" .. round)
  end

  -- The same holds one level up: a Customer Router that restarts must not
  -- repeat a nonce its ISP has already seen.
  local routerBefore = world.nodes["router-home"]:state().upstream_session_generation
  world:restart("router-home")
  assertTrue(world.nodes["router-home"]:state().upstream_session_generation > routerBefore,
    "the router's upstream generation is durable too")
end)
