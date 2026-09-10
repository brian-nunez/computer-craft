package web_test

// Milestone 8's numbers, on the Go side.
//
// Retention, the Gateway's in-flight bound, the wire's own limits, and a
// malformed-input corpus that a live Gateway Session has to survive rather than
// merely refuse.

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/buildinfo"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

//--------------------------------------------------------------------------
// Retention
//--------------------------------------------------------------------------

// Pruning telemetry must never prune the record of a decision, and it must
// never prune the topology either: one is what an Operator is accountable for,
// and the other is the only picture of the World this application holds.
func TestRetentionRemovesTrafficAndKeepsEverythingElse(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	node.reportFixture(7, "enabled")
	node.reportOutcomes()

	ctx := context.Background()
	if err := held.app.Store.Do(ctx, func(tx store.Tx) error {
		return tx.AppendAudit(store.AuditRecord{
			WorldID: worldID, Actor: "alex", Action: "network.disable",
			Subject: "network-farm", Detail: "cmd-1", Recorded: held.clockValue,
		})
	}); err != nil {
		t.Fatalf("record a decision: %v", err)
	}

	before, err := held.app.View.Traffic(ctx, worldID, 1000)
	if err != nil {
		t.Fatalf("traffic: %v", err)
	}
	if len(before) == 0 {
		t.Fatal("there is nothing to prune")
	}

	// A day short of the window: nothing goes.
	held.advance(29 * 24 * time.Hour)
	if removed, err := held.app.Prune(ctx); err != nil || removed != 0 {
		t.Fatalf("premature prune removed %d (%v)", removed, err)
	}

	// Past it: the telemetry goes and nothing else does.
	held.advance(2 * 24 * time.Hour)
	removed, err := held.app.Prune(ctx)
	if err != nil {
		t.Fatalf("prune: %v", err)
	}
	if removed != int64(len(before)) {
		t.Fatalf("pruned %d of %d Traffic Events", removed, len(before))
	}

	after, err := held.app.View.Traffic(ctx, worldID, 1000)
	if err != nil {
		t.Fatalf("traffic after: %v", err)
	}
	if len(after) != 0 {
		t.Fatalf("%d Traffic Events survived retention", len(after))
	}

	records, err := held.app.View.Audit(ctx, worldID, 100)
	if err != nil {
		t.Fatalf("audit: %v", err)
	}
	found := false
	for _, record := range records {
		if record.Action == "network.disable" {
			found = true
		}
	}
	if !found {
		t.Fatal("pruning telemetry pruned the record of a decision")
	}

	view, err := held.app.View.World(ctx, worldID)
	if err != nil {
		t.Fatalf("world: %v", err)
	}
	if view.Revision != 7 {
		t.Fatalf("the topology did not survive retention: revision %d", view.Revision)
	}
}

//--------------------------------------------------------------------------
// The Gateway's bounds
//--------------------------------------------------------------------------

// The Gateway holds at most 256 operations in flight. The next one is refused
// with `busy` rather than queued: a queue with no bound is a slower way of
// failing, somewhere less obvious.
func TestTheGatewayRefusesWorkPastItsInFlightBound(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	// Every one of these is sent and left unanswered, so they really are
	// concurrent.
	for index := 0; index < protocol.GatewayInFlight; index++ {
		commandID := fmt.Sprintf("cmd-%04d", index)
		go func() {
			_, _ = held.app.Gateways.Command(context.Background(), worldID, commandID,
				"set_network_status", protocol.Object{
					"action": "set_network_status", "customer_network_id": "network-farm",
					"status": "disabled",
				}, 30*time.Second)
		}()
		frame := node.expect()
		if frame.Kind != "admin_command" {
			t.Fatalf("command %d: kind = %s", index, frame.Kind)
		}
	}

	_, err := held.app.Gateways.Command(context.Background(), worldID, "cmd-one-too-many",
		"set_network_status", protocol.Object{
			"action": "set_network_status", "customer_network_id": "network-farm",
			"status": "disabled",
		}, time.Second)
	if code := protocol.CodeOf(err); code != protocol.CodeBusy {
		t.Fatalf("the %dth command gave %q, want busy", protocol.GatewayInFlight+1, code)
	}
}

func TestTheWireLimitsAreTheOnesTheGatewayEnforces(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()

	// One event short of the batch limit is accepted.
	accepted := protocol.Array{}
	for index := 0; index < protocol.TrafficBatchEvents; index++ {
		accepted = append(accepted, protocol.Object{
			"event_id": fmt.Sprintf("evt-%04d", index), "observed_at_ms": int64(1000 + index),
			"world_id": worldID, "direction": "outbound", "kind": "service_request",
			"outcome": "delivered_remote", "bytes": int64(8),
		})
	}
	node.send(protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-full",
		Body: protocol.Object{
			"first_sequence": int64(1), "last_sequence": int64(protocol.TrafficBatchEvents),
			"events": accepted,
		},
	})
	if frame := node.expect(); frame.Kind != "ack" {
		t.Fatalf("a full batch was refused: %s %v", frame.Kind, frame.Body)
	}

	// One past it is refused. The sender's own encoder already refuses to build
	// it, which is worth knowing, so this goes out as raw text to prove the
	// receiver refuses it too rather than trusting the sender to have.
	tooMany := append(protocol.Array{}, accepted...)
	tooMany = append(tooMany, protocol.Object{
		"event_id": "evt-extra", "observed_at_ms": int64(9999), "world_id": worldID,
		"direction": "outbound", "kind": "service_request",
		"outcome": "delivered_remote", "bytes": int64(8),
	})
	oversized := protocol.GatewayFrame{
		Kind: "traffic_batch", RequestID: "req-over",
		Body: protocol.Object{
			"first_sequence": int64(200),
			"last_sequence":  int64(200 + protocol.TrafficBatchEvents),
			"events":         tooMany,
		},
	}
	if _, err := protocol.EncodeGatewayFrame(oversized); err == nil {
		t.Fatal("the sender should refuse to build an oversized batch")
	}

	raw, err := protocol.Encode(protocol.Object{
		"v": int64(buildinfo.WireVersion), "kind": "traffic_batch",
		"request_id": "req-over", "body": oversized.Body,
	})
	if err != nil {
		t.Fatalf("encode the raw frame: %v", err)
	}
	if err := node.write(raw); err != nil {
		t.Fatalf("write: %v", err)
	}
	if code := errorCode(t, node.expect()); code != protocol.CodeMessageTooLarge {
		t.Fatalf("an oversized batch gave %q", code)
	}
}

//--------------------------------------------------------------------------
// The malformed input corpus
//--------------------------------------------------------------------------

// corpus is damage aimed at the Gateway: truncated, type-confused, oversized,
// and structurally wrong. None of it may crash the process, and none of it may
// end the session -- a Central Server that sends one bad frame must not have to
// reconnect the whole World.
func corpus() []string {
	long := strings.Repeat("x", protocol.GatewayFrameBytes+16)
	return []string{
		"", " ", "{", "}", "[]", "null", "true", "0", "\x00", "\xff\xfe",
		`{}`,
		`{"v":1}`,
		`{"v":1,"kind":"heartbeat"}`,
		`{"v":1,"kind":"heartbeat","body":"not an object"}`,
		`{"v":1,"kind":"heartbeat","body":{}}` + "\n" + `{"v":1,"kind":"ack","body":{}}`,
		`{"v":0,"kind":"heartbeat","body":{}}`,
		`{"v":99,"kind":"heartbeat","body":{}}`,
		`{"v":1,"kind":"","body":{}}`,
		`{"v":1,"kind":"drop_tables","body":{}}`,
		`{"v":1,"kind":"admin_command","body":{}}`,
		`{"v":1,"kind":"external_request","body":{}}`,
		`{"v":1,"kind":"external_request","body":{"ancestry":"nope"}}`,
		`{"v":1,"kind":"topology_snapshot","body":{"revision":-1}}`,
		`{"v":1,"kind":"topology_snapshot","body":{"revision":1,"world":{}}}`,
		`{"v":1,"kind":"traffic_batch","body":{"first_sequence":0,"last_sequence":0,"events":[]}}`,
		`{"v":1,"kind":"traffic_batch","body":{"first_sequence":1,"last_sequence":1,"events":[{}]}}`,
		`{"v":1,"kind":"traffic_batch","body":{"first_sequence":1,"last_sequence":1,` +
			`"events":[{"event_id":"e","observed_at_ms":1,"world_id":"w","direction":"sideways",` +
			`"kind":"service_request","outcome":"delivered_local","bytes":0}]}}`,
		`{"v":1,"kind":"command_result","body":{"command_id":"nobody-asked","status":"applied","revision":1}}`,
		`{"v":1,"kind":"heartbeat","body":{"connectivity_state":"ready","revision":"four"}}`,
		`{"v":1,"kind":"heartbeat","body":{"connectivity_state":"` + long + `"}}`,
		`{"v":1,"kind":"heartbeat","request_id":"` + long + `","body":{}}`,
		long,
	}
}

func TestAMalformedFrameIsRefusedRatherThanDecoded(t *testing.T) {
	for index, text := range corpus() {
		frame, err := protocol.DecodeGatewayFrame(text)
		if err == nil {
			// A few of these are structurally valid; what came back must then be
			// a frame whose kind the wire actually defines.
			if !protocol.IsKind(frame.Kind) {
				t.Fatalf("case %d: accepted %q as a kind", index, frame.Kind)
			}
			continue
		}
		if code := protocol.CodeOf(err); !protocol.KnownCode(code) {
			t.Fatalf("case %d: refused with %q, which is not in the catalog", index, code)
		}
	}
}

// The stronger claim: a live session takes the whole corpus and is still there
// afterwards, still authenticated, still able to do its job.
func TestAGatewaySessionSurvivesTheWholeCorpus(t *testing.T) {
	held := newHarness(t)
	node, _ := held.connectDefault()
	node.reportFixture(7, "enabled")

	// Every one of these is answered, so something has to be reading, exactly as
	// a real Central Server would be. A test that only wrote would deadlock on
	// its own back pressure and learn nothing about the server.
	drained := make(chan struct{})
	go func() {
		defer close(drained)
		for {
			if _, err := node.read(); err != nil {
				return
			}
		}
	}()

	for index, text := range corpus() {
		if len(text) > protocol.GatewayFrameBytes {
			// The read limit closes the socket on an oversized frame by design;
			// that case is the decoder's, tested above.
			continue
		}
		if err := node.write(text); err != nil {
			t.Fatalf("case %d: the session ended on write: %v", index, err)
		}
	}

	// Whatever it answered with, it is still the same session: a topology
	// report still lands, and the World is still connected.
	text, err := protocol.EncodeGatewayFrame(topologyFrame(8))
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if err := node.write(text); err != nil {
		t.Fatalf("the session ended before the topology: %v", err)
	}

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		view, err := held.app.View.World(context.Background(), worldID)
		if err != nil {
			t.Fatalf("world: %v", err)
		}
		if view.Revision == 8 {
			if !view.Presence.Connected {
				t.Fatal("the corpus ended the Gateway Session")
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the session did not survive the corpus")
}

// And the dashboard's own surface takes the same treatment.
func TestTheDashboardAPIRefusesRubbishWithoutFallingOver(t *testing.T) {
	held := newHarness(t)
	view := held.signedIn()

	for index, body := range []string{
		"", "{", "null", "[]", `{"status":null}`, `{"status":123}`,
		`{"status":"disabled","command_id":""}`,
		`{"status":"disabled","command_id":"` + strings.Repeat("c", 4096) + `"}`,
		`{"status":"` + strings.Repeat("d", 100000) + `"}`,
	} {
		request, err := http.NewRequest(http.MethodPost,
			view.base+"/api/worlds/"+worldID+"/networks/network-farm/status",
			strings.NewReader(body))
		if err != nil {
			t.Fatalf("case %d: %v", index, err)
		}
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Origin", view.base)

		response, err := view.client.Do(request)
		if err != nil {
			t.Fatalf("case %d: the server went away: %v", index, err)
		}
		response.Body.Close()
		if response.StatusCode >= 500 {
			t.Fatalf("case %d: status %d for %q", index, response.StatusCode, body)
		}
	}

	// Still signed in, still working.
	if response, _ := view.get("/api/worlds"); response.StatusCode != http.StatusOK {
		t.Fatalf("status = %d after the corpus", response.StatusCode)
	}
}
