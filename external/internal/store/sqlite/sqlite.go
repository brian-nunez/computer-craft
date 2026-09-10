// Package sqlite is the production store adapter.
//
// It uses a CGo-free driver so that craftnetd stays a single static binary, and
// it runs every migration forward-only at open. Nothing outside this package
// writes SQL, and nothing inside it makes a domain decision.

package sqlite

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"

	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// Store is the SQLite adapter.
type Store struct {
	db *sql.DB
}

// Open connects to a file-backed database and brings it up to date. An
// in-memory path is accepted for tests, where it behaves identically.
func Open(ctx context.Context, path string) (*Store, error) {
	// Foreign keys are off by default in SQLite, and busy_timeout is what keeps
	// a second connection from failing instantly while the first commits.
	dsn := path + "?_pragma=foreign_keys(1)&_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open database: %w", err)
	}
	// One writer at a time. SQLite allows exactly that, and pretending otherwise
	// only moves the contention somewhere harder to see.
	db.SetMaxOpenConns(1)

	if err := db.PingContext(ctx); err != nil {
		db.Close()
		return nil, fmt.Errorf("reach database: %w", err)
	}
	if err := migrate(ctx, db); err != nil {
		db.Close()
		return nil, err
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// Do runs fn in one transaction, committing only if it returns nil.
func (s *Store) Do(ctx context.Context, fn func(store.Tx) error) error {
	transaction, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin: %w", err)
	}
	if err := fn(&tx{ctx: ctx, tx: transaction}); err != nil {
		// The rollback error is deliberately not surfaced: the caller's failure
		// is the one worth reporting.
		_ = transaction.Rollback()
		return err
	}
	if err := transaction.Commit(); err != nil {
		return fmt.Errorf("commit: %w", err)
	}
	return nil
}

//--------------------------------------------------------------------------
// Migrations
//--------------------------------------------------------------------------

// migrations are forward-only and applied in order. A released migration is
// never edited; a correction is a new one.
var migrations = []string{
	`CREATE TABLE IF NOT EXISTS schema_version (version INTEGER NOT NULL);`,

	`CREATE TABLE IF NOT EXISTS worlds (
		world_id TEXT PRIMARY KEY,
		central_id TEXT NOT NULL,
		gateway_credential_ref TEXT NOT NULL,
		gateway_credential_sha TEXT NOT NULL,
		world_key_sha TEXT NOT NULL,
		created_at INTEGER NOT NULL
	);`,

	`CREATE TABLE IF NOT EXISTS credentials (
		reference TEXT PRIMARY KEY,
		kind TEXT NOT NULL,
		subject TEXT NOT NULL,
		world_id TEXT NOT NULL,
		digest_sha TEXT NOT NULL,
		issued_at INTEGER NOT NULL,
		revoked_at INTEGER
	);`,

	`CREATE TABLE IF NOT EXISTS devices (
		device_id TEXT PRIMARY KEY,
		world_id TEXT NOT NULL,
		isp_id TEXT NOT NULL,
		customer_network_id TEXT NOT NULL,
		router_id TEXT NOT NULL,
		computer_id TEXT NOT NULL,
		local_address TEXT NOT NULL,
		credential_ref TEXT NOT NULL,
		registered_at INTEGER NOT NULL
	);`,
	`CREATE UNIQUE INDEX IF NOT EXISTS devices_by_computer
		ON devices (world_id, computer_id);`,

	`CREATE TABLE IF NOT EXISTS tokens (
		token_id TEXT PRIMARY KEY,
		world_id TEXT NOT NULL,
		device_id TEXT NOT NULL,
		issued_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL,
		revoked_at INTEGER
	);`,

	`CREATE TABLE IF NOT EXISTS topology (
		world_id TEXT PRIMARY KEY,
		revision INTEGER NOT NULL,
		document TEXT NOT NULL,
		observed_at INTEGER NOT NULL
	);`,

	`CREATE TABLE IF NOT EXISTS events (
		world_id TEXT NOT NULL,
		event_id TEXT NOT NULL,
		sequence INTEGER NOT NULL,
		observed_at INTEGER NOT NULL,
		document TEXT NOT NULL,
		PRIMARY KEY (world_id, event_id)
	);`,
	`CREATE INDEX IF NOT EXISTS events_by_time ON events (observed_at);`,
	`CREATE INDEX IF NOT EXISTS events_by_sequence ON events (world_id, sequence);`,

	`CREATE TABLE IF NOT EXISTS commands (
		command_id TEXT PRIMARY KEY,
		world_id TEXT NOT NULL,
		action TEXT NOT NULL,
		document TEXT NOT NULL,
		status TEXT NOT NULL,
		revision INTEGER NOT NULL,
		error TEXT NOT NULL,
		issued_at INTEGER NOT NULL,
		settled_at INTEGER
	);`,
	`CREATE INDEX IF NOT EXISTS commands_pending ON commands (world_id, status);`,

	`CREATE TABLE IF NOT EXISTS audit (
		world_id TEXT NOT NULL,
		actor TEXT NOT NULL,
		action TEXT NOT NULL,
		subject TEXT NOT NULL,
		detail TEXT NOT NULL,
		recorded_at INTEGER NOT NULL
	);`,
	`CREATE INDEX IF NOT EXISTS audit_by_time ON audit (world_id, recorded_at);`,

	`CREATE TABLE IF NOT EXISTS operators (
		name TEXT PRIMARY KEY,
		salt TEXT NOT NULL,
		password_sha TEXT NOT NULL,
		iterations INTEGER NOT NULL,
		created_at INTEGER NOT NULL,
		disabled_at INTEGER
	);`,

	`CREATE TABLE IF NOT EXISTS sessions (
		token_sha TEXT PRIMARY KEY,
		operator TEXT NOT NULL,
		issued_at INTEGER NOT NULL,
		expires_at INTEGER NOT NULL
	);`,
	`CREATE INDEX IF NOT EXISTS sessions_by_expiry ON sessions (expires_at);`,
}

// SchemaVersion is what a fully migrated database reports.
var SchemaVersion = len(migrations)

func migrate(ctx context.Context, db *sql.DB) error {
	if _, err := db.ExecContext(ctx, migrations[0]); err != nil {
		return fmt.Errorf("create schema_version: %w", err)
	}

	var current int
	row := db.QueryRowContext(ctx, `SELECT COALESCE(MAX(version), 0) FROM schema_version`)
	if err := row.Scan(&current); err != nil {
		return fmt.Errorf("read schema version: %w", err)
	}
	if current >= len(migrations) {
		return nil
	}

	transaction, err := db.BeginTx(ctx, nil)
	if err != nil {
		return fmt.Errorf("begin migration: %w", err)
	}
	for index := current; index < len(migrations); index++ {
		if _, err := transaction.ExecContext(ctx, migrations[index]); err != nil {
			_ = transaction.Rollback()
			return fmt.Errorf("migration %d: %w", index+1, err)
		}
	}
	if _, err := transaction.ExecContext(ctx,
		`DELETE FROM schema_version`); err != nil {
		_ = transaction.Rollback()
		return fmt.Errorf("clear schema version: %w", err)
	}
	if _, err := transaction.ExecContext(ctx,
		`INSERT INTO schema_version (version) VALUES (?)`, len(migrations)); err != nil {
		_ = transaction.Rollback()
		return fmt.Errorf("record schema version: %w", err)
	}
	return transaction.Commit()
}

//--------------------------------------------------------------------------
// Transactions
//--------------------------------------------------------------------------

type tx struct {
	ctx context.Context
	tx  *sql.Tx
}

func stamp(at time.Time) int64 { return at.UTC().UnixMilli() }

func moment(value int64) time.Time { return time.UnixMilli(value).UTC() }

func optional(value *time.Time) any {
	if value == nil {
		return nil
	}
	return stamp(*value)
}

func readOptional(value sql.NullInt64) *time.Time {
	if !value.Valid {
		return nil
	}
	at := moment(value.Int64)
	return &at
}

func translate(err error) error {
	if errors.Is(err, sql.ErrNoRows) {
		return store.ErrNotFound
	}
	return err
}

func (t *tx) PutWorld(world store.World) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO worlds (world_id, central_id, gateway_credential_ref,
			gateway_credential_sha, world_key_sha, created_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(world_id) DO UPDATE SET
			central_id = excluded.central_id,
			gateway_credential_ref = excluded.gateway_credential_ref,
			gateway_credential_sha = excluded.gateway_credential_sha,
			world_key_sha = excluded.world_key_sha`,
		world.WorldID, world.CentralID, world.GatewayCredentialRef,
		world.GatewayCredentialSHA, world.WorldKeySHA, stamp(world.CreatedAt))
	return err
}

func (t *tx) World(worldID string) (store.World, error) {
	var world store.World
	var created int64
	row := t.tx.QueryRowContext(t.ctx, `
		SELECT world_id, central_id, gateway_credential_ref, gateway_credential_sha,
			world_key_sha, created_at FROM worlds WHERE world_id = ?`, worldID)
	err := row.Scan(&world.WorldID, &world.CentralID, &world.GatewayCredentialRef,
		&world.GatewayCredentialSHA, &world.WorldKeySHA, &created)
	if err != nil {
		return store.World{}, translate(err)
	}
	world.CreatedAt = moment(created)
	return world, nil
}

func (t *tx) Worlds() ([]store.World, error) {
	rows, err := t.tx.QueryContext(t.ctx, `
		SELECT world_id, central_id, gateway_credential_ref, gateway_credential_sha,
			world_key_sha, created_at FROM worlds ORDER BY world_id`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	found := make([]store.World, 0)
	for rows.Next() {
		var world store.World
		var created int64
		if err := rows.Scan(&world.WorldID, &world.CentralID, &world.GatewayCredentialRef,
			&world.GatewayCredentialSHA, &world.WorldKeySHA, &created); err != nil {
			return nil, err
		}
		world.CreatedAt = moment(created)
		found = append(found, world)
	}
	return found, rows.Err()
}

func (t *tx) PutCredential(credential store.Credential) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO credentials (reference, kind, subject, world_id, digest_sha, issued_at, revoked_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(reference) DO UPDATE SET
			kind = excluded.kind, subject = excluded.subject, world_id = excluded.world_id,
			digest_sha = excluded.digest_sha, revoked_at = excluded.revoked_at`,
		credential.Reference, credential.Kind, credential.Subject, credential.WorldID,
		credential.DigestSHA, stamp(credential.IssuedAt), optional(credential.RevokedAt))
	return err
}

func (t *tx) Credential(reference string) (store.Credential, error) {
	var credential store.Credential
	var issued int64
	var revoked sql.NullInt64
	row := t.tx.QueryRowContext(t.ctx, `
		SELECT reference, kind, subject, world_id, digest_sha, issued_at, revoked_at
		FROM credentials WHERE reference = ?`, reference)
	err := row.Scan(&credential.Reference, &credential.Kind, &credential.Subject,
		&credential.WorldID, &credential.DigestSHA, &issued, &revoked)
	if err != nil {
		return store.Credential{}, translate(err)
	}
	credential.IssuedAt = moment(issued)
	credential.RevokedAt = readOptional(revoked)
	return credential, nil
}

func (t *tx) RevokeCredential(reference string, at time.Time) error {
	result, err := t.tx.ExecContext(t.ctx,
		`UPDATE credentials SET revoked_at = ? WHERE reference = ?`, stamp(at), reference)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return store.ErrNotFound
	}
	return nil
}

func (t *tx) PutDevice(device store.Device) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO devices (device_id, world_id, isp_id, customer_network_id, router_id,
			computer_id, local_address, credential_ref, registered_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(device_id) DO UPDATE SET
			isp_id = excluded.isp_id, customer_network_id = excluded.customer_network_id,
			router_id = excluded.router_id, local_address = excluded.local_address,
			credential_ref = excluded.credential_ref`,
		device.DeviceID, device.WorldID, device.ISPID, device.CustomerNetworkID,
		device.RouterID, device.ComputerID, device.LocalAddress, device.CredentialRef,
		stamp(device.RegisteredAt))
	return err
}

func scanDevice(row interface{ Scan(...any) error }) (store.Device, error) {
	var device store.Device
	var registered int64
	err := row.Scan(&device.DeviceID, &device.WorldID, &device.ISPID,
		&device.CustomerNetworkID, &device.RouterID, &device.ComputerID,
		&device.LocalAddress, &device.CredentialRef, &registered)
	if err != nil {
		return store.Device{}, translate(err)
	}
	device.RegisteredAt = moment(registered)
	return device, nil
}

const deviceColumns = `device_id, world_id, isp_id, customer_network_id, router_id,
	computer_id, local_address, credential_ref, registered_at`

func (t *tx) Device(deviceID string) (store.Device, error) {
	return scanDevice(t.tx.QueryRowContext(t.ctx,
		`SELECT `+deviceColumns+` FROM devices WHERE device_id = ?`, deviceID))
}

func (t *tx) DeviceByComputer(worldID, computerID string) (store.Device, error) {
	return scanDevice(t.tx.QueryRowContext(t.ctx,
		`SELECT `+deviceColumns+` FROM devices WHERE world_id = ? AND computer_id = ?`,
		worldID, computerID))
}

func (t *tx) PutToken(token store.IssuedToken) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO tokens (token_id, world_id, device_id, issued_at, expires_at, revoked_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(token_id) DO UPDATE SET revoked_at = excluded.revoked_at`,
		token.TokenID, token.WorldID, token.DeviceID,
		stamp(token.IssuedAt), stamp(token.ExpiresAt), optional(token.RevokedAt))
	return err
}

func (t *tx) Token(tokenID string) (store.IssuedToken, error) {
	var token store.IssuedToken
	var issued, expires int64
	var revoked sql.NullInt64
	row := t.tx.QueryRowContext(t.ctx, `
		SELECT token_id, world_id, device_id, issued_at, expires_at, revoked_at
		FROM tokens WHERE token_id = ?`, tokenID)
	err := row.Scan(&token.TokenID, &token.WorldID, &token.DeviceID, &issued, &expires, &revoked)
	if err != nil {
		return store.IssuedToken{}, translate(err)
	}
	token.IssuedAt = moment(issued)
	token.ExpiresAt = moment(expires)
	token.RevokedAt = readOptional(revoked)
	return token, nil
}

func (t *tx) RevokeToken(tokenID string, at time.Time) error {
	result, err := t.tx.ExecContext(t.ctx,
		`UPDATE tokens SET revoked_at = ? WHERE token_id = ?`, stamp(at), tokenID)
	if err != nil {
		return err
	}
	affected, err := result.RowsAffected()
	if err != nil {
		return err
	}
	if affected == 0 {
		return store.ErrNotFound
	}
	return nil
}

func (t *tx) PutTopology(topology store.Topology) error {
	// A replayed older snapshot is ignored rather than applied: going backwards
	// would make the dashboard lie about what is out there now.
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO topology (world_id, revision, document, observed_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(world_id) DO UPDATE SET
			revision = excluded.revision,
			document = excluded.document,
			observed_at = excluded.observed_at
		WHERE excluded.revision >= topology.revision`,
		topology.WorldID, topology.Revision, topology.Document, stamp(topology.ObservedAt))
	return err
}

func (t *tx) Topology(worldID string) (store.Topology, error) {
	var topology store.Topology
	var observed int64
	row := t.tx.QueryRowContext(t.ctx,
		`SELECT world_id, revision, document, observed_at FROM topology WHERE world_id = ?`, worldID)
	err := row.Scan(&topology.WorldID, &topology.Revision, &topology.Document, &observed)
	if err != nil {
		return store.Topology{}, translate(err)
	}
	topology.ObservedAt = moment(observed)
	return topology, nil
}

func (t *tx) AppendEvents(events []store.Event) error {
	for _, event := range events {
		// A reconnecting Central Server replays its buffer, so an event that has
		// already been stored is not a failure.
		_, err := t.tx.ExecContext(t.ctx, `
			INSERT INTO events (world_id, event_id, sequence, observed_at, document)
			VALUES (?, ?, ?, ?, ?)
			ON CONFLICT(world_id, event_id) DO NOTHING`,
			event.WorldID, event.EventID, event.Sequence, stamp(event.ObservedAt), event.Document)
		if err != nil {
			return err
		}
	}
	return nil
}

func (t *tx) Events(worldID string, limit int) ([]store.Event, error) {
	if limit <= 0 {
		limit = 1000
	}
	rows, err := t.tx.QueryContext(t.ctx, `
		SELECT world_id, event_id, sequence, observed_at, document
		FROM events WHERE world_id = ? ORDER BY sequence DESC LIMIT ?`, worldID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	found := make([]store.Event, 0)
	for rows.Next() {
		var event store.Event
		var observed int64
		if err := rows.Scan(&event.WorldID, &event.EventID, &event.Sequence,
			&observed, &event.Document); err != nil {
			return nil, err
		}
		event.ObservedAt = moment(observed)
		found = append(found, event)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	// Read newest-first so the limit takes the newest, then hand them back in
	// the order they happened.
	for left, right := 0, len(found)-1; left < right; left, right = left+1, right-1 {
		found[left], found[right] = found[right], found[left]
	}
	return found, nil
}

func (t *tx) LastSequence(worldID string) (int64, error) {
	var highest sql.NullInt64
	row := t.tx.QueryRowContext(t.ctx,
		`SELECT MAX(sequence) FROM events WHERE world_id = ?`, worldID)
	if err := row.Scan(&highest); err != nil {
		return 0, err
	}
	if !highest.Valid {
		return 0, nil
	}
	return highest.Int64, nil
}

func (t *tx) PruneEvents(before time.Time) (int64, error) {
	result, err := t.tx.ExecContext(t.ctx,
		`DELETE FROM events WHERE observed_at < ?`, stamp(before))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

func (t *tx) PutCommand(command store.Command) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO commands (command_id, world_id, action, document, status, revision,
			error, issued_at, settled_at)
		VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
		ON CONFLICT(command_id) DO UPDATE SET
			status = excluded.status, revision = excluded.revision,
			error = excluded.error, settled_at = excluded.settled_at`,
		command.CommandID, command.WorldID, command.Action, command.Document,
		command.Status, command.Revision, command.Error,
		stamp(command.IssuedAt), optional(command.SettledAt))
	return err
}

const commandColumns = `command_id, world_id, action, document, status, revision,
	error, issued_at, settled_at`

func scanCommand(row interface{ Scan(...any) error }) (store.Command, error) {
	var command store.Command
	var issued int64
	var settled sql.NullInt64
	err := row.Scan(&command.CommandID, &command.WorldID, &command.Action,
		&command.Document, &command.Status, &command.Revision, &command.Error,
		&issued, &settled)
	if err != nil {
		return store.Command{}, translate(err)
	}
	command.IssuedAt = moment(issued)
	command.SettledAt = readOptional(settled)
	return command, nil
}

func (t *tx) Command(commandID string) (store.Command, error) {
	return scanCommand(t.tx.QueryRowContext(t.ctx,
		`SELECT `+commandColumns+` FROM commands WHERE command_id = ?`, commandID))
}

func (t *tx) PendingCommands(worldID string) ([]store.Command, error) {
	rows, err := t.tx.QueryContext(t.ctx,
		`SELECT `+commandColumns+` FROM commands WHERE world_id = ? AND status = ?
		 ORDER BY command_id`, worldID, store.CommandPending)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	found := make([]store.Command, 0)
	for rows.Next() {
		command, err := scanCommand(rows)
		if err != nil {
			return nil, err
		}
		found = append(found, command)
	}
	return found, rows.Err()
}

func (t *tx) AppendAudit(record store.AuditRecord) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO audit (world_id, actor, action, subject, detail, recorded_at)
		VALUES (?, ?, ?, ?, ?, ?)`,
		record.WorldID, record.Actor, record.Action, record.Subject,
		record.Detail, stamp(record.Recorded))
	return err
}

func (t *tx) Audit(worldID string, limit int) ([]store.AuditRecord, error) {
	if limit <= 0 {
		limit = 200
	}
	rows, err := t.tx.QueryContext(t.ctx, `
		SELECT world_id, actor, action, subject, detail, recorded_at
		FROM audit WHERE world_id = ? ORDER BY recorded_at DESC, rowid DESC LIMIT ?`,
		worldID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	found := make([]store.AuditRecord, 0)
	for rows.Next() {
		var record store.AuditRecord
		var recorded int64
		if err := rows.Scan(&record.WorldID, &record.Actor, &record.Action,
			&record.Subject, &record.Detail, &recorded); err != nil {
			return nil, err
		}
		record.Recorded = moment(recorded)
		found = append(found, record)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	for left, right := 0, len(found)-1; left < right; left, right = left+1, right-1 {
		found[left], found[right] = found[right], found[left]
	}
	return found, nil
}

//--------------------------------------------------------------------------
// Operators and sessions
//--------------------------------------------------------------------------

func (t *tx) PutOperator(operator store.Operator) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO operators (name, salt, password_sha, iterations, created_at, disabled_at)
		VALUES (?, ?, ?, ?, ?, ?)
		ON CONFLICT(name) DO UPDATE SET
			salt = excluded.salt, password_sha = excluded.password_sha,
			iterations = excluded.iterations, disabled_at = excluded.disabled_at`,
		operator.Name, operator.Salt, operator.PasswordSHA, operator.Iterations,
		stamp(operator.CreatedAt), optional(operator.DisabledAt))
	return err
}

const operatorColumns = `name, salt, password_sha, iterations, created_at, disabled_at`

func scanOperator(row interface{ Scan(...any) error }) (store.Operator, error) {
	var operator store.Operator
	var created int64
	var disabled sql.NullInt64
	err := row.Scan(&operator.Name, &operator.Salt, &operator.PasswordSHA,
		&operator.Iterations, &created, &disabled)
	if err != nil {
		return store.Operator{}, translate(err)
	}
	operator.CreatedAt = moment(created)
	operator.DisabledAt = readOptional(disabled)
	return operator, nil
}

func (t *tx) Operator(name string) (store.Operator, error) {
	return scanOperator(t.tx.QueryRowContext(t.ctx,
		`SELECT `+operatorColumns+` FROM operators WHERE name = ?`, name))
}

func (t *tx) Operators() ([]store.Operator, error) {
	rows, err := t.tx.QueryContext(t.ctx,
		`SELECT `+operatorColumns+` FROM operators ORDER BY name`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	found := make([]store.Operator, 0)
	for rows.Next() {
		operator, err := scanOperator(rows)
		if err != nil {
			return nil, err
		}
		found = append(found, operator)
	}
	return found, rows.Err()
}

func (t *tx) PutSession(session store.Session) error {
	_, err := t.tx.ExecContext(t.ctx, `
		INSERT INTO sessions (token_sha, operator, issued_at, expires_at)
		VALUES (?, ?, ?, ?)
		ON CONFLICT(token_sha) DO UPDATE SET expires_at = excluded.expires_at`,
		session.TokenSHA, session.Operator, stamp(session.IssuedAt), stamp(session.ExpiresAt))
	return err
}

func (t *tx) Session(tokenSHA string) (store.Session, error) {
	var session store.Session
	var issued, expires int64
	row := t.tx.QueryRowContext(t.ctx,
		`SELECT token_sha, operator, issued_at, expires_at FROM sessions WHERE token_sha = ?`,
		tokenSHA)
	if err := row.Scan(&session.TokenSHA, &session.Operator, &issued, &expires); err != nil {
		return store.Session{}, translate(err)
	}
	session.IssuedAt = moment(issued)
	session.ExpiresAt = moment(expires)
	return session, nil
}

func (t *tx) DeleteSession(tokenSHA string) error {
	_, err := t.tx.ExecContext(t.ctx, `DELETE FROM sessions WHERE token_sha = ?`, tokenSHA)
	return err
}

func (t *tx) PruneSessions(before time.Time) (int64, error) {
	result, err := t.tx.ExecContext(t.ctx,
		`DELETE FROM sessions WHERE expires_at < ?`, stamp(before))
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}
