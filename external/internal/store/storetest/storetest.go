// Package storetest is the suite every store adapter has to pass.
//
// The in-memory adapter exists so tests are fast; it is only worth having if a
// test that passes against it means the same thing as one that passes against
// SQLite. That is what this package is for -- both adapters run exactly these
// cases, including the ones about rolling back.
package storetest

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// Factory builds a fresh, empty store.
type Factory func(t *testing.T) store.Store

var epoch = time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)

// Run executes the whole suite against one adapter.
func Run(t *testing.T, newStore Factory) {
	t.Run("a world round trips", func(t *testing.T) { worldRoundTrip(t, newStore) })
	t.Run("a missing row is ErrNotFound", func(t *testing.T) { missingRows(t, newStore) })
	t.Run("a failed transaction leaves nothing behind", func(t *testing.T) { rollback(t, newStore) })
	t.Run("a credential can be revoked", func(t *testing.T) { credentials(t, newStore) })
	t.Run("a device is unique per computer", func(t *testing.T) { devices(t, newStore) })
	t.Run("topology never goes backwards", func(t *testing.T) { topology(t, newStore) })
	t.Run("events deduplicate and prune", func(t *testing.T) { events(t, newStore) })
	t.Run("commands settle once", func(t *testing.T) { commands(t, newStore) })
	t.Run("audit survives pruning", func(t *testing.T) { auditSurvives(t, newStore) })
}

func sampleWorld() store.World {
	return store.World{
		WorldID: "world-overworld", CentralID: "central-main",
		GatewayCredentialRef: "gwc-world-overworld",
		GatewayCredentialSHA: "aa", WorldKeySHA: "bb", CreatedAt: epoch,
	}
}

func worldRoundTrip(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutWorld(sampleWorld())
	}); err != nil {
		t.Fatalf("put: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		world, err := tx.World("world-overworld")
		if err != nil {
			return err
		}
		if world.CentralID != "central-main" {
			t.Fatalf("central_id = %s", world.CentralID)
		}
		if !world.CreatedAt.Equal(epoch) {
			t.Fatalf("created_at = %v, want %v", world.CreatedAt, epoch)
		}
		worlds, err := tx.Worlds()
		if err != nil {
			return err
		}
		if len(worlds) != 1 {
			t.Fatalf("listed %d worlds", len(worlds))
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func missingRows(t *testing.T, newStore Factory) {
	backing := newStore(t)
	err := backing.Do(context.Background(), func(tx store.Tx) error {
		for name, lookup := range map[string]func() error{
			"world":      func() error { _, err := tx.World("nobody"); return err },
			"credential": func() error { _, err := tx.Credential("nobody"); return err },
			"device":     func() error { _, err := tx.Device("nobody"); return err },
			"token":      func() error { _, err := tx.Token("nobody"); return err },
			"topology":   func() error { _, err := tx.Topology("nobody"); return err },
			"command":    func() error { _, err := tx.Command("nobody"); return err },
		} {
			if err := lookup(); !errors.Is(err, store.ErrNotFound) {
				t.Fatalf("%s: error = %v, want ErrNotFound", name, err)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("read: %v", err)
	}
}

// rollback is the case the in-memory adapter exists to be honest about: a
// transaction that fails must leave the store exactly as it was.
func rollback(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	sentinel := errors.New("deliberate")

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutWorld(sampleWorld())
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	err := backing.Do(ctx, func(tx store.Tx) error {
		if err := tx.PutCredential(store.Credential{
			Reference: "gwc-2", Kind: "gateway", Subject: "central-main",
			WorldID: "world-overworld", DigestSHA: "cc", IssuedAt: epoch,
		}); err != nil {
			return err
		}
		if err := tx.AppendEvents([]store.Event{{
			WorldID: "world-overworld", EventID: "evt-1", Sequence: 1,
			ObservedAt: epoch, Document: "{}",
		}}); err != nil {
			return err
		}
		if err := tx.AppendAudit(store.AuditRecord{
			WorldID: "world-overworld", Actor: "test", Action: "x", Recorded: epoch,
		}); err != nil {
			return err
		}
		return sentinel
	})
	if !errors.Is(err, sentinel) {
		t.Fatalf("error = %v, want the sentinel", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.Credential("gwc-2"); !errors.Is(err, store.ErrNotFound) {
			t.Fatal("the credential survived a rolled-back transaction")
		}
		events, err := tx.Events("world-overworld", 10)
		if err != nil {
			return err
		}
		if len(events) != 0 {
			t.Fatalf("%d events survived a rolled-back transaction", len(events))
		}
		records, err := tx.Audit("world-overworld", 10)
		if err != nil {
			return err
		}
		if len(records) != 0 {
			t.Fatalf("%d audit records survived a rolled-back transaction", len(records))
		}
		// And what was there before is still there.
		if _, err := tx.World("world-overworld"); err != nil {
			t.Fatalf("the seeded world was lost: %v", err)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func credentials(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	revokedAt := epoch.Add(time.Hour)

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutCredential(store.Credential{
			Reference: "dev-1", Kind: "device", Subject: "cmp-1",
			WorldID: "world-overworld", DigestSHA: "dd", IssuedAt: epoch,
		})
	}); err != nil {
		t.Fatalf("put: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		credential, err := tx.Credential("dev-1")
		if err != nil {
			return err
		}
		if credential.Revoked() {
			t.Fatal("a fresh credential is not revoked")
		}
		return tx.RevokeCredential("dev-1", revokedAt)
	}); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		credential, err := tx.Credential("dev-1")
		if err != nil {
			return err
		}
		if !credential.Revoked() {
			t.Fatal("the revocation did not stick")
		}
		if !credential.RevokedAt.Equal(revokedAt) {
			t.Fatalf("revoked_at = %v, want %v", credential.RevokedAt, revokedAt)
		}
		if err := tx.RevokeCredential("nobody", revokedAt); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("revoking nothing = %v, want ErrNotFound", err)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func devices(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	device := store.Device{
		DeviceID: "world-overworld-cmp-1", WorldID: "world-overworld",
		ISPID: "isp-acme", CustomerNetworkID: "net-home", RouterID: "rtr-home",
		ComputerID: "cmp-1", LocalAddress: "192.168.1.20",
		CredentialRef: "dev-1", RegisteredAt: epoch,
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutDevice(device)
	}); err != nil {
		t.Fatalf("put: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.DeviceByComputer("world-overworld", "cmp-1")
		if err != nil {
			return err
		}
		if found.CustomerNetworkID != "net-home" {
			t.Fatalf("customer_network_id = %s", found.CustomerNetworkID)
		}
		if !found.AncestryOf().Matches(device.AncestryOf()) {
			t.Fatal("the ancestry did not round trip")
		}
		if _, err := tx.DeviceByComputer("world-overworld", "cmp-2"); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("unknown computer = %v, want ErrNotFound", err)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func topology(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()

	write := func(revision int64, document string) {
		if err := backing.Do(ctx, func(tx store.Tx) error {
			return tx.PutTopology(store.Topology{
				WorldID: "world-overworld", Revision: revision,
				Document: document, ObservedAt: epoch,
			})
		}); err != nil {
			t.Fatalf("put %d: %v", revision, err)
		}
	}

	write(5, `{"revision":5}`)
	write(7, `{"revision":7}`)
	// A reconnecting Central Server may replay. Going backwards would make the
	// dashboard lie about what is out there now.
	write(6, `{"revision":6}`)

	if err := backing.Do(ctx, func(tx store.Tx) error {
		held, err := tx.Topology("world-overworld")
		if err != nil {
			return err
		}
		if held.Revision != 7 {
			t.Fatalf("revision = %d, want 7", held.Revision)
		}
		if held.Document != `{"revision":7}` {
			t.Fatalf("document = %s", held.Document)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func events(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	old := epoch.Add(-40 * 24 * time.Hour)

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.AppendEvents([]store.Event{
			{WorldID: "w", EventID: "evt-1", Sequence: 1, ObservedAt: old, Document: `{"a":1}`},
			{WorldID: "w", EventID: "evt-2", Sequence: 2, ObservedAt: epoch, Document: `{"a":2}`},
			// A replayed event is not a failure: a Central Server that reconnects
			// resends its buffer.
			{WorldID: "w", EventID: "evt-2", Sequence: 2, ObservedAt: epoch, Document: `{"a":2}`},
		})
	}); err != nil {
		t.Fatalf("append: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		held, err := tx.Events("w", 100)
		if err != nil {
			return err
		}
		if len(held) != 2 {
			t.Fatalf("held %d events, want 2", len(held))
		}
		if held[0].Sequence != 1 || held[1].Sequence != 2 {
			t.Fatal("events came back out of order")
		}
		sequence, err := tx.LastSequence("w")
		if err != nil {
			return err
		}
		if sequence != 2 {
			t.Fatalf("last sequence = %d, want 2", sequence)
		}

		removed, err := tx.PruneEvents(epoch.Add(-24 * time.Hour))
		if err != nil {
			return err
		}
		if removed != 1 {
			t.Fatalf("pruned %d, want 1", removed)
		}
		remaining, err := tx.Events("w", 100)
		if err != nil {
			return err
		}
		if len(remaining) != 1 || remaining[0].EventID != "evt-2" {
			t.Fatal("pruning removed the wrong event")
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func commands(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	settled := epoch.Add(time.Minute)

	if err := backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutCommand(store.Command{
			CommandID: "cmd-1", WorldID: "w", Action: "set_network_status",
			Document: `{}`, Status: store.CommandPending, IssuedAt: epoch,
		})
	}); err != nil {
		t.Fatalf("put: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		pending, err := tx.PendingCommands("w")
		if err != nil {
			return err
		}
		if len(pending) != 1 {
			t.Fatalf("%d pending, want 1", len(pending))
		}
		command := pending[0]
		command.Status = store.CommandApplied
		command.Revision = 12
		command.SettledAt = &settled
		return tx.PutCommand(command)
	}); err != nil {
		t.Fatalf("settle: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		pending, err := tx.PendingCommands("w")
		if err != nil {
			return err
		}
		if len(pending) != 0 {
			t.Fatalf("%d still pending after settling", len(pending))
		}
		command, err := tx.Command("cmd-1")
		if err != nil {
			return err
		}
		if command.Status != store.CommandApplied || command.Revision != 12 {
			t.Fatalf("command = %+v", command)
		}
		if command.SettledAt == nil || !command.SettledAt.Equal(settled) {
			t.Fatal("settled_at did not round trip")
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

// auditSurvives is the property that matters most about retention: pruning
// telemetry must never prune the record of a decision.
func auditSurvives(t *testing.T, newStore Factory) {
	backing := newStore(t)
	ctx := context.Background()
	old := epoch.Add(-40 * 24 * time.Hour)

	if err := backing.Do(ctx, func(tx store.Tx) error {
		if err := tx.AppendEvents([]store.Event{{
			WorldID: "w", EventID: "evt-old", Sequence: 1, ObservedAt: old, Document: `{}`,
		}}); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: "w", Actor: "operator", Action: "network.disable",
			Subject: "net-farm", Recorded: old,
		})
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	if err := backing.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.PruneEvents(epoch); err != nil {
			return err
		}
		records, err := tx.Audit("w", 10)
		if err != nil {
			return err
		}
		if len(records) != 1 {
			t.Fatalf("%d audit records survived pruning, want 1", len(records))
		}
		if records[0].Action != "network.disable" {
			t.Fatalf("action = %s", records[0].Action)
		}
		return nil
	}); err != nil {
		t.Fatalf("prune: %v", err)
	}
}
