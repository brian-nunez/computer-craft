// Package gateway owns the Central Server's side of the wire.
//
// One World has at most one live Gateway Session. Everything the Central Server
// reports -- topology, Traffic Events -- is ingested through it, every External
// Operation a Computer makes arrives through it, and every administrative
// command goes back out through it.
//
// A gap is never fabricated. If a Central Server was away, its World is marked
// stale and the dashboard says so, rather than the application inventing a
// plausible present.
package gateway

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/identity"
	"github.com/brian-nunez/computer-craft/external/internal/operations"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// StaleAfter is how long a World may go unheard from before the dashboard shows
// it as stale. It is three heartbeat intervals: one missed is normal, three is
// a gap worth showing.
const StaleAfter = 30 * time.Second

// Conn is what a Gateway Session talks over. The WebSocket adapter satisfies it,
// and so does a pipe in a test -- which is what makes the whole session testable
// without a network.
type Conn interface {
	Send(ctx context.Context, text string) error
	Receive(ctx context.Context) (string, error)
	Close() error
}

// ErrNoSession is returned when a World has no live Gateway Session. It becomes
// gateway_unavailable on the wire: internal CraftNet traffic carries on, and
// only external calls fail.
var ErrNoSession = &protocol.Error{
	Code:    protocol.CodeGatewayUnavailable,
	Message: "that World has no live Gateway Session",
}

//--------------------------------------------------------------------------
// Sessions
//--------------------------------------------------------------------------

// Session is one live connection to one World's Central Server.
type Session struct {
	ID        string
	WorldID   string
	CentralID string

	conn     Conn
	registry *Registry

	mutex    sync.Mutex
	closed   bool
	nextID   int64
	pending  map[string]chan protocol.Object
	lastSeen time.Time
	sequence int64
}

// Registry holds at most one Session per World.
type Registry struct {
	mutex    sync.RWMutex
	sessions map[string]*Session

	backing    store.Store
	identities *identity.Service
	allowlist  *operations.Registry
	now        func() time.Time
	inFlight   int
}

// Options configures a Registry.
type Options struct {
	Store      store.Store
	Identities *identity.Service
	Operations *operations.Registry
	Now        func() time.Time
	// MaxInFlight bounds outstanding operations on one Gateway Session. Excess
	// work fails with busy rather than being queued without bound.
	MaxInFlight int
}

// NewRegistry builds the session registry.
func NewRegistry(options Options) *Registry {
	registry := &Registry{
		sessions:   map[string]*Session{},
		backing:    options.Store,
		identities: options.Identities,
		allowlist:  options.Operations,
		now:        options.Now,
		inFlight:   options.MaxInFlight,
	}
	if registry.now == nil {
		registry.now = time.Now
	}
	if registry.inFlight <= 0 {
		registry.inFlight = protocol.GatewayInFlight
	}
	return registry
}

// Session returns the live session for a World, if there is one.
func (r *Registry) Session(worldID string) (*Session, bool) {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	session, ok := r.sessions[worldID]
	return session, ok
}

// Worlds lists the Worlds currently connected.
func (r *Registry) Worlds() []string {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	found := make([]string, 0, len(r.sessions))
	for worldID := range r.sessions {
		found = append(found, worldID)
	}
	return found
}

// Accept authenticates a connecting Central Server and takes over that World's
// session. A second connection for the same World displaces the first rather
// than running alongside it: one World, one Gateway Session, and a Central
// Server that reconnected is the one that is really there.
func (r *Registry) Accept(ctx context.Context, conn Conn, credential string) (*Session, error) {
	hello, err := r.readHello(ctx, conn)
	if err != nil {
		return nil, err
	}

	world, err := r.identities.AuthenticateGateway(ctx, r.backing, hello.WorldID, credential)
	if err != nil {
		return nil, err
	}
	if world.CentralID != hello.CentralID {
		return nil, &protocol.Error{
			Code:    protocol.CodeAuthenticationFail,
			Message: "that Gateway Credential belongs to another Central Server",
		}
	}

	accepted, err := r.acceptedState(ctx, hello)
	if err != nil {
		return nil, err
	}

	welcome, err := protocol.EncodeGatewayWelcome(protocol.GatewayWelcome{
		GatewaySessionID:         accepted.sessionID,
		AcceptedTopologyRevision: accepted.topologyRevision,
		AcceptedTrafficSequence:  accepted.trafficSequence,
		ServerTime:               r.now().UTC().Format(time.RFC3339),
	})
	if err != nil {
		return nil, err
	}
	if err := conn.Send(ctx, welcome); err != nil {
		return nil, err
	}

	session := &Session{
		ID:        accepted.sessionID,
		WorldID:   world.WorldID,
		CentralID: world.CentralID,
		conn:      conn,
		registry:  r,
		pending:   map[string]chan protocol.Object{},
		lastSeen:  r.now().UTC(),
		sequence:  accepted.trafficSequence,
	}

	r.mutex.Lock()
	if previous, ok := r.sessions[world.WorldID]; ok {
		// The older connection is closed outside the lock's critical work, but
		// removed from the registry now so nothing new is routed to it.
		go previous.Close()
	}
	r.sessions[world.WorldID] = session
	r.mutex.Unlock()

	return session, nil
}

type accepted struct {
	sessionID        string
	topologyRevision int64
	trafficSequence  int64
}

// acceptedState tells a reconnecting Central Server what this application
// already holds, so it can send only what is missing rather than everything.
func (r *Registry) acceptedState(ctx context.Context, hello *protocol.GatewayHello) (accepted, error) {
	result := accepted{}
	err := r.backing.Do(ctx, func(tx store.Tx) error {
		topology, err := tx.Topology(hello.WorldID)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			return err
		}
		result.topologyRevision = topology.Revision

		sequence, err := tx.LastSequence(hello.WorldID)
		if err != nil {
			return err
		}
		result.trafficSequence = sequence
		return nil
	})
	if err != nil {
		return accepted{}, err
	}
	result.sessionID = fmt.Sprintf("gws-%d", r.now().UTC().UnixNano())
	return result, nil
}

func (r *Registry) readHello(ctx context.Context, conn Conn) (*protocol.GatewayHello, error) {
	text, err := conn.Receive(ctx)
	if err != nil {
		return nil, err
	}
	return protocol.DecodeGatewayHello(text)
}

// Release removes a session, if it is still the live one for its World.
func (r *Registry) Release(session *Session) {
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if current, ok := r.sessions[session.WorldID]; ok && current == session {
		delete(r.sessions, session.WorldID)
	}
}

//--------------------------------------------------------------------------
// Session lifecycle
//--------------------------------------------------------------------------

// Close ends the session and fails everything still waiting on it.
func (s *Session) Close() error {
	s.mutex.Lock()
	if s.closed {
		s.mutex.Unlock()
		return nil
	}
	s.closed = true
	waiting := s.pending
	s.pending = map[string]chan protocol.Object{}
	s.mutex.Unlock()

	for _, channel := range waiting {
		close(channel)
	}
	s.registry.Release(s)
	return s.conn.Close()
}

// LastSeen is when authenticated traffic last arrived on this session.
func (s *Session) LastSeen() time.Time {
	s.mutex.Lock()
	defer s.mutex.Unlock()
	return s.lastSeen
}

// Stale reports whether this World's view should be shown as out of date.
func (s *Session) Stale(now time.Time) bool {
	return now.Sub(s.LastSeen()) > StaleAfter
}

// Serve reads frames until the connection ends. It is the whole inbound path:
// nothing else reads from the connection.
func (s *Session) Serve(ctx context.Context) error {
	defer s.Close()

	// Anything left pending from a previous session is resent, once, on the
	// session that replaced it.
	if err := s.resendPending(ctx); err != nil {
		return err
	}

	for {
		text, err := s.conn.Receive(ctx)
		if err != nil {
			return err
		}
		frame, err := protocol.DecodeGatewayFrame(text)
		if err != nil {
			// A frame that does not validate is answered with a stable error
			// rather than closing the session: one bad message is not a reason
			// to lose a World.
			s.sendError(ctx, "", protocol.CodeOf(err), err.Error())
			continue
		}

		s.mutex.Lock()
		s.lastSeen = s.registry.now().UTC()
		s.mutex.Unlock()

		if err := s.dispatch(ctx, frame); err != nil {
			return err
		}
	}
}

func (s *Session) dispatch(ctx context.Context, frame *protocol.GatewayFrame) error {
	switch frame.Kind {
	case "heartbeat":
		return nil
	case "topology_snapshot", "topology_change":
		return s.ingestTopology(ctx, frame)
	case "traffic_batch":
		return s.ingestTraffic(ctx, frame)
	case "external_request":
		return s.serveExternalRequest(ctx, frame)
	case "command_result":
		return s.settleCommand(ctx, frame)
	case "external_response", "ack", "error":
		s.deliver(frame)
		return nil
	}
	return nil
}

// deliver hands a correlated reply to whoever is waiting for it.
func (s *Session) deliver(frame *protocol.GatewayFrame) {
	if frame.RequestID == "" {
		return
	}
	s.mutex.Lock()
	channel, ok := s.pending[frame.RequestID]
	if ok {
		delete(s.pending, frame.RequestID)
	}
	s.mutex.Unlock()
	if ok {
		channel <- frame.Body
		close(channel)
	}
}

func (s *Session) send(ctx context.Context, frame protocol.GatewayFrame) error {
	text, err := protocol.EncodeGatewayFrame(frame)
	if err != nil {
		return err
	}
	return s.conn.Send(ctx, text)
}

func (s *Session) sendError(ctx context.Context, requestID, code, message string) {
	if code == "" {
		code = protocol.CodeInternalError
	}
	body, err := protocol.ErrorBody(code, message, nil)
	if err != nil {
		return
	}
	_ = s.send(ctx, protocol.GatewayFrame{Kind: "error", RequestID: requestID, Body: body})
}
