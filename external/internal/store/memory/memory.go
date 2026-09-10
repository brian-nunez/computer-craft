// Package memory is the in-memory store adapter.
//
// It exists for tests, and it is held to exactly the same suite as the SQLite
// adapter, so a test that passes here means the same thing. Its one job beyond
// storing values is to be genuinely transactional: a function that returns an
// error must leave nothing behind, or tests would pass against it that the real
// database would fail.

package memory

import (
	"context"
	"sort"
	"sync"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/store"
)

type data struct {
	worlds      map[string]store.World
	credentials map[string]store.Credential
	devices     map[string]store.Device
	tokens      map[string]store.IssuedToken
	topology    map[string]store.Topology
	events      map[string][]store.Event
	commands    map[string]store.Command
	audit       map[string][]store.AuditRecord
}

func newData() *data {
	return &data{
		worlds:      map[string]store.World{},
		credentials: map[string]store.Credential{},
		devices:     map[string]store.Device{},
		tokens:      map[string]store.IssuedToken{},
		topology:    map[string]store.Topology{},
		events:      map[string][]store.Event{},
		commands:    map[string]store.Command{},
		audit:       map[string][]store.AuditRecord{},
	}
}

// clone is what makes a rollback real: a transaction works on a copy, and the
// copy is only adopted when the function returns without error.
func (d *data) clone() *data {
	copied := newData()
	for key, value := range d.worlds {
		copied.worlds[key] = value
	}
	for key, value := range d.credentials {
		copied.credentials[key] = value
	}
	for key, value := range d.devices {
		copied.devices[key] = value
	}
	for key, value := range d.tokens {
		copied.tokens[key] = value
	}
	for key, value := range d.topology {
		copied.topology[key] = value
	}
	for key, value := range d.events {
		copied.events[key] = append([]store.Event(nil), value...)
	}
	for key, value := range d.commands {
		copied.commands[key] = value
	}
	for key, value := range d.audit {
		copied.audit[key] = append([]store.AuditRecord(nil), value...)
	}
	return copied
}

// Store is the in-memory adapter.
type Store struct {
	mutex sync.Mutex
	data  *data
}

// New builds an empty store.
func New() *Store {
	return &Store{data: newData()}
}

// Do runs fn inside a transaction. The whole store is held for the duration,
// which is heavy-handed and exactly right for a test adapter.
func (s *Store) Do(ctx context.Context, fn func(store.Tx) error) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	s.mutex.Lock()
	defer s.mutex.Unlock()

	working := s.data.clone()
	if err := fn(&tx{data: working}); err != nil {
		return err
	}
	s.data = working
	return nil
}

func (s *Store) Close() error { return nil }

type tx struct{ data *data }

//--------------------------------------------------------------------------
// Worlds
//--------------------------------------------------------------------------

func (t *tx) PutWorld(world store.World) error {
	t.data.worlds[world.WorldID] = world
	return nil
}

func (t *tx) World(worldID string) (store.World, error) {
	world, ok := t.data.worlds[worldID]
	if !ok {
		return store.World{}, store.ErrNotFound
	}
	return world, nil
}

func (t *tx) Worlds() ([]store.World, error) {
	found := make([]store.World, 0, len(t.data.worlds))
	for _, world := range t.data.worlds {
		found = append(found, world)
	}
	sort.Slice(found, func(a, b int) bool { return found[a].WorldID < found[b].WorldID })
	return found, nil
}

//--------------------------------------------------------------------------
// Credentials
//--------------------------------------------------------------------------

func (t *tx) PutCredential(credential store.Credential) error {
	t.data.credentials[credential.Reference] = credential
	return nil
}

func (t *tx) Credential(reference string) (store.Credential, error) {
	credential, ok := t.data.credentials[reference]
	if !ok {
		return store.Credential{}, store.ErrNotFound
	}
	return credential, nil
}

func (t *tx) RevokeCredential(reference string, at time.Time) error {
	credential, ok := t.data.credentials[reference]
	if !ok {
		return store.ErrNotFound
	}
	credential.RevokedAt = &at
	t.data.credentials[reference] = credential
	return nil
}

//--------------------------------------------------------------------------
// Devices
//--------------------------------------------------------------------------

func (t *tx) PutDevice(device store.Device) error {
	t.data.devices[device.DeviceID] = device
	return nil
}

func (t *tx) Device(deviceID string) (store.Device, error) {
	device, ok := t.data.devices[deviceID]
	if !ok {
		return store.Device{}, store.ErrNotFound
	}
	return device, nil
}

func (t *tx) DeviceByComputer(worldID, computerID string) (store.Device, error) {
	for _, device := range t.data.devices {
		if device.WorldID == worldID && device.ComputerID == computerID {
			return device, nil
		}
	}
	return store.Device{}, store.ErrNotFound
}

//--------------------------------------------------------------------------
// Tokens
//--------------------------------------------------------------------------

func (t *tx) PutToken(token store.IssuedToken) error {
	t.data.tokens[token.TokenID] = token
	return nil
}

func (t *tx) Token(tokenID string) (store.IssuedToken, error) {
	token, ok := t.data.tokens[tokenID]
	if !ok {
		return store.IssuedToken{}, store.ErrNotFound
	}
	return token, nil
}

func (t *tx) RevokeToken(tokenID string, at time.Time) error {
	token, ok := t.data.tokens[tokenID]
	if !ok {
		return store.ErrNotFound
	}
	token.RevokedAt = &at
	t.data.tokens[tokenID] = token
	return nil
}

//--------------------------------------------------------------------------
// Topology
//--------------------------------------------------------------------------

func (t *tx) PutTopology(topology store.Topology) error {
	existing, ok := t.data.topology[topology.WorldID]
	// A snapshot that is older than what is already held is not applied: a
	// reconnecting Central Server may replay, and going backwards would make the
	// dashboard lie.
	if ok && existing.Revision > topology.Revision {
		return nil
	}
	t.data.topology[topology.WorldID] = topology
	return nil
}

func (t *tx) Topology(worldID string) (store.Topology, error) {
	topology, ok := t.data.topology[worldID]
	if !ok {
		return store.Topology{}, store.ErrNotFound
	}
	return topology, nil
}

//--------------------------------------------------------------------------
// Traffic
//--------------------------------------------------------------------------

func (t *tx) AppendEvents(events []store.Event) error {
	for _, event := range events {
		held := t.data.events[event.WorldID]
		duplicate := false
		for _, existing := range held {
			if existing.EventID == event.EventID {
				duplicate = true
				break
			}
		}
		if !duplicate {
			t.data.events[event.WorldID] = append(held, event)
		}
	}
	return nil
}

func (t *tx) Events(worldID string, limit int) ([]store.Event, error) {
	held := t.data.events[worldID]
	sorted := append([]store.Event(nil), held...)
	sort.Slice(sorted, func(a, b int) bool { return sorted[a].Sequence < sorted[b].Sequence })
	if limit > 0 && len(sorted) > limit {
		sorted = sorted[len(sorted)-limit:]
	}
	return sorted, nil
}

func (t *tx) LastSequence(worldID string) (int64, error) {
	var highest int64
	for _, event := range t.data.events[worldID] {
		if event.Sequence > highest {
			highest = event.Sequence
		}
	}
	return highest, nil
}

func (t *tx) PruneEvents(before time.Time) (int64, error) {
	var removed int64
	for worldID, held := range t.data.events {
		kept := held[:0:0]
		for _, event := range held {
			if event.ObservedAt.Before(before) {
				removed++
				continue
			}
			kept = append(kept, event)
		}
		t.data.events[worldID] = kept
	}
	return removed, nil
}

//--------------------------------------------------------------------------
// Commands
//--------------------------------------------------------------------------

func (t *tx) PutCommand(command store.Command) error {
	t.data.commands[command.CommandID] = command
	return nil
}

func (t *tx) Command(commandID string) (store.Command, error) {
	command, ok := t.data.commands[commandID]
	if !ok {
		return store.Command{}, store.ErrNotFound
	}
	return command, nil
}

func (t *tx) PendingCommands(worldID string) ([]store.Command, error) {
	found := make([]store.Command, 0)
	for _, command := range t.data.commands {
		if command.WorldID == worldID && command.Status == store.CommandPending {
			found = append(found, command)
		}
	}
	sort.Slice(found, func(a, b int) bool { return found[a].CommandID < found[b].CommandID })
	return found, nil
}

//--------------------------------------------------------------------------
// Audit
//--------------------------------------------------------------------------

func (t *tx) AppendAudit(record store.AuditRecord) error {
	t.data.audit[record.WorldID] = append(t.data.audit[record.WorldID], record)
	return nil
}

func (t *tx) Audit(worldID string, limit int) ([]store.AuditRecord, error) {
	held := t.data.audit[worldID]
	if limit > 0 && len(held) > limit {
		held = held[len(held)-limit:]
	}
	return append([]store.AuditRecord(nil), held...), nil
}
