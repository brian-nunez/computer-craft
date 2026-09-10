-- Durable state on disk.
--
-- A snapshot has one job that matters more than the others: never lose a
-- World's identities and addresses because a chunk unloaded halfway through a
-- write. These tests pull the disk out from under it at every point they can.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local fakes = require("tests.lua.support.fakes")

local snapshot = runtimePackage.snapshot

local function newStore(storage, role)
  return snapshot.new({ storage = storage, path = "state/router", role = role or "router" })
end

local function sampleState()
  return {
    role = "router",
    revision = 7,
    router_id = "router-home",
    customer_network_id = "network-home",
    customer_network_name = "home",
    router_address = "192.168.1.1",
    pool_first = "192.168.1.20",
    pool_last = "192.168.1.39",
    provider_address = "100.64.0.10",
    isp_id = "isp-acme",
    bindings = {
      ["computer-home-alex"] = {
        computer_id = "computer-home-alex", hostname = "alex-pc", address = "192.168.1.20",
      },
    },
    exposed = { ["computer-home-display"] = { ["display.update"] = true } },
  }
end

test("a saved snapshot round trips every durable field", function()
  local storage = fakes.storage()
  local store = newStore(storage)
  assertTrue(store:save(sampleState(), 1000), "saved")

  local loaded, source = store:load()
  assertEqual(source, "primary", "the primary was used")
  assertEqual(loaded.router_id, "router-home", "identity")
  assertEqual(loaded.revision, 7, "revision")
  assertEqual(loaded.bindings["computer-home-alex"].address, "192.168.1.20", "a binding")
  assertEqual(loaded.exposed["computer-home-display"]["display.update"], true, "an exposure")
  assertEqual(loaded.pool_last, "192.168.1.39", "the pool")
end)

test("saving twice leaves exactly one primary and one backup", function()
  local storage = fakes.storage()
  local store = newStore(storage)

  local first = sampleState()
  assertTrue(store:save(first, 1000), "first save")
  assertEqual(#storage:paths(), 1, "the first save leaves only a primary")

  local second = sampleState()
  second.revision = 8
  second.router_address = "192.168.1.254"
  assertTrue(store:save(second, 2000), "second save")

  local paths = storage:paths()
  assertEqual(#paths, 2, "a primary and one backup, never more")
  assertEqual(store:load().revision, 8, "the primary is the newer one")

  -- Only one generation is kept: a third save must not leave three files.
  local third = sampleState()
  third.revision = 9
  assertTrue(store:save(third, 3000), "third save")
  assertEqual(#storage:paths(), 2, "still exactly two")
end)

test("a corrupt primary falls back to the valid backup", function()
  local storage = fakes.storage()
  local store = newStore(storage)

  local first = sampleState()
  assertTrue(store:save(first, 1000), "first save")
  local second = sampleState()
  second.revision = 8
  assertTrue(store:save(second, 2000), "second save")

  storage:corrupt("state/router.json")
  local loaded, source = store:load()
  assertTrue(loaded ~= nil, "the backup was readable")
  assertEqual(source, "backup", "and it was used")
  assertEqual(loaded.revision, 7, "which holds the previous generation")
end)

test("a snapshot edited to still parse is caught by its digest", function()
  local storage = fakes.storage()
  local store = newStore(storage)
  assertTrue(store:save(sampleState(), 1000), "save")
  assertTrue(store:save(sampleState(), 2000), "save again so a backup exists")

  -- The file is still canonical JSON; only a value moved. Without a digest this
  -- would load silently with someone else's address.
  storage:tamper("state/router.json", '"192%.168%.1%.20"', '"192.168.1.99"')
  local loaded, source = store:load()
  assertEqual(source, "backup", "the tampered primary was refused")
  assertEqual(loaded.bindings["computer-home-alex"].address, "192.168.1.20", "the real address")
end)

test("both copies unreadable is reported rather than papered over", function()
  local storage = fakes.storage()
  local store = newStore(storage)
  assertTrue(store:save(sampleState(), 1000), "save")
  assertTrue(store:save(sampleState(), 2000), "save again")

  storage:corrupt("state/router.json")
  storage:corrupt("state/router.bak.json")

  local loaded, source, detail = store:load()
  assertTrue(loaded == nil, "nothing was invented to continue from")
  assertEqual(source, "unreadable", "and the failure is named")
  assertTrue(detail:find("primary", 1, true) ~= nil, "the report says which copies failed")
  assertTrue(detail:find("backup", 1, true) ~= nil, "both of them")
end)

test("a snapshot from another role is refused", function()
  local storage = fakes.storage()
  assertTrue(newStore(storage, "router"):save(sampleState(), 1000), "save as a router")

  local asIsp = snapshot.new({ storage = storage, path = "state/router", role = "isp" })
  local loaded, source = asIsp:load()
  assertTrue(loaded == nil, "an ISP will not adopt a router's state")
  assertEqual(source, "unreadable", "code")
end)

test("a failed write leaves the previous snapshot intact", function()
  local storage = fakes.storage()
  local store = newStore(storage)
  assertTrue(store:save(sampleState(), 1000), "the first save succeeds")

  storage.failWrites = true
  local ok, code = store:save(sampleState(), 2000)
  assertTrue(ok == nil, "the second save failed")
  assertEqual(code, "internal_error", "code")

  storage.failWrites = false
  assertEqual(store:load().revision, 7, "the original snapshot is still there")
end)

test("an empty array survives a restart as an array", function()
  local storage = fakes.storage()
  local store = snapshot.new({ storage = storage, path = "state/isp", role = "isp" })
  assertTrue(store:save({
    role = "isp", revision = 1, isp_id = "isp-acme", isp_name = "acme",
    provider_allocations = {},
    routers = {},
  }, 1000), "save")

  local loaded = store:load()
  assertEqual(type(loaded.provider_allocations), "table", "the field survived")
  assertEqual(#loaded.provider_allocations, 0, "and it is still empty")
end)

test("nested allocations and registries survive intact", function()
  local storage = fakes.storage()
  local store = snapshot.new({ storage = storage, path = "state/central", role = "central" })
  assertTrue(store:save({
    role = "central", revision = 12, world_id = "world-overworld", central_id = "central-main",
    isps = {
      ["isp-acme"] = {
        isp_id = "isp-acme", isp_name = "acme",
        provider_allocations = { { first = "100.64.0.0", last = "100.64.0.255" } },
      },
    },
    routes = {
      ["network-home"] = {
        customer_network_id = "network-home", customer_network_name = "home",
        router_id = "router-home", router_provider_address = "100.64.0.10", isp_id = "isp-acme",
      },
    },
    network_status = { ["network-home"] = "enabled" },
  }, 1000), "save")

  local loaded = store:load()
  assertEqual(loaded.isps["isp-acme"].provider_allocations[1].last, "100.64.0.255", "allocation")
  assertEqual(loaded.routes["network-home"].router_provider_address, "100.64.0.10", "route")
  assertEqual(loaded.network_status["network-home"], "enabled", "status")
end)
