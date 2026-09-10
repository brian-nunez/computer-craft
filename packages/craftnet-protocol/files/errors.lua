-- The stable CraftNet v1 error catalog.
--
-- Codes are wire constants: they change only through an explicit wire-version
-- decision. `retryable` describes whether a fresh attempt could succeed; it
-- never authorizes automatic replay of a non-idempotent request.

local errors = {}

local catalog = {
  { code = "invalid_message",       retryable = false, meaning = "JSON, type, required-field, or canonical-form validation failed" },
  { code = "unsupported_version",   retryable = false, meaning = "Peer does not implement the requested major version" },
  { code = "message_too_large",     retryable = false, meaning = "Frame, payload, snapshot, or batch exceeds a limit" },
  { code = "busy",                  retryable = true,  meaning = "Bounded in-flight capacity is exhausted" },
  { code = "authentication_failed", retryable = false, meaning = "Enrollment, session, Gateway, or device proof failed" },
  { code = "replay_rejected",       retryable = false, meaning = "Session ID, nonce, request, or counter was reused or out of order" },
  { code = "credential_revoked",    retryable = false, meaning = "Durable relationship, device, or Gateway credential is revoked" },
  { code = "access_token_expired",  retryable = true,  meaning = "The two-minute Access Token is expired" },
  { code = "forbidden_operation",   retryable = false, meaning = "Credential is valid but does not authorize the operation" },
  { code = "name_not_found",        retryable = false, meaning = "DNS name has no authoritative record" },
  { code = "name_conflict",         retryable = false, meaning = "Requested ISP, network, or hostname already exists in its scope" },
  { code = "pool_exhausted",        retryable = false, meaning = "No Customer or Provider Address is available" },
  { code = "address_conflict",      retryable = false, meaning = "Address is already bound in the relevant scope" },
  { code = "router_unavailable",    retryable = true,  meaning = "Destination or local Customer Router is disconnected" },
  { code = "upstream_unavailable",  retryable = true,  meaning = "Immediate parent relationship is unavailable" },
  { code = "route_not_found",       retryable = false, meaning = "Central route map has no destination Customer Network" },
  { code = "inbound_denied",        retryable = false, meaning = "No matching Exposed Service permits a new remote request" },
  { code = "nat_flow_missing",      retryable = false, meaning = "Reply refers to an expired or unknown NAT Flow" },
  { code = "network_disabled",      retryable = false, meaning = "Central Network Status disables the Customer Network" },
  { code = "gateway_unavailable",   retryable = true,  meaning = "Central Server lacks a ready Gateway Session" },
  { code = "request_timeout",       retryable = true,  meaning = "No terminal response arrived before the operation deadline" },
  { code = "revision_conflict",     retryable = true,  meaning = "Command or update was based on stale authoritative state" },
  { code = "internal_error",        retryable = true,  meaning = "An unexpected owner-side failure occurred without exposing internals" },
}

errors.catalog = catalog

local byCode = {}
for index = 1, #catalog do
  byCode[catalog[index].code] = catalog[index]
end

function errors.isKnown(code)
  return byCode[code] ~= nil
end

function errors.retryable(code)
  local entry = byCode[code]
  assert(entry, "unknown error code " .. tostring(code))
  return entry.retryable
end

function errors.meaning(code)
  local entry = byCode[code]
  assert(entry, "unknown error code " .. tostring(code))
  return entry.meaning
end

-- new builds an error body. `message` is player-safe prose; `details` carries
-- only non-secret structured context and is omitted when absent.
function errors.new(code, message, details)
  local entry = byCode[code]
  assert(entry, "unknown error code " .. tostring(code))
  local body = {
    code = code,
    message = message or entry.meaning,
    retryable = entry.retryable,
  }
  if details ~= nil then body.details = details end
  return body
end

return errors
