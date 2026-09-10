-- The whole World, standing up and carrying traffic.
--
-- Every node here is a real role package over a real runtime, real links, real
-- protocol, and real engines, stood up by the shared World builder.
--
-- What is being proved is scenarios 1, 3, 6, and 7: the hierarchy matches the
-- reference topology, overlapping addresses stay unambiguous, Home reaches Farm
-- around the Central Server, and the ways it can fail each fail distinctly.

local worlds = require("tests.lua.support.world")

local protocol = worlds.protocol
local core = worlds.core
local ispPackage = worlds.isp

local BUNDLE = worlds.BUNDLE
local LAN_PASSWORD = worlds.LAN_PASSWORD
local NETWORKS = worlds.NETWORKS
local newWorld = worlds.new
local fullWorld = worlds.full

local get = rawget

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

test("scenario 9: every device in the World reaches the Central Server's view", function()
  local world = fullWorld()
  local topology = world.central:topology()

  local computers = get(topology, "computers")
  assertEqual(#computers, 4, "all four Computers appear")

  local byId = {}
  for _, entry in ipairs(computers) do byId[get(entry, "computer_id")] = entry end

  local alex = byId[world.bindings["alex-pc"].computer_id]
  assertTrue(alex ~= nil, "alex-pc is in the view")
  assertEqual(get(alex, "hostname"), "alex-pc", "with its hostname")
  assertEqual(get(alex, "address"), "192.168.1.20", "and its address")
  assertEqual(get(alex, "customer_network_id"), "network-home", "in its own network")
  assertEqual(get(alex, "isp_id"), "isp-acme", "under its ISP")

  -- The Computer holding the same address in the other network is distinct.
  local harvester = byId[world.bindings["harvester"].computer_id]
  assertEqual(get(harvester, "address"), "192.168.1.20", "the overlapping address")
  assertEqual(get(harvester, "customer_network_id"), "network-farm", "in the other network")

  -- Nothing secret travelled with it.
  local rendered = assert(protocol.conformance.cj1.encode(topology))
  for _, forbidden in ipairs({ "credential", "password", "token", "secret", "mac", "proof", "payload" }) do
    assertTrue(rendered:lower():find(forbidden, 1, true) == nil,
      "'" .. forbidden .. "' reached the topology projection")
  end
end)

test("scenario 9: a released Computer leaves the World's view", function()
  local world = fullWorld()
  local computerId = world.bindings["silo-monitor"].computer_id

  world:pump(function()
    world.nodes["router-farm"].runtime:submit({
      kind = "release_binding", computer_id = computerId,
    })
    world.nodes["router-farm"]:serve(200)
  end)

  local computers = get(world.central:topology(), "computers")
  for _, entry in ipairs(computers) do
    assertTrue(get(entry, "computer_id") ~= computerId,
      "a released Computer is still in the view")
  end
  assertEqual(#computers, 3, "the other three remain")
end)

test("an ISP cannot report a Computer for a network it does not serve", function()
  local world = fullWorld()
  local outcome = world.central.runtime:submit({
    kind = "message",
    relationship_id = world.isp:state().relationship_id,
    message = {
      kind = "topology_change", request_id = "forged-1",
      body = protocol.object({
        revision = 1, change = "added", entity_type = "computer",
        entity = protocol.object({
          computer_id = "computer-elsewhere", hostname = "elsewhere",
          address = "192.168.1.50", customer_network_id = "network-nowhere",
        }),
      }),
    },
  })
  assertTrue(not outcome.result.ok, "the report was refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")
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

--------------------------------------------------------------------------
-- With the External Application switched off
--------------------------------------------------------------------------

test("internal traffic carries on with no Gateway Session at all", function()
  local world = fullWorld()
  -- The Gateway transport exists and has never reached anything: this is
  -- exactly what a stopped craftnetd looks like from in world.
  assertTrue(not world.central:gatewayStatus().ready, "there is no Gateway Session")

  -- Scenario 5: local delivery, entirely inside Home.
  local localReply = world:ask("alex-pc", {
    customer_network_id = "network-home",
    computer_id = world.bindings["wall-display"].computer_id,
  }, "display.update", protocol.object({ token = "t-local" }))
  assertTrue(localReply ~= nil and localReply.payload ~= nil, "local delivery still works")
  assertEqual(get(localReply.payload, "answered_by"), "wall-display", "from the right Computer")

  -- Scenario 6: Home to Farm, all the way around the Central Server.
  local remoteReply = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "t-remote" }))
  assertTrue(remoteReply ~= nil and remoteReply.payload ~= nil, "cross-network traffic still works")
  assertEqual(get(remoteReply.payload, "answered_by"), "harvester", "from the right Computer")
end)

test("an external call fails with gateway_unavailable and changes nothing", function()
  local world = fullWorld()
  local before = world.central:state().revision

  local outcome = world.central.runtime:submit({
    kind = "external_request",
    operation = "test.identity",
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
    local_address = "192.168.1.20",
    access_token = "opaque.bearer.token",
    request_id = "req-external-1",
  })

  -- The engine accepted it and asked for a Gateway; the runtime reported that
  -- there is none, and that came back as the stable code.
  assertEqual(world.central.runtime.lastError.code, "gateway_unavailable",
    "the failure reached the runtime")
  assertTrue(outcome.result.ok, "the engine did its part")
  assertEqual(world.central:state().revision, before,
    "and nothing durable moved because the External Application was away")
end)

test("the Central Server stamps the ancestry from what it knows", function()
  local world = fullWorld()
  local sent
  -- Stand in for a Gateway so the body it would have sent can be read.
  world.central.runtime.adapters.gateway = {
    send = function(_, kind, body) sent = { kind = kind, body = body } return true end,
  }

  world.central.runtime:submit({
    kind = "external_request",
    operation = "test.identity",
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
    local_address = "192.168.1.20",
    access_token = "opaque.bearer.token",
  })

  assertTrue(sent ~= nil, "the Gateway was handed a message")
  assertEqual(sent.kind, "external_request", "kind")
  local ancestry = get(sent.body, "ancestry")
  assertEqual(get(ancestry, "world_id"), "world-overworld", "World")
  assertEqual(get(ancestry, "isp_id"), "isp-acme", "the ISP that owns the route")
  assertEqual(get(ancestry, "router_id"), "router-farm", "and its Customer Router")
  assertEqual(get(ancestry, "customer_network_id"), "network-farm", "network")
end)

test("a disabled Customer Network cannot reach the External Application either", function()
  local world = fullWorld()
  world.central.runtime.adapters.gateway = {
    send = function() return true end,
  }
  assertTrue(world.central:setNetworkStatus("network-farm", "disabled", "cmd-x"), "disabled")

  local outcome = world.central.runtime:submit({
    kind = "external_request",
    operation = "test.identity",
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
    local_address = "192.168.1.20",
    access_token = "opaque.bearer.token",
  })
  assertTrue(not outcome.result.ok, "the call was refused")
  assertEqual(outcome.result.code, "network_disabled", "code")
end)

--------------------------------------------------------------------------
-- Credential revocation
--------------------------------------------------------------------------

test("revoking a LAN Credential removes the Computer and frees its address", function()
  local world = fullWorld()
  local computerId = world.bindings["alex-pc"].computer_id

  local before = world.nodes["router-home"]:state()
  local relationshipId
  for id, childId in pairs(before.relationships or {}) do
    if childId == computerId then relationshipId = id end
  end
  assertTrue(relationshipId ~= nil, "the router holds a relationship for alex-pc")
  assertEqual(before.bindings[computerId].address, "192.168.1.20", "and its Address Binding")

  assertTrue(world.nodes["router-home"]:revoke(relationshipId), "revoke")

  local after = world.nodes["router-home"]:state()
  assertTrue(after.relationships[relationshipId] == nil, "the relationship is gone")
  assertTrue(after.bindings[computerId] == nil, "and so is the Address Binding")
  assertTrue(world.nodes["router-home"].secrets:get(
    world.nodes["router-home"]:secretReference(relationshipId)) == nil,
    "the credential itself is gone from the secret store")

  -- The Computer still holds its own copy, and it gets it nowhere: the router
  -- no longer has anything to check it against.
  world:settle()
  local value, code
  world:pump(function()
    value, code = world.nodes["alex-pc"]:connect()
  end, "alex-pc")
  assertTrue(value == nil, "a revoked Computer must not reconnect")
  assertEqual(code, "router_unavailable", "code")

  -- Its neighbour is untouched. Revoking one credential is not an outage.
  local answer = world:ask("wall-display", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "after-revoke" }))
  assertTrue(answer and answer.payload, "wall-display still works")
  assertEqual(get(answer.payload, "answered_by"), "harvester", "and reaches the right Computer")
end)

test("a revoked Computer rejoins with the LAN Password and nothing else", function()
  local world = fullWorld()
  local computerId = world.bindings["alex-pc"].computer_id
  local relationshipId
  for id, childId in pairs(world.nodes["router-home"]:state().relationships or {}) do
    if childId == computerId then relationshipId = id end
  end
  assertTrue(world.nodes["router-home"]:revoke(relationshipId), "revoke")
  world:settle()

  -- The freed address is the lowest free one again, so the next Computer to
  -- join takes it -- which is the whole point of releasing it.
  local rejoined
  world:pump(function()
    local value, code, problem = world.nodes["alex-pc"]:joinNetwork({
      password = LAN_PASSWORD,
      hostname = "alex-pc",
      customer_network_name = "home",
      timeout_ms = 4000,
    })
    assert(value, "rejoin failed: " .. tostring(code) .. " " .. tostring(problem))
    rejoined = value
    assert(world.nodes["alex-pc"]:connect())
  end, "alex-pc")

  assertEqual(rejoined.address, "192.168.1.20", "the freed address was handed back out")
  local answer = world:ask("alex-pc", {
    customer_network_id = "network-farm",
    computer_id = world.bindings["harvester"].computer_id,
  }, "harvester.status", protocol.object({ token = "rejoined" }))
  assertTrue(answer and answer.payload, "and it is on CraftNet again")
  assertEqual(get(answer.payload, "token"), "rejoined", "carrying its own answer")
end)
