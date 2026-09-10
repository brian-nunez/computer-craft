-- The tested scale and the reference load.
--
-- Milestone 8's gate is a set of numbers rather than a set of paths: 1,685
-- entities, 10,000 seeded operations, 1,000 deterministic mixed requests, 64
-- outstanding requests on one relationship and `busy` for the 65th, and rolling
-- buffers that never grow past 100, 500, and 2,000 events.
--
-- Every number here is the v1 *tested* scale. It is not an architectural
-- maximum, and the release notes say so rather than letting a passing test be
-- read as a capacity claim.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local simulator = require("tests.lua.support.simulator")
local reference = require("tests.lua.support.reference")
local seed = require("tests.lua.support.seed")

local get = rawget

-- The scale fixture from the verification design: four ISPs, twenty Customer
-- Routers each, twenty Computers each.
local ISPS, ROUTERS_PER_ISP, COMPUTERS_PER_ROUTER = 4, 20, 20
local ENTITIES = 1 + ISPS + (ISPS * ROUTERS_PER_ISP)
  + (ISPS * ROUTERS_PER_ISP * COMPUTERS_PER_ROUTER)

-- Every Customer Network uses the identical RFC 1918 pool on purpose. Reuse is
-- the normal case in CraftNet, not an edge one.
local POOL_FIRST, POOL_LAST = "192.168.1.20", "192.168.1.39"

local function assertOk(outcome, what)
  assert(outcome.result.ok,
    what .. " failed: " .. tostring(outcome.result.code) .. " " .. tostring(outcome.result.message))
  return outcome.result
end

--------------------------------------------------------------------------
-- The scale fixture
--------------------------------------------------------------------------

-- buildScaleWorld stands the whole thing up through real state transitions.
-- Nothing is written into an engine by hand: every allocation, route, binding,
-- and address below was decided by craftnet-core.
local function buildScaleWorld()
  local sim = simulator.new({ core = core })
  local computers, routers, allocations = {}, {}, {}

  sim:addNode("central", "central")
  assertOk(sim:input("central", {
    kind = "configure",
    settings = { world_id = "world-overworld", central_id = "central-main" },
  }), "configure central")

  for ispIndex = 1, ISPS do
    local ispId = "isp-" .. ispIndex
    local ispName = "isp" .. ispIndex
    local allocation = assertOk(sim:input("central", {
      kind = "register_isp", isp_id = ispId, isp_name = ispName,
    }), "register " .. ispId).provider_allocations
    allocations[ispId] = allocation

    sim:addNode(ispId, "isp")
    assertOk(sim:input(ispId, {
      kind = "configure",
      settings = {
        isp_id = ispId, isp_name = ispName, world_id = "world-overworld",
        central_id = "central-main", provider_allocations = allocation,
      },
    }), "configure " .. ispId)
    sim:connect("central", ispId, "rel-central-" .. ispId)

    for routerIndex = 1, ROUTERS_PER_ISP do
      local routerId = "router-" .. ispIndex .. "-" .. routerIndex
      local networkId = "network-" .. ispIndex .. "-" .. routerIndex
      local networkName = "net" .. ispIndex .. "x" .. routerIndex

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
      sim:connect(ispId, routerId, "rel-" .. routerId)
      routers[#routers + 1] = { node = routerId, customer_network_id = networkId, isp_id = ispId }

      for computerIndex = 1, COMPUTERS_PER_ROUTER do
        local computerId = "pc-" .. ispIndex .. "-" .. routerIndex .. "-" .. computerIndex
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
        -- on the wrong one is visible rather than merely suspected.
        sim:serve(computerId, "probe", function(payload)
          return core.object({ answered_by = computerId, token = get(payload, "token") })
        end)

        computers[#computers + 1] = {
          node = computerId, computer_id = computerId, hostname = hostname,
          customer_network_id = networkId, address = binding.address,
          router = routerId, isp_id = ispId,
        }
      end
    end
  end
  return sim, computers, routers, allocations
end

--------------------------------------------------------------------------
-- Standing it up
--------------------------------------------------------------------------

test("the tested scale stands up as 1,685 entities", function()
  local sim, computers, routers = buildScaleWorld()

  assertEqual(ENTITIES, 1685, "the fixture is the one the verification design names")
  assertEqual(#computers, ISPS * ROUTERS_PER_ISP * COMPUTERS_PER_ROUTER, "Computers")
  assertEqual(#routers, ISPS * ROUTERS_PER_ISP, "Customer Routers")

  local central = sim:state("central")
  local ispCount = 0
  for _ in pairs(central.isps) do ispCount = ispCount + 1 end
  assertEqual(ispCount, ISPS, "registered ISPs")

  local routeCount = 0
  for _ in pairs(central.routes) do routeCount = routeCount + 1 end
  assertEqual(routeCount, ISPS * ROUTERS_PER_ISP, "exact routes, one per Customer Network")
end)

test("every ISP holds a disjoint Provider Allocation at scale", function()
  local _, _, _, allocations = buildScaleWorld()

  local ranges = {}
  for ispId, allocation in pairs(allocations) do
    for _, range in ipairs(allocation) do
      ranges[#ranges + 1] = {
        isp_id = ispId,
        first = core.ipv4.toNumber(range.first),
        last = core.ipv4.toNumber(range.last),
      }
    end
  end
  table.sort(ranges, function(left, right) return left.first < right.first end)

  for index = 2, #ranges do
    assertTrue(ranges[index].first > ranges[index - 1].last,
      ranges[index].isp_id .. " overlaps " .. ranges[index - 1].isp_id)
  end
  assertEqual(#ranges, ISPS, "one block each")
end)

test("every Customer Network reuses the identical RFC 1918 pool", function()
  local _, computers = buildScaleWorld()

  -- The same address appears once per Customer Network and is never ambiguous,
  -- because a network identity always travels with it.
  local holdersOf = {}
  for _, computer in ipairs(computers) do
    holdersOf[computer.address] = holdersOf[computer.address] or {}
    local seen = holdersOf[computer.address]
    assertTrue(seen[computer.customer_network_id] == nil,
      computer.address .. " was handed out twice inside " .. computer.customer_network_id)
    seen[computer.customer_network_id] = computer.computer_id
  end

  local shared = holdersOf[POOL_FIRST]
  local count = 0
  for _ in pairs(shared) do count = count + 1 end
  assertEqual(count, ISPS * ROUTERS_PER_ISP,
    "every Customer Network holds the first address of the same pool")
end)

test("a full accepted topology stays inside the protocol's entity limit", function()
  local sim = buildScaleWorld()
  local topology = assertOk(sim:input("central", { kind = "topology" }), "topology").topology

  local counted = #get(topology, "isps") + #get(topology, "routers")
    + #get(topology, "computers") + #get(topology, "network_statuses")
  assertTrue(counted <= protocol.limits.TOPOLOGY_ENTITIES,
    "a topology snapshot of " .. counted .. " entities exceeds the "
      .. protocol.limits.TOPOLOGY_ENTITIES .. " the wire accepts")

  local ok, problem = protocol.conformance.schema.validateBody("topology_snapshot", topology)
  assertTrue(ok, "the snapshot is a valid topology_snapshot: " .. tostring(problem))
end)

--------------------------------------------------------------------------
-- 10,000 seeded operations
--------------------------------------------------------------------------

test("10,000 seeded operations keep every route and every reply exact", function()
  local random = seed.new(seed.configured())
  local sim, computers = buildScaleWorld()

  local total, local_, remote, resolved = 0, 0, 0, 0

  for step = 1, 10000 do
    local from = computers[random:nextInteger(#computers)]
    local to = computers[random:nextInteger(#computers)]
    if from.node ~= to.node then
      sim:reset()
      local token = "t" .. step

      if step % 10 == 0 then
        -- A name lookup, mixed in among the requests.
        sim:input(from.node, {
          kind = "resolve",
          name = to.hostname .. "." .. "net"
            .. string.match(to.customer_network_id, "network%-(%d+)%-") .. "x"
            .. string.match(to.customer_network_id, "network%-%d+%-(%d+)")
            .. "." .. to.isp_id:gsub("isp%-", "isp") .. ".craft",
        })
        local answer = sim:lastResultAt(from.node, "dns_result")
        if answer and answer.ok then resolved = resolved + 1 end
      else
        -- Half the time address the target by its overlapping RFC 1918 address
        -- rather than by identity: the ambiguous-looking case.
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

        local replies = sim:resultsAt(from.node, "service_response")
        assertEqual(#replies, 1, "step " .. step .. ": exactly one reply reached the requester")
        local payload = replies[1].payload
        assertEqual(get(payload, "answered_by"), to.computer_id,
          "step " .. step .. ": the wrong Computer answered")
        assertEqual(get(payload, "token"), token,
          "step " .. step .. ": the reply belongs to another request")

        total = total + 1
        if from.customer_network_id == to.customer_network_id then
          local_ = local_ + 1
        else
          remote = remote + 1
        end
      end
    end
  end

  assertTrue(total > 8000, "the run exercised " .. total .. " requests")
  assertTrue(local_ > 0, "some stayed inside one Customer Network")
  assertTrue(remote > 8000, "and most crossed one, which is the hard case")
  assertTrue(resolved > 0, "name resolution was exercised too")

  -- Nothing may still be holding state for a conversation that finished.
  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    assertEqual(engine.flows:size(), 0, name .. " still holds a NAT Flow")
    assertEqual(engine.transit:size(), 0, name .. " still holds a correlation record")
  end
end)

--------------------------------------------------------------------------
-- The 1,000-request reference load
--------------------------------------------------------------------------

test("1,000 mixed requests on the reference topology leave nothing behind", function()
  local random = seed.new(seed.configured())
  local sim = reference.build(core)

  local sources = {
    { node = "alex-pc", network = "network-home" },
    { node = "wall-display", network = "network-home" },
    { node = "harvester", network = "network-farm" },
    { node = "silo-monitor", network = "network-farm" },
  }
  -- Each service echoes one field of its payload, so a reply can be tied back
  -- to the exact request that caused it.
  local targets = {
    { node = "wall-display", network = "network-home", computer_id = "computer-home-display",
      service = "display.update", carries = "text", echoes = "shown" },
    { node = "harvester", network = "network-farm", computer_id = "computer-farm-harvester",
      service = "harvester.status", carries = "asked", echoes = "bushels" },
  }

  local seenLocal, seenRemote, external = 0, 0, 0

  for step = 1, 1000 do
    sim:reset()
    local from = sources[random:nextInteger(#sources)]
    local to = targets[random:nextInteger(#targets)]

    if step % 25 == 0 then
      -- The external leg. With no Gateway Session wired, this is exactly what a
      -- stopped External Application looks like: the call fails and nothing
      -- else in the World is affected.
      local outcome = sim:input("central", {
        kind = "external_request",
        customer_network_id = from.network,
        computer_id = "computer-home-alex",
        local_address = "192.168.1.20",
        operation = "test.identity",
        payload = core.object({}),
      })
      assertTrue(outcome.result.ok, "step " .. step .. ": the call was forwarded")
      external = external + 1
    elseif from.node ~= to.node then
      local token = "t" .. step
      local payload = core.object({})
      rawset(payload, to.carries, token)
      sim:input(from.node, {
        kind = "local_request",
        destination = { customer_network_id = to.network, computer_id = to.computer_id },
        service = to.service,
        payload = payload,
      })

      -- Exactly one terminal result, at exactly the Computer that asked.
      local replies = sim:resultsAt(from.node, "service_response")
      assertEqual(#replies, 1, "step " .. step .. ": one terminal result, not two")
      if to.carries == "text" then
        assertEqual(get(replies[1].payload, "shown"), token,
          "step " .. step .. ": the reply belongs to another request")
      else
        assertEqual(get(replies[1].payload, "asked"), token,
          "step " .. step .. ": the reply belongs to another request")
      end

      for _, other in ipairs(sources) do
        if other.node ~= from.node then
          assertEqual(#sim:resultsAt(other.node, "service_response"), 0,
            "step " .. step .. ": a reply also reached " .. other.node)
        end
      end

      if from.network == to.network then seenLocal = seenLocal + 1 else seenRemote = seenRemote + 1 end

      -- Telemetry carries metadata and never a payload. The token is the
      -- canary: it exists only inside the payload, so finding it anywhere in an
      -- event would mean a payload had leaked into telemetry.
      for _, node in ipairs(sim.order) do
        for _, event in ipairs(sim:eventsAt(node)) do
          for key, value in pairs(event) do
            assertTrue(value ~= token,
              "step " .. step .. ": " .. node .. " leaked the payload into " .. tostring(key))
            assertTrue(key ~= "payload" and key ~= "body",
              "step " .. step .. ": " .. node .. " recorded a " .. tostring(key))
          end
        end
      end
    end
  end

  assertTrue(seenLocal > 0 and seenRemote > 0 and external > 0,
    "the load was mixed: " .. seenLocal .. " local, " .. seenRemote .. " remote, "
      .. external .. " external")

  -- Past the idle limit, every flow is forgotten rather than kept.
  sim:advance(core.limits.FLOW_IDLE_MS + 1000)
  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    assertEqual(engine.flows:size(), 0, name .. " still holds a NAT Flow")
    assertEqual(engine.transit:size(), 0, name .. " still holds a correlation record")
  end
end)

--------------------------------------------------------------------------
-- Bounds
--------------------------------------------------------------------------

test("a burst of 64 is accepted on one relationship and the 65th is busy", function()
  local sim = reference.build(core)
  local capacity = protocol.limits.RELATIONSHIP_IN_FLIGHT

  -- Nothing answers this service, so every request stays outstanding and the
  -- capacity really is concurrent rather than serialised.
  local function burst(token)
    return sim:input("alex-pc", {
      kind = "local_request",
      destination = { customer_network_id = "network-home", computer_id = "computer-home-display" },
      service = "nobody.answers",
      payload = core.object({ text = token }),
    })
  end

  local accepted = 0
  for index = 1, capacity do
    local outcome = burst("burst" .. index)
    assertTrue(outcome.result.ok,
      "request " .. index .. " of " .. capacity .. " was refused: " .. tostring(outcome.result.code))
    accepted = accepted + 1
  end
  assertEqual(accepted, 64, "a burst of 64 is accepted")

  local refused = burst("burst65")
  assertTrue(not refused.result.ok, "the 65th concurrent request must not be accepted")
  assertEqual(refused.result.code, "busy", "the 65th receives busy")

  -- Refusing is not the same as dropping: what was accepted is still there, and
  -- it is bounded.
  local engine = sim:engine("alex-pc")
  assertEqual(engine.transit:size(), capacity, "exactly the capacity is held")
  assertEqual(engine.transit:capacityOf(), capacity, "and the bound is the protocol's")

  -- Past the idle limit the whole burst is forgotten and the relationship is
  -- usable again, rather than being wedged by one silent peer.
  sim:advance(core.limits.FLOW_IDLE_MS + 1000)
  assertEqual(engine.transit:size(), 0, "the abandoned burst expired")
  local recovered = burst("after")
  assertTrue(recovered.result.ok, "the relationship recovered on its own")
end)

test("rolling diagnostic buffers never exceed 100, 500, and 2,000 events", function()
  assertEqual(core.limits.EVENT_BUFFER.router, 100, "router capacity")
  assertEqual(core.limits.EVENT_BUFFER.computer, 100, "computer capacity")
  assertEqual(core.limits.EVENT_BUFFER.isp, 500, "ISP capacity")
  assertEqual(core.limits.EVENT_BUFFER.central, 2000, "Central Server capacity")

  local random = seed.new(seed.configured())
  local sim = reference.build(core)
  local sources = { "alex-pc", "wall-display", "harvester", "silo-monitor" }

  for step = 1, 1200 do
    sim:reset()
    local from = sources[random:nextInteger(#sources)]
    sim:input(from, {
      kind = "local_request",
      destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
      service = "harvester.status",
      payload = core.object({ token = "t" .. step }),
    })
  end

  local overflowed = false
  for _, name in ipairs(sim.order) do
    local engine = sim:engine(name)
    local capacity = core.limits.EVENT_BUFFER[engine.role]
    assertTrue(engine.buffer:count() <= capacity,
      name .. " buffered " .. engine.buffer:count() .. " events past its " .. capacity)
    if engine.buffer.dropped > 0 then overflowed = true end
  end
  assertTrue(overflowed,
    "a busy run must show its overflow as dropped events rather than as growth")
end)

test("the wire's own bounds are the ones every role reads", function()
  -- One number, one home. A test that restated them would only prove that two
  -- copies agree with each other.
  assertEqual(protocol.limits.MODEM_FRAME_BYTES, 16 * 1024, "raw modem frame")
  assertEqual(protocol.limits.TRAFFIC_BATCH_EVENTS, 100, "traffic batch events")
  assertEqual(protocol.limits.TRAFFIC_BATCH_BYTES, 128 * 1024, "traffic batch bytes")
  assertEqual(protocol.limits.GATEWAY_IN_FLIGHT, 256, "gateway in flight")
  assertEqual(protocol.limits.RELATIONSHIP_IN_FLIGHT, 64, "relationship in flight")
  assertEqual(protocol.limits.TOPOLOGY_ENTITIES, 2000, "topology entities")
  assertEqual(core.limits.FLOW_IDLE_MS, 30000, "NAT Flow idle limit")
end)
