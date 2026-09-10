package sqlite

// Migrating a database that a previous release wrote.
//
// This is a white-box test on purpose: it needs to build a database at an
// earlier schema version, which nothing outside this package can or should be
// able to do. Ticket 14 allows exactly that for a dedicated adapter test.

import (
	"context"
	"database/sql"
	"path/filepath"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/testsupport"
)

// ReleaseCandidateSchema is the schema version the previous release candidate
// shipped: everything up to and including the audit index, before the operator
// and session tables the dashboard added.
//
// It is written down rather than computed so that adding a migration cannot
// quietly change what "the previous release" means. When v0.1.0 ships, this
// becomes SchemaVersion as of that tag, and the release after it migrates from
// there.
const ReleaseCandidateSchema = 14

// openAt builds a database at exactly `version` and stops there, which is what
// a binary from that release would have left behind.
func openAt(t *testing.T, path string, version int) {
	t.Helper()
	if version > len(migrations) {
		t.Fatalf("there is no schema version %d; there are %d migrations", version, len(migrations))
	}
	db, err := sql.Open("sqlite", path+"?_pragma=foreign_keys(1)")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer db.Close()

	ctx := context.Background()
	for index := 0; index < version; index++ {
		if _, err := db.ExecContext(ctx, migrations[index]); err != nil {
			t.Fatalf("migration %d: %v", index+1, err)
		}
	}
	if _, err := db.ExecContext(ctx,
		`INSERT INTO schema_version (version) VALUES (?)`, version); err != nil {
		t.Fatalf("record version: %v", err)
	}
}

func TestTheReleaseCandidateSchemaIsStillTheOneWeMigrateFrom(t *testing.T) {
	if ReleaseCandidateSchema >= len(migrations) {
		t.Fatalf("nothing has been added since schema %d; there is nothing to migrate",
			ReleaseCandidateSchema)
	}
	if SchemaVersion != len(migrations) {
		t.Fatalf("SchemaVersion = %d, want %d", SchemaVersion, len(migrations))
	}
}

// A database written by the previous release candidate migrates forward, and
// everything it held is still there afterwards. This is the migration path an
// upgrade actually takes, and it is not the same as starting empty.
func TestMigratesFromThePreviousReleaseCandidate(t *testing.T) {
	path := filepath.Join(testsupport.StateDir(t), "previous.db")
	openAt(t, path, ReleaseCandidateSchema)

	ctx := context.Background()
	seeded, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	now := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC).Unix()
	for _, statement := range []struct {
		query string
		args  []any
	}{
		{`INSERT INTO worlds (world_id, central_id, world_key_sha, gateway_credential_sha,
            gateway_credential_ref, created_at)
          VALUES (?, ?, ?, ?, ?, ?)`,
			[]any{"world-overworld", "central-main", "aa", "bb", "cred-1", now}},
		{`INSERT INTO audit (world_id, actor, action, subject, detail, recorded_at)
          VALUES (?, ?, ?, ?, ?, ?)`,
			[]any{"world-overworld", "central-main", "command.applied", "cmd-1", "old", now}},
	} {
		if _, err := seeded.ExecContext(ctx, statement.query, statement.args...); err != nil {
			seeded.Close()
			t.Fatalf("seed the previous release: %v", err)
		}
	}
	seeded.Close()

	// The current binary opens it and brings it forward.
	backing, err := Open(ctx, path)
	if err != nil {
		t.Fatalf("migrate forward: %v", err)
	}
	defer backing.Close()

	var version int
	row := backing.db.QueryRowContext(ctx, `SELECT MAX(version) FROM schema_version`)
	if err := row.Scan(&version); err != nil {
		t.Fatalf("read version: %v", err)
	}
	if version != SchemaVersion {
		t.Fatalf("version = %d, want %d", version, SchemaVersion)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		world, err := tx.World("world-overworld")
		if err != nil {
			return err
		}
		if world.CentralID != "central-main" {
			t.Fatalf("central_id = %q", world.CentralID)
		}
		records, err := tx.Audit("world-overworld", 10)
		if err != nil {
			return err
		}
		if len(records) != 1 || records[0].Subject != "cmd-1" {
			t.Fatalf("the audit history did not survive the migration: %+v", records)
		}
		// And what the new schema added is usable straight away.
		return tx.PutOperator(store.Operator{
			Name: "alex", Salt: "00", PasswordSHA: "11", Iterations: 1,
			CreatedAt: time.Now().UTC(),
		})
	}); err != nil {
		t.Fatalf("read the migrated database: %v", err)
	}
}

// Migrating is forward-only and safe to repeat, because it runs at every start.
func TestMigratingTwiceFromThePreviousReleaseChangesNothing(t *testing.T) {
	path := filepath.Join(testsupport.StateDir(t), "twice.db")
	openAt(t, path, ReleaseCandidateSchema)

	ctx := context.Background()
	for round := 1; round <= 3; round++ {
		backing, err := Open(ctx, path)
		if err != nil {
			t.Fatalf("round %d: %v", round, err)
		}
		var rows int
		row := backing.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM schema_version`)
		if err := row.Scan(&rows); err != nil {
			backing.Close()
			t.Fatalf("count: %v", err)
		}
		if rows != 1 {
			backing.Close()
			t.Fatalf("round %d: %d schema_version rows, want exactly 1", round, rows)
		}
		backing.Close()
	}
}
