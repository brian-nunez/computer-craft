# The credential rule for new External Operations

- **Type**: `wayfinder:grilling`
- **Status**: open
- **Assignee**: unclaimed
- **Blocked by**: nothing
- **Map**: [the software half of the v0.1.0 gate](../map.md)

## Question

`validateCredentialUse` fixes which credential an operation may present by
switching on the operation's **name**, while `operations.Policy` carries a
per-operation `Credential`. The two disagree about who owns the rule, and the
wire wins: any operation registered as `CredentialAncestry` or
`CredentialDevice` whose name is not one of three hardcoded strings is refused
at encode and at decode, in both languages. Two of the three policy values are
dead for anything new.

This is a wire question, so it changes by ADR or not at all. Options:

1. **Leave it.** The allowlist is deliberately closed and three names is the
   whole vocabulary a Computer may present something other than an Access Token
   for. Defensible — but then `operations.Credential` is lying, and the
   package's own doc comment ("Adding a capability means adding one of those")
   is only two-thirds true.
2. **Make the registry refuse what the wire cannot express.** Keep the wire
   exactly as it is; have `Registry.Register` reject a non-token policy for a
   name the wire does not know. The seam stays closed, but it fails loudly at
   the composition root instead of silently at the far end. Cheapest honest fix
   and needs no wire change.
3. **Carry the credential kind on the frame** rather than inferring it from the
   name. Opens the seam properly, and costs a v1 edit: `schema.lua`,
   `schema.go`, a `fixturegen` case, `make fixtures`, and the rejected cases
   that pin down what it must refuse.

## `device.rotate` rides on this

`device.rotate` is named in the rule and registered nowhere, so the wire
currently permits a credential combination for an operation that does not
exist. Milestone 6 decided re-registering covers recovering a lost Device
Credential, which makes the name vestigial. Decide in this ticket whether it
leaves the rule or gains a handler — it is the same surface, and splitting it
would mean touching the fixtures twice.

## Evidence

Found while trying to register a probe operation:

```
encode external_request: invalid_message:
operation "slow.op" does not permit this credential combination
```

- `external/internal/protocol/schema.go:330` — `validateCredentialUse`
- `external/internal/protocol/schema.go:434` — where it is attached
- `external/internal/operations/operations.go` — `Credential`, and the seam it promises
- `packages/craftnet-protocol/files/schema.lua` — the same rule, written once per language
- `docs/protocol/v1.md` — "Naming the External Application", the credential table

## Also answer

Does this block the v0.1.0 tag?
