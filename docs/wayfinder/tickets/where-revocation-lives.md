# Where revocation lives

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

`identity.RevokeDevice` and `identity.RevokeToken` are written, tested, and
reachable from nothing but tests. There is no dashboard route, no `craftnetd`
subcommand, and no `admin_command` action for either. An Operator whose
Computer is compromised has no way to withdraw its Device Credential short of
editing SQLite by hand, and `credential_revoked` is a stable catalog code that
production cannot currently produce.

Where should the Operator reach it?

1. **A `craftnetd` subcommand**, beside `operator` and `provision`. Consistent
   with how every other privileged act already works, needs no wire change, and
   is available when the dashboard is not. But it is the one administrative act
   that does not appear where the Operator is already looking.
2. **A dashboard route**, beside `setNetworkStatus` — which already shows the
   pattern: an audit record for the decision, then the act. Puts revocation
   where the evidence that provoked it is. Costs a listing surface too: there is
   no `Devices(worldID)` on `store.Tx`, so the dashboard cannot currently show
   what there is to revoke.
3. **Both**, with the CLI as the floor.

Revoking in world — a new `admin_command` action — is a third thing and
probably not this. v1 permits only `set_network_status`, and the External
Application already owns device identity; ask whether the Central Server needs
to know at all, or whether refusing the next call is enough.

## Evidence

- `external/internal/identity/identity.go:381` — `RevokeDevice`, no production caller
- `external/internal/identity/identity.go:493` — `RevokeToken`, no production caller
- `external/internal/web/web.go` — `Handler()`, the complete route list
- `external/internal/store/store.go:199` — `PutDevice` and `Device`, no listing
- `external/internal/web/dashboard.go:279` — `setNetworkStatus`, the pattern to copy
- `docs/protocol/v1.md` — `admin_command` permits only `set_network_status` in v1

## Also answer

Does this block the v0.1.0 tag? A release that can issue a credential it cannot
withdraw is a specific claim to be comfortable with.
