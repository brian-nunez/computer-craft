-- Drives both sides of enrollment and session establishment.
--
-- The fixture catalog proves that recorded exchanges verify and derive the
-- right keys. These tests prove the live state machines agree with each other
-- and fail closed on a wrong secret, a reused session identity, and a replayed
-- nonce.

local protocol = dofile("packages/craftnet-protocol/files/init.lua")
local keys = protocol.conformance.keys

local WORLD_KEY = "development-world-key-material"
local CLIENT_NONCE = string.rep("ab", 32)
local PARENT_NONCE = string.rep("cd", 32)

local function ispConfiguration(name)
  return protocol.object({
    isp_id = "isp-acme",
    isp_name = name,
    operational_channel = 2100,
    provider_allocations = protocol.array({
      protocol.object({ first = "100.64.0.0", last = "100.64.255.255" }),
    }),
  })
end

local function enroll(options)
  options = options or {}
  local secret = keys.enrollmentSecret(WORLD_KEY, "isp", 3)

  local child = protocol.childEnrollment({
    enrollment_secret = options.child_secret or secret,
    role = "isp",
    requested_name = "acme",
    client_nonce = CLIENT_NONCE,
    request_id = "req-enroll-1",
  })
  local parent = protocol.parentEnrollment({
    enrollment_secret = secret,
    parent_id = "central-overworld",
    parent_revision = 12,
    parent_nonce = PARENT_NONCE,
    relationship_id = "rel-acme-0001",
    assign = function(request)
      return {
        child_id = "isp-acme",
        operational_channel = 2100,
        configuration = ispConfiguration(request.requested_name),
      }
    end,
  })
  return child, parent, secret
end

test("enrollment derives the same relationship credential on both sides", function()
  local child, parent = enroll()

  local openText = assert(child:open())
  local challengeText = assert(parent:receiveOpen(openText))
  local confirmText = assert(child:receiveChallenge(challengeText))
  local acceptText, parentOutcome = assert(parent:receiveConfirm(confirmText))
  local childOutcome = assert(child:receiveAccept(acceptText))

  assertEqual(childOutcome.child_id, "isp-acme", "assigned identity")
  assertEqual(childOutcome.relationship_id, "rel-acme-0001", "relationship")
  assertEqual(childOutcome.operational_channel, 2100, "operational channel")
  assertEqual(
    keys.toHex(childOutcome.relationship_credential),
    keys.toHex(parentOutcome.relationship_credential),
    "both sides must derive the same durable credential")
end)

test("a wrong enrollment secret is rejected without revealing why", function()
  local child, parent = enroll({ child_secret = keys.enrollmentSecret(WORLD_KEY, "isp", 4) })
  local openText = assert(child:open())
  local challengeText, code = parent:receiveOpen(openText)
  assertTrue(challengeText == nil, "a forged enrollment must not be answered")
  assertEqual(code, "authentication_failed", "code")
end)

test("a tampered enrollment challenge fails the child's verification", function()
  local child, parent = enroll()
  local challengeText = assert(parent:receiveOpen(assert(child:open())))
  local tampered = string.gsub(challengeText, '"parent_revision":12', '"parent_revision":13', 1)
  local confirmText, code = child:receiveChallenge(tampered)
  assertTrue(confirmText == nil, "a tampered challenge must not be confirmed")
  assertEqual(code, "authentication_failed", "code")
end)

local function establishedCredential()
  local child, parent = enroll()
  local challengeText = assert(parent:receiveOpen(assert(child:open())))
  local confirmText = assert(child:receiveChallenge(challengeText))
  local acceptText = assert(parent:receiveConfirm(confirmText))
  return assert(child:receiveAccept(acceptText)).relationship_credential
end

local function openSession(credential, options)
  options = options or {}
  local child = protocol.childSession({
    relationship_credential = credential,
    relationship_id = "rel-acme-0001",
    client_nonce = options.client_nonce or keys.nonce(credential, "isp", 1),
    child_revision = 4,
    request_id = "req-session-1",
  })
  local parent = protocol.parentSession({
    relationship_credential = credential,
    relationship_id = "rel-acme-0001",
    parent_nonce = keys.nonce(credential, "central", 1),
    parent_revision = 12,
    session_id = options.session_id or "ses-000007",
    used_session_ids = options.used_session_ids,
    used_nonces = options.used_nonces,
  })
  return child, parent
end

test("session establishment derives the same session key on both sides", function()
  local credential = establishedCredential()
  local child, parent = openSession(credential)

  local challengeText = assert(parent:receiveOpen(assert(child:open())))
  local confirmText, childLive = assert(child:receiveChallenge(challengeText))
  local parentLive = assert(parent:receiveConfirm(confirmText))

  assertEqual(keys.toHex(childLive.sessionKey), keys.toHex(parentLive.sessionKey), "session key")
  assertEqual(childLive:nextCounter(), 1, "the first operational counter is 1")
end)

test("a reconnect derives a different session key than the first session", function()
  local credential = establishedCredential()

  local firstChild, firstParent = openSession(credential, { session_id = "ses-000007" })
  local firstConfirm, firstLive = assert(firstChild:receiveChallenge(
    assert(firstParent:receiveOpen(assert(firstChild:open())))))
  assert(firstParent:receiveConfirm(firstConfirm))

  local secondChild, secondParent = openSession(credential, {
    session_id = "ses-000008",
    client_nonce = keys.nonce(credential, "isp", 2),
  })
  local secondConfirm, secondLive = assert(secondChild:receiveChallenge(
    assert(secondParent:receiveOpen(assert(secondChild:open())))))
  assert(secondParent:receiveConfirm(secondConfirm))

  assertTrue(keys.toHex(firstLive.sessionKey) ~= keys.toHex(secondLive.sessionKey),
    "reconnection must not resume the previous session key")
end)

test("a reused session identifier is refused", function()
  local credential = establishedCredential()
  local used = { ["ses-000007"] = true }
  local child, parent = openSession(credential, { used_session_ids = used })
  local challengeText, code = parent:receiveOpen(assert(child:open()))
  assertTrue(challengeText == nil, "a reused session identifier must not be accepted")
  assertEqual(code, "replay_rejected", "code")
end)

test("a reused client nonce is refused", function()
  local credential = establishedCredential()
  local nonce = keys.nonce(credential, "isp", 1)
  local child, parent = openSession(credential, {
    client_nonce = nonce,
    used_nonces = { [nonce] = true },
  })
  local challengeText, code = parent:receiveOpen(assert(child:open()))
  assertTrue(challengeText == nil, "a reused nonce must not be accepted")
  assertEqual(code, "replay_rejected", "code")
end)

test("derived nonces never repeat across generations", function()
  local credential = establishedCredential()
  local seen = {}
  for generation = 1, 64 do
    local nonce = keys.nonce(credential, "isp", generation)
    assertTrue(seen[nonce] == nil, "generation " .. generation .. " repeated a nonce")
    assertEqual(#nonce, 64, "a nonce is 32 bytes of lowercase hexadecimal")
    seen[nonce] = true
  end
  -- The parent's nonce space is separated from the child's by role.
  assertTrue(keys.nonce(credential, "isp", 1) ~= keys.nonce(credential, "central", 1),
    "roles must not share a nonce sequence")
end)

test("an established session carries real traffic and rejects a replay", function()
  local credential = establishedCredential()
  local child, parent = openSession(credential)
  local confirmText, childLive = assert(child:receiveChallenge(
    assert(parent:receiveOpen(assert(child:open())))))
  local parentLive = assert(parent:receiveConfirm(confirmText))

  local text = assert(childLive:seal("heartbeat",
    protocol.object({ connectivity_state = "ready", revision = 4 })))
  local message = assert(parentLive:open(text))
  assertEqual(message.kind, "heartbeat", "kind")
  assertEqual(rawget(message.body, "connectivity_state"), "ready", "state")

  local replayed, code = parentLive:open(text)
  assertTrue(replayed == nil, "a replayed frame must not be accepted")
  assertEqual(code, "replay_rejected", "code")
end)
