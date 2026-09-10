// Package store is the External Application's one durable seam.
//
// It is deliberately a single cohesive transactional interface rather than a
// repository per table: registering a device writes a credential, an audit
// record, and a topology revision, and either all of that happens or none of it
// does. Splitting it up would make that guarantee somebody else's problem.
//
// The production adapter is internal/store/sqlite. An in-memory adapter exists
// only for tests, and both are held to the same test suite.
package store

import (
	"context"
	"errors"
	"time"
)

// ErrNotFound is returned by every lookup that finds nothing. Callers compare
// against it rather than inspecting an adapter's own error.
var ErrNotFound = errors.New("not found")

// ErrConflict is returned when a write would violate a uniqueness the domain
// depends on -- two Worlds with one identity, two live Gateway Sessions.
var ErrConflict = errors.New("conflict")

// World is one Minecraft world's durable identity. The World Key and the
// Gateway Credential are never stored in the clear: what is kept is enough to
// verify a presented secret and nothing more.
type World struct {
	WorldID              string
	CentralID            string
	GatewayCredentialRef string
	GatewayCredentialSHA string
	WorldKeySHA          string
	CreatedAt            time.Time
}

// Credential is a bearer secret the application issued. Only its digest is
// stored, so a database that leaks tells an attacker nothing it can present.
type Credential struct {
	Reference string
	Kind      string
	Subject   string
	WorldID   string
	DigestSHA string
	IssuedAt  time.Time
	RevokedAt *time.Time
}

// Revoked reports whether this credential has been withdrawn. Revocation stops
// new authenticated traffic; it never deletes the subject's identity.
func (c Credential) Revoked() bool { return c.RevokedAt != nil }

// Device is a Computer the application has met, recorded with the exact CraftNet
// ancestry that vouched for it.
type Device struct {
	DeviceID          string
	WorldID           string
	ISPID             string
	CustomerNetworkID string
	RouterID          string
	ComputerID        string
	LocalAddress      string
	CredentialRef     string
	RegisteredAt      time.Time
}

// Ancestry is the verified path a request travelled. It is compared exactly:
// a valid credential presented from another Customer Network is refused.
type Ancestry struct {
	WorldID           string
	ISPID             string
	CustomerNetworkID string
	RouterID          string
	ComputerID        string
	LocalAddress      string
}

// Matches reports whether two ancestries are the same path. Every field counts.
func (a Ancestry) Matches(other Ancestry) bool {
	return a.WorldID == other.WorldID &&
		a.ISPID == other.ISPID &&
		a.CustomerNetworkID == other.CustomerNetworkID &&
		a.RouterID == other.RouterID &&
		a.ComputerID == other.ComputerID
}

// AncestryOf is the path a Device was registered under.
func (d Device) AncestryOf() Ancestry {
	return Ancestry{
		WorldID:           d.WorldID,
		ISPID:             d.ISPID,
		CustomerNetworkID: d.CustomerNetworkID,
		RouterID:          d.RouterID,
		ComputerID:        d.ComputerID,
		LocalAddress:      d.LocalAddress,
	}
}

// IssuedToken records an Access Token so it can be revoked before it expires.
// Only the identifier is kept: the token itself is a signed claim set the
// application can verify without having stored it.
type IssuedToken struct {
	TokenID   string
	WorldID   string
	DeviceID  string
	IssuedAt  time.Time
	ExpiresAt time.Time
	RevokedAt *time.Time
}

// Topology is the projection a Central Server last reported. It is a view of
// authoritative in-world state, never an authority in its own right.
type Topology struct {
	WorldID    string
	Revision   int64
	Document   string
	ObservedAt time.Time
}

// Event is one Traffic Event as received. It carries metadata only; the
// protocol layer refuses to construct one that carries anything else.
type Event struct {
	WorldID    string
	Sequence   int64
	EventID    string
	ObservedAt time.Time
	Document   string
}

// Command is an administrative instruction and whatever became of it. The
// application retains a pending command and resends the same identifier after a
// Gateway recovery until the Central Server reports the applied result.
type Command struct {
	CommandID string
	WorldID   string
	Action    string
	Document  string
	Status    string
	Revision  int64
	Error     string
	IssuedAt  time.Time
	SettledAt *time.Time
}

// Command statuses. `pending` is the only one that is resent.
const (
	CommandPending  = "pending"
	CommandApplied  = "applied"
	CommandRejected = "rejected"
)

// AuditRecord is what an Operator did, kept apart from traffic so that pruning
// telemetry never prunes the record of a decision.
type AuditRecord struct {
	WorldID  string
	Actor    string
	Action   string
	Subject  string
	Detail   string
	Recorded time.Time
}

// Tx is everything one transaction can do. Nothing here writes outside a
// transaction, so a half-applied change is not representable.
type Tx interface {
	PutWorld(World) error
	World(worldID string) (World, error)
	Worlds() ([]World, error)

	PutCredential(Credential) error
	Credential(reference string) (Credential, error)
	RevokeCredential(reference string, at time.Time) error

	PutDevice(Device) error
	Device(deviceID string) (Device, error)
	DeviceByComputer(worldID, computerID string) (Device, error)

	PutToken(IssuedToken) error
	Token(tokenID string) (IssuedToken, error)
	RevokeToken(tokenID string, at time.Time) error

	PutTopology(Topology) error
	Topology(worldID string) (Topology, error)

	AppendEvents(events []Event) error
	Events(worldID string, limit int) ([]Event, error)
	LastSequence(worldID string) (int64, error)
	PruneEvents(before time.Time) (int64, error)

	PutCommand(Command) error
	Command(commandID string) (Command, error)
	PendingCommands(worldID string) ([]Command, error)

	AppendAudit(AuditRecord) error
	Audit(worldID string, limit int) ([]AuditRecord, error)
}

// Store hands out transactions and nothing else. A caller cannot reach the
// database except through Do, which is what makes "all or nothing" structural.
type Store interface {
	Do(ctx context.Context, fn func(Tx) error) error
	Close() error
}
