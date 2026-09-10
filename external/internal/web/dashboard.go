package web

// The Operator dashboard.
//
// One origin serves the page, its assets, and its API, which is what lets a
// cookie hold the session: there is no second origin to guard against and no
// bearer token for a script to steal out of local storage.
//
// Every /api route fails closed. A request with no session, an expired session,
// or a session belonging to a disabled Operator is refused before a handler
// runs, and an /api path nobody registered is refused the same way rather than
// falling through to the page.

import (
	"context"
	"crypto/rand"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io/fs"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// The page and its assets ship inside the binary. Nothing is fetched from a
// CDN, so the dashboard works next to a Minecraft server with no internet.
//
//go:embed assets
var assetFS embed.FS

// SessionCookie is the name of the dashboard's session cookie.
const SessionCookie = "craftnet_session"

// commandWait is how long an Operator's command waits for the Central Server
// before the dashboard reports that it is still outstanding. A retained command
// is not lost when this elapses: it is resent under the same Command ID.
const commandWait = 10 * time.Second

//--------------------------------------------------------------------------
// The page
//--------------------------------------------------------------------------

func (s *Server) assets() http.Handler {
	sub, err := fs.Sub(assetFS, "assets")
	if err != nil {
		panic("the dashboard assets are missing from the binary: " + err.Error())
	}
	// The mux hands over the whole path, so the prefix comes off before the
	// file system sees it.
	return http.StripPrefix("/assets/", http.FileServerFS(sub))
}

// page serves the single HTML document. Its headers say what the page is
// allowed to do, and the answer is: talk to itself, and nothing else.
func (s *Server) page(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Security-Policy",
		"default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Cache-Control", "no-store")

	file, err := assetFS.ReadFile("assets/index.html")
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"the dashboard is missing from this build")
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	_, _ = w.Write(file)
}

//--------------------------------------------------------------------------
// Sessions
//--------------------------------------------------------------------------

// sameOrigin refuses a state-changing request that a different site caused the
// browser to make. The cookie is already SameSite=Strict; this is the second
// lock, because a fail-closed check is worth having twice.
func sameOrigin(r *http.Request) bool {
	origin := r.Header.Get("Origin")
	if origin == "" {
		// A non-browser caller sends none. There is nothing to cross here.
		return true
	}
	trimmed := origin
	if index := strings.Index(trimmed, "://"); index >= 0 {
		trimmed = trimmed[index+3:]
	}
	return trimmed == r.Host
}

func (s *Server) sessionToken(r *http.Request) string {
	cookie, err := r.Cookie(SessionCookie)
	if err != nil {
		return ""
	}
	return cookie.Value
}

// guard is the fail-closed wrapper every /api route wears.
func (s *Server) guard(next func(http.ResponseWriter, *http.Request, store.Operator)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		if r.Method != http.MethodGet && r.Method != http.MethodHead && !sameOrigin(r) {
			s.writeProblem(w, http.StatusForbidden, protocol.CodeForbiddenOperation,
				"that request did not come from the dashboard")
			return
		}
		if s.identities == nil {
			s.writeProblem(w, http.StatusUnauthorized, protocol.CodeAuthenticationFail,
				"this build has no operator sign-in")
			return
		}
		operator, err := s.identities.Authenticate(r.Context(), s.backing, s.sessionToken(r))
		if err != nil {
			s.writeProblem(w, http.StatusUnauthorized, protocol.CodeAuthenticationFail,
				"sign in to read this")
			return
		}
		next(w, r, operator)
	}
}

func (s *Server) signIn(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if !sameOrigin(r) {
		s.writeProblem(w, http.StatusForbidden, protocol.CodeForbiddenOperation,
			"that request did not come from the dashboard")
		return
	}
	if s.identities == nil {
		s.writeProblem(w, http.StatusUnauthorized, protocol.CodeAuthenticationFail,
			"this build has no operator sign-in")
		return
	}

	var body struct {
		Name     string `json:"name"`
		Password string `json:"password"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body); err != nil {
		s.writeProblem(w, http.StatusBadRequest, protocol.CodeInvalidMessage,
			"that is not a sign-in request")
		return
	}

	token, expires, err := s.identities.SignIn(r.Context(), s.backing, body.Name, body.Password)
	if err != nil {
		// One message for every failure: which half was wrong is not something
		// an unauthenticated caller gets to learn.
		s.writeProblem(w, http.StatusUnauthorized, protocol.CodeAuthenticationFail,
			"that operator name and password do not match")
		return
	}

	http.SetCookie(w, &http.Cookie{
		Name: SessionCookie, Value: token, Path: "/",
		HttpOnly: true, Secure: s.secureCookies, SameSite: http.SameSiteStrictMode,
		// Both are measured against the application's own clock, so a test that
		// places time exactly gets a cookie that agrees with the session.
		Expires: expires, MaxAge: int(expires.Sub(s.now().UTC()).Seconds()),
	})
	s.writeJSON(w, http.StatusOK, map[string]any{
		"operator":   body.Name,
		"expires_at": expires.UTC().Format(time.RFC3339),
	})
}

func (s *Server) signOut(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")
	if s.identities != nil {
		_ = s.identities.SignOut(r.Context(), s.backing, s.sessionToken(r))
	}
	http.SetCookie(w, &http.Cookie{
		Name: SessionCookie, Value: "", Path: "/",
		HttpOnly: true, Secure: s.secureCookies, SameSite: http.SameSiteStrictMode,
		MaxAge: -1,
	})
	s.writeJSON(w, http.StatusOK, map[string]any{"signed_out": true})
}

func (s *Server) session(w http.ResponseWriter, r *http.Request, operator store.Operator) {
	s.writeJSON(w, http.StatusOK, map[string]any{"operator": operator.Name})
}

//--------------------------------------------------------------------------
// Projections
//--------------------------------------------------------------------------

func limitOf(r *http.Request, fallback, ceiling int) int {
	raw := r.URL.Query().Get("limit")
	if raw == "" {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value <= 0 {
		return fallback
	}
	if value > ceiling {
		return ceiling
	}
	return value
}

func (s *Server) audit(w http.ResponseWriter, r *http.Request, _ store.Operator) {
	records, err := s.view.Audit(r.Context(), r.PathValue("world"), limitOf(r, 200, 1000))
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"the audit history could not be read")
		return
	}
	listed := make([]map[string]any, 0, len(records))
	for _, record := range records {
		listed = append(listed, map[string]any{
			"recorded": record.Recorded.UTC().Format(time.RFC3339),
			"actor":    record.Actor,
			"action":   record.Action,
			"subject":  record.Subject,
			"detail":   record.Detail,
		})
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"records": listed})
}

// commands lists what Operators asked a World to do and what became of it.
func (s *Server) commands(w http.ResponseWriter, r *http.Request, _ store.Operator) {
	worldID := r.PathValue("world")
	var pending []store.Command
	err := s.backing.Do(r.Context(), func(tx store.Tx) error {
		found, err := tx.PendingCommands(worldID)
		if err != nil {
			return err
		}
		pending = found
		return nil
	})
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"the outstanding commands could not be read")
		return
	}
	listed := make([]map[string]any, 0, len(pending))
	for _, record := range pending {
		listed = append(listed, commandJSON(record))
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"pending": listed})
}

func commandJSON(record store.Command) map[string]any {
	body := map[string]any{
		"command_id": record.CommandID,
		"action":     record.Action,
		"status":     record.Status,
		"revision":   record.Revision,
		"issued_at":  record.IssuedAt.UTC().Format(time.RFC3339),
	}
	if record.Error != "" {
		body["error"] = record.Error
	}
	if record.SettledAt != nil {
		body["settled_at"] = record.SettledAt.UTC().Format(time.RFC3339)
	}
	return body
}

//--------------------------------------------------------------------------
// Network Status
//--------------------------------------------------------------------------

// setNetworkStatus is the one command an Operator can give a World. The
// dashboard confirms it first; this records the decision before sending it, so
// what was asked for survives even when the answer does not arrive.
func (s *Server) setNetworkStatus(w http.ResponseWriter, r *http.Request, operator store.Operator) {
	worldID := r.PathValue("world")
	networkID := r.PathValue("network")

	var body struct {
		Status    string `json:"status"`
		CommandID string `json:"command_id"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&body); err != nil {
		s.writeProblem(w, http.StatusBadRequest, protocol.CodeInvalidMessage,
			"that is not a Network Status change")
		return
	}
	if body.Status != "enabled" && body.Status != "disabled" {
		s.writeProblem(w, http.StatusBadRequest, protocol.CodeInvalidMessage,
			"a Network Status is enabled or disabled")
		return
	}

	commandID := body.CommandID
	if commandID == "" {
		raw := make([]byte, 16)
		if _, err := rand.Read(raw); err != nil {
			s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
				"a Command ID could not be drawn")
			return
		}
		commandID = "cmd-" + hex.EncodeToString(raw)
	}

	// A repeat of a Command ID the application already holds is the same
	// decision arriving twice, not a second one: it is not recorded again.
	repeated := false
	_ = s.backing.Do(r.Context(), func(tx store.Tx) error {
		if _, err := tx.Command(commandID); err == nil {
			repeated = true
		}
		return nil
	})
	if !repeated {
		action := "network.enable"
		if body.Status == "disabled" {
			action = "network.disable"
		}
		if err := s.backing.Do(r.Context(), func(tx store.Tx) error {
			return tx.AppendAudit(store.AuditRecord{
				WorldID: worldID, Actor: operator.Name, Action: action,
				Subject: networkID, Detail: commandID, Recorded: s.now().UTC(),
			})
		}); err != nil {
			s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
				"the decision could not be recorded")
			return
		}
	}

	record, err := s.gateways.Command(r.Context(), worldID, commandID, "set_network_status",
		protocol.Object{
			"action":              "set_network_status",
			"customer_network_id": networkID,
			"status":              body.Status,
		}, commandWait)

	answer := commandJSON(record)
	answer["customer_network_id"] = networkID
	answer["status_requested"] = body.Status
	answer["repeated"] = repeated

	switch {
	case err == nil:
		s.writeJSON(w, http.StatusOK, answer)
	case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
		return
	default:
		// The command is retained either way, so this reports what is known
		// rather than pretending nothing happened.
		code := protocol.CodeOf(err)
		if code == "" {
			code = protocol.CodeInternalError
		}
		answer["code"] = code
		answer["message"] = "the Central Server has not confirmed this yet; it is retained and will be resent"
		s.writeJSON(w, http.StatusAccepted, answer)
	}
}

//--------------------------------------------------------------------------
// Operator administration
//--------------------------------------------------------------------------

// operators lists who can sign in. It carries names and status, never a salt,
// a digest, or an iteration count that would help anyone attacking one.
func (s *Server) operators(w http.ResponseWriter, r *http.Request, _ store.Operator) {
	var found []store.Operator
	err := s.backing.Do(r.Context(), func(tx store.Tx) error {
		listed, err := tx.Operators()
		if err != nil {
			return err
		}
		found = listed
		return nil
	})
	if err != nil {
		s.writeProblem(w, http.StatusInternalServerError, protocol.CodeInternalError,
			"the operator list could not be read")
		return
	}
	listed := make([]map[string]any, 0, len(found))
	for _, operator := range found {
		listed = append(listed, map[string]any{
			"name":     operator.Name,
			"disabled": operator.Disabled(),
			"created":  operator.CreatedAt.UTC().Format(time.RFC3339),
		})
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"operators": listed})
}
