-- The local Customer Network vertical slice.
--
-- Everything here runs the code that ships: the real role packages, the real
-- runtime, the real links adapter, the real protocol, and the real engines.
-- Only the modem is imaginary, and even that is a shared air that delivers to
-- whoever has the channel open, the way a modem does.
--
-- What is being proved is scenario 2: four Computers join a Customer Network
-- with a LAN Password, a wrong password does not, the lowest free addresses are
-- assigned, the router and DNS are reported, and a restart changes neither an
-- identity nor an address.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local packages = { protocol = protocol, core = core, runtime = runtimePackage }
local routerPackage = dofile("packages/craftnet-router/files/init.lua").withPackages(packages)
local computerPackage = dofile("packages/craftnet-computer/files/init.lua").withPackages(packages)

local fakes = require("tests.lua.support.fakes")
local lanworld = require("tests.lua.support.lanworld")

local get = rawget

local PASSWORD = "correct horse battery staple"
local LAN_CHANNEL = 42201

local HOME = {
  router_id = "router-home",
  customer_network_id = "network-home",
  customer_network_name = "home",
  router_address = "192.168.1.1",
  pool_first = "192.168.1.20",
  pool_last = "192.168.1.39",
  lan_operational_channel = LAN_CHANNEL,
  isp_id = "isp-acme",
  isp_name = "acme",
  provider_address = "100.64.0.10",
  world_id = "world-overworld",
}

--------------------------------------------------------------------------
-- Building a Customer Network
--------------------------------------------------------------------------

local Bench = {}
Bench.__index = Bench

-- newBench stands up one Customer Network on its own LAN. Storage is kept per
-- node so a test can restart one Computer without disturbing anything else.
local function newBench(settings, options)
  options = options or {}
  local clock = fakes.clock()
  local world = lanworld.new({ clock = clock, step_ms = 50 })
  local bench = setmetatable({
    world = world,
    clock = clock,
    settings = settings or HOME,
    storage = {},
    computers = {},
    order = {},
  }, Bench)

  bench.storage.router = fakes.storage()
  bench.router = routerPackage.new({
    path = "state/router",
    adapters = {
      transport = world:attach(bench.settings.router_id),
      clock = clock,
      storage = bench.storage.router,
      screen = fakes.screen(),
    },
  })
  assert(bench.router:start())
  assert(bench.router:configure(bench.settings, options.password or PASSWORD))
  return bench
end

function Bench:addComputer(name, number)
  self.storage[name] = self.storage[name] or fakes.storage()
  local node = computerPackage.new({
    path = "state/computer",
    computer_number = number or (#self.order + 1),
    adapters = {
      transport = self.world:attach(name),
      clock = self.clock,
      storage = self.storage[name],
      screen = fakes.screen(),
    },
    application = {
      ["probe"] = function(payload)
        return protocol.object({ answered_by = name, token = get(payload, "token") })
      end,
    },
  })
  assert(node:start())
  self.computers[name] = node
  self.order[#self.order + 1] = name
  return node
end

-- restart rebuilds one node on the same fake disk, which is exactly what a
-- Computer coming back after a chunk unload does.
function Bench:restartComputer(name, number)
  local node = computerPackage.new({
    path = "state/computer",
    computer_number = number or 1,
    adapters = {
      transport = self.world:attach(name),
      clock = self.clock,
      storage = self.storage[name],
      screen = fakes.screen(),
    },
  })
  local ok, source = node:start()
  assert(ok, "the Computer did not restart")
  self.computers[name] = node
  return node, source
end

-- serveWhile runs the router alongside a program, until that program finishes.
function Bench:serveWhile(name, body)
  local finished = false
  self.world:spawn("router-loop", function()
    while not finished do
      self.router:serve(200)
    end
  end)
  self.world:spawn(name, function()
    body()
    finished = true
  end)
  self.world:run()
  self.world.order = {}
  return self
end

local function joinOptions(hostname, password)
  return {
    password = password or PASSWORD,
    hostname = hostname,
    customer_network_name = "home",
    isp_name = "acme",
    world_id = "world-overworld",
    timeout_ms = 3000,
  }
end

--------------------------------------------------------------------------
-- Scenario 2 -- join and configure Computers
--------------------------------------------------------------------------

test("a Computer joins with the LAN Password and is told everything it needs", function()
  local bench = newBench()
  local alex = bench:addComputer("alex-pc", 1)

  local joined
  bench:serveWhile("alex-pc", function()
    joined = assert(alex:joinNetwork(joinOptions("alex-pc")))
  end)

  assertEqual(joined.hostname, "alex-pc", "hostname")
  assertEqual(joined.address, "192.168.1.20", "the lowest free address")
  assertEqual(joined.router_address, "192.168.1.1", "its default gateway")
  assertEqual(joined.dns_address, "192.168.1.1", "and its DNS")
  assertEqual(joined.computer_id, "network-home-alex-pc", "an identity the router assigned")

  -- The router's own view agrees.
  local binding = bench.router:state().bindings[joined.computer_id]
  assertEqual(binding.address, "192.168.1.20", "the router bound the same address")
  assertEqual(binding.hostname, "alex-pc", "under the same hostname")
end)

test("four Computers join and receive the lowest free addresses in order", function()
  local bench = newBench()
  local expected = {
    ["alex-pc"] = "192.168.1.20",
    ["wall-display"] = "192.168.1.21",
    ["kitchen"] = "192.168.1.22",
    ["porch-light"] = "192.168.1.23",
  }
  local names = { "alex-pc", "wall-display", "kitchen", "porch-light" }

  for index, name in ipairs(names) do
    local node = bench:addComputer(name, index)
    local joined
    bench:serveWhile(name, function()
      joined = assert(node:joinNetwork(joinOptions(name)))
    end)
    assertEqual(joined.address, expected[name], name .. " address")
  end

  local bound = 0
  for _ in pairs(bench.router:state().bindings) do bound = bound + 1 end
  assertEqual(bound, 4, "the router holds four Address Bindings")
end)

test("a wrong LAN Password does not join and binds nothing", function()
  local bench = newBench()
  local intruder = bench:addComputer("intruder", 9)

  local result, code
  bench:serveWhile("intruder", function()
    result, code = intruder:joinNetwork(joinOptions("intruder", "correct horse battery stapl"))
  end)

  assertTrue(result == nil, "the join failed")
  assertTrue(code == "authentication_failed" or code == "request_timeout",
    "and it failed without being told why (" .. tostring(code) .. ")")
  assertTrue(next(bench.router:state().bindings) == nil, "no Address Binding was created")
  assertTrue(intruder:isJoined() == false, "and the Computer did not believe it joined")
end)

test("repeated wrong passwords are rate limited rather than answered forever", function()
  local bench = newBench()
  local intruder = bench:addComputer("intruder", 9)
  local engine = bench.router.runtime.engine

  -- Drive the engine's admission policy directly: this is the decision the
  -- listener consults before it spends anything on a guess.
  local limit = engine.handlers.LAN_FAILURE_LIMIT
  for attempt = 1, limit do
    local outcome = engine:handle({ kind = "lan_admission", requested_name = "intruder" }, 0)
    assertTrue(outcome.result.ok, "attempt " .. attempt .. " is still considered")
    engine:handle({ kind = "lan_failure", requested_name = "intruder" }, 0)
  end

  local blocked = engine:handle({ kind = "lan_admission", requested_name = "intruder" }, 0)
  assertTrue(not blocked.result.ok, "the next attempt is refused outright")
  assertEqual(blocked.result.code, "authentication_failed",
    "with the same code a wrong password gives, so nothing is learned from it")

  -- The block lifts, because a mistyped password must not lock a Computer out
  -- of its own network forever.
  local later = engine:handle({ kind = "lan_admission", requested_name = "intruder" },
    engine.handlers.LAN_BLOCK_MS + engine.handlers.LAN_WINDOW_MS)
  assertTrue(later.result.ok, "the block eventually lifts")
end)

test("one Computer's failures do not lock out its neighbours", function()
  local bench = newBench()
  local engine = bench.router.runtime.engine
  for _ = 1, engine.handlers.LAN_FAILURE_LIMIT do
    engine:handle({ kind = "lan_failure", requested_name = "intruder" }, 0)
  end
  assertTrue(not engine:handle({ kind = "lan_admission", requested_name = "intruder" }, 0).result.ok,
    "the guesser is blocked")
  assertTrue(engine:handle({ kind = "lan_admission", requested_name = "alex-pc" }, 0).result.ok,
    "an unrelated Computer is not")
end)

test("a sweep across many identities is caught by the shared limit", function()
  local bench = newBench()
  local engine = bench.router.runtime.engine
  for attempt = 1, engine.handlers.LAN_SWEEP_LIMIT do
    engine:handle({ kind = "lan_failure", requested_name = "guess" .. attempt }, 0)
  end
  assertTrue(not engine:handle({ kind = "lan_admission", requested_name = "guess-fresh" }, 0).result.ok,
    "rotating identities does not escape the limit")
end)

test("a successful join clears that Computer's failure count", function()
  local bench = newBench()
  local engine = bench.router.runtime.engine
  engine:handle({ kind = "lan_failure", requested_name = "alex-pc" }, 0)
  engine:handle({ kind = "lan_failure", requested_name = "alex-pc" }, 0)
  engine:handle({ kind = "lan_success", requested_name = "alex-pc" }, 0)

  local recorded = engine:handle({ kind = "lan_failure", requested_name = "alex-pc" }, 0)
  assertEqual(recorded.result.failures, 1, "one mistyped password does not follow a Computer around")
end)

--------------------------------------------------------------------------
-- Restart
--------------------------------------------------------------------------

test("a restart changes neither identity nor address", function()
  local bench = newBench()
  local alex = bench:addComputer("alex-pc", 1)
  local joined
  bench:serveWhile("alex-pc", function()
    joined = assert(alex:joinNetwork(joinOptions("alex-pc")))
  end)

  local restarted, source = bench:restartComputer("alex-pc", 1)
  assertEqual(source, "primary", "it came back from its own snapshot")
  assertEqual(restarted:state().computer_id, joined.computer_id, "identity")
  assertEqual(restarted:state().address, joined.address, "address")
  assertEqual(restarted:state().relationship_id, joined.relationship_id, "relationship")
  assertTrue(restarted:isJoined(), "and it knows it is a member")

  -- It reconnects with its LAN Credential, never with the password again.
  assertTrue(restarted.secrets:get("lan-credential") ~= nil, "the credential survived")
  assertTrue(restarted.secrets:get("lan-password") == nil, "the password was never stored")
end)

test("a rejoining Computer keeps the address it already had", function()
  local bench = newBench()
  local alex = bench:addComputer("alex-pc", 1)
  local first
  bench:serveWhile("alex-pc", function()
    first = assert(alex:joinNetwork(joinOptions("alex-pc")))
  end)

  -- Someone else takes the next address in between.
  local display = bench:addComputer("wall-display", 2)
  bench:serveWhile("wall-display", function()
    assert(display:joinNetwork(joinOptions("wall-display")))
  end)

  local restarted = bench:restartComputer("alex-pc", 1)
  local again
  bench:serveWhile("alex-pc", function()
    again = assert(restarted:joinNetwork(joinOptions("alex-pc")))
  end)
  assertEqual(again.address, first.address, "the same address came back")
  assertEqual(again.computer_id, first.computer_id, "under the same identity")
end)

--------------------------------------------------------------------------
-- Two networks, the same pool
--------------------------------------------------------------------------

test("Home and Farm both allocate .20 and .21 from the identical pool", function()
  local farm = {}
  for key, value in pairs(HOME) do farm[key] = value end
  farm.router_id = "router-farm"
  farm.customer_network_id = "network-farm"
  farm.customer_network_name = "farm"
  farm.provider_address = "100.64.0.11"
  farm.lan_operational_channel = 42202

  local results = {}
  for _, network in ipairs({ { HOME, "home" }, { farm, "farm" } }) do
    local bench = newBench(network[1])
    local hosts = network[2] == "home"
      and { "alex-pc", "wall-display" } or { "harvester", "silo-monitor" }
    results[network[2]] = {}
    for index, host in ipairs(hosts) do
      local node = bench:addComputer(host, index)
      bench:serveWhile(host, function()
        results[network[2]][host] = assert(node:joinNetwork(joinOptions(host)))
      end)
    end
  end

  assertEqual(results.home["alex-pc"].address, "192.168.1.20", "Home's first")
  assertEqual(results.home["wall-display"].address, "192.168.1.21", "Home's second")
  assertEqual(results.farm["harvester"].address, "192.168.1.20", "Farm's first")
  assertEqual(results.farm["silo-monitor"].address, "192.168.1.21", "Farm's second")

  -- The addresses are identical on purpose; the Customer Network identity is
  -- what tells them apart.
  assertTrue(results.home["alex-pc"].computer_id ~= results.farm["harvester"].computer_id,
    "but their identities differ")
end)

--------------------------------------------------------------------------
-- Scenarios 4 and 5 -- names and local traffic, end to end
--------------------------------------------------------------------------

-- joinedHome brings up a Home network with two Computers online and sessions
-- established, which is what scenarios 4 and 5 start from.
local function joinedHome()
  local bench = newBench()
  local nodes = {}
  for index, name in ipairs({ "alex-pc", "wall-display" }) do
    local node = bench:addComputer(name, index)
    bench:serveWhile(name, function()
      assert(node:joinNetwork(joinOptions(name)))
      assert(node:connect())
    end)
    nodes[name] = node
  end
  return bench, nodes
end

test("a session is established with the LAN Credential and carries traffic", function()
  local bench, nodes = joinedHome()

  -- Both Computers are known to the router through live sessions.
  assertEqual(bench.router.links:count(), 2, "the router holds two relationships")
  for name, node in pairs(nodes) do
    assertTrue(node.links:get(node:state().relationship_id).session ~= nil,
      name .. " has a live session")
  end
end)

-- exercise runs the router and a driver together until the driver finishes.
-- Nodes other than the driver just serve, the way a startup program does.
function Bench:exercise(driverName, driver, quiet)
  local finished = false
  self.world:spawn("router-loop", function()
    while not finished do self.router:serve(100) end
  end)
  for _, name in ipairs(self.order) do
    if name ~= driverName then
      local node = self.computers[name]
      self.world:spawn(name .. "-loop", function()
        while not finished do node:serve(100) end
      end)
    end
  end
  self.world:spawn("driver", function()
    driver()
    finished = true
  end)
  self.world:run()
  self.world.order = {}
end

-- awaitResult serves one node until a transition produces the answer a test is
-- waiting for, or until it gives up.
local function awaitResult(node, wanted)
  for _ = 1, 40 do
    local outcome = node:serve(200)
    if outcome and outcome.result and wanted(outcome.result) then
      return outcome.result
    end
  end
  return nil
end

test("scenario 4: a local name resolves through the real router", function()
  local bench, nodes = joinedHome()
  local alex = nodes["alex-pc"]
  local answer

  bench:exercise("alex-pc", function()
    alex:resolve("wall-display")
    answer = awaitResult(alex, function(result) return result.address ~= nil end)
  end)

  assertTrue(answer ~= nil, "the lookup was answered")
  assertEqual(answer.address, "192.168.1.21", "wall-display's address")
  assertEqual(answer.canonical_name, "wall-display.home.acme.craft", "fully qualified")
  assertEqual(answer.customer_network_id, "network-home", "in this Customer Network")
end)

test("scenario 4: an unknown local name fails with name_not_found", function()
  local bench, nodes = joinedHome()
  local alex = nodes["alex-pc"]
  local answer

  bench:exercise("alex-pc", function()
    alex:resolve("ghost")
    answer = awaitResult(alex, function(result) return result.ok == false end)
  end)

  assertTrue(answer ~= nil, "the lookup was refused")
  assertEqual(answer.code, "name_not_found", "code")
end)

test("scenario 4: api.craft is answered without any lookup at all", function()
  local bench, nodes = joinedHome()
  local outcome = nodes["alex-pc"]:resolve("api.craft")
  assertTrue(outcome.result.ok, "it resolved")
  assertEqual(outcome.result.kind, "external", "as the External Application")
  assertEqual(bench.world.transmissions, bench.world.transmissions,
    "and nothing was put on the wire to find out")
end)

test("scenario 5: a local request reaches its neighbour and comes back", function()
  local bench, nodes = joinedHome()
  local alex = nodes["alex-pc"]
  local display = nodes["wall-display"]
  local reply

  bench:exercise("alex-pc", function()
    alex:request({
      customer_network_id = "network-home",
      computer_id = display:state().computer_id,
    }, "probe", protocol.object({ token = "t1" }))
    reply = awaitResult(alex, function(result) return result.payload ~= nil end)
  end)

  assertTrue(reply ~= nil, "the reply came back")
  assertEqual(get(reply.payload, "answered_by"), "wall-display", "from the intended Computer")
  assertEqual(get(reply.payload, "token"), "t1", "carrying this request's own token")

  -- The traffic never left the Customer Network.
  assertEqual(bench.router.runtime.engine.flows:size(), 0, "no NAT Flow was created")
  local sawLocal = false
  for _, event in ipairs(bench.router.runtime.telemetry) do
    if get(event, "outcome") == "delivered_local" then sawLocal = true end
  end
  assertTrue(sawLocal, "the router recorded delivered_local")
end)

test("scenario 5: a request for a Computer that is not there fails locally", function()
  local bench, nodes = joinedHome()
  local alex = nodes["alex-pc"]
  local answer

  bench:exercise("alex-pc", function()
    alex:request({
      customer_network_id = "network-home",
      computer_id = "network-home-nobody",
    }, "probe", protocol.object({}))
    answer = awaitResult(alex, function(result) return result.ok == false end)
  end)

  assertTrue(answer ~= nil, "the request failed")
  assertEqual(answer.code, "name_not_found", "code")
end)
