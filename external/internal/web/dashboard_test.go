package web_test

// The Operator dashboard, and reference scenarios 9 and 10.
//
// Everything here runs the real server: a real HTTP client with a real cookie
// jar, and a test stand-in for a Central Server on a real WebSocket. What is
// being proved is that the dashboard shows the whole World, that it shows
// nothing it must not, that it fails closed, and that disabling and re-enabling
// a Customer Network works the way an Operator needs it to.

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/cookiejar"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/web"
)

const (
	operatorName     = "alex"
	operatorPassword = "a passphrase is better than a word"
)

//--------------------------------------------------------------------------
// A signed-in browser
//--------------------------------------------------------------------------

// browser is the dashboard's client: one cookie jar, same-origin requests.
type browser struct {
	t      *testing.T
	base   string
	client *http.Client
}

func (h *harness) browser() *browser {
	h.t.Helper()
	jar, err := cookiejar.New(nil)
	if err != nil {
		h.t.Fatalf("cookie jar: %v", err)
	}
	return &browser{t: h.t, base: h.server.URL, client: &http.Client{Jar: jar, Timeout: 20 * time.Second}}
}

// addOperator is what `craftnetd operator` does, without the process.
func (h *harness) addOperator(name, password string) {
	h.t.Helper()
	err := h.app.Identities.PutOperator(context.Background(), h.app.Store, name, password)
	if err != nil {
		h.t.Fatalf("add the operator: %v", err)
	}
}

func (b *browser) do(method, path string, body any) (*http.Response, map[string]any) {
	b.t.Helper()
	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			b.t.Fatalf("encode: %v", err)
		}
		reader = bytes.NewReader(encoded)
	}
	request, err := http.NewRequest(method, b.base+path, reader)
	if err != nil {
		b.t.Fatalf("request: %v", err)
	}
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	// A browser on the dashboard's own origin sends exactly this.
	request.Header.Set("Origin", b.base)

	response, err := b.client.Do(request)
	if err != nil {
		b.t.Fatalf("%s %s: %v", method, path, err)
	}
	raw, _ := io.ReadAll(response.Body)
	response.Body.Close()

	decoded := map[string]any{}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &decoded)
	}
	decoded["__raw"] = string(raw)
	return response, decoded
}

func (b *browser) get(path string) (*http.Response, map[string]any) {
	return b.do(http.MethodGet, path, nil)
}

func (b *browser) signIn(name, password string) *http.Response {
	b.t.Helper()
	response, _ := b.do(http.MethodPost, "/api/session",
		map[string]string{"name": name, "password": password})
	return response
}

// signedIn is the ordinary starting point: one operator, signed in.
func (h *harness) signedIn() *browser {
	h.t.Helper()
	h.addOperator(operatorName, operatorPassword)
	view := h.browser()
	if response := view.signIn(operatorName, operatorPassword); response.StatusCode != http.StatusOK {
		h.t.Fatalf("sign in: status %d", response.StatusCode)
	}
	return view
}

func raw(body map[string]any) string {
	text, _ := body["__raw"].(string)
	return text
}

//--------------------------------------------------------------------------
// The page
//--------------------------------------------------------------------------

func TestTheDashboardIsServedFromTheBinary(t *testing.T) {
	held := newHarness(t)

	for _, path := range []string{"/", "/assets/dashboard.css", "/assets/dashboard.js"} {
		response, err := http.Get(held.server.URL + path)
		if err != nil {
			t.Fatalf("get %s: %v", path, err)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode != http.StatusOK {
			t.Fatalf("%s: status %d", path, response.StatusCode)
		}
		if len(body) == 0 {
			t.Fatalf("%s: served nothing", path)
		}
	}
}

// The page may talk to itself and to nothing else, so a compromised dependency
// has nowhere to send what it reads. There are no dependencies either.
func TestTheDashboardDeclaresWhatItMayTalkTo(t *testing.T) {
	held := newHarness(t)
	response, err := http.Get(held.server.URL + "/")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	body, _ := io.ReadAll(response.Body)
	response.Body.Close()

	policy := response.Header.Get("Content-Security-Policy")
	if !strings.Contains(policy, "default-src 'self'") {
		t.Fatalf("Content-Security-Policy = %q", policy)
	}
	if strings.Contains(string(body), "//cdn") || strings.Contains(string(body), "https://") {
		t.Fatal("the page reaches for something off this origin")
	}
}

//--------------------------------------------------------------------------
// Failing closed
//--------------------------------------------------------------------------

func TestEveryAPIRouteRefusesAnUnauthenticatedCaller(t *testing.T) {
	held := newHarness(t)
	held.addOperator(operatorName, operatorPassword)

	routes := []struct {
		method string
		path   string
	}{
		{http.MethodGet, "/api/session"},
		{http.MethodGet, "/api/operators"},
		{http.MethodGet, "/api/worlds"},
		{http.MethodGet, "/api/worlds/" + worldID},
		{http.MethodGet, "/api/worlds/" + worldID + "/traffic"},
		{http.MethodGet, "/api/worlds/" + worldID + "/incidents"},
		{http.MethodGet, "/api/worlds/" + worldID + "/audit"},
		{http.MethodGet, "/api/worlds/" + worldID + "/commands"},
		{http.MethodPost, "/api/worlds/" + worldID + "/networks/network-farm/status"},
		// A path nobody registered is refused too, rather than falling through
		// to the page.
		{http.MethodGet, "/api/anything-else"},
	}

	view := held.browser() // no session
	for _, route := range routes {
		response, _ := view.do(route.method, route.path, map[string]string{"status": "disabled"})
		if response.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s %s: status %d, want 401", route.method, route.path, response.StatusCode)
		}
	}
}

func TestSignInSaysTheSameThingWhicheverHalfIsWrong(t *testing.T) {
	held := newHarness(t)
	held.addOperator(operatorName, operatorPassword)
	view := held.browser()

	_, wrongPassword := view.do(http.MethodPost, "/api/session",
		map[string]string{"name": operatorName, "password": "not the password"})
	_, noSuchOperator := view.do(http.MethodPost, "/api/session",
		map[string]string{"name": "nobody", "password": "not the password"})

	if wrongPassword["message"] != noSuchOperator["message"] {
		t.Fatalf("the two failures are distinguishable: %q vs %q",
			wrongPassword["message"], noSuchOperator["message"])
	}
	if wrongPassword["code"] != protocol.CodeAuthenticationFail {
		t.Fatalf("code = %v", wrongPassword["code"])
	}
}

func TestSigningOutEndsTheSession(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	response, body := view.get("/api/session")
	if response.StatusCode != http.StatusOK || body["operator"] != operatorName {
		t.Fatalf("session = %d %v", response.StatusCode, body)
	}

	if response, _ := view.do(http.MethodDelete, "/api/session", nil); response.StatusCode != http.StatusOK {
		t.Fatalf("sign out: status %d", response.StatusCode)
	}
	if response, _ := view.get("/api/session"); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("after signing out: status %d, want 401", response.StatusCode)
	}
}

func TestADisabledOperatorStopsWorkingImmediately(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	err := held.app.Identities.DisableOperator(context.Background(), held.app.Store, operatorName)
	if err != nil {
		t.Fatalf("disable: %v", err)
	}

	// The session they already hold is refused at its next request.
	if response, _ := view.get("/api/worlds"); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}
	// And they cannot sign in again.
	if response := held.browser().signIn(operatorName, operatorPassword); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("sign in: status %d, want 401", response.StatusCode)
	}
}

func TestASessionExpires(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	held.advance(13 * time.Hour)
	if response, _ := view.get("/api/worlds"); response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}

	// The expired session is removed rather than merely refused.
	if err := held.app.Store.Do(context.Background(), func(tx store.Tx) error {
		removed, err := tx.PruneSessions(held.clockValue)
		if err != nil {
			return err
		}
		if removed != 0 {
			t.Fatalf("%d expired sessions were still held", removed)
		}
		return nil
	}); err != nil {
		t.Fatalf("prune: %v", err)
	}
}

func TestARequestFromAnotherSiteIsRefused(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	request, err := http.NewRequest(http.MethodPost,
		view.base+"/api/worlds/"+worldID+"/networks/network-farm/status",
		strings.NewReader(`{"status":"disabled"}`))
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", "http://somewhere-else.example")

	response, err := view.client.Do(request)
	if err != nil {
		t.Fatalf("do: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusForbidden {
		t.Fatalf("status = %d, want 403", response.StatusCode)
	}
}

// The Gateway is not a browser endpoint. A page that has somehow obtained a
// Gateway Credential must not be able to open a session with it.
func TestTheGatewayRefusesABrowserOrigin(t *testing.T) {
	held := newHarness(t)

	_, _, err := websocket.Dial(context.Background(), held.socketURL(), &websocket.DialOptions{
		HTTPHeader: http.Header{
			"Authorization": []string{"Bearer " + held.bundle.GatewayCredential},
			"Origin":        []string{"http://somewhere-else.example"},
		},
	})
	if err == nil {
		t.Fatal("a browser origin opened a Gateway Session")
	}

	// And the same credential still works without one.
	if _, _, err := held.connect(held.bundle.GatewayCredential, protocol.GatewayHello{
		WorldID: worldID, CentralID: centralID,
	}); err != nil {
		t.Fatalf("the credential itself is fine: %v", err)
	}
}

func TestTheSessionCookieCannotBeReadByAScript(t *testing.T) {
	held := newHarness(t)
	held.addOperator(operatorName, operatorPassword)
	view := held.browser()
	response := view.signIn(operatorName, operatorPassword)

	for _, cookie := range response.Cookies() {
		if cookie.Name != web.SessionCookie {
			continue
		}
		if !cookie.HttpOnly {
			t.Fatal("the session cookie is readable by a script")
		}
		if cookie.SameSite != http.SameSiteStrictMode {
			t.Fatal("the session cookie is sent on cross-site requests")
		}
		return
	}
	t.Fatal("no session cookie was set")
}

//--------------------------------------------------------------------------
// The reference fixture
//--------------------------------------------------------------------------

// reportFixture makes the stand-in Central Server report the reference
// topology: one World, one ISP, Home and Farm, and four Computers, with
// `alex-pc` and `harvester` deliberately holding the same address in different
// Customer Networks.
func (c *central) reportFixture(revision int64, farmStatus string) {
	c.t.Helper()
	c.send(protocol.GatewayFrame{
		Kind: "topology_snapshot", RequestID: "req-topology",
		Body: protocol.Object{
			"revision": revision,
			"world":    protocol.Object{"world_id": worldID, "central_id": centralID},
			"isps": protocol.Array{protocol.Object{
				"isp_id": "isp-acme", "display_name": "Acme",
				"provider_allocations": protocol.Array{protocol.Object{
					"first": "100.64.0.10", "last": "100.64.0.40",
				}},
			}},
			"routers": protocol.Array{
				protocol.Object{
					"router_id": "router-home", "isp_id": "isp-acme",
					"customer_network_id": "network-home", "customer_network_name": "home",
					"router_provider_address": "100.64.0.10",
				},
				protocol.Object{
					"router_id": "router-farm", "isp_id": "isp-acme",
					"customer_network_id": "network-farm", "customer_network_name": "farm",
					"router_provider_address": "100.64.0.11",
				},
			},
			"computers": protocol.Array{
				protocol.Object{
					"computer_id": "computer-home-alex", "hostname": "alex-pc",
					"address": "192.168.1.20", "customer_network_id": "network-home",
					"router_id": "router-home", "isp_id": "isp-acme",
				},
				protocol.Object{
					"computer_id": "computer-home-wall", "hostname": "wall-display",
					"address": "192.168.1.21", "customer_network_id": "network-home",
					"router_id": "router-home", "isp_id": "isp-acme",
				},
				protocol.Object{
					"computer_id": "computer-farm-harvester", "hostname": "harvester",
					"address": "192.168.1.20", "customer_network_id": "network-farm",
					"router_id": "router-farm", "isp_id": "isp-acme",
				},
				protocol.Object{
					"computer_id": "computer-farm-silo", "hostname": "silo",
					"address": "192.168.1.21", "customer_network_id": "network-farm",
					"router_id": "router-farm", "isp_id": "isp-acme",
				},
			},
			"network_statuses": protocol.Array{
				protocol.Object{"customer_network_id": "network-home", "status": "enabled"},
				protocol.Object{"customer_network_id": "network-farm", "status": farmStatus},
			},
		},
	})
	c.expect()
}

// reportOutcomes sends one Traffic Event per outcome an Operator has to be able
// to see, which is what scenario 9 means by "all required outcomes".
func (c *central) reportOutcomes() []string {
	c.t.Helper()
	outcomes := []string{
		"delivered_local", "delivered_remote", "delivered_external",
		"inbound_denied", "nat_flow_missing", "route_not_found",
		"pool_exhausted", "network_disabled", "name_not_found",
	}
	events := protocol.Array{}
	for index, outcome := range outcomes {
		direction := "outbound"
		if index%3 == 0 {
			direction = "local"
		} else if index%3 == 1 {
			direction = "inbound"
		}
		events = append(events, protocol.Object{
			"event_id":            "evt-" + outcome,
			"observed_at_ms":      int64(1000 * (index + 1)),
			"world_id":            worldID,
			"isp_id":              "isp-acme",
			"customer_network_id": "network-farm",
			"router_id":           "router-farm",
			"computer_id":         "computer-farm-harvester",
			"direction":           direction,
			"kind":                "service_request",
			"operation":           "harvester.status",
			"outcome":             outcome,
			"bytes":               int64(64 + index),
		})
	}
	c.send(protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-traffic",
		Body: protocol.Object{
			"first_sequence": int64(1), "last_sequence": int64(len(outcomes)),
			"events": events,
		},
	})
	c.expect()
	return outcomes
}

//--------------------------------------------------------------------------
// Scenario 9 -- observe operations
//--------------------------------------------------------------------------

func TestScenario9(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	node.reportFixture(7, "enabled")
	outcomes := node.reportOutcomes()

	view := held.signedIn()

	// The World is listed, and it is there.
	_, listed := view.get("/api/worlds")
	worlds, _ := listed["worlds"].([]any)
	if len(worlds) != 1 {
		t.Fatalf("%d worlds listed", len(worlds))
	}

	// Every device in the fixture appears in the topology the dashboard reads.
	_, world := view.get("/api/worlds/" + worldID)
	document := raw(world)
	for _, name := range []string{
		"isp-acme", "Acme", "100.64.0.10", "100.64.0.11",
		"router-home", "router-farm", "network-home", "network-farm",
		"alex-pc", "wall-display", "harvester", "silo",
	} {
		if !strings.Contains(document, name) {
			t.Fatalf("the topology does not show %s", name)
		}
	}
	if revision, _ := world["revision"].(float64); revision != 7 {
		t.Fatalf("revision = %v, want 7", world["revision"])
	}

	// Overlapping addressing survives the projection: both Computers hold
	// 192.168.1.20, each inside its own Customer Network.
	topology, _ := world["topology"].(map[string]any)
	computers, _ := topology["computers"].([]any)
	holders := map[string]string{}
	for _, entry := range computers {
		computer, _ := entry.(map[string]any)
		if computer["address"] == "192.168.1.20" {
			holders[computer["customer_network_id"].(string)] = computer["hostname"].(string)
		}
	}
	if holders["network-home"] != "alex-pc" || holders["network-farm"] != "harvester" {
		t.Fatalf("the two holders of 192.168.1.20 are %v", holders)
	}

	// Every outcome appears in Traffic.
	_, traffic := view.get("/api/worlds/" + worldID + "/traffic")
	events := raw(traffic)
	for _, outcome := range outcomes {
		if !strings.Contains(events, outcome) {
			t.Fatalf("Traffic does not show %s", outcome)
		}
	}

	// Incidents are the failures and only the failures.
	_, incidents := view.get("/api/worlds/" + worldID + "/incidents")
	listedIncidents, _ := incidents["incidents"].([]any)
	if len(listedIncidents) != 6 {
		t.Fatalf("%d incidents, want the 6 failing outcomes", len(listedIncidents))
	}
	for _, entry := range listedIncidents {
		record, _ := entry.(map[string]any)
		event, _ := record["event"].(map[string]any)
		outcome, _ := event["outcome"].(string)
		if strings.HasPrefix(outcome, "delivered_") {
			t.Fatalf("%s is not an incident", outcome)
		}
	}

	// Nothing the dashboard reads carries a payload or a secret.
	for _, path := range []string{
		"/api/worlds", "/api/worlds/" + worldID,
		"/api/worlds/" + worldID + "/traffic",
		"/api/worlds/" + worldID + "/incidents",
		"/api/worlds/" + worldID + "/audit",
	} {
		_, body := view.get(path)
		assertNoSecret(t, path, raw(body), held)
	}

	// A World with a live Gateway Session is not stale.
	if stale, _ := world["stale"].(bool); stale {
		t.Fatal("a connected World was shown as stale")
	}

	// And when the Central Server goes away, what the dashboard shows is
	// visibly the last thing it heard rather than what is happening now.
	node.conn.Close(websocket.StatusNormalClosure, "")
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		_, after := view.get("/api/worlds/" + worldID)
		if stale, _ := after["stale"].(bool); stale {
			if connected, _ := after["connected"].(bool); connected {
				t.Fatal("a disconnected World was shown as connected")
			}
			// The topology it last reported is still there to read.
			if !strings.Contains(raw(after), "harvester") {
				t.Fatal("the last reported topology was thrown away")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the World never became stale")
}

// assertNoSecret is the check scenario 9 turns on: a payload, a token, a MAC,
// and a password are things the dashboard must never show, and the reason it
// never shows them is that none of them are ever put anywhere it reads.
func assertNoSecret(t *testing.T, path, document string, held *harness) {
	t.Helper()
	for _, secret := range []string{
		held.bundle.WorldKey,
		held.bundle.GatewayCredential,
	} {
		if secret != "" && strings.Contains(document, secret) {
			t.Fatalf("%s carries a secret value", path)
		}
	}
	for _, field := range []string{
		`"payload"`, `"access_token"`, `"device_credential"`, `"world_key"`,
		`"gateway_credential"`, `"lan_password"`, `"password"`, `"mac"`, `"credential"`,
	} {
		if strings.Contains(document, field) {
			t.Fatalf("%s carries %s", path, field)
		}
	}
}

//--------------------------------------------------------------------------
// Scenario 10 -- disable and recover Farm
//--------------------------------------------------------------------------

// settle answers the next admin_command the way a Central Server does.
func (c *central) settle(status string, revision int64) *protocol.GatewayFrame {
	c.t.Helper()
	frame := c.expect()
	if frame.Kind != "admin_command" {
		c.t.Fatalf("kind = %s, want admin_command", frame.Kind)
	}
	c.send(protocol.GatewayFrame{
		Kind: "command_result", RequestID: frame.RequestID, CommandID: frame.CommandID,
		Body: protocol.Object{
			"command_id": frame.CommandID, "status": status, "revision": revision,
		},
	})
	return frame
}

func TestScenario10(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	node.reportFixture(7, "enabled")

	view := held.signedIn()
	path := "/api/worlds/" + worldID + "/networks/network-farm/status"

	// Disabling is a decision an Operator makes deliberately, so it carries a
	// Command ID the dashboard can safely repeat.
	settled := make(chan *protocol.GatewayFrame, 1)
	go func() { settled <- node.settle("applied", 8) }()

	response, body := view.do(http.MethodPost, path,
		map[string]string{"status": "disabled", "command_id": "cmd-disable-farm"})
	if response.StatusCode != http.StatusOK {
		t.Fatalf("disable: status %d (%s)", response.StatusCode, raw(body))
	}
	if body["status"] != store.CommandApplied {
		t.Fatalf("status = %v, want applied", body["status"])
	}
	frame := <-settled
	if frame.CommandID != "cmd-disable-farm" {
		t.Fatalf("command_id = %s", frame.CommandID)
	}
	action, _ := frame.Body["action"].(string)
	network, _ := frame.Body["customer_network_id"].(string)
	wanted, _ := frame.Body["status"].(string)
	if action != "set_network_status" || network != "network-farm" || wanted != "disabled" {
		t.Fatalf("the command said %v", frame.Body)
	}

	// The decision is in the audit history, attributed to the Operator who made
	// it, and so is the Central Server's answer.
	_, audit := view.get("/api/worlds/" + worldID + "/audit")
	document := raw(audit)
	if !strings.Contains(document, "network.disable") || !strings.Contains(document, operatorName) {
		t.Fatalf("the decision was not recorded: %s", document)
	}
	if !strings.Contains(document, "command.applied") {
		t.Fatalf("the result was not recorded: %s", document)
	}

	// Repeating the same Command ID is harmless: it returns what already
	// happened rather than doing it a second time, and does not record a second
	// decision.
	before := countAudit(t, view, "network.disable")
	repeat, repeatBody := view.do(http.MethodPost, path,
		map[string]string{"status": "disabled", "command_id": "cmd-disable-farm"})
	if repeat.StatusCode != http.StatusOK {
		t.Fatalf("repeat: status %d (%s)", repeat.StatusCode, raw(repeatBody))
	}
	if repeated, _ := repeatBody["repeated"].(bool); !repeated {
		t.Fatal("the repeat was not recognised as one")
	}
	if repeatBody["status"] != store.CommandApplied || repeatBody["revision"].(float64) != 8 {
		t.Fatalf("the repeat did not return what already happened: %v", repeatBody)
	}
	if after := countAudit(t, view, "network.disable"); after != before {
		t.Fatalf("the repeat recorded a second decision (%d then %d)", before, after)
	}

	// The Central Server reports Farm disabled, and its durable configuration
	// is untouched: the same router, the same Provider Address, the same
	// Computers, the same addresses.
	node.reportFixture(8, "disabled")
	_, world := view.get("/api/worlds/" + worldID)
	if statusIn(t, world, "network-farm") != "disabled" {
		t.Fatal("Farm is not shown as disabled")
	}
	for _, kept := range []string{"router-farm", "100.64.0.11", "harvester", "192.168.1.20", "silo"} {
		if !strings.Contains(raw(world), kept) {
			t.Fatalf("disabling Farm lost %s", kept)
		}
	}

	// New Farm traffic is refused while it is disabled, and an Operator can see
	// exactly that in Incidents.
	node.send(protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-refused",
		Body: protocol.Object{
			"first_sequence": int64(1), "last_sequence": int64(1),
			"events": protocol.Array{protocol.Object{
				"event_id": "evt-refused", "observed_at_ms": int64(9000), "world_id": worldID,
				"customer_network_id": "network-farm", "direction": "outbound",
				"kind": "service_request", "outcome": "network_disabled", "bytes": int64(0),
			}},
		},
	})
	node.expect()
	_, incidents := view.get("/api/worlds/" + worldID + "/incidents")
	if !strings.Contains(raw(incidents), "network_disabled") {
		t.Fatal("the refusal is not visible in Incidents")
	}

	// Re-enabling needs no enrollment and no new addresses: it is one command,
	// and the fixture comes back exactly as it was.
	settledAgain := make(chan *protocol.GatewayFrame, 1)
	go func() { settledAgain <- node.settle("applied", 9) }()
	response, body = view.do(http.MethodPost, path,
		map[string]string{"status": "enabled", "command_id": "cmd-enable-farm"})
	if response.StatusCode != http.StatusOK || body["status"] != store.CommandApplied {
		t.Fatalf("enable: %d %v", response.StatusCode, body)
	}
	<-settledAgain

	node.reportFixture(9, "enabled")
	_, recovered := view.get("/api/worlds/" + worldID)
	if statusIn(t, recovered, "network-farm") != "enabled" {
		t.Fatal("Farm did not come back")
	}
	topology, _ := recovered["topology"].(map[string]any)
	computers, _ := topology["computers"].([]any)
	for _, entry := range computers {
		computer, _ := entry.(map[string]any)
		if computer["hostname"] == "harvester" && computer["address"] != "192.168.1.20" {
			t.Fatalf("harvester's address changed to %v", computer["address"])
		}
	}
}

func statusIn(t *testing.T, world map[string]any, networkID string) string {
	t.Helper()
	topology, _ := world["topology"].(map[string]any)
	statuses, _ := topology["network_statuses"].([]any)
	for _, entry := range statuses {
		status, _ := entry.(map[string]any)
		if status["customer_network_id"] == networkID {
			value, _ := status["status"].(string)
			return value
		}
	}
	t.Fatalf("%s has no Network Status", networkID)
	return ""
}

func countAudit(t *testing.T, view *browser, action string) int {
	t.Helper()
	_, body := view.get("/api/worlds/" + worldID + "/audit")
	records, _ := body["records"].([]any)
	count := 0
	for _, entry := range records {
		record, _ := entry.(map[string]any)
		if record["action"] == action {
			count++
		}
	}
	return count
}

// A command given while the Central Server is away is retained rather than
// lost, and the dashboard says so instead of claiming it worked.
func TestACommandWithNoGatewayIsRetainedAndSaidSo(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	response, body := view.do(http.MethodPost,
		"/api/worlds/"+worldID+"/networks/network-farm/status",
		map[string]string{"status": "disabled", "command_id": "cmd-while-away"})
	if response.StatusCode != http.StatusAccepted {
		t.Fatalf("status = %d, want 202", response.StatusCode)
	}
	if body["code"] != protocol.CodeGatewayUnavailable {
		t.Fatalf("code = %v", body["code"])
	}

	// It goes out when the Gateway comes back, under the same Command ID.
	node, _ := held.connectDefault()
	frame := node.expect()
	if frame.Kind != "admin_command" || frame.CommandID != "cmd-while-away" {
		t.Fatalf("the retained command was not resent: %+v", frame)
	}
}

func TestANetworkStatusMustBeOneOfTwoThings(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()
	response, body := view.do(http.MethodPost,
		"/api/worlds/"+worldID+"/networks/network-farm/status",
		map[string]string{"status": "paused"})
	if response.StatusCode != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", response.StatusCode)
	}
	if body["code"] != protocol.CodeInvalidMessage {
		t.Fatalf("code = %v", body["code"])
	}
}
