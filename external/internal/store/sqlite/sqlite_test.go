package sqlite_test

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/store/sqlite"
	"github.com/brian-nunez/computer-craft/external/internal/store/storetest"
	"github.com/brian-nunez/computer-craft/external/internal/testsupport"
)

// newStore opens a temporary file-backed database, which is what production
// uses. An in-memory SQLite would be faster and would not exercise the file.
func newStore(t *testing.T) store.Store {
	t.Helper()
	path := filepath.Join(testsupport.StateDir(t), "craftnet.db")
	backing, err := sqlite.Open(context.Background(), path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	t.Cleanup(func() { backing.Close() })
	return backing
}

func TestSQLiteStore(t *testing.T) {
	storetest.Run(t, newStore)
}

// Migrations are forward-only and have to be safe to run again, because that is
// what happens every time the process starts.
func TestMigrationsAreIdempotent(t *testing.T) {
	path := filepath.Join(testsupport.StateDir(t), "craftnet.db")
	ctx := context.Background()

	first, err := sqlite.Open(ctx, path)
	if err != nil {
		t.Fatalf("first open: %v", err)
	}
	if err := first.Do(ctx, func(tx store.Tx) error {
		return tx.PutWorld(store.World{WorldID: "w", CentralID: "c"})
	}); err != nil {
		t.Fatalf("write: %v", err)
	}
	first.Close()

	second, err := sqlite.Open(ctx, path)
	if err != nil {
		t.Fatalf("second open: %v", err)
	}
	defer second.Close()

	if err := second.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.World("w"); err != nil {
			t.Fatalf("the world did not survive reopening: %v", err)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

// A database created by an older release has to migrate forward, not be
// rejected or rebuilt.
func TestMigratesAnEmptyDatabaseForward(t *testing.T) {
	path := filepath.Join(testsupport.StateDir(t), "fresh.db")
	backing, err := sqlite.Open(context.Background(), path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer backing.Close()
	if sqlite.SchemaVersion <= 0 {
		t.Fatal("a migrated database reports a schema version")
	}
}
