-- The reference World, stood up out of real role packages.
--
-- Every node here is a real role package over a real runtime, real links, real
-- protocol, and real engines. The hierarchy is provisioned the way an Operator
-- would provision it: a bundle from the External Application, then one-time
-- tokens carried from one screen to the next, then Computers joining with a
-- LAN Password. Nothing is written into a node's state by hand.
--
-- It lives here rather than inside one suite because more than one gate needs
-- the whole World: the internetwork scenarios, and the restart matrix.

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
    rebuild = {},
    reconnect = {},
    aliases = {},
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

-- register records a node and, with it, how to build the same node again from
-- the same disk. A restart is exactly that: a new instance over the state the
-- old one left behind, with nothing carried across in memory.
-- settle runs the whole World for a moment with nothing driving it, so a frame
-- left over from an abandoned exchange is consumed and discarded rather than
-- turning up later as the answer to a different question.
function World:settle(rounds)
  self:pump(function()
    for _ = 1, rounds or 20 do coroutine.yield() end
  end)
end

function World:register(name, node, rebuild)
  self.nodes[name] = node
  self.order[#self.order + 1] = name
  self.rebuild[name] = rebuild
  return node
end

-- restart stops a node and starts a fresh instance over its disk. Nothing is
-- handed over: whatever the new instance knows, it read back from a snapshot.
--
-- `reconnect` is the child's own reconnection call, run while the rest of the
-- World is serving, because that is what a role does at boot.
function World:restart(name)
  local rebuild = self.rebuild[name]
  assert(rebuild, "there is no way to restart " .. name)

  local node = rebuild()
  assert(node:start(), name .. " did not start from its snapshot")
  self.nodes[name] = node
  if self.aliases[name] then self[self.aliases[name]] = node end

  local reconnect = self.reconnect[name]
  if reconnect then
    self:pump(function()
      local value, code, problem = reconnect(node)
      assertOk(value, code, problem, name .. " did not come back after its restart")
    end, name)
  end
  return node
end

-- provision runs scenario 1 from the top: the Central Server takes its bundle,
-- issues an ISP Enrollment Token, and the ISP spends it.
function World:provision()
  local buildCentral = function()
    return centralPackage.new({ path = "state/central", adapters = self:adapters("central") })
  end
  self.central = buildCentral()
  assert(self.central:start())
  assertOk(self.central:provision(BUNDLE), nil, nil, "provision")
  self.aliases["central"] = "central"
  self:register("central", self.central, buildCentral)

  local token = assertOk(self.central:issueToken(), nil, nil, "issue an ISP token")
  self.ispToken = token

  local buildIsp = function()
    return ispPackage.new({ path = "state/isp", adapters = self:adapters("acme") })
  end
  self.isp = buildIsp()
  assert(self.isp:start())
  assertOk(self.isp:configure({ isp_id = "isp-acme", isp_name = "acme" }), nil, nil, "configure isp")

  local enrolled
  self:pump(function()
    local value, code, problem = self.isp:enrollUpstream({ token = token, timeout_ms = 4000 })
    enrolled = assertOk(value, code, problem, "enroll the ISP")
    assertOk(self.isp:connectUpstream())
  end)
  self.aliases["acme"] = "isp"
  self.reconnect["acme"] = function(node) return node:connectUpstream() end
  self:register("acme", self.isp, buildIsp)
  self.ispEnrollment = enrolled
  return enrolled
end

-- addNetwork runs a Customer Router through its own wizard, then spends a
-- Router Enrollment Token to put it on CraftNet.
function World:addNetwork(key)
  local spec = NETWORKS[key]
  local buildRouter = function()
    return routerPackage.new({ path = "state/router", adapters = self:adapters(spec.router_id) })
  end
  local node = buildRouter()
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

  self.aliases[spec.router_id] = key
  self.reconnect[spec.router_id] = function(fresh) return fresh:connectUpstream() end
  self:register(spec.router_id, node, buildRouter)
  self[key] = node
  return enrolled
end

function World:addComputer(key, hostname, number)
  local spec = NETWORKS[key]
  local buildComputer = function()
    return computerPackage.new({
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
  end
  local node = buildComputer()
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
  self.reconnect[hostname] = function(fresh) return fresh:connect() end
  self:register(hostname, node, buildComputer)
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
return {
  protocol = protocol,
  core = core,
  runtime = runtimePackage,
  central = centralPackage,
  isp = ispPackage,
  router = routerPackage,
  computer = computerPackage,

  BUNDLE = BUNDLE,
  LAN_PASSWORD = LAN_PASSWORD,
  NETWORKS = NETWORKS,

  -- new builds every node but starts nothing talking.
  new = newWorld,
  -- full is the reference topology, stood up end to end.
  full = fullWorld,
}
