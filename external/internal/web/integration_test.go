package web_test

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/brian-nunez/computer-craft/external/internal/app"
	"github.com/brian-nunez/computer-craft/external/internal/identity"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/store/memory"
)

// These run the real server over a real WebSocket. What is being proved is
// reference scenario 8 and the Gateway behaviour around it: authentication, one
// live session per World, reconnect snapshots, sequence gaps, command
// idempotency, two-minute token expiry, exact ancestry, and the allowlist.

const (
	worldID   = "world-overworld"
	centralID = "central-main"
)

var ancestry = store.Ancestry{
	WorldID:           worldID,
	ISPID:             "isp-acme",
	CustomerNetworkID: "network-farm",
	RouterID:          "router-farm",
	ComputerID:        "computer-farm-harvester",
	LocalAddress:      "192.168.1.20",
}

//--------------------------------------------------------------------------
// Harness
//--------------------------------------------------------------------------

type harness struct {
	t          *testing.T
	app        *app.App
	server     *httptest.Server
	bundle     *identity.Bundle
	clockValue time.Time
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	held := &harness{t: t, clockValue: time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)}

	application, err := app.New(app.Options{
		Store: memory.New(),
		Now:   func() time.Time { return held.clockValue },
	})
	if err != nil {
		t.Fatalf("build the application: %v", err)
	}
	held.app = application

	held.server = httptest.NewServer(application.Web.Handler())
	t.Cleanup(held.server.Close)

	bundle, err := application.Identities.ProvisionWorld(
		context.Background(), application.Store, worldID, centralID, "ws://example/gateway")
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	held.bundle = bundle
	return held
}

func (h *harness) advance(by time.Duration) { h.clockValue = h.clockValue.Add(by) }

func (h *harness) socketURL() string {
	return "ws" + strings.TrimPrefix(h.server.URL, "http") + "/gateway"
}

// central is a test stand-in for a Central Server: it speaks the Gateway wire
// and nothing else.
type central struct {
	t    *testing.T
	conn *websocket.Conn
	ctx  context.Context
}

// connect opens a Gateway Session the way a Central Server does: a credential in
// the Authorization header, then a hello.
func (h *harness) connect(credential string, hello protocol.GatewayHello) (*central, *protocol.GatewayWelcome, error) {
	h.t.Helper()
	ctx := context.Background()

	conn, _, err := websocket.Dial(ctx, h.socketURL(), &websocket.DialOptions{
		HTTPHeader: http.Header{"Authorization": []string{"Bearer " + credential}},
	})
	if err != nil {
		return nil, nil, err
	}
	node := &central{t: h.t, conn: conn, ctx: ctx}
	h.t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "") })

	text, err := protocol.EncodeGatewayHello(hello)
	if err != nil {
		return nil, nil, err
	}
	if err := node.write(text); err != nil {
		return nil, nil, err
	}

	reply, err := node.read()
	if err != nil {
		return nil, nil, err
	}
	welcome, err := protocol.DecodeGatewayWelcome(reply)
	if err != nil {
		return nil, nil, err
	}
	return node, welcome, nil
}

func (h *harness) connectDefault() (*central, *protocol.GatewayWelcome) {
	h.t.Helper()
	node, welcome, err := h.connect(h.bundle.GatewayCredential, protocol.GatewayHello{
		WorldID: worldID, CentralID: centralID,
	})
	if err != nil {
		h.t.Fatalf("connect: %v", err)
	}
	return node, welcome
}

func (c *central) write(text string) error {
	return c.conn.Write(c.ctx, websocket.MessageText, []byte(text))
}

func (c *central) read() (string, error) {
	ctx, cancel := context.WithTimeout(c.ctx, 5*time.Second)
	defer cancel()
	_, data, err := c.conn.Read(ctx)
	return string(data), err
}

func (c *central) send(frame protocol.GatewayFrame) {
	c.t.Helper()
	text, err := protocol.EncodeGatewayFrame(frame)
	if err != nil {
		c.t.Fatalf("encode %s: %v", frame.Kind, err)
	}
	if err := c.write(text); err != nil {
		c.t.Fatalf("send %s: %v", frame.Kind, err)
	}
}

func (c *central) expect() *protocol.GatewayFrame {
	c.t.Helper()
	text, err := c.read()
	if err != nil {
		c.t.Fatalf("read: %v", err)
	}
	frame, err := protocol.DecodeGatewayFrame(text)
	if err != nil {
		c.t.Fatalf("decode: %v", err)
	}
	return frame
}

// call performs one External Operation on behalf of a Computer and returns
// either the payload or the error body.
func (c *central) call(requestID string, body protocol.Object) *protocol.GatewayFrame {
	c.t.Helper()
	c.send(protocol.GatewayFrame{Kind: "external_request", RequestID: requestID, Body: body})
	return c.expect()
}

func ancestryObject(value store.Ancestry) protocol.Object {
	return protocol.Object{
		"world_id":            value.WorldID,
		"isp_id":              value.ISPID,
		"customer_network_id": value.CustomerNetworkID,
		"router_id":           value.RouterID,
		"computer_id":         value.ComputerID,
		"local_address":       value.LocalAddress,
	}
}

func errorCode(t *testing.T, frame *protocol.GatewayFrame) string {
	t.Helper()
	if frame.Kind != "error" {
		t.Fatalf("expected an error, received %s", frame.Kind)
	}
	code, _ := frame.Body["code"].(string)
	return code
}

func payloadOf(t *testing.T, frame *protocol.GatewayFrame) protocol.Object {
	t.Helper()
	if frame.Kind != "external_response" {
		code, _ := frame.Body["code"].(string)
		message, _ := frame.Body["message"].(string)
		t.Fatalf("expected a response, received %s (%s: %s)", frame.Kind, code, message)
	}
	payload, _ := frame.Body["payload"].(protocol.Object)
	return payload
}

//--------------------------------------------------------------------------
// Authentication
//--------------------------------------------------------------------------

func TestGatewayRefusesAConnectionWithNoCredential(t *testing.T) {
	held := newHarness(t)
	response, err := http.Get(held.server.URL + "/gateway")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", response.StatusCode)
	}
}

func TestGatewayRefusesTheWrongCredential(t *testing.T) {
	held := newHarness(t)
	_, _, err := held.connect("not-the-credential", protocol.GatewayHello{
		WorldID: worldID, CentralID: centralID,
	})
	if err == nil {
		t.Fatal("a wrong Gateway Credential was accepted")
	}
}

func TestGatewayRefusesAnotherCentralServer(t *testing.T) {
	held := newHarness(t)
	_, _, err := held.connect(held.bundle.GatewayCredential, protocol.GatewayHello{
		WorldID: worldID, CentralID: "central-impostor",
	})
	if err == nil {
		t.Fatal("a credential was accepted for another Central Server")
	}
}

func TestGatewayRefusesARevokedCredential(t *testing.T) {
	held := newHarness(t)
	ctx := context.Background()
	if err := held.app.Store.Do(ctx, func(tx store.Tx) error {
		return tx.RevokeCredential(held.bundle.GatewayCredentialRef, held.clockValue)
	}); err != nil {
		t.Fatalf("revoke: %v", err)
	}
	if _, _, err := held.connect(held.bundle.GatewayCredential, protocol.GatewayHello{
		WorldID: worldID, CentralID: centralID,
	}); err == nil {
		t.Fatal("a revoked Gateway Credential was accepted")
	}
}

func TestOneLiveSessionPerWorld(t *testing.T) {
	held := newHarness(t)
	first, _ := held.connectDefault()
	_ = first

	// A Central Server that reconnected is the one that is really there, so the
	// newer connection takes over rather than running alongside the old one.
	second, _ := held.connectDefault()
	_ = second

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if len(held.app.Gateways.Worlds()) == 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if worlds := held.app.Gateways.Worlds(); len(worlds) != 1 {
		t.Fatalf("%d live sessions, want 1", len(worlds))
	}
}

//--------------------------------------------------------------------------
// Scenario 8
//--------------------------------------------------------------------------

// registerAndToken walks the two steps a Computer takes before it can call
// anything: register on the strength of its ancestry, then exchange the Device
// Credential for a two-minute Access Token.
func (h *harness) registerAndToken(node *central) (string, string) {
	h.t.Helper()

	registered := node.call("req-register", protocol.Object{
		"ancestry":           ancestryObject(ancestry),
		"source_flow_id":     "flow-a1",
		"operation":          "device.register",
		"registration_nonce": strings.Repeat("ab", 32),
		"payload":            protocol.Object{},
	})
	payload := payloadOf(h.t, registered)
	credential, _ := payload["device_credential"].(string)
	if credential == "" {
		h.t.Fatal("device.register returned no Device Credential")
	}

	issued := node.call("req-token", protocol.Object{
		"ancestry":          ancestryObject(ancestry),
		"source_flow_id":    "flow-a2",
		"operation":         "token.issue",
		"device_credential": credential,
		"payload":           protocol.Object{},
	})
	tokenPayload := payloadOf(h.t, issued)
	token, _ := tokenPayload["access_token"].(string)
	if token == "" {
		h.t.Fatal("token.issue returned no Access Token")
	}
	return credential, token
}

func TestScenario8(t *testing.T) {
	held := newHarness(t)
	node, welcome := held.connectDefault()

	if welcome.GatewaySessionID == "" {
		t.Fatal("the welcome carried no Gateway Session")
	}

	_, token := held.registerAndToken(node)

	// test.identity reports the ancestry the application actually verified.
	answered := node.call("req-identity", protocol.Object{
		"ancestry":       ancestryObject(ancestry),
		"source_flow_id": "flow-a3",
		"operation":      "test.identity",
		"access_token":   token,
		"payload":        protocol.Object{},
	})
	payload := payloadOf(t, answered)

	for field, want := range map[string]string{
		"world_id":            ancestry.WorldID,
		"isp_id":              ancestry.ISPID,
		"customer_network_id": ancestry.CustomerNetworkID,
		"router_id":           ancestry.RouterID,
		"computer_id":         ancestry.ComputerID,
		"local_address":       ancestry.LocalAddress,
	} {
		if got, _ := payload[field].(string); got != want {
			t.Fatalf("%s = %q, want %q", field, got, want)
		}
	}
}

func TestScenario8RejectsAMismatchedAncestry(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	_, token := held.registerAndToken(node)

	// The same valid token, presented from another Customer Network.
	elsewhere := ancestry
	elsewhere.CustomerNetworkID = "network-home"
	elsewhere.RouterID = "router-home"

	refused := node.call("req-elsewhere", protocol.Object{
		"ancestry":       ancestryObject(elsewhere),
		"source_flow_id": "flow-b1",
		"operation":      "test.identity",
		"access_token":   token,
		"payload":        protocol.Object{},
	})
	if code := errorCode(t, refused); code != protocol.CodeAuthenticationFail {
		t.Fatalf("code = %s, want %s", code, protocol.CodeAuthenticationFail)
	}
}

func TestScenario8RejectsAnotherWorld(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	elsewhere := ancestry
	elsewhere.WorldID = "world-nether"
	refused := node.call("req-otherworld", protocol.Object{
		"ancestry":           ancestryObject(elsewhere),
		"source_flow_id":     "flow-b2",
		"operation":          "device.register",
		"registration_nonce": strings.Repeat("cd", 32),
		"payload":            protocol.Object{},
	})
	if code := errorCode(t, refused); code != protocol.CodeAuthenticationFail {
		t.Fatalf("code = %s, want %s", code, protocol.CodeAuthenticationFail)
	}
}

func TestScenario8RejectsADisallowedOperation(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	_, token := held.registerAndToken(node)

	refused := node.call("req-nope", protocol.Object{
		"ancestry":       ancestryObject(ancestry),
		"source_flow_id": "flow-b3",
		"operation":      "market.settle",
		"access_token":   token,
		"payload":        protocol.Object{},
	})
	if code := errorCode(t, refused); code != protocol.CodeForbiddenOperation {
		t.Fatalf("code = %s, want %s", code, protocol.CodeForbiddenOperation)
	}
}

func TestScenario8RejectsAnExpiredToken(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	_, token := held.registerAndToken(node)

	// Two minutes and a second later, the token is past its life.
	held.advance(protocol.AccessTokenSeconds*time.Second + time.Second)

	refused := node.call("req-expired", protocol.Object{
		"ancestry":       ancestryObject(ancestry),
		"source_flow_id": "flow-b4",
		"operation":      "test.identity",
		"access_token":   token,
		"payload":        protocol.Object{},
	})
	if code := errorCode(t, refused); code != protocol.CodeAccessTokenExpired {
		t.Fatalf("code = %s, want %s", code, protocol.CodeAccessTokenExpired)
	}
}

func TestScenario8RejectsARevokedToken(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	_, token := held.registerAndToken(node)

	var tokenID string
	ctx := context.Background()
	if err := held.app.Store.Do(ctx, func(tx store.Tx) error {
		// One token was issued, so this is it.
		device, err := tx.DeviceByComputer(worldID, ancestry.ComputerID)
		if err != nil {
			return err
		}
		_ = device
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}

	claims, err := held.app.Identities.AuthorizeToken(ctx, held.app.Store, token,
		"test.identity", ancestry)
	if err != nil {
		t.Fatalf("the token should be valid before revocation: %v", err)
	}
	tokenID = claims.TokenID

	if err := held.app.Identities.RevokeToken(ctx, held.app.Store, tokenID, "operator"); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	refused := node.call("req-revoked", protocol.Object{
		"ancestry":       ancestryObject(ancestry),
		"source_flow_id": "flow-b5",
		"operation":      "test.identity",
		"access_token":   token,
		"payload":        protocol.Object{},
	})
	if code := errorCode(t, refused); code != protocol.CodeCredentialRevoked {
		t.Fatalf("code = %s, want %s", code, protocol.CodeCredentialRevoked)
	}
}

func TestScenario8RejectsAnOrdinaryOperationWithoutAToken(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	// The schema itself refuses this combination: an ordinary operation without
	// an Access Token is not a well-formed external_request.
	text, err := protocol.EncodeGatewayFrame(protocol.GatewayFrame{
		Kind: "external_request", RequestID: "req-bare",
		Body: protocol.Object{
			"ancestry":       ancestryObject(ancestry),
			"source_flow_id": "flow-b6",
			"operation":      "test.identity",
			"payload":        protocol.Object{},
		},
	})
	if err == nil {
		t.Fatalf("a tokenless ordinary operation was encodable: %s", text)
	}
	if code := protocol.CodeOf(err); code != protocol.CodeInvalidMessage {
		t.Fatalf("code = %s, want %s", code, protocol.CodeInvalidMessage)
	}
	_ = node
}

//--------------------------------------------------------------------------
// Ingestion
//--------------------------------------------------------------------------

func topologyFrame(revision int64) protocol.GatewayFrame {
	return protocol.GatewayFrame{
		Kind: "topology_snapshot", RequestID: "req-topology",
		Body: protocol.Object{
			"revision":         revision,
			"world":            protocol.Object{"world_id": worldID},
			"isps":             protocol.Array{protocol.Object{"isp_id": "isp-acme"}},
			"routers":          protocol.Array{protocol.Object{"router_id": "router-farm"}},
			"computers":        protocol.Array{},
			"network_statuses": protocol.Array{protocol.Object{"customer_network_id": "network-farm", "status": "enabled"}},
		},
	}
}

func TestTopologyIsIngestedAndProjected(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	node.send(topologyFrame(31))
	if frame := node.expect(); frame.Kind != "ack" {
		t.Fatalf("kind = %s, want ack", frame.Kind)
	}

	view, err := held.app.View.World(context.Background(), worldID)
	if err != nil {
		t.Fatalf("project: %v", err)
	}
	if view.Revision != 31 {
		t.Fatalf("revision = %d, want 31", view.Revision)
	}
	if !view.Presence.Connected {
		t.Fatal("the World should be shown as connected")
	}
}

func TestReconnectResumesFromWhatIsHeld(t *testing.T) {
	held := newHarness(t)
	node, welcome := held.connectDefault()
	if welcome.AcceptedTopologyRevision != 0 || welcome.AcceptedTrafficSequence != 0 {
		t.Fatal("a first connection has nothing to resume from")
	}

	node.send(topologyFrame(31))
	node.expect()
	node.send(trafficFrame(1, 2))
	node.expect()

	// The Central Server comes back. What it is told is what the application
	// already holds, so it sends only what is missing.
	_, resumed := held.connectDefault()
	if resumed.AcceptedTopologyRevision != 31 {
		t.Fatalf("accepted topology = %d, want 31", resumed.AcceptedTopologyRevision)
	}
	if resumed.AcceptedTrafficSequence != 2 {
		t.Fatalf("accepted sequence = %d, want 2", resumed.AcceptedTrafficSequence)
	}
}

func trafficFrame(first, last int64) protocol.GatewayFrame {
	events := protocol.Array{}
	for sequence := first; sequence <= last; sequence++ {
		events = append(events, protocol.Object{
			"event_id":       "evt-" + string(rune('0'+sequence)),
			"observed_at_ms": int64(1000 * sequence),
			"world_id":       worldID,
			"direction":      "outbound",
			"kind":           "service_request",
			"outcome":        "delivered_remote",
			"bytes":          int64(240),
		})
	}
	return protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-traffic",
		Body: protocol.Object{
			"first_sequence": first, "last_sequence": last, "events": events,
		},
	}
}

func TestASequenceGapIsRecordedRatherThanHidden(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	node.send(trafficFrame(1, 2))
	node.expect()
	// 3 and 4 were lost while the Gateway was away.
	node.send(trafficFrame(5, 6))
	node.expect()

	records, err := held.app.View.Audit(context.Background(), worldID, 20)
	if err != nil {
		t.Fatalf("audit: %v", err)
	}
	found := false
	for _, record := range records {
		if record.Action == "traffic.gap" && record.Subject == "3..4" {
			found = true
		}
	}
	if !found {
		t.Fatal("the gap was not recorded")
	}

	// And what did arrive is all there: a gap is not a reason to drop the rest.
	events, err := held.app.View.Traffic(context.Background(), worldID, 100)
	if err != nil {
		t.Fatalf("traffic: %v", err)
	}
	if len(events) != 4 {
		t.Fatalf("%d events held, want 4", len(events))
	}
}

func TestIncidentsAreTheFailures(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	node.send(protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-traffic",
		Body: protocol.Object{
			"first_sequence": int64(1), "last_sequence": int64(2),
			"events": protocol.Array{
				protocol.Object{
					"event_id": "evt-ok", "observed_at_ms": int64(1000), "world_id": worldID,
					"direction": "outbound", "kind": "service_request",
					"outcome": "delivered_remote", "bytes": int64(10),
				},
				protocol.Object{
					"event_id": "evt-bad", "observed_at_ms": int64(2000), "world_id": worldID,
					"direction": "inbound", "kind": "service_request",
					"outcome": "inbound_denied", "bytes": int64(0),
				},
			},
		},
	})
	node.expect()

	incidents, err := held.app.View.Incidents(context.Background(), worldID, 10)
	if err != nil {
		t.Fatalf("incidents: %v", err)
	}
	if len(incidents) != 1 {
		t.Fatalf("%d incidents, want 1", len(incidents))
	}
	if outcome, _ := incidents[0].Event["outcome"].(string); outcome != "inbound_denied" {
		t.Fatalf("outcome = %s", outcome)
	}
}

//--------------------------------------------------------------------------
// Commands
//--------------------------------------------------------------------------

func TestACommandIsDeliveredAndSettled(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	done := make(chan store.Command, 1)
	go func() {
		record, err := held.app.Gateways.Command(context.Background(), worldID, "cmd-0001",
			"set_network_status", protocol.Object{
				"action": "set_network_status", "customer_network_id": "network-farm",
				"status": "disabled",
			}, 5*time.Second)
		if err != nil {
			t.Errorf("command: %v", err)
		}
		done <- record
	}()

	frame := node.expect()
	if frame.Kind != "admin_command" {
		t.Fatalf("kind = %s, want admin_command", frame.Kind)
	}
	if frame.CommandID != "cmd-0001" {
		t.Fatalf("command_id = %s", frame.CommandID)
	}

	node.send(protocol.GatewayFrame{
		Kind: "command_result", RequestID: frame.RequestID, CommandID: "cmd-0001",
		Body: protocol.Object{
			"command_id": "cmd-0001", "status": "applied", "revision": int64(33),
		},
	})

	record := <-done
	if record.Status != store.CommandApplied || record.Revision != 33 {
		t.Fatalf("record = %+v", record)
	}
}

func TestACommandIsIdempotentByIdentifier(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	body := protocol.Object{
		"action": "set_network_status", "customer_network_id": "network-farm",
		"status": "disabled",
	}

	done := make(chan struct{})
	go func() {
		defer close(done)
		_, _ = held.app.Gateways.Command(context.Background(), worldID, "cmd-0009",
			"set_network_status", body, 5*time.Second)
	}()

	frame := node.expect()
	node.send(protocol.GatewayFrame{
		Kind: "command_result", RequestID: frame.RequestID, CommandID: "cmd-0009",
		Body: protocol.Object{"command_id": "cmd-0009", "status": "applied", "revision": int64(33)},
	})
	<-done

	// The same identifier again returns what already happened rather than doing
	// it a second time.
	repeated, err := held.app.Gateways.Command(context.Background(), worldID, "cmd-0009",
		"set_network_status", body, time.Second)
	if err != nil {
		t.Fatalf("repeat: %v", err)
	}
	if repeated.Status != store.CommandApplied || repeated.Revision != 33 {
		t.Fatalf("repeat = %+v", repeated)
	}
}

func TestACommandForAnAbsentWorldIsRetained(t *testing.T) {
	held := newHarness(t)
	// No Central Server has connected.
	_, err := held.app.Gateways.Command(context.Background(), worldID, "cmd-0100",
		"set_network_status", protocol.Object{
			"action": "set_network_status", "customer_network_id": "network-farm",
			"status": "disabled",
		}, time.Second)
	if code := protocol.CodeOf(err); code != protocol.CodeGatewayUnavailable {
		t.Fatalf("code = %s, want %s", code, protocol.CodeGatewayUnavailable)
	}

	// It is still pending, so it goes out when the Gateway comes back.
	node, _ := held.connectDefault()
	frame := node.expect()
	if frame.Kind != "admin_command" || frame.CommandID != "cmd-0100" {
		t.Fatalf("the retained command was not resent: %+v", frame)
	}
}

//--------------------------------------------------------------------------
// The HTTP surface
//--------------------------------------------------------------------------

func TestWorldsAreListedWithTheirPresence(t *testing.T) {
	held := newHarness(t)

	// The listing is behind the dashboard's session, like everything else
	// under /api.
	view := held.signedIn()
	read := func() map[string]any {
		_, body := view.get("/api/worlds")
		return body
	}

	before := read()
	worlds, _ := before["worlds"].([]any)
	if len(worlds) != 1 {
		t.Fatalf("%d worlds listed", len(worlds))
	}
	entry, _ := worlds[0].(map[string]any)
	if connected, _ := entry["connected"].(bool); connected {
		t.Fatal("a World with no Gateway Session is not connected")
	}
	if stale, _ := entry["stale"].(bool); !stale {
		t.Fatal("and it is stale")
	}

	held.connectDefault()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		entry, _ = read()["worlds"].([]any)[0].(map[string]any)
		if connected, _ := entry["connected"].(bool); connected {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("the World never showed as connected")
}

func TestHealthIsServed(t *testing.T) {
	held := newHarness(t)
	response, err := http.Get(held.server.URL + "/healthz")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", response.StatusCode)
	}
}

//--------------------------------------------------------------------------
// Provisioning
//--------------------------------------------------------------------------

func TestProvisioningTwiceIsRefused(t *testing.T) {
	held := newHarness(t)
	_, err := held.app.Identities.ProvisionWorld(context.Background(), held.app.Store,
		worldID, centralID, "ws://example/gateway")
	if !errors.Is(err, store.ErrConflict) {
		t.Fatalf("error = %v, want ErrConflict", err)
	}
}

func TestASecretIsNeverStoredInTheClear(t *testing.T) {
	held := newHarness(t)
	ctx := context.Background()

	if err := held.app.Store.Do(ctx, func(tx store.Tx) error {
		world, err := tx.World(worldID)
		if err != nil {
			return err
		}
		if world.WorldKeySHA == held.bundle.WorldKey {
			t.Fatal("the World Key was stored in the clear")
		}
		if world.GatewayCredentialSHA == held.bundle.GatewayCredential {
			t.Fatal("the Gateway Credential was stored in the clear")
		}
		if world.WorldKeySHA != identity.Digest(held.bundle.WorldKey) {
			t.Fatal("the World Key digest does not verify")
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}
