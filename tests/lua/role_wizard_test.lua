-- The Customer Router setup questions.
--
-- A wizard is the one part of CraftNet an Operator types into, so what it
-- accepts matters as much as what the engine accepts. The questions and their
-- rules live apart from the terminal that asks them, which is why they can be
-- checked here without a Computer.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local routerPackage = dofile("packages/craftnet-router/files/init.lua")
  .withPackages({ protocol = protocol, core = core, runtime = runtimePackage })

local wizard = routerPackage.wizard

local function answers(overrides)
  local base = {
    customer_network_name = "home",
    router_address = "192.168.1.1",
    pool_first = "192.168.1.20",
    pool_last = "192.168.1.39",
    lan_operational_channel = 42201,
    lan_password = "correct horse battery staple",
  }
  for key, value in pairs(overrides or {}) do base[key] = value end
  return base
end

test("the wizard asks for everything a Customer Network needs", function()
  local asked = {}
  for _, question in ipairs(wizard.questions) do
    asked[question.key] = true
    assertEqual(type(question.prompt), "string", question.key .. " has a prompt")
    assertEqual(type(question.validate), "function", question.key .. " has a rule")
  end
  for _, key in ipairs({ "customer_network_name", "router_address", "pool_first",
    "pool_last", "lan_operational_channel", "lan_password" }) do
    assertTrue(asked[key], key .. " is never asked for")
  end
end)

test("a network name has to be a normalized name", function()
  assertEqual(wizard.validate("customer_network_name", "home"), "home", "a good name")
  for _, bad in ipairs({ "Home", "my home", "home-", "-home", "", "home.farm" }) do
    local value, problem = wizard.validate("customer_network_name", bad)
    assertTrue(value == nil, "'" .. bad .. "' must be refused")
    assertTrue(problem:find("lowercase", 1, true) ~= nil, "and the reason says why")
  end
end)

test("addresses have to be inside RFC 1918 space", function()
  for _, good in ipairs({ "10.0.0.1", "172.16.5.1", "192.168.1.1" }) do
    assertEqual(wizard.validate("router_address", good), good, good)
  end
  for _, bad in ipairs({ "8.8.8.8", "100.64.0.1", "192.168.1", "192.168.1.256", "router" }) do
    local value, problem = wizard.validate("router_address", bad)
    assertTrue(value == nil, "'" .. bad .. "' must be refused")
    assertTrue(problem:find("RFC 1918", 1, true) ~= nil, "and the reason says why")
  end
end)

test("a channel is a number, and it is returned as one", function()
  assertEqual(wizard.validate("lan_operational_channel", "42201"), 42201, "typed as text")
  for _, bad in ipairs({ "70000", "-1", "channel", "" }) do
    assertTrue(wizard.validate("lan_operational_channel", bad) == nil, "'" .. bad .. "'")
  end
end)

test("a LAN Password has to be long enough to be worth having", function()
  local value, problem = wizard.validate("lan_password", "short")
  assertTrue(value == nil, "a short password is refused")
  assertTrue(problem:find("passphrase", 1, true) ~= nil,
    "and the Operator is told what would be better")
  assertTrue(wizard.validate("lan_password", "correct horse battery staple") ~= nil, "a passphrase")
end)

test("the review catches the answers that only conflict together", function()
  assertTrue(wizard.review(answers()) ~= nil, "a sensible set passes")

  local value, problem = wizard.review(answers({ router_address = "192.168.1.25" }))
  assertTrue(value == nil, "a router inside its own pool is refused")
  assertTrue(problem:find("own address", 1, true) ~= nil, "and told why")

  value, problem = wizard.review(answers({ pool_first = "192.168.1.39", pool_last = "192.168.1.20" }))
  assertTrue(value == nil, "a backwards range is refused")

  local review = wizard.review(answers({ pool_first = "192.168.1.20", pool_last = "192.168.1.20" }))
  assertEqual(review.size, 1, "a pool of one is allowed, and its size is reported")
end)

test("the review reports the pool size so an Operator sees what they chose", function()
  local review = wizard.review(answers())
  assertEqual(review.size, 20, "twenty Computers")
  assertEqual(review.first, "192.168.1.20", "first")
  assertEqual(review.last, "192.168.1.39", "last")
end)

test("settings derive identities from the name the Operator chose", function()
  local settings = wizard.settings(answers())
  assertEqual(settings.router_id, "router-home", "router identity")
  assertEqual(settings.customer_network_id, "network-home", "network identity")
  assertEqual(settings.dns_address, settings.router_address,
    "a Customer Router is its own DNS as well as its gateway")
  assertEqual(settings.lan_operational_channel, 42201, "channel")
end)

test("settings the wizard produces are accepted by the engine", function()
  -- The point of the wizard is to produce something the engine will take, so
  -- the two are checked against each other rather than separately.
  local engine = core.newEngine({ role = "router" })
  local outcome = engine:handle({ kind = "configure", settings = wizard.settings(answers()) }, 0)
  assertTrue(outcome.result.ok,
    "the engine refused the wizard's own output: " .. tostring(outcome.result.message))
  assertEqual(engine.state.customer_network_name, "home", "and applied it")
end)

test("a password is never part of the settings the engine stores", function()
  local settings = wizard.settings(answers())
  for key, value in pairs(settings) do
    assertTrue(tostring(key):find("password", 1, true) == nil,
      "'" .. tostring(key) .. "' must not carry a secret into durable state")
    if type(value) == "string" then
      assertTrue(value:find("battery staple", 1, true) == nil,
        "the LAN Password leaked into " .. tostring(key))
    end
  end
end)
