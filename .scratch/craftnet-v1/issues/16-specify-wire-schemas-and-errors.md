Type: grilling
Status: resolved
Blocked by: 05, 06, 07, 08, 09

## Question

What exact versioned JSON-compatible schemas, canonical signing representation, size limits, message kinds, required fields, and error catalog implement the settled enrollment, configuration, DNS, routing, NAT, ISP, and External Application contracts?

## Answer

CraftNet v1 uses UTF-8 JSON objects on both raw modem links and the Gateway WebSocket. The protocol version is the integer `1`; unknown major versions are rejected with `unsupported_version`. Field names and message kinds are lowercase `snake_case`. Receivers reject unknown fields in authentication and control messages, but External Operation payload objects are application-defined and may contain unknown fields.

### Scalar and identifier rules

- All protocol numbers are integers in JavaScript's exact range, `-(2^53-1)` through `2^53-1`. Non-finite and fractional numbers are invalid. External Operation handlers that need decimals use strings or scaled integers.
- IDs are opaque lowercase ASCII strings of 1–64 characters matching `^[a-z0-9][a-z0-9_-]*$`. Identity values never embed display names or addresses.
- A Request ID is unique for the issuing identity across its persisted counter lifetime. A Command ID is globally unique within a World. Duplicate requests return the cached terminal result when available; duplicate commands return the already-applied result.
- Display names and hostnames are 1–32 characters. Normalized names are lowercase ASCII letters, digits, and internal hyphens; they begin and end with a letter or digit.
- Operation and service names contain 1–64 lowercase letters, digits, dots, underscores, or hyphens.
- IPv4-looking addresses are strings. Customer addresses must be within RFC 1918; Provider Addresses and allocation endpoints must be within `100.64.0.0/10`.
- Timestamps on the Gateway are RFC 3339 UTC strings. CraftOS messages use integer monotonic milliseconds only for durations and observations; security never depends on a Computer's wall clock.

### CraftNet Canonical JSON 1

Every HMAC input uses CraftNet Canonical JSON 1 (`CJ1`). It encodes null, booleans, integers, strings, arrays, and objects with standard JSON tokens; emits no insignificant whitespace; preserves array order; sorts object keys by unsigned UTF-8 byte order; encodes control characters with lowercase four-digit `\u` escapes; and otherwise emits valid UTF-8. Duplicate keys, sparse arrays, mixed table keys, non-string object keys, fractional numbers, and values outside the exact integer range are rejected before signing. The Lua and Go implementations share golden vectors.

An established relationship uses this operational frame:

```json
{
  "v": 1,
  "kind": "service_request",
  "relationship_id": "rel_router_farm",
  "session_id": "ses_42",
  "request_id": "req_harvester_104",
  "counter": 17,
  "body": {},
  "body_hash": "64 lowercase hexadecimal SHA-256 characters",
  "mac": "64 lowercase hexadecimal HMAC-SHA-256 characters"
}
```

`body_hash` is `SHA256(CJ1(body))`. The exact MAC input is `CJ1([1, kind, relationship_id, session_id, request_id, counter, body_hash])`; messages with no request correlation use the empty string for `request_id`. `mac` is `HMAC-SHA256(session_key, mac_input)`. A receiver validates types, size, relationship, session, strictly increasing counter, body hash, and MAC—in that order—before dispatch. Authentication failures receive no detailed response on a discovery channel.

Enrollment and session establishment use an unsigned outer object `{v, kind, request_id, body, proof}`. The enrollment exchange is `enroll_open`, `enroll_challenge`, `enroll_confirm`, then `enroll_accept` or `enroll_error`. Required transcript fields are child identity when re-enrolling, requested normalized name, role, parent identity, relationship ID, 32-byte lowercase-hex client and parent nonces, and parent revision. `proof` is HMAC over `CJ1([1, kind, request_id, body])` using the one-time ISP/Router enrollment token or LAN Password. On success, both peers derive the durable relationship credential as `HMAC-SHA256(enrollment_secret, "craftnet/v1/relationship\n" || CJ1(transcript))`; the parent invalidates a one-time token only after `enroll_accept` is durably committed. This deliberately gives LAN Passwords only the gameplay-grade offline-dictionary resistance already accepted by the design.

A reconnect exchange is `session_open`, `session_challenge`, and `session_confirm`. It carries the relationship ID, both fresh nonces, child and parent revisions, and proposed session ID. Proofs use the durable relationship credential over the complete canonical transcript. Both sides derive `session_key = HMAC-SHA256(relationship_credential, "craftnet/v1/session\n" || CJ1(transcript))`; the first operational counter is 1. A session ID or nonce may never be reused with the same relationship credential.

CraftOS never uses `math.random` as a security source. A parent assigns relationship and session IDs from its identity plus a durable generation counter. After enrollment, each peer derives its nonce with HMAC from the relationship credential, its role, and a durable per-relationship generation counter, committing the increment before transmitting. The one-time enrollment transcript combines the child's best-effort boot nonce with the parent's durable token-use counter; uniqueness comes from the parent counter even though LAN-password enrollment does not claim cryptographic randomness.

### In-world message bodies

All fields listed are required unless suffixed with `?`. An optional field is omitted, never encoded as an empty substitute.

| Kind | Required body fields |
|---|---|
| `discover` | `role`, `client_nonce` |
| `offer` | `parent_id`, `parent_role`, `display_name`, `discovery_channel`, `client_nonce` |
| `enroll_open` | `role`, `requested_name`, `client_id?`, `client_nonce` |
| `enroll_challenge` | `parent_id`, `relationship_id`, `client_nonce`, `parent_nonce`, `parent_revision` |
| `enroll_confirm` | `relationship_id`, `client_nonce`, `parent_nonce`, `child_revision` |
| `enroll_accept` | `child_id`, `relationship_id`, `operational_channel`, `configuration`, `parent_revision` |
| `session_open` | `relationship_id`, `client_nonce`, `child_revision` |
| `session_challenge` | `relationship_id`, `session_id`, `client_nonce`, `parent_nonce`, `parent_revision` |
| `session_confirm` | `relationship_id`, `session_id`, `client_nonce`, `parent_nonce` |
| `heartbeat` | `connectivity_state`, `revision` |
| `ack` | `acked_request_id`, `result_revision?` |
| `config_request` | `known_revision` |
| `config_snapshot` | `revision`, `role`, `configuration` |
| `dns_query` | `name` |
| `dns_result` | `canonical_name`, `customer_network_id`, `computer_id`, `address` |
| `route_register` | `customer_network_id`, `customer_network_name`, `router_id`, `router_provider_address`, `isp_id`, `revision` |
| `route_remove` | `customer_network_id`, `revision` |
| `service_request` | `source`, `destination`, `service`, `payload`, `source_flow_id?`, `destination_flow_id?` |
| `service_response` | `source_flow_id?`, `destination_flow_id?`, `payload` |
| `error` | `code`, `message`, `retryable`, `details?` |
| `topology_snapshot` | `revision`, `world`, `isps`, `routers`, `computers`, `network_statuses` |
| `topology_change` | `revision`, `change`, `entity_type`, `entity` |
| `traffic_batch` | `first_sequence`, `last_sequence`, `events` |
| `network_status_set` | `command_id`, `customer_network_id`, `status` |
| `command_result` | `command_id`, `status`, `revision`, `error?` |

`source` is `{computer_id, customer_network_id, local_address}` and is replaced or verified at every owning hop. `destination` is `{customer_network_id, computer_id?, address?}` and must contain exactly one of `computer_id` or `address`. Flow IDs are opaque IDs paired with the authenticated router relationship; a bare flow ID is never globally routable.

An Address Binding in `configuration` is `{computer_id, hostname, address}`. Router configuration additionally contains `{customer_network_id, customer_network_name, router_address, dns_address, pool_first, pool_last, lan_operational_channel, provider_address, isp_id}`. ISP configuration contains `{isp_id, isp_name, provider_allocations, operational_channel}`, where an allocation is `{first, last}`. Central configuration contains `{world_id, central_id, gateway_url, gateway_credential_ref, provider_allocations}`; snapshots and messages never contain secret values.

A Traffic Event is `{event_id, observed_at_ms, request_id?, command_id?, world_id, isp_id?, customer_network_id?, router_id?, computer_id?, direction, kind, operation?, outcome, bytes}`. It contains metadata only—never `payload`, credentials, proofs, MACs, or Access Tokens.

### Gateway messages

The Central Server opens the WebSocket with `Authorization: Bearer <Gateway Credential>` and then sends `gateway_hello` containing `{v, world_id, central_id, last_topology_revision, last_traffic_sequence}`. The Go application replies with `gateway_welcome` containing `{v, gateway_session_id, accepted_topology_revision, accepted_traffic_sequence, server_time}` or closes with an authentication/policy error. Subsequent WebSocket frames use `{v, kind, request_id?, command_id?, body}` and rely on WSS plus the authenticated Gateway Session rather than a second message HMAC.

Gateway kinds are `heartbeat`, `ack`, `external_request`, `external_response`, `error`, `topology_snapshot`, `topology_change`, `traffic_batch`, `admin_command`, and `command_result`. `external_request.body` is `{ancestry, source_flow_id, access_token?, device_credential?, registration_nonce?, operation, payload}`. `ancestry` is `{world_id, isp_id, customer_network_id, router_id, computer_id, local_address}`. Credential presence depends on the operation: `device.register` has a one-time `registration_nonce` and no Device Credential or Access Token because the authenticated ancestry is the attestation; `token.issue` and `device.rotate` use the Device Credential; ordinary External Operations use the Access Token. The External Application rejects every other combination. `external_response.body` is `{payload}`. `admin_command.body` currently permits only `{action: "set_network_status", customer_network_id, status}`.

An Access Token JWT uses asymmetric Ed25519 signing with header `{alg:"EdDSA",typ:"JWT",kid}` and required claims `{iss, aud:"craftnet-gateway", sub:computer_id, world_id, customer_network_id, operations, iat, exp, jti}`. `exp - iat` is at most 120 seconds. The Go application validates signature, issuer, audience, expiry, revocation state, allowed operation, and exact ancestry match. CraftOS treats the token as opaque.

### Limits and transport behavior

- Raw-modem JSON is at most 16 KiB after UTF-8 encoding; an External Operation payload inside it is at most 8 KiB. A modem receiver discards larger frames before JSON decoding.
- A Gateway WebSocket message is at most 256 KiB. A topology snapshot is at most 2,000 entities. A Traffic Event batch contains at most 100 events and 128 KiB.
- Strings are at most 8 KiB unless a narrower rule is stated; object depth is at most 16; an object has at most 128 keys; an array has at most 2,000 elements.
- CraftNet performs no fragmentation. `message_too_large` tells the caller to reduce its application payload or batch.
- At most 64 requests may be in flight per immediate relationship and 256 through the Gateway Session. Excess work fails with `busy`; it is not silently queued without bound.

### Error catalog

Every error has `{code, message, retryable, details?}`. `message` is safe for players, while `details` contains only non-secret structured context. Stable v1 codes are:

| Code | Retryable | Meaning |
|---|---:|---|
| `invalid_message` | no | JSON, type, required-field, or canonical-form validation failed |
| `unsupported_version` | no | Peer does not implement the requested major version |
| `message_too_large` | no | Frame, payload, snapshot, or batch exceeds a limit |
| `busy` | yes | Bounded in-flight capacity is exhausted |
| `authentication_failed` | no | Enrollment, session, Gateway, or device proof failed |
| `replay_rejected` | no | Session ID, nonce, request, or counter was reused or out of order |
| `credential_revoked` | no | Durable relationship, device, or Gateway credential is revoked |
| `access_token_expired` | yes | The two-minute Access Token is expired |
| `forbidden_operation` | no | Credential is valid but does not authorize the operation |
| `name_not_found` | no | DNS name has no authoritative record |
| `name_conflict` | no | Requested ISP, network, or hostname already exists in its scope |
| `pool_exhausted` | no | No Customer or Provider Address is available |
| `address_conflict` | no | Address is already bound in the relevant scope |
| `router_unavailable` | yes | Destination or local Customer Router is disconnected |
| `upstream_unavailable` | yes | Immediate parent relationship is unavailable |
| `route_not_found` | no | Central route map has no destination Customer Network |
| `inbound_denied` | no | No matching Exposed Service permits a new remote request |
| `nat_flow_missing` | no | Reply refers to an expired or unknown NAT Flow |
| `network_disabled` | no | Central Network Status disables the Customer Network |
| `gateway_unavailable` | yes | Central Server lacks a ready Gateway Session |
| `request_timeout` | yes | No terminal response arrived before the operation deadline |
| `revision_conflict` | yes | Command or update was based on stale authoritative state |
| `internal_error` | yes | An unexpected owner-side failure occurred without exposing internals |

Retryability describes whether a fresh attempt could succeed; it never authorizes automatic replay. Only idempotent administrative commands are resent automatically with the same Command ID under the previously settled recovery rule.
