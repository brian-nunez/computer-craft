// Package worldview builds the projections an Operator reads.
//
// Everything here is derived from what a Central Server reported and what this
// application recorded. None of it is an authority: the in-world roles own the
// network, and a projection that disagrees with them is the projection that is
// wrong. What this package does own is saying so -- a World nobody has heard
// from is marked stale rather than shown as though it were current.
package worldview

import (
	"context"
	"errors"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// Retention is how long Traffic Events are kept by default.
const Retention = 30 * 24 * time.Hour

// Service builds projections over the store.
type Service struct {
	backing store.Store
	now     func() time.Time
	// connected reports whether a World currently has a live Gateway Session.
	connected func(worldID string) (time.Time, bool)
	retention time.Duration
}

// Options configures a Service.
type Options struct {
	Store     store.Store
	Now       func() time.Time
	Connected func(worldID string) (time.Time, bool)
	Retention time.Duration
}

// New builds the service.
func New(options Options) *Service {
	service := &Service{
		backing:   options.Store,
		now:       options.Now,
		connected: options.Connected,
		retention: options.Retention,
	}
	if service.now == nil {
		service.now = time.Now
	}
	if service.connected == nil {
		service.connected = func(string) (time.Time, bool) { return time.Time{}, false }
	}
	if service.retention <= 0 {
		service.retention = Retention
	}
	return service
}

// Presence is what a dashboard shows above everything else: is this World
// there, and if not, how out of date is what follows.
type Presence struct {
	WorldID   string
	Connected bool
	LastSeen  time.Time
	Stale     bool
	StaleFor  time.Duration
}

// Presence reports one World's liveness.
func (s *Service) Presence(worldID string) Presence {
	now := s.now().UTC()
	lastSeen, connected := s.connected(worldID)
	presence := Presence{WorldID: worldID, Connected: connected, LastSeen: lastSeen}
	if !connected {
		presence.Stale = true
		if !lastSeen.IsZero() {
			presence.StaleFor = now.Sub(lastSeen)
		}
		return presence
	}
	if age := now.Sub(lastSeen); age > 0 {
		presence.StaleFor = age
	}
	return presence
}

// World is the whole view of one World.
type World struct {
	Presence Presence
	Revision int64
	Topology protocol.Object
	Observed time.Time
}

// World assembles the projection for one World. A World with no topology yet is
// not an error: it has simply never reported.
func (s *Service) World(ctx context.Context, worldID string) (World, error) {
	view := World{Presence: s.Presence(worldID)}

	err := s.backing.Do(ctx, func(tx store.Tx) error {
		topology, err := tx.Topology(worldID)
		if errors.Is(err, store.ErrNotFound) {
			return nil
		}
		if err != nil {
			return err
		}
		view.Revision = topology.Revision
		view.Observed = topology.ObservedAt

		value, err := protocol.Decode(topology.Document, protocol.DefaultLimits())
		if err != nil {
			return err
		}
		if object, ok := value.(protocol.Object); ok {
			view.Topology = object
		}
		return nil
	})
	return view, err
}

// TrafficEntry is one Traffic Event as a dashboard reads it. It carries what
// the event carried and nothing more -- there is no payload to redact here,
// because there was never one to begin with.
type TrafficEntry struct {
	Sequence   int64
	EventID    string
	ObservedAt time.Time
	Event      protocol.Object
}

// Traffic returns the most recent Traffic Events for a World, oldest first.
func (s *Service) Traffic(ctx context.Context, worldID string, limit int) ([]TrafficEntry, error) {
	var entries []TrafficEntry
	err := s.backing.Do(ctx, func(tx store.Tx) error {
		events, err := tx.Events(worldID, limit)
		if err != nil {
			return err
		}
		entries = make([]TrafficEntry, 0, len(events))
		for _, event := range events {
			entry := TrafficEntry{
				Sequence: event.Sequence, EventID: event.EventID, ObservedAt: event.ObservedAt,
			}
			value, err := protocol.Decode(event.Document, protocol.DefaultLimits())
			if err == nil {
				if object, ok := value.(protocol.Object); ok {
					entry.Event = object
				}
			}
			entries = append(entries, entry)
		}
		return nil
	})
	return entries, err
}

// Incidents are the Traffic Events that did not end in a delivery, which is
// what an Operator looks at when something is wrong.
func (s *Service) Incidents(ctx context.Context, worldID string, limit int) ([]TrafficEntry, error) {
	// Read a wider window than asked for, because incidents are the minority.
	entries, err := s.Traffic(ctx, worldID, limit*20)
	if err != nil {
		return nil, err
	}
	found := make([]TrafficEntry, 0, limit)
	for index := len(entries) - 1; index >= 0 && len(found) < limit; index-- {
		outcome, _ := entries[index].Event["outcome"].(string)
		if protocol.KnownCode(outcome) {
			found = append(found, entries[index])
		}
	}
	// Hand them back oldest first, like every other listing.
	for left, right := 0, len(found)-1; left < right; left, right = left+1, right-1 {
		found[left], found[right] = found[right], found[left]
	}
	return found, nil
}

// Audit returns what Operators and the application itself did.
func (s *Service) Audit(ctx context.Context, worldID string, limit int) ([]store.AuditRecord, error) {
	var records []store.AuditRecord
	err := s.backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.Audit(worldID, limit)
		if err != nil {
			return err
		}
		records = found
		return nil
	})
	return records, err
}

// Prune removes Traffic Events past the retention window. Audit records are
// deliberately untouched: pruning telemetry must never prune the record of a
// decision.
func (s *Service) Prune(ctx context.Context) (int64, error) {
	before := s.now().UTC().Add(-s.retention)
	var removed int64
	err := s.backing.Do(ctx, func(tx store.Tx) error {
		count, err := tx.PruneEvents(before)
		if err != nil {
			return err
		}
		removed = count
		return nil
	})
	return removed, err
}
