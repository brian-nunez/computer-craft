package app_test

import (
	"context"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/app"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/store/memory"
)

func newApp(t *testing.T, now *time.Time) *app.App {
	t.Helper()
	application, err := app.New(app.Options{
		Store: memory.New(),
		Now:   func() time.Time { return *now },
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	return application
}

func TestTheAllowlistIsExactlyWhatThisReleaseAllows(t *testing.T) {
	clock := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	application := newApp(t, &clock)

	registered := map[string]bool{}
	for _, name := range application.Operations.Names() {
		registered[name] = true
	}
	for _, expected := range app.DefaultOperations {
		if !registered[expected] {
			t.Fatalf("%s is not registered", expected)
		}
	}
	if len(registered) != len(app.DefaultOperations) {
		t.Fatalf("%d operations registered, want %d", len(registered), len(app.DefaultOperations))
	}
}

// Retention prunes telemetry and nothing else. An audit record is the record of
// a decision, and losing one to a retention window would be a different kind of
// mistake entirely.
func TestPruningRemovesTrafficAndKeepsAudit(t *testing.T) {
	clock := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	application := newApp(t, &clock)
	ctx := context.Background()

	old := clock.Add(-40 * 24 * time.Hour)
	recent := clock.Add(-time.Hour)

	if err := application.Store.Do(ctx, func(tx store.Tx) error {
		if err := tx.AppendEvents([]store.Event{
			{WorldID: "w", EventID: "evt-old", Sequence: 1, ObservedAt: old, Document: `{}`},
			{WorldID: "w", EventID: "evt-new", Sequence: 2, ObservedAt: recent, Document: `{}`},
		}); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: "w", Actor: "operator", Action: "network.disable",
			Subject: "net-farm", Recorded: old,
		})
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	removed, err := application.Prune(ctx)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != 1 {
		t.Fatalf("pruned %d, want 1", removed)
	}

	events, err := application.View.Traffic(ctx, "w", 100)
	if err != nil {
		t.Fatalf("traffic: %v", err)
	}
	if len(events) != 1 || events[0].EventID != "evt-new" {
		t.Fatalf("pruning kept the wrong events: %+v", events)
	}

	records, err := application.View.Audit(ctx, "w", 10)
	if err != nil {
		t.Fatalf("audit: %v", err)
	}
	if len(records) != 1 {
		t.Fatalf("%d audit records survived, want 1", len(records))
	}
}

// A World nobody has heard from is stale. The dashboard says so rather than
// showing a plausible present.
func TestAWorldWithNoSessionIsStale(t *testing.T) {
	clock := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	application := newApp(t, &clock)
	presence := application.View.Presence("world-overworld")
	if presence.Connected {
		t.Fatal("a World with no Gateway Session is not connected")
	}
	if !presence.Stale {
		t.Fatal("and it is stale")
	}
}
