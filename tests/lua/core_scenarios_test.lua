-- The reference acceptance scenarios, run against real state transitions.
--
-- Milestone 2's gate is scenarios 3 through 7 from the verification design:
-- overlapping addresses stay unambiguous, local delivery creates no NAT, the
-- Central path is used even within one ISP, replies follow paired flows,
-- missing and expired and disabled paths fail distinctly, and authority
-- ownership cannot be bypassed. No peripheral, file, timer, or socket is
-- involved in any of it.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local core = dofile("packages/craftnet-core/files/init.lua").withProtocol(protocol)
local reference = require("tests.lua.support.reference")

local get = rawget

local function build(options)
  return reference.build(core, options)
end

local function bindingOf(sim, routerNode, computerId)
  return sim:state(routerNode).bindings[computerId]
end

--------------------------------------------------------------------------
-- Scenario 3 -- prove overlapping addressing
--------------------------------------------------------------------------

test("scenario 3: two Customer Networks hold the same address unambiguously", function()
  local sim = build()

  local alex = bindingOf(sim, "router-home", "computer-home-alex")
  local harvester = bindingOf(sim, "router-farm", "computer-farm-harvester")
  assertEqual(alex.address, "192.168.1.20", "alex-pc address")
  assertEqual(harvester.address, "192.168.1.20", "harvester address")

  -- The same address in two scopes is not a conflict, because a Customer
  -- Network identity always travels with it.
  assertTrue(alex.address == harvester.address, "both networks must reuse the pool")
  assertTrue(sim:state("router-home").customer_network_id
    ~= sim:state("router-farm").customer_network_id, "network scopes differ")

  -- The Central route directory holds one exact entry per network, keyed by
  -- identity, and their Provider Addresses are distinct.
  local routes = sim:state("central").routes
  assertEqual(routes["network-home"].router_provider_address, "100.64.0.10", "home provider address")
  assertEqual(routes["network-farm"].router_provider_address, "100.64.0.11", "farm provider address")

  local display = bindingOf(sim, "router-home", "computer-home-display")
  local silo = bindingOf(sim, "router-farm", "computer-farm-silo")
  assertEqual(display.address, "192.168.1.21", "wall-display address")
  assertEqual(silo.address, "192.168.1.21", "silo-monitor address")
end)

test("scenario 3: a binding is permanent and a rejoining Computer keeps it", function()
  local sim = build()
  local before = bindingOf(sim, "router-home", "computer-home-alex").address

  local again = reference.assertOk(sim:input("router-home", {
    kind = "bind_computer", computer_id = "computer-home-alex", hostname = "alex-pc",
  }), "rebind")
  assertTrue(again.reused, "a returning Computer is not a new join")
  assertEqual(again.address, before, "its address is unchanged")

  -- A different Computer never inherits an address that is still bound.
  local newcomer = reference.assertOk(sim:input("router-home", {
    kind = "bind_computer", computer_id = "computer-home-spare", hostname = "spare",
  }), "bind newcomer")
  assertEqual(newcomer.address, "192.168.1.22", "the newcomer gets the next free address")
end)

--------------------------------------------------------------------------
-- Scenario 4 -- resolve names
--------------------------------------------------------------------------

test("scenario 4: a local short name resolves within its own network", function()
  local sim = build()
  sim:input("alex-pc", { kind = "resolve", name = "wall-display" })
  local answer = sim:lastResultAt("alex-pc", "dns_result")
  assertTrue(answer and answer.ok, "the lookup was answered")
  assertEqual(answer.address, "192.168.1.21", "address")
  assertEqual(answer.canonical_name, "wall-display.home.acme.craft", "canonical name")
end)

test("scenario 4: a name qualified by Customer Network resolves across the World", function()
  local sim = build()
  sim:input("alex-pc", { kind = "resolve", name = "harvester.farm" })
  local answer = sim:lastResultAt("alex-pc", "dns_result")
  assertTrue(answer and answer.ok, "the lookup was answered")
  assertEqual(answer.address, "192.168.1.20", "address")
  assertEqual(answer.customer_network_id, "network-farm", "scope travels with the address")
  assertEqual(answer.computer_id, "computer-farm-harvester", "computer")
end)

test("scenario 4: a fully qualified craft name resolves", function()
  local sim = build()
  sim:input("alex-pc", { kind = "resolve", name = "HARVESTER.Farm.Acme.Craft" })
  local answer = sim:lastResultAt("alex-pc", "dns_result")
  assertTrue(answer and answer.ok, "names are case-insensitive")
  assertEqual(answer.canonical_name, "harvester.farm.acme.craft", "canonical name")
  assertEqual(answer.address, "192.168.1.20", "address")
end)

test("scenario 4: api.craft is the External Application, not an address", function()
  local sim = build()
  -- The Computer classifies this without a lookup: the External Application is
  -- reached through an External Operation and its verified ancestry.
  local outcome = sim:input("alex-pc", { kind = "resolve", name = "api.craft" })
  assertTrue(outcome.result.ok, "api.craft resolves")
  assertEqual(outcome.result.kind, "external", "it is the External Application")
  assertEqual(outcome.result.canonical, "api.craft", "canonical name")
end)

test("scenario 4: an unknown name fails with name_not_found", function()
  local sim = build()
  sim:input("alex-pc", { kind = "resolve", name = "ghost" })
  local answer = sim:lastResultAt("alex-pc", "error")
  assertTrue(answer and not answer.ok, "the lookup failed")
  assertEqual(answer.code, "name_not_found", "code")

  sim:input("alex-pc", { kind = "resolve", name = "ghost.nowhere.acme" })
  answer = sim:lastResultAt("alex-pc", "error")
  assertEqual(answer.code, "name_not_found", "an unknown network is also name_not_found")
end)

test("scenario 4: a duplicate hostname fails with name_conflict", function()
  local sim = build()
  local outcome = sim:input("router-home", {
    kind = "bind_computer", computer_id = "computer-home-impostor", hostname = "alex-pc",
  })
  assertTrue(not outcome.result.ok, "the duplicate was refused")
  assertEqual(outcome.result.code, "name_conflict", "code")
end)

--------------------------------------------------------------------------
-- Scenario 5 -- deliver local traffic
--------------------------------------------------------------------------

test("scenario 5: local traffic stays behind its router and creates no NAT Flow", function()
  local sim = build()
  local display = bindingOf(sim, "router-home", "computer-home-display")

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-home", address = display.address },
    service = "display.update",
    payload = core.object({ text = "harvest ready" }),
  })

  local answer = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(answer and answer.ok, "the reply arrived")
  assertEqual(get(answer.payload, "shown"), "harvest ready", "payload")

  -- No Provider Address and no flow are involved: the traffic never left.
  assertEqual(sim:engine("router-home").flows:size(), 0, "no NAT Flow was opened")
  assertTrue(sim:sawOutcome("delivered_local", "router-home"), "the router recorded delivered_local")

  -- Nothing reached the ISP or the Central Server at all.
  assertEqual(#sim:path("service_request"), 2, "only the router and the target saw the request")
  for _, node in ipairs({ "acme", "central", "router-farm" }) do
    assertEqual(#sim:resultsAt(node, "service_request"), 0, node .. " saw no local traffic")
  end
end)

test("scenario 5: a local request reaches only the intended Computer", function()
  local sim = build()
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-home", computer_id = "computer-home-display" },
    service = "display.update",
    payload = core.object({ text = "one" }),
  })
  assertEqual(#sim:resultsAt("wall-display", "service_request"), 1, "the target was called once")
  assertEqual(#sim:resultsAt("silo-monitor", "service_request"), 0, "nobody else was")
  assertEqual(#sim:resultsAt("harvester", "service_request"), 0, "nobody else was")
end)

--------------------------------------------------------------------------
-- Scenario 6 -- route between Customer Networks
--------------------------------------------------------------------------

test("scenario 6: Home to Farm travels through the Central Server and returns home", function()
  local sim = build()

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({ asked = "bushels" }),
  })

  -- The observed path visits the ISP twice, around the Central Server, even
  -- though both Customer Networks belong to that same ISP.
  local path = sim:path("service_request")
  local expected = { "router-home", "acme", "central", "acme", "router-farm", "harvester" }
  assertEqual(#path, #expected, "hop count")
  for index = 1, #expected do
    assertEqual(path[index], expected[index], "hop " .. index)
  end

  local answer = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(answer and answer.ok, "the reply arrived")
  assertEqual(get(answer.payload, "bushels"), 128, "payload")

  -- The reply went to Home's 192.168.1.20, not Farm's, and both flows closed.
  assertTrue(sim:sawOutcome("delivered_remote", "router-home"), "home recorded delivered_remote")
  assertEqual(sim:engine("router-home").flows:size(), 0, "the source flow closed")
  assertEqual(sim:engine("router-farm").flows:size(), 0, "the destination flow closed")
  assertEqual(#sim:resultsAt("alex-pc", "service_response"), 1, "exactly one reply reached alex-pc")
  assertEqual(#sim:resultsAt("wall-display", "service_response"), 0, "no reply went astray")
end)

test("scenario 6: paired flows carry both halves on the reply", function()
  local sim = build()

  -- Watch the flow while the request is in flight by holding the reply back.
  sim:step("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  -- Deliver only as far as the destination router, then inspect both halves.
  for _ = 1, 5 do
    if #sim.queue == 0 then break end
    local entry = table.remove(sim.queue, 1)
    sim:apply(sim:node(entry.to), entry.input)
  end

  local sourceFlows = sim:engine("router-home").flows
  local destinationFlows = sim:engine("router-farm").flows
  assertEqual(sourceFlows:size(), 1, "the source router holds one flow")
  assertEqual(destinationFlows:size(), 1, "the destination router holds the far half")

  local sourceId
  for identifier in pairs(sourceFlows.byId) do sourceId = identifier end
  local destinationEntry
  for _, entry in pairs(destinationFlows.byId) do destinationEntry = entry end
  assertEqual(destinationEntry.peer_flow_id, sourceId,
    "the far half names the near half, which is what identifies the original Computer")

  sim:drain()
  assertEqual(sourceFlows:size(), 0, "the pair closed once the reply arrived")
end)

--------------------------------------------------------------------------
-- Scenario 7 -- fail closed
--------------------------------------------------------------------------

test("scenario 7: an unexposed remote service is refused with inbound_denied", function()
  local sim = build()
  -- silo-monitor exists on Farm but publishes nothing.
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-silo" },
    service = "silo.read",
    payload = core.object({}),
  })

  local answer = sim:lastResultAt("alex-pc", "error")
  assertTrue(answer and not answer.ok, "the request failed")
  assertEqual(answer.code, "inbound_denied", "code")
  assertTrue(sim:sawOutcome("inbound_denied", "router-farm"), "the destination router recorded it")
  assertEqual(#sim:resultsAt("silo-monitor", "service_request"), 0,
    "the Computer never saw the unsolicited request")
end)

test("scenario 7: a late reply against an expired flow fails with nat_flow_missing", function()
  local sim = build()

  -- Hold the reply back long enough for the flow to go idle.
  sim:step("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  sim:drain()
  assertEqual(sim:engine("router-home").flows:size(), 0, "the flow closed on the reply")

  -- Now do it again, but lose the reply on the way back into Home's router so
  -- the flow is left open and then expires.
  sim:reset()
  sim:step("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  sim:lose("rel-acme-home", 1)
  sim:drain()
  assertEqual(sim:engine("router-home").flows:size(), 1, "the source flow is still waiting")

  sim:advance(core.limits.FLOW_IDLE_MS)
  assertEqual(sim:engine("router-home").flows:size(), 0, "the idle flow expired")

  -- A reply arriving now has nothing to match.
  local outcome = sim:step("router-home", {
    kind = "message",
    relationship_id = "rel-acme-home",
    message = {
      kind = "service_response",
      request_id = "router-home-r99",
      body = core.object({ source_flow_id = "router-flow-1", payload = core.object({}) }),
    },
  })
  assertTrue(not outcome.result.ok, "the late reply was refused")
  assertEqual(outcome.result.code, "nat_flow_missing", "code")
end)

test("scenario 7: a removed route fails with route_not_found", function()
  local sim = build()
  reference.assertOk(sim:input("acme", {
    kind = "deregister_router", router_id = "router-farm",
  }), "deregister farm")
  assertTrue(sim:state("central").routes["network-farm"] == nil, "the route is gone")

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  local answer = sim:lastResultAt("alex-pc", "error")
  assertEqual(answer.code, "route_not_found", "code")
  assertTrue(sim:sawOutcome("route_not_found", "central"), "the Central Server recorded it")
end)

test("scenario 7: a disabled Customer Network fails with network_disabled", function()
  local sim = build()
  reference.assertOk(sim:input("central", {
    kind = "set_network_status", command_id = "cmd-0001",
    customer_network_id = "network-farm", status = "disabled",
  }), "disable farm")

  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  local answer = sim:lastResultAt("alex-pc", "error")
  assertEqual(answer.code, "network_disabled", "code")

  -- Disabling refuses new traffic but keeps every durable registration, so
  -- re-enabling needs no re-enrollment and no address changes.
  assertTrue(sim:state("central").routes["network-farm"] ~= nil, "the route survived")
  assertEqual(bindingOf(sim, "router-farm", "computer-farm-harvester").address, "192.168.1.20",
    "the binding survived")

  reference.assertOk(sim:input("central", {
    kind = "set_network_status", command_id = "cmd-0002",
    customer_network_id = "network-farm", status = "enabled",
  }), "re-enable farm")
  sim:reset()
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  local recovered = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(recovered and recovered.ok, "traffic resumed without re-enrollment")
end)

test("scenario 7: an exhausted pool fails with pool_exhausted", function()
  local sim = build({ pool_first = "192.168.1.20", pool_last = "192.168.1.21" })
  -- Both addresses are already bound by the reference Computers.
  local outcome = sim:input("router-home", {
    kind = "bind_computer", computer_id = "computer-home-extra", hostname = "extra",
  })
  assertTrue(not outcome.result.ok, "the join was refused")
  assertEqual(outcome.result.code, "pool_exhausted", "code")

  -- The Operator's remedy is to release a binding, never an automatic eviction.
  reference.assertOk(sim:input("router-home", {
    kind = "release_binding", computer_id = "computer-home-display",
  }), "release")
  local retried = reference.assertOk(sim:input("router-home", {
    kind = "bind_computer", computer_id = "computer-home-extra", hostname = "extra",
  }), "retry")
  assertEqual(retried.address, "192.168.1.21", "the released address was reused")
end)

test("scenario 7: an administrative command is idempotent by Command ID", function()
  local sim = build()
  local first = reference.assertOk(sim:input("central", {
    kind = "set_network_status", command_id = "cmd-0009",
    customer_network_id = "network-farm", status = "disabled",
  }), "disable")
  assertTrue(not first.repeated, "the first application is not a repeat")

  local again = reference.assertOk(sim:input("central", {
    kind = "set_network_status", command_id = "cmd-0009",
    customer_network_id = "network-farm", status = "disabled",
  }), "repeat")
  assertTrue(again.repeated, "the repeat returned the already-applied result")
end)

--------------------------------------------------------------------------
-- Scenario 8 -- use the External Application
--------------------------------------------------------------------------

-- The Central Server is the only role that holds a Gateway Session, so in the
-- simulator its `gateway` effect is where the World ends. What is being checked
-- here is everything up to that point, and everything back from it.

local function gatewayEffects(sim, nodeName)
  local found = {}
  for _, effect in ipairs(sim:node(nodeName).outbox) do
    if effect.kind == "gateway" then found[#found + 1] = effect end
  end
  return found
end

local function callExternal(sim, from, fields)
  local input = { kind = "external_call", operation = fields.operation or "test.identity" }
  for key, value in pairs(fields) do input[key] = value end
  input.kind = "external_call"
  sim:input(from, input)
  return gatewayEffects(sim, "central")
end

test("scenario 8: an external call travels the whole ancestry and the answer comes home", function()
  local sim = build()

  local sent = callExternal(sim, "alex-pc", {
    operation = "test.identity", access_token = "opaque.bearer.token",
  })

  -- Computer to router to ISP to Central Server. No Customer Network is named
  -- anywhere on the way: the kind is the destination.
  --
  -- alex-pc leads the path because a Computer's own initiating input carries
  -- the same name as the message it produces, unlike local_request.
  local path = sim:path("external_call")
  local expected = { "alex-pc", "router-home", "acme", "central" }
  assertEqual(#path, #expected, "hop count")
  for index = 1, #expected do
    assertEqual(path[index], expected[index], "hop " .. index)
  end

  assertEqual(#sent, 1, "the Central Server put exactly one request on the Gateway")
  assertEqual(sent[1].message_kind, "external_request", "and it is a Gateway kind")

  -- The External Application answers, and the reply retraces the NAT Flow the
  -- source Customer Router opened.
  sim:input("central", {
    kind = "gateway_frame", frame_kind = "external_response",
    request_id = sent[1].request_id,
    body = core.object({ payload = core.object({ verified = "yes" }) }),
  })
  sim:drain()

  local answer = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(answer and answer.ok, "the reply arrived at the Computer that asked")
  assertEqual(get(answer.payload, "verified"), "yes", "carrying what the application answered")
  assertEqual(#sim:resultsAt("wall-display", "service_response"), 0, "and nowhere else")
  assertEqual(sim:engine("router-home").flows:size(), 0, "the flow closed")
end)

test("scenario 8: the ancestry is stamped from the route directory, never from the caller", function()
  local sim = build()

  local sent = callExternal(sim, "harvester", {
    operation = "test.identity", access_token = "opaque.bearer.token",
  })
  assertEqual(#sent, 1, "one request reached the Gateway")

  local ancestry = get(sent[1].body, "ancestry")
  assertEqual(get(ancestry, "world_id"), sim:state("central").world_id, "World")
  assertEqual(get(ancestry, "isp_id"), "isp-acme", "the ISP that owns the route")
  assertEqual(get(ancestry, "customer_network_id"), "network-farm", "the Customer Network")
  assertEqual(get(ancestry, "router_id"), "router-farm", "its Customer Router")
  assertEqual(get(ancestry, "computer_id"), "computer-farm-harvester", "the Computer")
  assertEqual(get(ancestry, "local_address"), "192.168.1.20", "and the address it holds")

  -- Farm's 192.168.1.20, not Home's. The ancestry is what tells them apart.
  assertTrue(get(sent[1].body, "source_flow_id") ~= nil,
    "the call was NATted, so a reply can find its way back")
end)

test("scenario 8: each operation may present only the credential it is allowed", function()
  local sim = build()

  -- device.register offers the verified ancestry and nothing else.
  local registering = sim:input("alex-pc", {
    kind = "external_call", operation = "device.register",
    registration_nonce = string.rep("cc", 32),
  })
  assertTrue(registering.result.ok, "registering with a nonce alone is allowed")

  -- The same call carrying a token as well is refused before it leaves.
  local both = sim:input("alex-pc", {
    kind = "external_call", operation = "device.register",
    registration_nonce = string.rep("cc", 32), access_token = "opaque.bearer.token",
  })
  assertTrue(not both.result.ok, "a device registration may not also present a token")
  assertEqual(both.result.code, "invalid_message", "code")

  -- And an ordinary operation with no token at all is refused too.
  local naked = sim:input("alex-pc", { kind = "external_call", operation = "test.identity" })
  assertTrue(not naked.result.ok, "an ordinary operation needs its Access Token")
  assertEqual(naked.result.code, "invalid_message", "code")
end)

test("scenario 8: the External Application does not call into a Customer Network", function()
  local sim = build()

  -- An external_call arriving from upstream is not a call to serve. Both the
  -- ISP and the Customer Router refuse one, so there is no path inward.
  local atRouter = sim:input("router-home", {
    kind = "message",
    relationship_id = "rel-acme-home",
    message = {
      kind = "external_call", request_id = "req-inbound",
      body = core.object({
        source = core.object({
          computer_id = "computer-home-alex", customer_network_id = "network-home",
          local_address = "192.168.1.20",
        }),
        operation = "test.identity", access_token = "t", payload = core.object(),
      }),
    },
  })
  assertTrue(not atRouter.result.ok, "the router refused it")
  assertEqual(atRouter.result.code, "inbound_denied", "code")
end)

test("scenario 8: a disabled Customer Network cannot reach the External Application", function()
  local sim = build()
  reference.assertOk(sim:input("central", {
    kind = "set_network_status", customer_network_id = "network-farm",
    status = "disabled", command_id = "cmd-external-1",
  }), "disable farm")

  local before = #gatewayEffects(sim, "central")
  sim:input("harvester", {
    kind = "external_call", operation = "test.identity", access_token = "opaque.bearer.token",
  })
  sim:drain()

  assertEqual(#gatewayEffects(sim, "central"), before,
    "nothing reached the Gateway")
  local answer = sim:lastResultAt("harvester", "error")
  assertTrue(answer ~= nil, "and the Computer was told why")
end)

test("scenario 8: a Gateway that could not carry the call answers the Computer", function()
  local sim = build()

  local sent = callExternal(sim, "alex-pc", {
    operation = "test.identity", access_token = "opaque.bearer.token",
  })
  assertEqual(#sent, 1, "the request was handed to the Gateway")

  -- This is what the runtime reports when there is no Gateway Session. Without
  -- it the Computer would wait out its timeout instead of being told.
  sim:input("central", {
    kind = "effect_result", effect = "gateway", ok = false,
    request_id = sent[1].request_id,
    code = "gateway_unavailable", message = "this role has no Gateway Session",
  })
  sim:drain()

  local answer = sim:lastResultAt("alex-pc", "error")
  assertTrue(answer ~= nil, "the failure reached the Computer that asked")
  assertEqual(answer.code, "gateway_unavailable", "as its stable code")
  assertEqual(sim:engine("router-home").flows:size(), 0, "and the flow was released")
end)

--------------------------------------------------------------------------
-- Scenario 10 -- administration arriving over the Gateway
--------------------------------------------------------------------------

-- An Operator's decision is made in the dashboard and applied here. The
-- External Application never edits a World: it asks, and the Central Server
-- answers on its own authoritative state.

local function gatewayFrames(sim, nodeName)
  local frames = {}
  for _, effect in ipairs(sim:node(nodeName).outbox) do
    if effect.kind == "gateway" then frames[#frames + 1] = effect end
  end
  return frames
end

local function lastGatewayFrame(sim, nodeName)
  local frames = gatewayFrames(sim, nodeName)
  return frames[#frames]
end

local function adminCommand(commandId, body)
  return {
    kind = "gateway_frame",
    frame_kind = "admin_command",
    command_id = commandId,
    request_id = commandId,
    body = core.object(body),
  }
end

test("scenario 10: an administrative command from the Gateway disables a Customer Network", function()
  local sim = build()
  sim:reset()

  local outcome = reference.assertOk(sim:input("central", adminCommand("cmd-0011", {
    action = "set_network_status",
    customer_network_id = "network-farm",
    status = "disabled",
  })), "disable farm from the dashboard")
  assertEqual(outcome.status, "disabled", "the status it applied")
  assertTrue(not outcome.repeated, "the first application is not a repeat")

  local frame = lastGatewayFrame(sim, "central")
  assertTrue(frame ~= nil, "the Central Server answered the command")
  assertEqual(frame.message_kind, "command_result", "answer kind")
  assertEqual(frame.command_id, "cmd-0011", "the answer carries the Command ID")
  assertEqual(get(frame.body, "status"), "applied", "answer status")
  local ok, problem = protocol.conformance.schema.validateBody("command_result", frame.body)
  assertTrue(ok, "the answer is a valid command_result: " .. tostring(problem))

  -- And the World really is disabled: new Farm traffic is refused.
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  assertEqual(sim:lastResultAt("alex-pc", "error").code, "network_disabled", "new Farm traffic")
end)

test("scenario 10: repeating a Command ID from the Gateway is harmless", function()
  local sim = build()
  reference.assertOk(sim:input("central", adminCommand("cmd-0012", {
    action = "set_network_status",
    customer_network_id = "network-farm",
    status = "disabled",
  })), "disable")

  sim:reset()
  local again = reference.assertOk(sim:input("central", adminCommand("cmd-0012", {
    action = "set_network_status",
    customer_network_id = "network-farm",
    status = "disabled",
  })), "the same command again")
  assertTrue(again.repeated, "the repeat returned the already-applied result")

  -- It is still answered, so the External Application stops resending it.
  local frame = lastGatewayFrame(sim, "central")
  assertEqual(get(frame.body, "status"), "applied", "a repeat is still applied")
end)

test("scenario 10: re-enabling over the Gateway needs no re-enrollment", function()
  local sim = build()
  reference.assertOk(sim:input("central", adminCommand("cmd-0013", {
    action = "set_network_status",
    customer_network_id = "network-farm",
    status = "disabled",
  })), "disable")
  reference.assertOk(sim:input("central", adminCommand("cmd-0014", {
    action = "set_network_status",
    customer_network_id = "network-farm",
    status = "enabled",
  })), "re-enable")

  -- The durable registrations were never touched, so traffic simply resumes.
  assertEqual(bindingOf(sim, "router-farm", "computer-farm-harvester").address, "192.168.1.20",
    "the binding survived")
  sim:reset()
  sim:input("alex-pc", {
    kind = "local_request",
    destination = { customer_network_id = "network-farm", computer_id = "computer-farm-harvester" },
    service = "harvester.status",
    payload = core.object({}),
  })
  local recovered = sim:lastResultAt("alex-pc", "service_response")
  assertTrue(recovered and recovered.ok, "traffic resumed")
end)

test("scenario 10: a command for an unknown Customer Network is refused out loud", function()
  local sim = build()
  sim:reset()
  local outcome = sim:input("central", adminCommand("cmd-0015", {
    action = "set_network_status",
    customer_network_id = "network-nowhere",
    status = "disabled",
  }))
  assertTrue(not outcome.result.ok, "it was refused")
  assertEqual(outcome.result.code, "route_not_found", "code")

  -- A command with no answer is one the External Application resends forever.
  local frame = lastGatewayFrame(sim, "central")
  assertTrue(frame ~= nil, "the refusal was still answered")
  assertEqual(get(frame.body, "status"), "rejected", "answer status")
  local ok, problem = protocol.conformance.schema.validateBody("command_result", frame.body)
  assertTrue(ok, "a rejection is a valid command_result: " .. tostring(problem))
end)

test("scenario 10: the Gateway carries only answers and commands inward", function()
  local sim = build()
  sim:reset()
  local outcome = sim:input("central", {
    kind = "gateway_frame",
    frame_kind = "admin_command",
    command_id = "cmd-0016",
    body = core.object({ action = "delete_everything" }),
  })
  assertTrue(not outcome.result.ok, "an unknown action is refused")
  assertEqual(outcome.result.code, "forbidden_operation", "code")

  -- An answer is carried inward, but only for a call this World actually made.
  -- One that matches nothing is not invented into an answer for anybody.
  local unmatched = sim:input("central", {
    kind = "gateway_frame", frame_kind = "external_response",
    request_id = "central-overworld-r999", body = core.object({ payload = core.object() }),
  })
  assertTrue(not unmatched.result.ok, "an answer to nothing is refused")
  assertEqual(unmatched.result.code, "nat_flow_missing", "code")

  local refused = sim:input("central", {
    kind = "gateway_frame", frame_kind = "dns_query", body = core.object({}),
  })
  assertTrue(not refused.result.ok, "nothing else arrives inward in v1")
  assertEqual(refused.result.code, "forbidden_operation", "code")
end)
