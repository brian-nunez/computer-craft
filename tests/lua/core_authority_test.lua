-- Authority ownership cannot be bypassed.
--
-- Every role owns a specific slice of state, and every hop validates only its
-- own immediate authenticated relationship. These tests attack that boundary
-- from below: a Computer claiming a neighbour, a Customer Router claiming
-- another network, an ISP claiming another ISP's route, address, or traffic.
-- Each attempt must be refused with a stable code rather than quietly honoured.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local simulator = require("tests.lua.support.simulator")
local reference = require("tests.lua.support.reference")

local get = rawget
local assertOk = reference.assertOk

--------------------------------------------------------------------------
-- A Computer may only speak for itself
--------------------------------------------------------------------------

test("a Computer cannot pose as one of its neighbours", function()
  local sim = reference.build(core)

  -- alex-pc writes silo-monitor's identity and Farm's address into the source
  -- field. The router replaces it from the authenticated session.
  sim:step("router-home", {
    kind = "message",
    relationship_id = "rel-computer-home-alex",
    message = {
      kind = "service_request",
      request_id = "forged-1",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-display",
          customer_network_id = "network-farm",
          local_address = "192.168.1.21",
        }),
        destination = core.object({
          customer_network_id = "network-farm",
          computer_id = "computer-farm-harvester",
        }),
        service = "harvester.status",
        payload = core.object({}),
      }),
    },
  })

  local flows = sim:engine("router-home").flows
  assertEqual(flows:size(), 1, "the request was accepted on its own merits")
  local entry
  for _, value in pairs(flows.byId) do entry = value end
  assertEqual(entry.computer_id, "computer-home-alex", "the source is the authenticated Computer")
  assertEqual(entry.local_address, "192.168.1.20", "and its real address")
end)

test("a Computer with no binding cannot send through the router", function()
  local sim = reference.build(core)
  sim:addNode("stranger", "computer")
  assertOk(sim:input("stranger", {
    kind = "configure",
    settings = {
      computer_id = "computer-stranger", hostname = "stranger", address = "192.168.1.99",
      customer_network_id = "network-home", router_id = "router-home",
      router_address = "192.168.1.1", dns_address = "192.168.1.1",
    },
  }), "configure stranger")
  sim:connect("router-home", "stranger", "rel-stranger")

  local outcome = sim:step("router-home", {
    kind = "message",
    relationship_id = "rel-stranger",
    message = {
      kind = "service_request",
      request_id = "stranger-1",
      body = core.object({
        source = core.object({
          computer_id = "computer-stranger",
          customer_network_id = "network-home",
          local_address = "192.168.1.99",
        }),
        destination = core.object({
          customer_network_id = "network-home",
          computer_id = "computer-home-display",
        }),
        service = "display.update",
        payload = core.object({}),
      }),
    },
  })
  assertTrue(not outcome.result.ok, "an unbound Computer was refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
end)

--------------------------------------------------------------------------
-- A Customer Router may only speak for its own Customer Network
--------------------------------------------------------------------------

test("a Customer Router cannot carry traffic for another network", function()
  local sim = reference.build(core)

  local outcome = sim:step("acme", {
    kind = "message",
    relationship_id = "rel-acme-home",
    message = {
      kind = "service_request",
      request_id = "forged-2",
      body = core.object({
        source = core.object({
          computer_id = "computer-farm-harvester",
          customer_network_id = "network-farm",
          local_address = "192.168.1.20",
        }),
        destination = core.object({
          customer_network_id = "network-home",
          computer_id = "computer-home-display",
        }),
        service = "display.update",
        payload = core.object({}),
      }),
    },
  })
  assertTrue(not outcome.result.ok, "Home's router could not speak for Farm")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
  assertTrue(sim:sawOutcome("forbidden_operation", "acme"), "the ISP recorded the attempt")
end)

--------------------------------------------------------------------------
-- An ISP may only register and carry its own routes
--------------------------------------------------------------------------

local function twoIsps()
  local sim = simulator.new({ core = core })
  sim:addNode("central", "central")
  assertOk(sim:input("central", {
    kind = "configure",
    settings = { world_id = "world-overworld", central_id = "central-main" },
  }), "configure central")

  local first = assertOk(sim:input("central", {
    kind = "register_isp", isp_id = "isp-acme", isp_name = "acme",
  }), "register acme")
  local second = assertOk(sim:input("central", {
    kind = "register_isp", isp_id = "isp-bolt", isp_name = "bolt",
  }), "register bolt")

  local providers = {
    { name = "acme", isp_id = "isp-acme", allocations = first.provider_allocations },
    { name = "bolt", isp_id = "isp-bolt", allocations = second.provider_allocations },
  }
  for _, provider in ipairs(providers) do
    sim:addNode(provider.name, "isp")
    assertOk(sim:input(provider.name, {
      kind = "configure",
      settings = {
        isp_id = provider.isp_id, isp_name = provider.name,
        world_id = "world-overworld", central_id = "central-main",
        provider_allocations = provider.allocations,
      },
    }), "configure " .. provider.name)
    sim:connect("central", provider.name, "rel-central-" .. provider.name)
  end
  return sim, first.provider_allocations, second.provider_allocations
end

test("every ISP receives a disjoint Provider Allocation", function()
  local sim, acme, bolt = twoIsps()
  local ipv4 = core.ipv4
  local left = ipv4.range(acme[1].first, acme[1].last)
  local right = ipv4.range(bolt[1].first, bolt[1].last)
  assertTrue(not ipv4.overlaps(left, right), "the two allocations must not overlap")
  assertEqual(ipv4.size(left), 256, "each ISP receives a full block")
  assertEqual(ipv4.size(right), 256, "each ISP receives a full block")
  assertTrue(sim:state("acme").provider_address ~= sim:state("bolt").provider_address,
    "and their own addresses differ")
end)

test("an ISP cannot register a route in another ISP's name", function()
  local sim = twoIsps()
  local outcome = sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-bolt",
    message = {
      kind = "route_register",
      request_id = "forged-3",
      body = core.object({
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-home", router_provider_address = "100.64.0.10",
        isp_id = "isp-acme", revision = 1,
      }),
    },
  })
  assertTrue(not outcome.result.ok, "bolt could not register as acme")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
  assertTrue(sim:state("central").routes["network-home"] == nil, "no route was recorded")
end)

test("an ISP cannot claim a Provider Address outside its own allocation", function()
  local sim, acme = twoIsps()
  -- An address that belongs to acme's block, published by bolt under its own
  -- identity, is still outside bolt's allocation.
  local outcome = sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-bolt",
    message = {
      kind = "route_register",
      request_id = "forged-4",
      body = core.object({
        customer_network_id = "network-bolt", customer_network_name = "boltnet",
        router_id = "router-bolt", router_provider_address = acme[1].first,
        isp_id = "isp-bolt", revision = 1,
      }),
    },
  })
  assertTrue(not outcome.result.ok, "the address was refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
end)

test("an ISP cannot take over a Customer Network another ISP already owns", function()
  local sim, acme, bolt = twoIsps()
  assertOk(sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-acme",
    message = {
      kind = "route_register",
      request_id = "route-1",
      body = core.object({
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-home", router_provider_address = acme[1].first,
        isp_id = "isp-acme", revision = 1,
      }),
    },
  }), "acme registers home")

  local outcome = sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-bolt",
    message = {
      kind = "route_register",
      request_id = "forged-5",
      body = core.object({
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-evil", router_provider_address = bolt[1].first,
        isp_id = "isp-bolt", revision = 1,
      }),
    },
  })
  assertTrue(not outcome.result.ok, "the takeover was refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
  assertEqual(sim:state("central").routes["network-home"].isp_id, "isp-acme",
    "the original owner keeps the route")
end)

test("an ISP cannot carry traffic for a Customer Network it does not serve", function()
  local sim, acme = twoIsps()
  assertOk(sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-acme",
    message = {
      kind = "route_register",
      request_id = "route-2",
      body = core.object({
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-home", router_provider_address = acme[1].first,
        isp_id = "isp-acme", revision = 1,
      }),
    },
  }), "acme registers home")

  local outcome = sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-bolt",
    message = {
      kind = "service_request",
      request_id = "forged-6",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-alex", customer_network_id = "network-home",
          local_address = "192.168.1.20",
        }),
        destination = core.object({
          customer_network_id = "network-home", computer_id = "computer-home-display",
        }),
        service = "display.update",
        payload = core.object({}),
      }),
    },
  })
  assertTrue(not outcome.result.ok, "bolt could not carry acme's traffic")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
end)

test("an ISP name is unique within a World and a network name within an ISP", function()
  local sim = twoIsps()
  local outcome = sim:input("central", {
    kind = "register_isp", isp_id = "isp-other", isp_name = "acme",
  })
  assertTrue(not outcome.result.ok, "a duplicate ISP name was refused")
  assertEqual(outcome.result.code, "name_conflict", "code")

  local reference_sim = reference.build(core)
  local duplicate = reference_sim:input("acme", {
    kind = "register_router", router_id = "router-other",
    customer_network_id = "network-other", customer_network_name = "home",
  })
  assertTrue(not duplicate.result.ok, "a duplicate network name was refused")
  assertEqual(duplicate.result.code, "name_conflict", "code")
end)

--------------------------------------------------------------------------
-- The Central Server is the only interconnection point
--------------------------------------------------------------------------

test("traffic between two networks on one ISP still visits the Central Server", function()
  local sim = reference.build(core)
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  local visited = false
  for _, node in ipairs(sim:path("service_request")) do
    if node == "central" then visited = true end
  end
  assertTrue(visited, "the ISP must not shortcut between its own customers")
end)

test("a message on an unknown relationship is refused", function()
  local sim = reference.build(core)
  local outcome = sim:step("router-home", {
    kind = "message",
    relationship_id = "rel-nobody",
    message = { kind = "heartbeat", body = core.object({}) },
  })
  assertTrue(not outcome.result.ok, "an unknown relationship was refused")
  assertEqual(outcome.result.code, "authentication_failed", "code")
end)

test("only an ISP may publish a route", function()
  local sim = reference.build(core)
  local outcome = sim:step("central", {
    kind = "message",
    relationship_id = "rel-central-acme",
    message = {
      kind = "route_remove",
      request_id = "forged-7",
      body = core.object({ customer_network_id = "network-farm", revision = 1 }),
    },
  })
  assertTrue(outcome.result.ok, "the owning ISP may remove its own route")

  local sim2 = reference.build(core)
  sim2:engine("central").links["rel-central-acme"].role = "router"
  local refused = sim2:step("central", {
    kind = "message",
    relationship_id = "rel-central-acme",
    message = {
      kind = "route_register",
      request_id = "forged-8",
      body = core.object({
        customer_network_id = "network-new", customer_network_name = "new",
        router_id = "router-new", router_provider_address = "100.64.0.12",
        isp_id = "isp-acme", revision = 1,
      }),
    },
  })
  assertTrue(not refused.result.ok, "a non-ISP peer could not publish a route")
  assertEqual(refused.result.code, "forbidden_operation", "code")
end)
