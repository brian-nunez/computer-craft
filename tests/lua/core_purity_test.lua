-- craftnet-core performs no I/O.
--
-- This is the property the whole design rests on: if the engine could quietly
-- read a file or open a modem, then "an effect is a description" would be a
-- convention rather than a fact, and the runtime could not be the only place
-- failure is handled.
--
-- It is checked twice. First by reading the source, which catches a reference
-- that no test happens to reach. Then by running the real reference topology
-- with every I/O global replaced by a trap, which catches one that a static
-- scan would miss.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local reference = require("tests.lua.support.reference")

local CORE_DIRECTORY = "packages/craftnet-core/files"
local PROTOCOL_DIRECTORY = "packages/craftnet-protocol/files"

-- Every module that carries behaviour. `init.lua` is deliberately absent: it is
-- the package loader, and reading its own sibling files is the one filesystem
-- touch a package cannot avoid. Nothing it loads may do the same.
local CORE_MODULES = {
  "engine", "outcome", "ipv4", "names", "events", "flows",
  "role_computer", "role_router", "role_isp", "role_central",
}

local PROTOCOL_MODULES = {
  "bitops", "sha256", "hmac", "cj1", "limits", "errors",
  "schema", "keys", "frame", "handshake", "link",
}

--------------------------------------------------------------------------
-- Reading the source
--------------------------------------------------------------------------

local FORBIDDEN_PATTERNS = {
  { name = "the filesystem", pattern = "%f[%w]fs%s*%." },
  { name = "Lua file io", pattern = "%f[%w]io%s*%." },
  { name = "http", pattern = "%f[%w]http%s*%." },
  { name = "peripherals", pattern = "%f[%w]peripheral%s*%." },
  { name = "the terminal", pattern = "%f[%w]term%s*%." },
  { name = "textutils", pattern = "%f[%w]textutils%s*%." },
  { name = "the shell", pattern = "%f[%w]shell%s*%." },
  { name = "os", pattern = "%f[%w]os%s*%.%a" },
  { name = "loadfile", pattern = "%f[%w]loadfile%s*%(" },
  { name = "dofile", pattern = "%f[%w]dofile%s*%(" },
  { name = "require", pattern = "%f[%w]require%s*%(" },
}

local function sourceOf(directory, name)
  local handle = assert(io.open(directory .. "/" .. name .. ".lua", "r"),
    "cannot read " .. name)
  local text = handle:read("*a")
  handle:close()
  -- Comments mention "on disk" and similar prose; only code is being judged.
  return (string.gsub(text, "%-%-[^\n]*", ""))
end

local function assertNoIO(directory, modules, label)
  for _, name in ipairs(modules) do
    local source = sourceOf(directory, name)
    for _, forbidden in ipairs(FORBIDDEN_PATTERNS) do
      assertTrue(string.find(source, forbidden.pattern) == nil,
        label .. "/" .. name .. ".lua reaches for " .. forbidden.name)
    end
  end
end

test("no core module names a filesystem, modem, timer, http, or screen global", function()
  assertNoIO(CORE_DIRECTORY, CORE_MODULES, "craftnet-core")
end)

test("no protocol module does either", function()
  -- The core leans on the protocol package for canonical form and validation,
  -- so its purity is part of the same guarantee.
  assertNoIO(PROTOCOL_DIRECTORY, PROTOCOL_MODULES, "craftnet-protocol")
end)

test("only the package loader reads a file, and only its own siblings", function()
  local source = sourceOf(CORE_DIRECTORY, "init")
  local _, loads = string.gsub(source, "loadfile%s*%(", "")
  assertEqual(loads, 1, "craftnet-core loads files in exactly one place")
  assertTrue(string.find(source, "moduleDirectory") ~= nil,
    "and only from its own module directory")
end)

--------------------------------------------------------------------------
-- Running with the world taken away
--------------------------------------------------------------------------

local FORBIDDEN_GLOBALS = {
  "fs", "io", "http", "peripheral", "term", "textutils", "shell",
  "redstone", "disk", "commands", "os", "loadfile", "dofile", "require",
}

local function trap(name)
  return setmetatable({}, {
    __index = function(_, key)
      error("craftnet-core reached for " .. name .. "." .. tostring(key), 2)
    end,
    __call = function()
      error("craftnet-core called " .. name, 2)
    end,
  })
end

-- sandbox builds an environment holding only pure standard library, with every
-- way out replaced by something that fails loudly.
local function sandbox()
  local env = {
    assert = assert, error = error, pairs = pairs, ipairs = ipairs, next = next,
    select = select, type = type, tostring = tostring, tonumber = tonumber,
    setmetatable = setmetatable, getmetatable = getmetatable,
    rawget = rawget, rawset = rawset, rawequal = rawequal, rawlen = rawlen,
    pcall = pcall, xpcall = xpcall, unpack = unpack,
    string = string, table = table, math = math,
  }
  for _, name in ipairs(FORBIDDEN_GLOBALS) do
    env[name] = trap(name)
  end
  -- sha256 asks whether bit32 exists through _G, so _G must be the sandbox
  -- rather than the real globals.
  env._G = env
  return env
end

local function loadInto(path, env)
  if setfenv then
    -- Lua 5.1 and LuaJIT set the environment after loading.
    local chunk = assert(loadfile(path))
    setfenv(chunk, env)
    return chunk
  end
  return assert(loadfile(path, "t", env))
end

-- sandboxedCore loads every behavioural core module into the trap environment
-- and assembles the same public surface the package would.
local function sandboxedCore()
  local env = sandbox()
  local loaded = { protocol = protocol }
  local internal

  internal = function(name)
    if loaded[name] then return loaded[name] end
    local module = loadInto(CORE_DIRECTORY .. "/" .. name .. ".lua", env)(internal)
    loaded[name] = module
    return module
  end

  local events = internal("events")
  return {
    newEngine = internal("engine").new,
    object = protocol.object,
    array = protocol.array,
    null = protocol.null,
    errors = protocol.errors,
    ipv4 = internal("ipv4"),
    names = internal("names"),
    events = events,
    limits = {
      FLOW_IDLE_MS = internal("flows").IDLE_MS,
      EVENT_BUFFER = events.CAPACITY,
    },
  }
end

test("the trap environment actually traps", function()
  local env = sandbox()
  local chunk = loadInto("packages/craftnet-core/files/ipv4.lua", env)
  assertTrue(chunk ~= nil, "a clean module still loads")

  -- Prove the sandbox would notice, so a passing run below means something.
  local reaches = loadInto("tests/lua/support/reaches_for_io.lua", env)
  local ok, problem = pcall(reaches)
  assertTrue(not ok, "a module that reaches for the filesystem must fail")
  assertTrue(tostring(problem):find("fs", 1, true) ~= nil, "and say what it reached for")
end)

test("the whole reference topology runs with no I/O available at all", function()
  local core = sandboxedCore()
  local sim = reference.build(core)

  -- Addressing, DNS, routing, NAT, and exposure policy, with no filesystem, no
  -- peripheral, no timer, and no terminal in reach.
  sim:input("alex-pc", { kind = "resolve", name = "harvester.farm" })
  local answer = sim:lastResultAt("alex-pc", "dns_result")
  assertTrue(answer and answer.ok, "a name resolved across the World")
  assertEqual(answer.address, "192.168.1.20", "address")

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({ asked = "bushels" }),
  })
  local reply = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(reply and reply.ok, "a cross-network request completed")
  assertEqual(rawget(reply.payload, "bushels"), 128, "with the right answer")

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-silo" },
    service = "silo.read",
    payload = core.object({}),
  })
  assertEqual(sim:lastResultAt("alex-pc", "error").code, "inbound_denied",
    "and a failure still failed for the right reason")
end)

test("time only ever arrives as an argument, never from a clock", function()
  local core = sandboxedCore()
  local engine = core.newEngine({ role = "router" })

  -- If the engine could read a clock it would not need this, and a test could
  -- not place a flow's expiry exactly where it wants it.
  engine:handle({ kind = "configure", settings = {
    router_id = "router-home", customer_network_id = "network-home",
    customer_network_name = "home", router_address = "192.168.1.1",
    pool_first = "192.168.1.20", pool_last = "192.168.1.39",
  } }, 0)

  local outcome = engine:handle({ kind = "tick" }, 5000)
  assertTrue(outcome.result.ok, "a tick at an arbitrary moment is fine")

  local refused = engine:handle({ kind = "tick" }, -1)
  assertEqual(refused.result.code, "invalid_message", "and time is validated, not assumed")
end)
