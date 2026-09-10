-- Guards the package boundary.
--
-- craftnet-protocol is meant to be deep: callers exchange semantic messages and
-- never calculate a MAC, a counter, a body hash, an operational channel, or a
-- canonical form. These tests fail if that surface widens by accident.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")

-- The complete intended public surface. `conformance` and `internal` are the
-- one deliberate exception: they exist so the shared fixture catalog can be
-- replayed in Lua exactly as it is in Go.
local PUBLIC_SURFACE = {
  name = "string",
  version = "string",
  wireVersion = "number",
  object = "function",
  array = "function",
  null = "table",
  open = "function",
  childEnrollment = "function",
  parentEnrollment = "function",
  childSession = "function",
  parentSession = "function",
  discovery = "table",
  handshake = "table",
  errors = "table",
  limits = "table",
  validate = "table",
  conformance = "table",
  internal = "function",
}

test("the package exposes exactly its intended surface", function()
  for key, expectedType in pairs(PUBLIC_SURFACE) do
    assertEqual(type(protocol[key]), expectedType, "protocol." .. key)
  end
  for key in pairs(protocol) do
    assertTrue(PUBLIC_SURFACE[key] ~= nil,
      "protocol." .. key .. " is not part of the documented surface")
  end
end)

test("no cryptographic helper is reachable from the public surface", function()
  for _, name in ipairs({ "sha256", "hmac", "mac", "bodyHash", "cj1", "encode", "decode",
    "keys", "frame", "schema", "sessionKey", "relationshipCredential", "nonce" }) do
    assertTrue(protocol[name] == nil,
      "protocol." .. name .. " leaks an internal helper to callers")
  end
end)

test("the error catalog is readable but its entries are wire constants", function()
  assertEqual(protocol.errors.retryable("busy"), true, "busy is retryable")
  assertEqual(protocol.errors.retryable("authentication_failed"), false, "authentication is not")
  assertTrue(protocol.errors.isKnown("gateway_unavailable"), "known code")
  assertTrue(not protocol.errors.isKnown("teapot"), "unknown code")

  local body = protocol.errors.new("route_not_found")
  assertEqual(rawget(body, "code"), "route_not_found", "code")
  assertEqual(rawget(body, "retryable"), false, "retryability comes from the catalog")
  assertTrue(rawget(body, "details") == nil, "an optional field is omitted, not emptied")
end)

test("an empty array and an empty object stay distinguishable on the wire", function()
  local cj1 = protocol.conformance.cj1
  assertEqual(cj1.encode(protocol.array({})), "[]", "explicit empty array")
  assertEqual(cj1.encode(protocol.object({})), "{}", "explicit empty object")
  -- A bare Lua table is ambiguous, so it resolves to an object rather than
  -- silently choosing an array.
  assertEqual(cj1.encode({}), "{}", "a bare empty table is an object")
end)

test("a caller completes a full exchange without touching any crypto", function()
  -- This mirrors what a role package does in Milestone 4: build bodies with the
  -- package's own constructors, drive the handshakes, and send. No MAC, counter,
  -- body hash, or canonical form appears anywhere in this test body.
  local child = protocol.childEnrollment({
    enrollment_secret = "shared-lan-password",
    role = "computer",
    requested_name = "harvester",
    client_nonce = string.rep("ab", 32),
    request_id = "req-join-1",
  })
  local parent = protocol.parentEnrollment({
    enrollment_secret = "shared-lan-password",
    parent_id = "rtr-farm",
    parent_revision = 4,
    parent_nonce = string.rep("cd", 32),
    assign = function()
      return {
        child_id = "cmp-harvester",
        relationship_id = "rel-farm-0007",
        operational_channel = 3100,
        configuration = protocol.object({
          computer_id = "cmp-harvester",
          hostname = "harvester",
          address = "192.168.1.20",
          customer_network_id = "net-farm",
          router_address = "192.168.1.1",
          dns_address = "192.168.1.1",
        }),
      }
    end,
  })

  local challenge = assert(parent:receiveOpen(assert(child:open())))
  local confirm = assert(child:receiveChallenge(challenge))
  local accept = assert(parent:receiveConfirm(confirm))
  local enrolled = assert(child:receiveAccept(accept))

  assertEqual(rawget(enrolled.configuration, "address"), "192.168.1.20", "configuration arrived")
  assertEqual(enrolled.operational_channel, 3100, "the package chose the channel, not the caller")
end)

test("a LAN password admits a computer once and a wrong one never does", function()
  local function join(password)
    local child = protocol.childEnrollment({
      enrollment_secret = password,
      role = "computer",
      requested_name = "harvester",
      client_nonce = string.rep("ab", 32),
      request_id = "req-join-1",
    })
    local parent = protocol.parentEnrollment({
      enrollment_secret = "correct horse battery staple",
      parent_id = "rtr-farm",
      parent_revision = 4,
      parent_nonce = string.rep("cd", 32),
      assign = function()
        return {
          child_id = "cmp-harvester",
          relationship_id = "rel-farm-0007",
          operational_channel = 3100,
          configuration = protocol.object({
            computer_id = "cmp-harvester", hostname = "harvester",
            address = "192.168.1.20", customer_network_id = "net-farm",
            router_address = "192.168.1.1", dns_address = "192.168.1.1",
          }),
        }
      end,
    })
    return parent:receiveOpen(assert(child:open()))
  end

  assertTrue(join("correct horse battery staple") ~= nil, "the right password admits the computer")
  local refused, code = join("correct horse battery stapl")
  assertTrue(refused == nil, "a wrong password must not be admitted")
  assertEqual(code, "authentication_failed", "code")
end)
