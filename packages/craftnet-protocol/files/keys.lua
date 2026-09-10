-- CraftNet key derivation and message proofs.
--
-- Secrets prove an already assigned identity; they are never the identity. Every
-- derivation is purpose separated by a label so that a relationship credential
-- can never be replayed as a session key, a nonce, or an enrollment secret, and
-- every input is canonicalized before it is signed.

local internal = ...
local cj1 = internal("cj1")
local sha256 = internal("sha256")
local hmac = internal("hmac")
local schema = internal("schema")

local keys = {}

local LABEL_ENROLLMENT = "craftnet/v1/enrollment\n"
local LABEL_RELATIONSHIP = "craftnet/v1/relationship\n"
local LABEL_SESSION = "craftnet/v1/session\n"
local LABEL_NONCE = "craftnet/v1/nonce\n"

keys.labels = {
  enrollment = LABEL_ENROLLMENT,
  relationship = LABEL_RELATIONSHIP,
  session = LABEL_SESSION,
  nonce = LABEL_NONCE,
}

keys.toHex = sha256.toHex
keys.fromHex = sha256.fromHex

--------------------------------------------------------------------------
-- Transcripts
--------------------------------------------------------------------------

local enrollmentTranscriptShape = {
  required = {
    requested_name = "normalized_name",
    role = "role",
    parent_id = "id",
    relationship_id = "id",
    client_nonce = "nonce",
    parent_nonce = "nonce",
    parent_revision = "revision",
  },
  -- child_id appears only when an existing logical child re-enrolls after a
  -- revocation, so a first enrollment and a re-enrollment never share a
  -- transcript and therefore never derive the same credential.
  optional = { child_id = "id" },
}

local sessionTranscriptShape = {
  required = {
    relationship_id = "id",
    session_id = "id",
    client_nonce = "nonce",
    parent_nonce = "nonce",
    child_revision = "revision",
    parent_revision = "revision",
  },
}

keys.enrollmentTranscriptShape = enrollmentTranscriptShape
keys.sessionTranscriptShape = sessionTranscriptShape

local function canonicalTranscript(shape, transcript, label)
  local ok, message = schema.validateShape(shape, transcript, label)
  if not ok then return nil, "invalid_message", message end
  local text, code, detail = cj1.encode(transcript)
  if not text then return nil, code, detail end
  return text
end

function keys.enrollmentTranscript(fields)
  local transcript = cj1.object({
    requested_name = fields.requested_name,
    role = fields.role,
    parent_id = fields.parent_id,
    relationship_id = fields.relationship_id,
    client_nonce = fields.client_nonce,
    parent_nonce = fields.parent_nonce,
    parent_revision = fields.parent_revision,
  })
  if fields.child_id ~= nil then rawset(transcript, "child_id", fields.child_id) end
  return transcript
end

function keys.sessionTranscript(fields)
  return cj1.object({
    relationship_id = fields.relationship_id,
    session_id = fields.session_id,
    client_nonce = fields.client_nonce,
    parent_nonce = fields.parent_nonce,
    child_revision = fields.child_revision,
    parent_revision = fields.parent_revision,
  })
end

--------------------------------------------------------------------------
-- Derivation
--------------------------------------------------------------------------

-- enrollmentSecret lets a parent derive a child's one-time enrollment secret
-- from its own root secret rather than storing a separate secret per child.
function keys.enrollmentSecret(rootSecret, childRole, tokenUseCounter)
  assert(type(rootSecret) == "string" and #rootSecret > 0, "root secret must be a byte string")
  assert(schema.scalars.role(childRole), "child role must be a CraftNet role")
  assert(schema.scalars.non_negative(tokenUseCounter), "token use counter must be a non-negative integer")
  local context = cj1.mustEncode(cj1.array({ 1, childRole, tokenUseCounter }))
  return hmac.bytes(rootSecret, LABEL_ENROLLMENT .. context)
end

-- relationshipCredential is the durable credential both peers commit after a
-- successful enrollment. The parent invalidates the one-time secret only after
-- enroll_accept is durably committed.
function keys.relationshipCredential(enrollmentSecret, transcript)
  assert(type(enrollmentSecret) == "string", "enrollment secret must be a byte string")
  local text, code, message = canonicalTranscript(enrollmentTranscriptShape, transcript, "enrollment_transcript")
  if not text then return nil, code, message end
  return hmac.bytes(enrollmentSecret, LABEL_RELATIONSHIP .. text)
end

-- sessionKey is fresh for every reconnect. A session ID or nonce may never be
-- reused with the same relationship credential.
function keys.sessionKey(relationshipCredential, transcript)
  assert(type(relationshipCredential) == "string", "relationship credential must be a byte string")
  local text, code, message = canonicalTranscript(sessionTranscriptShape, transcript, "session_transcript")
  if not text then return nil, code, message end
  return hmac.bytes(relationshipCredential, LABEL_SESSION .. text)
end

-- nonce is derived, never drawn from math.random. Uniqueness comes from a
-- durable per-relationship generation counter whose increment is committed
-- before the nonce is transmitted.
function keys.nonce(relationshipCredential, role, generation)
  assert(type(relationshipCredential) == "string", "relationship credential must be a byte string")
  assert(schema.scalars.role(role), "role must be a CraftNet role")
  assert(schema.scalars.non_negative(generation), "generation must be a non-negative integer")
  local context = cj1.mustEncode(cj1.array({ 1, role, generation }))
  return sha256.toHex(hmac.bytes(relationshipCredential, LABEL_NONCE .. context))
end

--------------------------------------------------------------------------
-- Proofs
--------------------------------------------------------------------------

-- handshakeProof covers the whole unsigned outer object of an enrollment or
-- session-establishment message.
function keys.handshakeProof(secret, kind, requestId, body)
  assert(type(secret) == "string", "handshake secret must be a byte string")
  local text, code, message = cj1.encode(cj1.array({ schema.VERSION, kind, requestId, body }))
  if not text then return nil, code, message end
  return sha256.toHex(hmac.bytes(secret, text))
end

function keys.bodyHash(body)
  local text, code, message = cj1.encode(body)
  if not text then return nil, code, message end
  return sha256.hex(text)
end

-- macInput is the exact operational signing preimage. Messages with no request
-- correlation use the empty string for request_id.
function keys.macInput(kind, relationshipId, sessionId, requestId, counter, bodyHash)
  return cj1.encode(cj1.array({
    schema.VERSION, kind, relationshipId, sessionId, requestId or "", counter, bodyHash,
  }))
end

function keys.mac(sessionKey, kind, relationshipId, sessionId, requestId, counter, bodyHash)
  local text, code, message = keys.macInput(kind, relationshipId, sessionId, requestId, counter, bodyHash)
  if not text then return nil, code, message end
  return sha256.toHex(hmac.bytes(sessionKey, text))
end

keys.equals = hmac.equals

return keys
