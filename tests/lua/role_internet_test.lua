-- The whole World, standing up and carrying traffic.
--
-- Every node here is a real role package over a real runtime, real links, real
-- protocol, and real engines. The hierarchy is provisioned the way an Operator
-- would provision it: a bundle from the External Application, then one-time
-- tokens carried from one screen to the next, then Computers joining with a
-- LAN Password. Nothing is written into a node's state by hand.
--
-- What is being proved is scenarios 1, 3, 6, and 7: the hierarchy matches the
-- reference topology, overlapping addresses stay unambiguous, Home reaches Farm
-- around the Central Server, and the ways it can fail each fail distinctly.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local packages = { protocol = protocol, core = core, runtime = runtimePackage }

local centralPackage = dofile("packages/craftnet-central/files/init.lua").withPackages(packages)
local ispPackage = dofile("packages/craftnet-isp/files/init.lua").withPackages(packages)
local routerPackage = dofile("packages/craftnet-router/files/init.lua").withPackages(packages)
local computerPackage = dofile("packages/craftnet-computer/files/init.lua").withPackages(packages)

local fakes = require("tests.lua.support.fakes")
local lanworld = require("tests.lua.support.lanworld")

local get = rawget

-- Fixture material, not credentials: a real World Key comes from crypto/rand in
-- the Go provisioning command.
local BUNDLE = {
  world_id = "world-overworld",
  central_id = "central-main",
  gateway_url = "wss://127.0.0.1:8080/gateway",
  gateway_credential_ref = "gateway-credential",
  world_key = string.rep("a1", 32),
  gateway_credential = string.rep("b2", 32),
}

local LAN_PASSWORD = "correct horse battery staple"

local NETWORKS = {
  home = {
    name = "home", router_id = "router-home", network_id = "network-home",
    lan_channel = 42201,
    computers = { "alex-pc", "wall-display" },
  },
  farm = {
    name = "farm", router_id = "router-farm", network_id = "network-farm",
    lan_channel = 42202,
    computers = { "harvester", "silo-monitor" },
  },
}

--------------------------------------------------------------------------
-- Standing up a World
--------------------------------------------------------------------------

local World = {}
World.__index = World

local function assertOk(value, code, problem, what)
  assert(value, (what or "step") .. " failed: " .. tostring(code) .. " " .. tostring(problem))
  return value
end

-- newWorld builds every node but starts nothing talking. Each gets its own fake
-- disk, so a restart touches one node and nothing else.
local function newWorld()
  local clock = fakes.clock()
  local world = setmetatable({
    air = lanworld.new({ clock = clock, step_ms = 50 }),
    clock = clock,
    storage = {},
    nodes = {},
    order = {},
  }, World)
  return world
end

function World:disk(name)
  self.storage[name] = self.storage[name] or fakes.storage()
  return self.storage[name]
end

function World:adapters(name)
  return {
    transport = self.air:attach(name),
    clock = self.clock,
    storage = self:disk(name),
    screen = fakes.screen(),
  }
end

-- pump runs every node that is already up, alongside a driver, until the driver
-- finishes. This is what makes a blocking wizard call work: the parent is
-- serving while the child waits.
function World:pump(driver, except)
  local finished = false
  for _, name in ipairs(self.order) do
    if name ~= except then
      local node = self.nodes[name]
      self.air:spawn(name .. "-loop", function()
        while not finished do node:serve(100) end
      end)
    end
  end
  self.air:spawn("driver", function()
    driver()
    finished = true
  end)
  self.air:run()
  self.air.order = {}
end

function World:register(name, node)
  self.nodes[name] = node
  self.order[#self.order + 1] = name
  return node
end

-- provision runs scenario 1 from the top: the Central Server takes its bundle,
-- issues an ISP Enrollment Token, and the ISP spends it.
function World:provision()
  self.central = centralPackage.new({ path = "state/central", adapters = self:adapters("central") })
  assert(self.central:start())
  assertOk(self.central:provision(BUNDLE), nil, nil, "provision")
  self:register("central", self.central)

  local token = assertOk(self.central:issueToken(), nil, nil, "issue an ISP token")
  self.ispToken = token

  self.isp = ispPackage.new({ path = "state/isp", adapters = self:adapters("acme") })
  assert(self.isp:start())
  assertOk(self.isp:configure({ isp_id = "isp-acme", isp_name = "acme" }), nil, nil, "configure isp")

  local enrolled
  self:pump(function()
    local value, code, problem = self.isp:enrollUpstream({ token = token, timeout_ms = 4000 })
    enrolled = assertOk(value, code, problem, "enroll the ISP")
    assertOk(self.isp:connectUpstream())
  end)
  self:register("acme", self.isp)
  self.ispEnrollment = enrolled
  return enrolled
end

-- addNetwork runs a Customer Router through its own wizard, then spends a
-- Router Enrollment Token to put it on CraftNet.
function World:addNetwork(key)
  local spec = NETWORKS[key]
  local node = routerPackage.new({ path = "state/router", adapters = self:adapters(spec.router_id) })
  assert(node:start())
  assertOk(node:configure({
    router_id = spec.router_id,
    customer_network_id = spec.network_id,
    customer_network_name = spec.name,
    router_address = "192.168.1.1",
    pool_first = "192.168.1.20",
    pool_last = "192.168.1.39",
    lan_operational_channel = spec.lan_channel,
    world_id = BUNDLE.world_id,
  }, LAN_PASSWORD), nil, nil, "configure " .. spec.router_id)

  local token = assertOk(self.isp:issueToken(), nil, nil, "issue a Router token")
  local enrolled
  self:pump(function()
    local value, code, problem = node:enrollUpstream({
      token = token, isp_name = "acme", timeout_ms = 4000,
    })
    enrolled = assertOk(value, code, problem, "enroll " .. spec.router_id)
    assertOk(node:connectUpstream())
  end)

  self:register(spec.router_id, node)
  self[key] = node
  return enrolled
end

function World:addComputer(key, hostname, number)
  local spec = NETWORKS[key]
  local node = computerPackage.new({
    path = "state/computer",
    computer_number = number,
    adapters = self:adapters(hostname),
    -- The application answers whatever service it is asked for, and says who
    -- answered, so a reply that reached the wrong Computer would be visible
    -- rather than merely suspected.
    application = setmetatable({}, {
      __index = function()
        return function(payload)
          return protocol.object({ answered_by = hostname, token = get(payload, "token") })
        end
      end,
    }),
  })
  assert(node:start())

  local joined
  self:pump(function()
    local value, code, problem = node:joinNetwork({
      password = LAN_PASSWORD,
      hostname = hostname,
      customer_network_name = spec.name,
      timeout_ms = 4000,
    })
    joined = assertOk(value, code, problem, "join " .. hostname)
    assertOk(node:connect())
  end)
  self:register(hostname, node)
  self.nodes[hostname] = node
  return joined, node
end

-- expose publishes a service, which is the only way a Computer becomes
-- reachable from another Customer Network.
function World:expose(key, computerId, service)
  local spec = NETWORKS[key]
  local outcome = self.nodes[spec.router_id].runtime:submit({
    kind = "expose_service", computer_id = computerId, service = service,
  })
  assert(outcome.result.ok, "expose failed: " .. tostring(outcome.result.message))
end

-- ask sends one request from a Computer and waits for the answer.
function World:ask(from, destination, service, payload)
  local node = self.nodes[from]
  local answer
  -- The asking Computer is served by the driver itself, so nothing else is
  -- pulling frames out from under it.
  self:pump(function()
    node:request(destination, service, payload or protocol.object())
    for _ = 1, 60 do
      local outcome = node:serve(200)
      if outcome and outcome.result
        and (outcome.result.payload ~= nil or outcome.result.ok == false) then
        answer = outcome.result
        break
      end
    end
  end, from)
  return answer
end

-- fullWorld is the reference topology, stood up end to end.
local function fullWorld()
  local world = newWorld()
  world:provision()
  world:addNetwork("home")
  world:addNetwork("farm")
  world.bindings = {}
  world.bindings["alex-pc"] = world:addComputer("home", "alex-pc", 1)
  world.bindings["wall-display"] = world:addComputer("home", "wall-display", 2)
  world.bindings["harvester"] = world:addComputer("farm", "harvester", 3)
  world.bindings["silo-monitor"] = world:addComputer("farm", "silo-monitor", 4)

  world:expose("farm", world.bindings["harvester"].computer_id, "harvester.status")
  world:expose("home", world.bindings["wall-display"].computer_id, "display.update")
  return world
end

--------------------------------------------------------------------------
-- Scenario 1 -- provision the hierarchy
--------------------------------------------------------------------------

test("scenario 1: the World is provisioned from a bundle, not from thin air", function()
  local world = newWorld()
  world:provision()

  local state = world.central:state()
  assertEqual(state.world_id, "world-overworld", "World identity")
  assertEqual(state.central_id, "central-main", "Central Server identity")

  -- The secrets are held, and nothing about them reaches durable state.
  assertTrue(world.central.secrets:get("world-key") ~= nil, "the World Key is held")
  assertTrue(world.central.secrets:get("gateway-credential") ~= nil, "so is the Gateway Credential")
  local snapshot = world.storage.central.files["state/central.json"]
  assertTrue(snapshot:find("a1a1", 1, true) == nil, "the World Key never reaches the snapshot")
  assertTrue(snapshot:find("b2b2", 1, true) == nil, "nor the Gateway Credential")
  assertTrue(snapshot:find("gateway-credential", 1, true) ~= nil,
    "only a reference to it does")
end)

test("scenario 1: an ISP spends a one-time token and receives an allocation", function()
  local world = newWorld()
  local enrolled = world:provision()

  assertEqual(enrolled.isp_id, "isp-acme", "the ISP identity")
  assertEqual(enrolled.central_id, "central-main", "under this Central Server")
  assertEqual(#enrolled.provider_allocations, 1, "one Provider Allocation")
  assertEqual(enrolled.provider_allocations[1].first, "100.64.0.0", "from RFC 6598 space")
  assertEqual(enrolled.provider_allocations[1].last, "100.64.0.255", "a block of 256")
  assertEqual(enrolled.operational_channel, 42100, "and an Operational Channel")

  -- The Central Server's registry agrees, and the token is spent.
  assertTrue(world.central:state().isps["isp-acme"] ~= nil, "the ISP is registered")
  assertEqual(world.central:state().tokens_spent["1"], true, "the token was spent")
end)

test("scenario 1: a spent token cannot be used again", function()
  local world = newWorld()
  world:provision()

  local second = ispPackage.new({ path = "state/isp", adapters = world:adapters("bolt") })
  assert(second:start())
  assert(second:configure({ isp_id = "isp-bolt", isp_name = "bolt" }))

  local result, code
  world:pump(function()
    result, code = second:enrollUpstream({ token = world.ispToken, timeout_ms = 2000 })
  end)
  assertTrue(result == nil, "the spent token was refused")
  assertEqual(code, "authentication_failed", "and refused without saying why")
  assertTrue(world.central:state().isps["isp-bolt"] == nil, "nothing was registered")
end)

test("scenario 1: the hierarchy matches the reference topology", function()
  local world = fullWorld()
  local topology = world.central:topology()

  assertEqual(get(get(topology, "world"), "world_id"), "world-overworld", "World")
  assertEqual(#get(topology, "isps"), 1, "one ISP")
  assertEqual(get(get(topology, "isps")[1], "isp_id"), "isp-acme", "Acme")
  assertEqual(#get(topology, "routers"), 2, "two Customer Networks")

  local byNetwork = {}
  for _, entry in ipairs(get(topology, "routers")) do
    byNetwork[get(entry, "customer_network_id")] = entry
  end
  assertEqual(get(byNetwork["network-home"], "router_id"), "router-home", "Home's router")
  assertEqual(get(byNetwork["network-farm"], "router_id"), "router-farm", "Farm's router")
  assertTrue(get(byNetwork["network-home"], "router_provider_address")
    ~= get(byNetwork["network-farm"], "router_provider_address"),
    "their Provider Addresses differ")

  for _, entry in ipairs(get(topology, "network_statuses")) do
    assertEqual(get(entry, "status"), "enabled", "every Customer Network starts enabled")
  end
end)

test("scenario 1: a bypass message is ignored", function()
  local world = fullWorld()
  -- A Computer shouting straight at the Central Server's discovery channel.
  local stranger = world.air:attach("stranger")
  stranger:open(42000)
  local before = world.central:state().revision

  world:pump(function()
    stranger:transmit(42000, 42000, "not even a CraftNet frame")
    world.central:serve(200)
  end)
  assertEqual(world.central:state().revision, before, "nothing about the World changed")
end)

--------------------------------------------------------------------------
-- Scenario 3 -- overlapping addressing, through the whole hierarchy
--------------------------------------------------------------------------

test("scenario 3: both Customer Networks hold 192.168.1.20 and .21", function()
  local world = fullWorld()
  assertEqual(world.bindings["alex-pc"].address, "192.168.1.20", "alex-pc")
  assertEqual(world.bindings["wall-display"].address, "192.168.1.21", "wall-display")
  assertEqual(world.bindings["harvester"].address, "192.168.1.20", "harvester")
  assertEqual(world.bindings["silo-monitor"].address, "192.168.1.21", "silo-monitor")

  -- The Central Server tells them apart by identity, never by address.
  local routes = world.central:state().routes
  assertTrue(routes["network-home"] ~= nil and routes["network-farm"] ~= nil, "both routes exist")
  assertTrue(routes["network-home"].router_provider_address
    ~= routes["network-farm"].router_provider_address, "with distinct Provider Addresses")
end)

--------------------------------------------------------------------------
-- Scenario 6 -- route between Customer Networks
--------------------------------------------------------------------------

test("scenario 6: Home reaches Farm around the Central Server and the reply comes home", function()
  local world = fullWorld()
  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "t1" }))

  assertTrue(answer ~= nil and answer.payload ~= nil, "the reply arrived")
  assertEqual(get(answer.payload, "answered_by"), "harvester", "from the intended Computer")
  assertEqual(get(answer.payload, "token"), "t1", "carrying this request's own token")

  -- The Central Server is on the path, even though both Customer Networks
  -- belong to the same ISP: it is the only interconnection point.
  local centralForwarded = false
  for _, event in ipairs(world.central.runtime.telemetry) do
    if get(event, "kind") == "service_request" and get(event, "outcome") == "delivered_remote" then
      centralForwarded = true
      assertEqual(get(event, "customer_network_id"), "network-farm", "towards Farm")
    end
  end
  assertTrue(centralForwarded, "the Central Server forwarded the request")

  local homeRecorded = false
  for _, event in ipairs(world.nodes["router-home"].runtime.telemetry) do
    if get(event, "outcome") == "delivered_remote" then homeRecorded = true end
  end
  assertTrue(homeRecorded, "Home's router recorded a remote delivery")

  -- Nothing is left holding state for a conversation that finished.
  assertEqual(world.central.runtime.engine.transit:size(), 0,
    "the Central Server kept no correlation once the reply passed")
  assertEqual(world.isp.runtime.engine.transit:size(), 0, "nor did the ISP")
  assertEqual(world.nodes["router-home"].runtime.engine.flows:size(), 0, "the source flow closed")
  assertEqual(world.nodes["router-farm"].runtime.engine.flows:size(), 0, "the destination flow closed")
end)

test("scenario 6: a reply reaches Home's .20 and not Farm's", function()
  local world = fullWorld()
  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "t2" }))
  assertTrue(answer and answer.payload, "the reply arrived at alex-pc")

  -- wall-display shares neither the request nor the reply, and silo-monitor
  -- holds the same address as alex-pc in the other network.
  for _, bystander in ipairs({ "wall-display", "silo-monitor" }) do
    local replies = 0
    for _, entry in ipairs(world.nodes[bystander].runtime.telemetry) do
      if get(entry, "kind") == "service_response" then replies = replies + 1 end
    end
    assertEqual(replies, 0, bystander .. " saw no part of it")
  end
end)

--------------------------------------------------------------------------
-- Scenario 7 -- fail closed, through the whole hierarchy
--------------------------------------------------------------------------

test("scenario 7: an unexposed remote service is refused with inbound_denied", function()
  local world = fullWorld()
  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["silo-monitor"].computer_id,
  }, "silo.read")

  assertTrue(answer ~= nil and answer.ok == false, "the request failed")
  assertEqual(answer.code, "inbound_denied", "code")
end)

test("scenario 7: a removed route fails with route_not_found", function()
  local world = fullWorld()
  local removed = world.isp.runtime:submit({
    kind = "deregister_router", router_id = "router-farm",
  })
  assertTrue(removed.result.ok, "the ISP withdrew the route")
  world:pump(function() world.central:serve(200) end)
  assertTrue(world.central:state().routes["network-farm"] == nil, "the Central route is gone")

  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status")
  assertTrue(answer ~= nil and answer.ok == false, "the request failed")
  assertEqual(answer.code, "route_not_found", "code")

  -- Withdrawing a route takes nothing durable away from the Customer Network.
  assertEqual(world.nodes["router-farm"]:state().bindings[
    world.bindings["harvester"].computer_id].address, "192.168.1.20",
    "Farm keeps its Address Bindings")
end)

test("scenario 7: a disabled Customer Network fails with network_disabled and recovers", function()
  local world = fullWorld()
  assertTrue(world.central:setNetworkStatus("network-farm", "disabled", "cmd-0001"),
    "Farm was disabled")

  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status")
  assertTrue(answer ~= nil and answer.ok == false, "the request failed")
  assertEqual(answer.code, "network_disabled", "code")

  -- Every durable registration survived, so re-enabling needs no re-enrollment.
  assertTrue(world.central:state().routes["network-farm"] ~= nil, "the route survived")
  assertTrue(world.central:setNetworkStatus("network-farm", "enabled", "cmd-0002"), "re-enabled")

  local recovered = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "t3" }))
  assertTrue(recovered ~= nil and recovered.payload ~= nil, "traffic resumed")
  assertEqual(get(recovered.payload, "token"), "t3", "with the right answer")
end)

test("scenario 7: an offline ISP makes its routes unreachable without deleting them", function()
  local world = fullWorld()
  local relationshipId = world.isp:state().relationship_id
  world.central.links:forget(relationshipId)
  world:pump(function() world.central:serve(200) end)

  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status")
  assertTrue(answer == nil or answer.ok == false, "the request did not succeed")

  -- Nothing durable was reassigned or forgotten.
  assertTrue(world.central:state().routes["network-farm"] ~= nil, "the route is still registered")
  assertTrue(world.central:state().isps["isp-acme"] ~= nil, "the ISP is still registered")
  assertEqual(world.central:state().isps["isp-acme"].provider_allocations[1].first, "100.64.0.0",
    "and still holds its allocation")
end)

--------------------------------------------------------------------------
-- Multi-ISP
--------------------------------------------------------------------------

test("every ISP receives a disjoint Provider Allocation", function()
  local world = newWorld()
  world:provision()

  local allocations = { world.ispEnrollment.provider_allocations[1] }
  for index = 2, 4 do
    local token = assert(world.central:issueToken())
    local node = ispPackage.new({
      path = "state/isp", adapters = world:adapters("isp" .. index),
    })
    assert(node:start())
    assert(node:configure({ isp_id = "isp-" .. index, isp_name = "isp" .. index }))
    local enrolled
    world:pump(function()
      enrolled = assert(node:enrollUpstream({ token = token, timeout_ms = 4000 }))
      assert(node:connectUpstream())
    end)
    world:register("isp" .. index, node)
    allocations[#allocations + 1] = enrolled.provider_allocations[1]
  end

  for left = 1, #allocations do
    for right = left + 1, #allocations do
      local a = core.ipv4.range(allocations[left].first, allocations[left].last)
      local b = core.ipv4.range(allocations[right].first, allocations[right].last)
      assertTrue(not core.ipv4.overlaps(a, b),
        allocations[left].first .. " overlaps " .. allocations[right].first)
    end
  end
  assertEqual(#allocations, 4, "four ISPs, four disjoint blocks")
end)

test("no ISP can register a route in another ISP's name", function()
  local world = fullWorld()
  local token = assert(world.central:issueToken())
  local bolt = ispPackage.new({ path = "state/isp", adapters = world:adapters("bolt") })
  assert(bolt:start())
  assert(bolt:configure({ isp_id = "isp-bolt", isp_name = "bolt" }))
  world:pump(function()
    assert(bolt:enrollUpstream({ token = token, timeout_ms = 4000 }))
    assert(bolt:connectUpstream())
  end)
  world:register("bolt", bolt)

  -- Bolt claims Home, which Acme owns.
  local outcome = world.central.runtime:submit({
    kind = "message",
    relationship_id = bolt:state().relationship_id,
    message = {
      kind = "route_register", request_id = "forged-1",
      body = protocol.object({
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-home", router_provider_address = "100.64.1.5",
        isp_id = "isp-bolt", revision = 1,
      }),
    },
  })
  assertTrue(not outcome.result.ok, "the claim was refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
  assertEqual(world.central:state().routes["network-home"].isp_id, "isp-acme",
    "Acme keeps the route")
end)
