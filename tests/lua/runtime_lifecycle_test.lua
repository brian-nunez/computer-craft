-- Restart, disconnect, and reconciliation.
--
-- These drive a real runtime over fake adapters: durable state goes to a fake
-- disk, messages go to a fake links adapter, and time moves only when a test
-- says so. What is being checked is what survives a restart, what must not, and
-- what a parent is allowed to change about its child.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local runtimePackage = dofile("packages/craftnet-runtime/files/init.lua")
  .withPackages({ protocol = protocol, core = core })
local fakes = require("tests.lua.support.fakes")

local get = rawget

local ROUTER_SETTINGS = {
  router_id = "router-home",
  customer_network_id = "network-home",
  customer_network_name = "home",
  router_address = "192.168.1.1",
  pool_first = "192.168.1.20",
  pool_last = "192.168.1.39",
  lan_operational_channel = 42201,
  isp_id = "isp-acme",
  isp_name = "acme",
  provider_address = "100.64.0.10",
  world_id = "world-overworld",
}

-- newRouter builds a started router runtime over a given set of adapters, so a
-- test can restart it by building a second one on the same fake disk.
local function newRouter(adapters, options)
  options = options or {}
  local instance = runtimePackage.new({
    role = "router",
    path = "state/router",
    adapters = adapters,
    connectivity = options.connectivity,
  })
  local ok, source = instance:start()
  return instance, ok, source
end

local function configuredRouter()
  local adapters = fakes.set()
  local instance = newRouter(adapters)
  instance:submit({ kind = "configure", settings = ROUTER_SETTINGS })
  instance:submit({
    kind = "link_up", relationship_id = "rel-acme-home",
    peer_role = "isp", peer_id = "isp-acme", direction = "parent",
  })
  instance:submit({ kind = "bind_computer", computer_id = "computer-home-alex", hostname = "alex-pc" })
  instance:submit({
    kind = "link_up", relationship_id = "rel-alex",
    peer_role = "computer", peer_id = "computer-home-alex", direction = "child",
  })
  instance:submit({
    kind = "expose_service", computer_id = "computer-home-alex", service = "probe",
  })
  return instance, adapters
end

--------------------------------------------------------------------------
-- Restart
--------------------------------------------------------------------------

test("a restart preserves every durable field", function()
  local before, adapters = configuredRouter()
  local revision = before:revision()
  assertTrue(revision > 0, "the router persisted something")

  local after, ok, source = newRouter(adapters)
  assertTrue(ok, "the restarted router started")
  assertEqual(source, "primary", "from its own snapshot")

  local state = after:state()
  assertEqual(state.router_id, "router-home", "identity")
  assertEqual(state.customer_network_id, "network-home", "network identity")
  assertEqual(state.pool_first, "192.168.1.20", "pool")
  assertEqual(state.provider_address, "100.64.0.10", "Provider Address")
  assertEqual(state.bindings["computer-home-alex"].address, "192.168.1.20", "Address Binding")
  assertEqual(state.exposed["computer-home-alex"]["probe"], true, "Exposed Service")
  assertEqual(state.revision, revision, "and the revision it had reached")
end)

test("a restart discards every ephemeral field", function()
  local before, adapters = configuredRouter()

  -- Put a NAT Flow and a correlation record in flight.
  before:submit({
    kind = "message", relationship_id = "rel-alex",
    message = {
      kind = "service_request", request_id = "alex-1",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-alex", customer_network_id = "network-home",
          local_address = "192.168.1.20",
        }),
        destination = core.object({
          customer_network_id = "network-farm", computer_id = "computer-farm-harvester",
        }),
        service = "harvester.status", payload = core.object({}),
      }),
    },
  })
  assertEqual(before.engine.flows:size(), 1, "a flow is open before the restart")
  assertTrue(before.engine.buffer:count() >= 0, "the buffer exists")
  assertTrue(next(before.engine.links) ~= nil, "relationships exist")

  local after = newRouter(adapters)
  assertEqual(after.engine.flows:size(), 0, "no NAT Flow survived")
  assertEqual(after.engine.transit:size(), 0, "no correlation survived")
  assertEqual(after.engine.buffer:count(), 0, "no diagnostic buffer survived")
  assertTrue(next(after.engine.links) == nil, "no Authenticated Session survived")
  assertTrue(after.engine.parentRelationshipId == nil, "not even the parent link")

  -- And none of it was ever written to disk in the first place.
  local raw = adapters.storage:read("state/router.json")
  for _, forbidden in ipairs({ "flow", "transit", "session", "counter" }) do
    assertTrue(raw:lower():find(forbidden, 1, true) == nil,
      "'" .. forbidden .. "' must not appear in a snapshot")
  end
end)

test("a pending request is not replayed after a restart", function()
  local before, adapters = configuredRouter()
  before:submit({
    kind = "message", relationship_id = "rel-alex",
    message = {
      kind = "service_request", request_id = "alex-1",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-alex", customer_network_id = "network-home",
          local_address = "192.168.1.20",
        }),
        destination = core.object({
          customer_network_id = "network-farm", computer_id = "computer-farm-harvester",
        }),
        service = "harvester.status", payload = core.object({}),
      }),
    },
  })
  local sentBefore = #adapters.links.sent
  assertTrue(sentBefore > 0, "the request went upstream once")

  local after = newRouter(adapters)
  assertEqual(#adapters.links.sent, sentBefore, "starting up sent nothing")

  after:submit({ kind = "tick" })
  assertEqual(#adapters.links.sent, sentBefore, "and neither did a tick")
end)

test("an unreadable snapshot refuses to start rather than inventing a World", function()
  local before, adapters = configuredRouter()
  before:submit({ kind = "bind_computer", computer_id = "computer-home-b", hostname = "b" })
  adapters.storage:corrupt("state/router.json")
  adapters.storage:corrupt("state/router.bak.json")

  local after, ok, code = newRouter(adapters)
  assertTrue(ok == nil, "the router did not start")
  assertEqual(code, "internal_error", "code")
  assertEqual(after.snapshotSource, "unreadable", "and it says why")
  assertTrue(adapters.storage:read("state/router.json") ~= nil,
    "nothing was overwritten, so an Operator can still recover the file")
end)

test("a corrupt primary starts the router from its backup", function()
  local before, adapters = configuredRouter()
  before:submit({ kind = "bind_computer", computer_id = "computer-home-b", hostname = "b" })
  adapters.storage:corrupt("state/router.json")

  local after, ok, source = newRouter(adapters)
  assertTrue(ok, "the router started")
  assertEqual(source, "backup", "from the backup")
  assertEqual(after:state().bindings["computer-home-alex"].address, "192.168.1.20",
    "with the generation before the corruption")
end)

--------------------------------------------------------------------------
-- Effect feedback
--------------------------------------------------------------------------

test("a send that fails is reported back and the correlation is dropped", function()
  local instance, adapters = configuredRouter()
  adapters.links:fail("rel-acme-home")

  local outcome = instance:submit({
    kind = "message", relationship_id = "rel-alex",
    message = {
      kind = "service_request", request_id = "alex-1",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-alex", customer_network_id = "network-home",
          local_address = "192.168.1.20",
        }),
        destination = core.object({
          customer_network_id = "network-farm", computer_id = "computer-farm-harvester",
        }),
        service = "harvester.status", payload = core.object({}),
      }),
    },
  })
  assertTrue(outcome.result.ok, "the engine accepted the request")

  -- The message never left, so the flow it belonged to is gone rather than
  -- waiting for a reply that can never come.
  assertEqual(instance.engine.flows:size(), 0, "the flow was dropped")
  assertEqual(instance.lastError.code, "upstream_unavailable", "and the failure is visible")
  assertEqual(instance:connectivityState("rel-acme-home"), "disconnected",
    "the relationship is marked disconnected")
end)

test("a failed persist surfaces as an actionable error", function()
  local instance, adapters = configuredRouter()
  adapters.storage.failWrites = true
  instance:submit({ kind = "bind_computer", computer_id = "computer-home-c", hostname = "c" })
  assertEqual(instance.lastError.code, "internal_error", "the write failure reached the runtime")
  assertTrue(instance:lines()[#instance:lines()]:find("!", 1, true) == 1,
    "and the screen shows it")
end)

--------------------------------------------------------------------------
-- Reconciliation
--------------------------------------------------------------------------

test("a child asks its parent whether its configuration is still current", function()
  local instance, adapters = configuredRouter()
  local outcome = instance:submit({ kind = "reconcile" })
  assertTrue(outcome.result.ok, "the request went out")

  local sent = adapters.links:sentOf("rel-acme-home")
  local last = sent[#sent]
  assertEqual(last.message_kind, "config_request", "it asked for configuration")
  assertEqual(get(last.body, "known_revision"), instance:state().parent_revision or 0,
    "presenting the last parent revision it accepted")
end)

test("a parent answers an unchanged child with an acknowledgement", function()
  local adapters = fakes.set()
  local isp = runtimePackage.new({ role = "isp", path = "state/isp", adapters = adapters })
  isp:start()
  isp:submit({ kind = "configure", settings = {
    isp_id = "isp-acme", isp_name = "acme", world_id = "world-overworld",
    provider_allocations = { { first = "100.64.0.0", last = "100.64.0.255" } },
  } })
  isp:submit({ kind = "register_router", router_id = "router-home",
    customer_network_id = "network-home", customer_network_name = "home",
    router_address = "192.168.1.1", pool_first = "192.168.1.20", pool_last = "192.168.1.39",
    lan_operational_channel = 42201 })
  isp:submit({ kind = "link_up", relationship_id = "rel-acme-home",
    peer_role = "router", peer_id = "router-home", direction = "child" })

  isp:submit({ kind = "message", relationship_id = "rel-acme-home", message = {
    kind = "config_request", request_id = "req-1",
    body = core.object({ known_revision = isp:revision() }),
  } })
  local sent = adapters.links:sentOf("rel-acme-home")
  assertEqual(sent[#sent].message_kind, "ack", "nothing changed, so nothing is replaced")

  isp:submit({ kind = "message", relationship_id = "rel-acme-home", message = {
    kind = "config_request", request_id = "req-2",
    body = core.object({ known_revision = 0 }),
  } })
  sent = adapters.links:sentOf("rel-acme-home")
  assertEqual(sent[#sent].message_kind, "config_snapshot", "a stale child gets a replacement")
  assertEqual(get(get(sent[#sent].body, "configuration"), "provider_address"), "100.64.0.1",
    "carrying what the ISP owns: the ISP kept .0 for itself")
end)

test("reconciliation obeys authority ownership", function()
  local instance = configuredRouter()

  -- The ISP owns the Provider Address. It does not own this router's pool, so a
  -- snapshot that tries to move the pool is not obeyed.
  instance:submit({ kind = "message", relationship_id = "rel-acme-home", message = {
    kind = "config_snapshot", request_id = "req-9",
    body = core.object({
      revision = 12, role = "router",
      configuration = core.object({
        customer_network_id = "network-home",
        customer_network_name = "home",
        provider_address = "100.64.0.77",
        isp_id = "isp-acme",
        router_address = "10.0.0.1",
        dns_address = "10.0.0.1",
        pool_first = "10.0.0.2",
        pool_last = "10.0.0.99",
        lan_operational_channel = 1,
      }),
    }),
  } })

  local state = instance:state()
  assertEqual(state.provider_address, "100.64.0.77", "the ISP's field was accepted")
  assertEqual(state.parent_revision, 12, "and the parent revision recorded")
  assertEqual(state.router_address, "192.168.1.1", "the router's own address was not moved")
  assertEqual(state.pool_first, "192.168.1.20", "nor its pool")
  assertEqual(state.pool_last, "192.168.1.39", "either end of it")
  assertEqual(state.lan_operational_channel, 42201, "nor its LAN channel")
end)

test("a child refuses configuration that did not come from its parent", function()
  local instance = configuredRouter()
  local outcome = instance:submit({ kind = "message", relationship_id = "rel-alex", message = {
    kind = "config_snapshot", request_id = "req-10",
    body = core.object({
      revision = 99, role = "router",
      configuration = core.object({
        customer_network_id = "network-home", customer_network_name = "home",
        provider_address = "100.64.0.99", isp_id = "isp-acme",
        router_address = "192.168.1.1", dns_address = "192.168.1.1",
        pool_first = "192.168.1.20", pool_last = "192.168.1.39",
        lan_operational_channel = 42201,
      }),
    }),
  } })
  assertTrue(not outcome.result.ok, "a Computer cannot reconfigure its router")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
  assertEqual(instance:state().provider_address, "100.64.0.10", "nothing moved")
end)

--------------------------------------------------------------------------
-- Heartbeats and the screen
--------------------------------------------------------------------------

test("a tick sends a heartbeat once the interval has passed", function()
  local instance, adapters = configuredRouter()
  local before = #adapters.links:sentOf("rel-acme-home")

  instance:tick()
  assertEqual(#adapters.links:sentOf("rel-acme-home"), before, "nothing is due yet")

  adapters.clock:advance(runtimePackage.limits.HEARTBEAT_MS)
  instance:tick()
  local sent = adapters.links:sentOf("rel-acme-home")
  assertEqual(#sent, before + 1, "one heartbeat went out")
  assertEqual(sent[#sent].message_kind, "heartbeat", "kind")
  assertEqual(get(sent[#sent].body, "revision"), instance:revision(), "carrying this role's revision")
end)

test("silence past the threshold disconnects the relationship and drops its work", function()
  local instance, adapters = configuredRouter()
  instance:submit({ kind = "message", relationship_id = "rel-acme-home", message = {
    kind = "heartbeat", body = core.object({ connectivity_state = "ready", revision = 3 }),
  } })
  assertEqual(instance:connectivityState("rel-acme-home"), "ready", "it was heard from")

  adapters.clock:advance(runtimePackage.limits.HEARTBEAT_MS)
  instance:tick()
  assertEqual(instance:connectivityState("rel-acme-home"), "degraded", "one missed heartbeat")

  adapters.clock:advance(runtimePackage.limits.DISCONNECT_MS)
  instance:tick()
  assertEqual(instance:connectivityState("rel-acme-home"), "disconnected", "then it is gone")
  assertTrue(instance.engine.links["rel-acme-home"] == nil, "and the relationship was released")
end)

test("a disconnected parent is retried under backoff, never in a spin", function()
  local instance, adapters = configuredRouter()
  instance:submit({ kind = "message", relationship_id = "rel-acme-home", message = {
    kind = "heartbeat", body = core.object({ connectivity_state = "ready", revision = 1 }),
  } })

  adapters.clock:advance(runtimePackage.limits.DISCONNECT_MS)
  instance:tick()
  assertEqual(#adapters.links.connects, 0, "the first retry is not immediate")

  adapters.clock:advance(1000)
  instance:tick()
  assertEqual(#adapters.links.connects, 1, "one attempt after a second")

  adapters.clock:advance(1000)
  instance:tick()
  assertEqual(#adapters.links.connects, 1, "and not again until the wait doubles")

  adapters.clock:advance(1000)
  instance:tick()
  assertEqual(#adapters.links.connects, 2, "then a second attempt")
end)

test("the screen shows role, identity, connectivity, and the latest error", function()
  local instance, adapters = configuredRouter()
  local text = adapters.screen:text()
  assertTrue(text:find("Customer Router", 1, true) ~= nil, "role")
  assertTrue(text:find("home", 1, true) ~= nil, "name")
  assertTrue(text:find("router-home", 1, true) ~= nil, "identity")
  assertTrue(text:find("net ", 1, true) ~= nil, "connectivity")

  instance:submit({ kind = "bind_computer", computer_id = "computer-home-alex", hostname = "taken" })
  instance:submit({ kind = "bind_computer", computer_id = "computer-home-d", hostname = "taken" })
  assertTrue(adapters.screen:text():find("already taken", 1, true) ~= nil,
    "the latest actionable error is shown in words a player can act on")
end)

test("a snapshot never contains a credential, a password, or a token", function()
  local instance, adapters = configuredRouter()
  local raw = adapters.storage:read("state/router.json")
  for _, forbidden in ipairs({ "credential", "password", "token", "secret", "mac", "proof" }) do
    assertTrue(raw:lower():find(forbidden, 1, true) == nil,
      "'" .. forbidden .. "' must not appear in a router snapshot")
  end
end)

--------------------------------------------------------------------------
-- Buffers
--------------------------------------------------------------------------

test("the diagnostic buffer stays bounded however busy the role gets", function()
  local instance, adapters = configuredRouter()
  instance:submit({ kind = "link_up", relationship_id = "rel-b", peer_role = "computer",
    peer_id = "computer-home-b", direction = "child" })

  for index = 1, 250 do
    instance:submit({
      kind = "message", relationship_id = "rel-alex",
      message = {
        kind = "service_request", request_id = "alex-" .. index,
        body = core.object({
          source = core.object({
            computer_id = "computer-home-alex", customer_network_id = "network-home",
            local_address = "192.168.1.20",
          }),
          destination = core.object({
            customer_network_id = "network-home", computer_id = "computer-home-missing",
          }),
          service = "probe", payload = core.object({}),
        }),
      },
    })
  end

  assertEqual(instance:bufferedEvents(), core.limits.EVENT_BUFFER.router,
    "the router's buffer holds exactly its capacity")
  assertTrue(instance.engine.buffer.dropped > 0, "and the overflow is counted, not hidden")
end)
