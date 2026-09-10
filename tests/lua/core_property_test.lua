-- Property-style seeded runs.
--
-- The scenarios prove specific paths. These prove invariants over many random
-- ones: an address is never handed out twice inside one Customer Network, and a
-- reply never reaches the wrong Computer -- even when every network in the
-- World deliberately reuses the identical RFC 1918 pool, which is exactly the
-- situation that would make a naive implementation deliver to a neighbour.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local simulator = require("tests.lua.support.simulator")
local seed = require("tests.lua.support.seed")

local get = rawget

local POOL_FIRST = "192.168.1.20"
local POOL_LAST = "192.168.1.39"

local function assertOk(outcome, what)
  assert(outcome.result.ok,
    what .. " failed: " .. tostring(outcome.result.code) .. " " .. tostring(outcome.result.message))
  return outcome.result
end

-- buildWorld stands up ispCount ISPs, each with networkCount Customer Networks,
-- each with computerCount Computers. Every network uses the same pool on
-- purpose, so overlapping addresses are the norm rather than a special case.
local function buildWorld(ispCount, networkCount, computerCount)
  local sim = simulator.new({ core = core })
  local computers = {}

  sim:addNode("central", "central")
  assertOk(sim:input("central", {
    kind = "configure",
    settings = { world_id = "world-overworld", central_id = "central-main" },
  }), "configure central")

  for ispIndex = 1, ispCount do
    local ispId = "isp-" .. ispIndex
    local ispName = "isp" .. ispIndex
    local allocation = assertOk(sim:input("central", {
      kind = "register_isp", isp_id = ispId, isp_name = ispName,
    }), "register " .. ispId).provider_allocations

    sim:addNode(ispId, "isp")
    assertOk(sim:input(ispId, {
      kind = "configure",
      settings = {
        isp_id = ispId, isp_name = ispName, world_id = "world-overworld",
        central_id = "central-main", provider_allocations = allocation,
      },
    }), "configure " .. ispId)
    sim:connect("central", ispId, "rel-central-" .. ispId)

    for networkIndex = 1, networkCount do
      local routerId = "router-" .. ispIndex .. "-" .. networkIndex
      local networkId = "network-" .. ispIndex .. "-" .. networkIndex
      local networkName = "net" .. ispIndex .. "x" .. networkIndex

      sim:addNode(routerId, "router")
      assertOk(sim:input(routerId, {
        kind = "configure",
        settings = {
          router_id = routerId, customer_network_id = networkId,
          customer_network_name = networkName, router_address = "192.168.1.1",
          pool_first = POOL_FIRST, pool_last = POOL_LAST,
          isp_id = ispId, isp_name = ispName, world_id = "world-overworld",
        },
      }), "configure " .. routerId)

      assertOk(sim:input(ispId, {
        kind = "register_router", router_id = routerId,
        customer_network_id = networkId, customer_network_name = networkName,
      }), "register " .. routerId)
      sim:connect(ispId, routerId, "rel-" .. ispId .. "-" .. routerId)

      for computerIndex = 1, computerCount do
        local computerId = "computer-" .. ispIndex .. "-" .. networkIndex .. "-" .. computerIndex
        local hostname = "host" .. computerIndex
        sim:addNode(computerId, "computer")
        local binding = assertOk(sim:input(routerId, {
          kind = "bind_computer", computer_id = computerId, hostname = hostname,
        }), "bind " .. computerId)

        assertOk(sim:input(computerId, {
          kind = "configure",
          settings = {
            computer_id = computerId, hostname = hostname, address = binding.address,
            customer_network_id = networkId, customer_network_name = networkName,
            router_id = routerId, router_address = "192.168.1.1",
            dns_address = "192.168.1.1", isp_id = ispId, isp_name = ispName,
            world_id = "world-overworld",
          },
        }), "configure " .. computerId)
        sim:connect(routerId, computerId, "rel-" .. computerId)

        assertOk(sim:input(routerId, {
          kind = "expose_service", computer_id = computerId, service = "probe",
        }), "expose probe on " .. computerId)

        -- Every Computer answers with its own identity, so a reply that landed
        -- on the wrong Computer is visible rather than merely suspected.
        sim:serve(computerId, "probe", function(payload)
          return core.object({
            answered_by = computerId,
            token = get(payload, "token"),
          })
        end)

        computers[#computers + 1] = {
          node = computerId, computer_id = computerId,
          customer_network_id = networkId, address = binding.address,
        }
      end
    end
  end
  return sim, computers
end

--------------------------------------------------------------------------
-- Addresses
--------------------------------------------------------------------------

test("an address is never allocated twice inside one Customer Network", function()
  local random = seed.new(seed.configured())
  local sim = simulator.new({ core = core })

  sim:addNode("router", "router")
  assertOk(sim:input("router", {
    kind = "configure",
    settings = {
      router_id = "router-probe", customer_network_id = "network-probe",
      customer_network_name = "probe", router_address = "192.168.1.1",
      pool_first = "192.168.1.2", pool_last = "192.168.1.254",
    },
  }), "configure")

  local seen = {}
  local byComputer = {}
  local joins = 0

  for step = 1, 400 do
    local action = random:nextInteger(10)
    if action <= 7 then
      -- A join, sometimes by a Computer that has joined before.
      local existing = random:nextInteger(4) == 1 and next(byComputer)
      local computerId = existing or ("computer-p" .. random:nextInteger(150))
      local outcome = sim:input("router", {
        kind = "bind_computer", computer_id = computerId, hostname = "h" .. computerId,
      })
      if outcome.result.ok then
        local address = outcome.result.address
        if byComputer[computerId] then
          assertEqual(address, byComputer[computerId],
            computerId .. " must keep the address it already had")
        else
          assertTrue(seen[address] == nil,
            "address " .. address .. " was handed out twice inside one network")
          seen[address] = computerId
          byComputer[computerId] = address
          joins = joins + 1
        end
      else
        assertEqual(outcome.result.code, "pool_exhausted", "the only expected refusal")
      end
    else
      -- A release, which is the only thing that ever frees an address.
      local computerId = next(byComputer)
      if computerId then
        local released = assertOk(sim:input("router", {
          kind = "release_binding", computer_id = computerId,
        }), "release")
        seen[released.address] = nil
        byComputer[computerId] = nil
      end
    end

    -- The router's own view must agree with ours at every step.
    local addresses = {}
    for computerId, binding in pairs(sim:state("router").bindings) do
      assertTrue(addresses[binding.address] == nil,
        "the router holds " .. binding.address .. " twice")
      addresses[binding.address] = computerId
    end
  end

  assertTrue(joins > 20, "the run exercised a meaningful number of joins")
end)

test("a Provider Allocation is never delegated twice", function()
  local sim = simulator.new({ core = core })
  sim:addNode("central", "central")
  assertOk(sim:input("central", {
    kind = "configure",
    settings = { world_id = "world-overworld", central_id = "central-main" },
  }), "configure central")

  local ranges = {}
  for index = 1, 40 do
    local allocation = assertOk(sim:input("central", {
      kind = "register_isp", isp_id = "isp-" .. index, isp_name = "isp" .. index,
    }), "register isp " .. index).provider_allocations[1]
    local range = core.ipv4.range(allocation.first, allocation.last)
    for _, existing in ipairs(ranges) do
      assertTrue(not core.ipv4.overlaps(range, existing),
        "allocation " .. allocation.first .. " overlaps one already delegated")
    end
    ranges[#ranges + 1] = range
  end
  assertEqual(#ranges, 40, "every ISP received a block")
end)

--------------------------------------------------------------------------
-- Delivery
--------------------------------------------------------------------------

test("a reply never reaches the wrong Computer across many seeded requests", function()
  local random = seed.new(seed.configured())
  local sim, computers = buildWorld(2, 3, 3)

  local requests = 0
  local remote = 0

  for step = 1, 150 do
    local from = computers[random:nextInteger(#computers)]
    local to = computers[random:nextInteger(#computers)]
    if from.node ~= to.node then
      sim:reset()
      local token = "t" .. step
      -- Half the time address the target by its overlapping RFC 1918 address
      -- rather than by identity, which is the ambiguous-looking case.
      local destination = { customer_network_id = to.customer_network_id }
      if random:nextInteger(2) == 1 then
        destination.computer_id = to.computer_id
      else
        destination.address = to.address
      end

      sim:input(from.node, {
        kind = "local_request",
        destination = destination,
        service = "probe",
        payload = core.object({ token = token }),
      })
      requests = requests + 1
      if from.customer_network_id ~= to.customer_network_id then remote = remote + 1 end

      -- Exactly one reply, at exactly the Computer that asked, from exactly the
      -- Computer that was addressed.
      local replies = sim:resultsAt(from.node, "service_response")
      assertEqual(#replies, 1, "step " .. step .. ": the requester received one reply")
      local payload = replies[1].payload
      assertEqual(get(payload, "answered_by"), to.computer_id,
        "step " .. step .. ": the wrong Computer answered")
      assertEqual(get(payload, "token"), token,
        "step " .. step .. ": the reply belongs to another request")

      for _, other in ipairs(computers) do
        if other.node ~= from.node then
          assertEqual(#sim:resultsAt(other.node, "service_response"), 0,
            "step " .. step .. ": a reply reached " .. other.node .. " as well")
        end
      end
    end
  end

  assertTrue(requests > 100, "the run exercised a meaningful number of requests")
  assertTrue(remote > 50, "and a meaningful number of them crossed networks")
end)

test("every flow closes once its reply lands, across a whole seeded run", function()
  local random = seed.new(seed.configured())
  local sim, computers = buildWorld(2, 2, 2)

  for step = 1, 60 do
    local from = computers[random:nextInteger(#computers)]
    local to = computers[random:nextInteger(#computers)]
    if from.node ~= to.node then
      sim:input(from.node, {
        kind = "local_request",
        destination = { customer_network_id = to.customer_network_id, computer_id = to.computer_id },
        service = "probe",
        payload = core.object({ token = "t" .. step }),
      })
    end
  end

  -- Nothing may be left holding state for a conversation that finished.
  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    assertEqual(engine.flows:size(), 0, name .. " still holds a NAT Flow")
    assertEqual(engine.transit:size(), 0, name .. " still holds a correlation record")
  end
end)

test("the diagnostic buffer never grows past its role's capacity", function()
  local random = seed.new(seed.configured())
  local sim, computers = buildWorld(1, 2, 2)

  for step = 1, 400 do
    local from = computers[random:nextInteger(#computers)]
    local to = computers[random:nextInteger(#computers)]
    if from.node ~= to.node then
      sim:input(from.node, {
        kind = "local_request",
        destination = { customer_network_id = to.customer_network_id, computer_id = to.computer_id },
        service = "probe",
        payload = core.object({ token = "t" .. step }),
      })
    end
  end

  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    local capacity = core.limits.EVENT_BUFFER[engine.role]
    assertTrue(engine.buffer:count() <= capacity,
      name .. " buffered " .. engine.buffer:count() .. " events, past its " .. capacity)
  end
  assertTrue(sim:engine("router-1-1").buffer.dropped > 0,
    "a busy router must show its overflow as dropped rather than growing")
end)
