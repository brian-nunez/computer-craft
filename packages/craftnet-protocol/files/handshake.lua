-- Enrollment and session establishment.
--
-- One-time enrollment is separated from ongoing authentication: an enrollment
-- secret is exchanged exactly once for a durable relationship credential, and
-- every later reconnect derives a fresh session key from a fresh transcript.
-- Neither side ever resumes an old session.

local internal = ...
local cj1 = internal("cj1")
local keys = internal("keys")
local frame = internal("frame")
local schema = internal("schema")

local handshake = {}

local function fail(code, message)
  return nil, code, message
end

local function requireFields(options, names)
  for _, name in ipairs(names) do
    assert(options[name] ~= nil, "handshake requires option '" .. name .. "'")
  end
end

--------------------------------------------------------------------------
-- Enrollment: child side
--------------------------------------------------------------------------

local ChildEnrollment = {}
ChildEnrollment.__index = ChildEnrollment

-- childEnrollment drives discover -> enroll_open -> enroll_confirm on the
-- joining side. `enrollment_secret` is the one-time ISP or Router Enrollment
-- Token, or the LAN Password, already reduced to bytes by the caller.
function handshake.childEnrollment(options)
  requireFields(options, { "enrollment_secret", "role", "requested_name", "client_nonce", "request_id" })
  assert(schema.scalars.role(options.role), "role must be a CraftNet role")
  assert(schema.scalars.normalized_name(options.requested_name), "requested_name must be normalized")
  assert(schema.scalars.nonce(options.client_nonce), "client_nonce must be 32 lowercase hex bytes")
  assert(schema.scalars.id(options.request_id), "request_id must be a CraftNet ID")
  if options.client_id ~= nil then
    assert(schema.scalars.id(options.client_id), "client_id must be a CraftNet ID when re-enrolling")
  end
  return setmetatable({
    secret = options.enrollment_secret,
    role = options.role,
    requestedName = options.requested_name,
    clientNonce = options.client_nonce,
    clientId = options.client_id,
    requestId = options.request_id,
    childRevision = options.child_revision or 0,
    stage = "open",
  }, ChildEnrollment)
end

function ChildEnrollment:open()
  if self.stage ~= "open" then return fail("invalid_message", "enrollment is past enroll_open") end
  local body = cj1.object({
    role = self.role,
    requested_name = self.requestedName,
    client_nonce = self.clientNonce,
  })
  if self.clientId ~= nil then rawset(body, "client_id", self.clientId) end
  local text, code, message = frame.sealHandshake(self.secret, "enroll_open", self.requestId, body)
  if not text then return fail(code, message) end
  self.stage = "challenge"
  return text
end

function ChildEnrollment:receiveChallenge(text)
  if self.stage ~= "challenge" then return fail("invalid_message", "enrollment is not awaiting a challenge") end
  local message, code, detail = frame.openHandshake(self.secret, text)
  if not message then return fail(code, detail) end
  if message.kind == "enroll_error" then
    return fail(rawget(message.body, "code"), rawget(message.body, "message"))
  end
  if message.kind ~= "enroll_challenge" then
    return fail("invalid_message", "expected enroll_challenge, received " .. message.kind)
  end
  if message.request_id ~= self.requestId then
    return fail("invalid_message", "challenge does not correlate with enroll_open")
  end

  local body = message.body
  if rawget(body, "client_nonce") ~= self.clientNonce then
    return fail("replay_rejected", "challenge echoes a different client nonce")
  end

  self.parentId = rawget(body, "parent_id")
  self.relationshipId = rawget(body, "relationship_id")
  self.parentNonce = rawget(body, "parent_nonce")
  self.parentRevision = rawget(body, "parent_revision")

  self.transcript = keys.enrollmentTranscript({
    child_id = self.clientId,
    requested_name = self.requestedName,
    role = self.role,
    parent_id = self.parentId,
    relationship_id = self.relationshipId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    parent_revision = self.parentRevision,
  })

  local credential, credentialCode, credentialMessage = keys.relationshipCredential(self.secret, self.transcript)
  if not credential then return fail(credentialCode, credentialMessage) end
  self.credential = credential

  local confirmBody = cj1.object({
    relationship_id = self.relationshipId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    child_revision = self.childRevision,
  })
  local confirmText, confirmCode, confirmMessage =
    frame.sealHandshake(self.secret, "enroll_confirm", self.requestId, confirmBody)
  if not confirmText then return fail(confirmCode, confirmMessage) end
  self.stage = "accept"
  return confirmText
end

-- receiveAccept returns the durable outcome the child must commit before it
-- ever opens a session.
function ChildEnrollment:receiveAccept(text)
  if self.stage ~= "accept" then return fail("invalid_message", "enrollment is not awaiting an accept") end
  local message, code, detail = frame.openHandshake(self.secret, text)
  if not message then return fail(code, detail) end
  if message.kind == "enroll_error" then
    return fail(rawget(message.body, "code"), rawget(message.body, "message"))
  end
  if message.kind ~= "enroll_accept" then
    return fail("invalid_message", "expected enroll_accept, received " .. message.kind)
  end
  if message.request_id ~= self.requestId then
    return fail("invalid_message", "accept does not correlate with enroll_open")
  end

  local body = message.body
  if rawget(body, "relationship_id") ~= self.relationshipId then
    return fail("authentication_failed", "accept names another relationship")
  end
  if self.clientId ~= nil and rawget(body, "child_id") ~= self.clientId then
    return fail("authentication_failed", "accept reassigns an existing child identity")
  end
  local ok, configurationMessage = schema.validateConfiguration(self.role, rawget(body, "configuration"))
  if not ok then return fail("invalid_message", configurationMessage) end

  self.stage = "enrolled"
  return {
    child_id = rawget(body, "child_id"),
    relationship_id = self.relationshipId,
    parent_id = self.parentId,
    relationship_credential = self.credential,
    operational_channel = rawget(body, "operational_channel"),
    configuration = rawget(body, "configuration"),
    parent_revision = rawget(body, "parent_revision"),
  }
end

--------------------------------------------------------------------------
-- Enrollment: parent side
--------------------------------------------------------------------------

local ParentEnrollment = {}
ParentEnrollment.__index = ParentEnrollment

-- parentEnrollment drives the authority side. `assign` supplies the identities
-- and configuration the parent alone owns; it is called only after the child's
-- proof verifies.
function handshake.parentEnrollment(options)
  requireFields(options, { "enrollment_secret", "parent_id", "parent_revision", "parent_nonce", "assign" })
  assert(schema.scalars.id(options.parent_id), "parent_id must be a CraftNet ID")
  assert(schema.scalars.nonce(options.parent_nonce), "parent_nonce must be 32 lowercase hex bytes")
  assert(type(options.assign) == "function", "assign must be a function")
  return setmetatable({
    secret = options.enrollment_secret,
    parentId = options.parent_id,
    parentRevision = options.parent_revision,
    parentNonce = options.parent_nonce,
    assign = options.assign,
    stage = "open",
  }, ParentEnrollment)
end

function ParentEnrollment:receiveOpen(text)
  if self.stage ~= "open" then return fail("invalid_message", "enrollment is past enroll_open") end
  local message, code, detail = frame.openHandshake(self.secret, text)
  if not message then return fail(code, detail) end
  if message.kind ~= "enroll_open" then
    return fail("invalid_message", "expected enroll_open, received " .. message.kind)
  end

  local body = message.body
  self.requestId = message.request_id
  self.role = rawget(body, "role")
  self.requestedName = rawget(body, "requested_name")
  self.clientNonce = rawget(body, "client_nonce")
  self.clientId = rawget(body, "client_id")

  local assignment, assignCode, assignMessage = self.assign({
    role = self.role,
    requested_name = self.requestedName,
    client_id = self.clientId,
  })
  if not assignment then return fail(assignCode or "internal_error", assignMessage) end
  self.assignment = assignment
  self.relationshipId = assignment.relationship_id

  self.transcript = keys.enrollmentTranscript({
    child_id = self.clientId,
    requested_name = self.requestedName,
    role = self.role,
    parent_id = self.parentId,
    relationship_id = self.relationshipId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    parent_revision = self.parentRevision,
  })
  local credential, credentialCode, credentialMessage = keys.relationshipCredential(self.secret, self.transcript)
  if not credential then return fail(credentialCode, credentialMessage) end
  self.credential = credential

  local challengeBody = cj1.object({
    parent_id = self.parentId,
    relationship_id = self.relationshipId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    parent_revision = self.parentRevision,
  })
  self.stage = "confirm"
  return frame.sealHandshake(self.secret, "enroll_challenge", self.requestId, challengeBody)
end

-- receiveConfirm returns the accept text and the credential to commit. The
-- caller invalidates the one-time enrollment secret only after both are durable.
function ParentEnrollment:receiveConfirm(text)
  if self.stage ~= "confirm" then return fail("invalid_message", "enrollment is not awaiting a confirm") end
  local message, code, detail = frame.openHandshake(self.secret, text)
  if not message then return fail(code, detail) end
  if message.kind ~= "enroll_confirm" then
    return fail("invalid_message", "expected enroll_confirm, received " .. message.kind)
  end
  if message.request_id ~= self.requestId then
    return fail("invalid_message", "confirm does not correlate with enroll_open")
  end

  local body = message.body
  if rawget(body, "relationship_id") ~= self.relationshipId then
    return fail("authentication_failed", "confirm names another relationship")
  end
  if rawget(body, "client_nonce") ~= self.clientNonce
    or rawget(body, "parent_nonce") ~= self.parentNonce then
    return fail("replay_rejected", "confirm does not echo the challenge nonces")
  end

  local acceptBody = cj1.object({
    child_id = self.assignment.child_id,
    relationship_id = self.relationshipId,
    operational_channel = self.assignment.operational_channel,
    configuration = self.assignment.configuration,
    parent_revision = self.parentRevision,
  })
  local acceptText, acceptCode, acceptMessage =
    frame.sealHandshake(self.secret, "enroll_accept", self.requestId, acceptBody)
  if not acceptText then return fail(acceptCode, acceptMessage) end

  self.stage = "enrolled"
  return acceptText, {
    child_id = self.assignment.child_id,
    relationship_id = self.relationshipId,
    relationship_credential = self.credential,
    child_revision = rawget(body, "child_revision"),
  }
end

--------------------------------------------------------------------------
-- Session establishment
--------------------------------------------------------------------------

local ChildSession = {}
ChildSession.__index = ChildSession

function handshake.childSession(options)
  requireFields(options, { "relationship_credential", "relationship_id", "client_nonce", "request_id" })
  assert(schema.scalars.id(options.relationship_id), "relationship_id must be a CraftNet ID")
  assert(schema.scalars.nonce(options.client_nonce), "client_nonce must be 32 lowercase hex bytes")
  return setmetatable({
    credential = options.relationship_credential,
    relationshipId = options.relationship_id,
    clientNonce = options.client_nonce,
    childRevision = options.child_revision or 0,
    requestId = options.request_id,
    stage = "open",
  }, ChildSession)
end

function ChildSession:open()
  if self.stage ~= "open" then return fail("invalid_message", "session is past session_open") end
  local body = cj1.object({
    relationship_id = self.relationshipId,
    client_nonce = self.clientNonce,
    child_revision = self.childRevision,
  })
  local text, code, message = frame.sealHandshake(self.credential, "session_open", self.requestId, body)
  if not text then return fail(code, message) end
  self.stage = "challenge"
  return text
end

-- receiveChallenge returns the confirm text and the established session.
function ChildSession:receiveChallenge(text)
  if self.stage ~= "challenge" then return fail("invalid_message", "session is not awaiting a challenge") end
  local message, code, detail = frame.openHandshake(self.credential, text)
  if not message then return fail(code, detail) end
  if message.kind ~= "session_challenge" then
    return fail("invalid_message", "expected session_challenge, received " .. message.kind)
  end
  if message.request_id ~= self.requestId then
    return fail("invalid_message", "challenge does not correlate with session_open")
  end

  local body = message.body
  if rawget(body, "relationship_id") ~= self.relationshipId then
    return fail("authentication_failed", "challenge names another relationship")
  end
  if rawget(body, "client_nonce") ~= self.clientNonce then
    return fail("replay_rejected", "challenge echoes a different client nonce")
  end

  local sessionId = rawget(body, "session_id")
  local transcript = keys.sessionTranscript({
    relationship_id = self.relationshipId,
    session_id = sessionId,
    client_nonce = self.clientNonce,
    parent_nonce = rawget(body, "parent_nonce"),
    child_revision = self.childRevision,
    parent_revision = rawget(body, "parent_revision"),
  })
  local sessionKey, keyCode, keyMessage = keys.sessionKey(self.credential, transcript)
  if not sessionKey then return fail(keyCode, keyMessage) end

  local confirmBody = cj1.object({
    relationship_id = self.relationshipId,
    session_id = sessionId,
    client_nonce = self.clientNonce,
    parent_nonce = rawget(body, "parent_nonce"),
  })
  local confirmText, confirmCode, confirmMessage =
    frame.sealHandshake(self.credential, "session_confirm", self.requestId, confirmBody)
  if not confirmText then return fail(confirmCode, confirmMessage) end

  self.stage = "established"
  return confirmText, frame.newSession({
    relationship_id = self.relationshipId,
    session_id = sessionId,
    session_key = sessionKey,
  }), transcript
end

local ParentSession = {}
ParentSession.__index = ParentSession

-- parentSession refuses a session ID or nonce that has already been used with
-- this relationship credential, because reuse would repeat a session key.
function handshake.parentSession(options)
  requireFields(options, { "relationship_credential", "relationship_id", "parent_nonce", "parent_revision", "session_id" })
  assert(schema.scalars.id(options.session_id), "session_id must be a CraftNet ID")
  assert(schema.scalars.nonce(options.parent_nonce), "parent_nonce must be 32 lowercase hex bytes")
  return setmetatable({
    credential = options.relationship_credential,
    relationshipId = options.relationship_id,
    parentNonce = options.parent_nonce,
    parentRevision = options.parent_revision,
    sessionId = options.session_id,
    usedSessionIds = options.used_session_ids or {},
    usedNonces = options.used_nonces or {},
    stage = "open",
  }, ParentSession)
end

function ParentSession:receiveOpen(text)
  if self.stage ~= "open" then return fail("invalid_message", "session is past session_open") end
  local message, code, detail = frame.openHandshake(self.credential, text)
  if not message then return fail(code, detail) end
  if message.kind ~= "session_open" then
    return fail("invalid_message", "expected session_open, received " .. message.kind)
  end

  local body = message.body
  if rawget(body, "relationship_id") ~= self.relationshipId then
    return fail("authentication_failed", "session_open names another relationship")
  end
  if self.usedSessionIds[self.sessionId] then
    return fail("replay_rejected", "session identifier was already used with this relationship")
  end
  local clientNonce = rawget(body, "client_nonce")
  if self.usedNonces[clientNonce] then
    return fail("replay_rejected", "client nonce was already used with this relationship")
  end

  self.requestId = message.request_id
  self.clientNonce = clientNonce
  self.childRevision = rawget(body, "child_revision")

  self.transcript = keys.sessionTranscript({
    relationship_id = self.relationshipId,
    session_id = self.sessionId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    child_revision = self.childRevision,
    parent_revision = self.parentRevision,
  })
  local sessionKey, keyCode, keyMessage = keys.sessionKey(self.credential, self.transcript)
  if not sessionKey then return fail(keyCode, keyMessage) end
  self.sessionKey = sessionKey

  local challengeBody = cj1.object({
    relationship_id = self.relationshipId,
    session_id = self.sessionId,
    client_nonce = self.clientNonce,
    parent_nonce = self.parentNonce,
    parent_revision = self.parentRevision,
  })
  self.stage = "confirm"
  return frame.sealHandshake(self.credential, "session_challenge", self.requestId, challengeBody)
end

function ParentSession:receiveConfirm(text)
  if self.stage ~= "confirm" then return fail("invalid_message", "session is not awaiting a confirm") end
  local message, code, detail = frame.openHandshake(self.credential, text)
  if not message then return fail(code, detail) end
  if message.kind ~= "session_confirm" then
    return fail("invalid_message", "expected session_confirm, received " .. message.kind)
  end
  if message.request_id ~= self.requestId then
    return fail("invalid_message", "confirm does not correlate with session_open")
  end

  local body = message.body
  if rawget(body, "session_id") ~= self.sessionId
    or rawget(body, "relationship_id") ~= self.relationshipId then
    return fail("authentication_failed", "confirm names another session")
  end
  if rawget(body, "client_nonce") ~= self.clientNonce
    or rawget(body, "parent_nonce") ~= self.parentNonce then
    return fail("replay_rejected", "confirm does not echo the challenge nonces")
  end

  self.usedSessionIds[self.sessionId] = true
  self.usedNonces[self.clientNonce] = true
  self.stage = "established"
  return frame.newSession({
    relationship_id = self.relationshipId,
    session_id = self.sessionId,
    session_key = self.sessionKey,
  }), self.transcript
end

return handshake
