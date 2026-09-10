-- The canonical reference topology.
--
-- Every scenario runs against the same World: one Central Server, one ISP, the
-- Home and Farm Customer Networks deliberately reusing the same RFC 1918 pool,
-- and two Computers on each. These are the stable fixture values the in-world
-- acceptance run will also use, so a scenario that passes here is describing
-- the deployment an Operator actually builds.

local simulator = require("tests.lua.support.simulator")

local reference = {}

reference.WORLD_ID = "world-overworld"
reference.CENTRAL_ID = "central-main"
reference.ISP_ID = "isp-acme"
reference.ISP_NAME = "acme"

reference.ALLOCATION = { first = "100.64.0.0", last = "100.64.0.255" }
reference.ISP_ADDRESS = "100.64.0.1"

reference.NETWORKS = {
  home = {
    customer_network_id = "network-home",
    customer_network_name = "home",
    router_id = "router-home",
    provider_address = "100.64.0.10",
    router_address = "192.168.1.1",
    pool_first = "192.168.1.20",
    pool_last = "192.168.1.39",
    lan_operational_channel = 42201,
    computers = {
      { node = "alex-pc", computer_id = "computer-home-alex", hostname = "alex-pc" },
      { node = "wall-display", computer_id = "computer-home-display", hostname = "wall-display" },
    },
    exposed = { { computer_id = "computer-home-display", service = "display.update" } },
  },
  farm = {
    customer_network_id = "network-farm",
    customer_network_name = "farm",
    router_id = "router-farm",
    provider_address = "100.64.0.11",
    router_address = "192.168.1.1",
    pool_first = "192.168.1.20",
    pool_last = "192.168.1.39",
    lan_operational_channel = 42202,
    computers = {
      { node = "harvester", computer_id = "computer-farm-harvester", hostname = "harvester" },
      { node = "silo-monitor", computer_id = "computer-farm-silo", hostname = "silo-monitor" },
    },
    exposed = { { computer_id = "computer-farm-harvester", service = "harvester.status" } },
  },
}

local function assertOk(outcome, what)
  assert(outcome.result.ok,
    what .. " failed: " .. tostring(outcome.result.code) .. " " .. tostring(outcome.result.message))
  return outcome.result
end

-- build stands the whole World up through real state transitions. Nothing is
-- hand-written into an engine's state: every address, route, and binding here
-- was decided by craftnet-core.
function reference.build(core, options)
  options = options or {}
  local sim = simulator.new({ core = core })

  sim:addNode("central", "central")
  assertOk(sim:input("central", {
    kind = "configure",
    settings = {
      world_id = reference.WORLD_ID,
      central_id = reference.CENTRAL_ID,
      gateway_url = "wss://127.0.0.1:8080/gateway",
      gateway_credential_ref = "gwc-acceptance",
    },
  }), "central configure")

  local allocation = assertOk(sim:input("central", {
    kind = "register_isp", isp_id = reference.ISP_ID, isp_name = reference.ISP_NAME,
  }), "register isp").provider_allocations

  sim:addNode("acme", "isp")
  assertOk(sim:input("acme", {
    kind = "configure",
    settings = {
      isp_id = reference.ISP_ID,
      isp_name = reference.ISP_NAME,
      world_id = reference.WORLD_ID,
      central_id = reference.CENTRAL_ID,
      operational_channel = 42100,
      provider_allocations = allocation,
      provider_address = reference.ISP_ADDRESS,
    },
  }), "isp configure")
  sim:connect("central", "acme", "rel-central-acme")

  local order = options.order or { "home", "farm" }
  for _, key in ipairs(order) do
    local network = reference.NETWORKS[key]

    sim:addNode(network.router_id, "router")
    assertOk(sim:input(network.router_id, {
      kind = "configure",
      settings = {
        router_id = network.router_id,
        customer_network_id = network.customer_network_id,
        customer_network_name = network.customer_network_name,
        router_address = network.router_address,
        pool_first = options.pool_first or network.pool_first,
        pool_last = options.pool_last or network.pool_last,
        lan_operational_channel = network.lan_operational_channel,
        isp_id = reference.ISP_ID,
        isp_name = reference.ISP_NAME,
        provider_address = network.provider_address,
        world_id = reference.WORLD_ID,
      },
    }), network.router_id .. " configure")

    -- The ISP assigns the Provider Address and publishes the Route
    -- Registration; the Central Server records it only because the ISP owns it.
    assertOk(sim:input("acme", {
      kind = "register_router",
      router_id = network.router_id,
      customer_network_id = network.customer_network_id,
      customer_network_name = network.customer_network_name,
      provider_address = network.provider_address,
    }), "register " .. network.router_id)

    sim:connect("acme", network.router_id, "rel-acme-" .. network.customer_network_name)

    for _, computer in ipairs(network.computers) do
      sim:addNode(computer.node, "computer")
      local binding = assertOk(sim:input(network.router_id, {
        kind = "bind_computer",
        computer_id = computer.computer_id,
        hostname = computer.hostname,
      }), "bind " .. computer.hostname)

      assertOk(sim:input(computer.node, {
        kind = "configure",
        settings = {
          computer_id = computer.computer_id,
          hostname = binding.hostname,
          address = binding.address,
          customer_network_id = network.customer_network_id,
          customer_network_name = network.customer_network_name,
          router_id = network.router_id,
          router_address = network.router_address,
          dns_address = network.router_address,
          isp_id = reference.ISP_ID,
          isp_name = reference.ISP_NAME,
          world_id = reference.WORLD_ID,
        },
      }), "configure " .. computer.hostname)

      sim:connect(network.router_id, computer.node, "rel-" .. computer.computer_id)
    end

    for _, exposure in ipairs(network.exposed) do
      assertOk(sim:input(network.router_id, {
        kind = "expose_service",
        computer_id = exposure.computer_id,
        service = exposure.service,
      }), "expose " .. exposure.service)
    end
  end

  -- The applications the acceptance scenarios call.
  sim:serve("harvester", "harvester.status", function(payload)
    return core.object({ bushels = 128, asked = rawget(payload, "asked") or "status" })
  end)
  sim:serve("wall-display", "display.update", function(payload)
    return core.object({ shown = rawget(payload, "text") or "" })
  end)

  sim:reset()
  return sim
end

reference.assertOk = assertOk

return reference
