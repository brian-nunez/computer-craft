// Package web adapts HTTP and WebSockets to the rest of the application.
//
// It is an adapter and nothing else: it reads a request, hands values to a
// domain module, and writes whatever comes back. No decision is made here, and
// no SQL, no credential comparison, and no policy lives here.
//
// The Operator dashboard arrives in Milestone 7. What exists now is the Gateway
// endpoint the Central Server connects to, and enough of an HTTP surface to see
// that a World is there.
package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"

	"github.com/brian-nunez/computer-craft/external/internal/gateway"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/worldview"
)

// Server is the HTTP surface.
type Server struct {
	gateways  *gateway.Registry
	view      *worldview.Service
	backing   store.Store
	now       func() time.Time
	logf      func(string, ...any)
	originsOK []string
}

// Options configures a Server.
type Options struct {
	Gateways *gateway.Registry
	View     *worldview.Service
	Store    store.Store
	Now      func() time.Time
	Logf     func(string, ...any)
	// AllowedOrigins are the browser origins the dashboard may be served from.
	// The Gateway endpoint is not a browser endpoint and does not use them.
	AllowedOrigins []string
}

// New builds the server.
func New(options Options) *Server {
	server := &Server{
		gateways:  options.Gateways,
		view:      options.View,
		backing:   options.Store,
		now:       options.Now,
		logf:      options.Logf,
		originsOK: options.AllowedOrigins,
	}
	if server.now == nil {
		server.now = time.Now
	}
	if server.logf == nil {
		server.logf = func(string, ...any) {}
	}
	return server
}

// Handler builds the routes. Everything is on one origin, which is what lets
// the dashboard use a cookie session in Milestone 7 without CORS.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.health)
	mux.HandleFunc("GET /gateway", s.gateway)
	mux.HandleFunc("GET /api/worlds", s.worlds)
	mux.HandleFunc("GET /api/worlds/{world}", s.world)
	mux.HandleFunc("GET /api/worlds/{world}/traffic", s.traffic)
	mux.HandleFunc("GET /api/worlds/{world}/incidents", s.incidents)
	return mux
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}

// writeProblem reports a failure using the same stable codes the wire uses, so
// an Operator sees one vocabulary rather than two.
func (s *Server) writeProblem(w http.ResponseWriter, status int, code, message string) {
	s.writeJSON(w, status, map[string]any{"code": code, "message": message})
}

func (s *Server) health(w http.ResponseWriter, r *http.Request) {
	s.writeJSON(w, http.StatusOK, map[string]any{
		"status": "ok",
		"time":   s.now().UTC().Format(time.RFC3339),
	})
}

//--------------------------------------------------------------------------
// The Gateway endpoint
//--------------------------------------------------------------------------

// bearer reads the Gateway Credential. It is a header rather than a query
// parameter so it never lands in a proxy log or a browser history.
func bearer(r *http.Request) string {
	header := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if len(header) <= len(prefix) || !strings.EqualFold(header[:len(prefix)], prefix) {
		return ""
	}
	return strings.TrimSpace(header[len(prefix):])
}

// gateway accepts one Central Server's WebSocket. Authentication happens before
// anything is read from the socket beyond the opening frame, and an
// unauthenticated connection is closed rather than answered.
func (s *Server) gateway(w http.ResponseWriter, r *http.Request) {
	credential := bearer(r)
	if credential == "" {
		s.writeProblem(w, http.StatusUnauthorized,
			protocol.CodeAuthenticationFail, "a Gateway Credential is required")
		return
	}

	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{
		// The Gateway is not a browser endpoint. A Central Server sends no
		// Origin, and one that does is not one of ours.
		OriginPatterns: nil,
	})
	if err != nil {
		s.logf("gateway: accept failed: %v", err)
		return
	}
	conn.SetReadLimit(protocol.GatewayFrameBytes)

	ctx := r.Context()
	adapter := &socket{conn: conn}
	session, err := s.gateways.Accept(ctx, adapter, credential)
	if err != nil {
		code := protocol.CodeOf(err)
		if code == "" {
			code = protocol.CodeInternalError
		}
		s.logf("gateway: refused: %s", code)
		// The reason is deliberately terse in the close frame: a caller that
		// failed to authenticate learns only that it failed.
		_ = conn.Close(websocket.StatusPolicyViolation, code)
		return
	}

	s.logf("gateway: %s connected as %s", session.WorldID, session.ID)
	if err := session.Serve(ctx); err != nil && !errors.Is(err, context.Canceled) {
		s.logf("gateway: %s ended: %v", session.WorldID, err)
	}
	s.logf("gateway: %s disconnected", session.WorldID)
}

// socket adapts a WebSocket to the gateway package's Conn, which is what lets
// a whole session be driven over a pipe in a test.
type socket struct {
	conn *websocket.Conn
}

func (s *socket) Send(ctx context.Context, text string) error {
	return s.conn.Write(ctx, websocket.MessageText, []byte(text))
}

func (s *socket) Receive(ctx context.Context) (string, error) {
	kind, data, err := s.conn.Read(ctx)
	if err != nil {
		return "", err
	}
	if kind != websocket.MessageText {
		return "", errors.New("the Gateway carries text frames only")
	}
	return string(data), nil
}

func (s *socket) Close() error {
	return s.conn.Close(websocket.StatusNormalClosure, "")
}

//--------------------------------------------------------------------------
// Read-only views
//--------------------------------------------------------------------------

func (s *Server) worlds(w http.ResponseWriter, r *http.Request) {
	var listed []map[string]any
	err := s.backing.Do(r.Context(), func(tx store.Tx) error {
		worlds, err := tx.Worlds()
		if err != nil {
			return err
		}
		listed = make([]map[string]any, 0, len(worlds))
		for _, world := range worlds {
			presence := s.view.Presence(world.WorldID)
			listed = append(listed, map[string]any{
				"world_id":   world.WorldID,
				"central_id": world.CentralID,
				"connected":  presence.Connected,
				"stale":      presence.Stale,
			})
		}
		return nil
	})
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"the World list could not be read")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"worlds": listed})
}

func (s *Server) world(w http.ResponseWriter, r *http.Request) {
	worldID := r.PathValue("world")
	view, err := s.view.World(r.Context(), worldID)
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"that World could not be read")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{
		"world_id":  worldID,
		"connected": view.Presence.Connected,
		"stale":     view.Presence.Stale,
		"revision":  view.Revision,
		"topology":  view.Topology,
	})
}

func (s *Server) traffic(w http.ResponseWriter, r *http.Request) {
	entries, err := s.view.Traffic(r.Context(), r.PathValue("world"), 100)
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"traffic could not be read")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"events": entries})
}

func (s *Server) incidents(w http.ResponseWriter, r *http.Request) {
	entries, err := s.view.Incidents(r.Context(), r.PathValue("world"), 50)
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"incidents could not be read")
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"incidents": entries})
}
