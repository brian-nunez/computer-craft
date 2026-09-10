package protocol_test

import (
	"strings"
	"testing"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// These cover behaviour the shared fixture catalog cannot express as wire text:
// encoder refusals for values that never survive a decode, and session state
// that only shows up across several calls.

func TestEncodeRefusesValuesThatAreNotCanonical(t *testing.T) {
	cases := map[string]any{
		"untyped nil":                protocol.Object{"a": nil},
		"a float":                    protocol.Object{"a": 1.5},
		"an unsupported type":        protocol.Object{"a": make(chan int)},
		"an integer past the range":  protocol.Object{"a": protocol.ExactIntegerMaximum + 1},
		"an integer below the range": protocol.Object{"a": -protocol.ExactIntegerMaximum - 1},
		"invalid utf-8 in a value":   protocol.Object{"a": string([]byte{0xff, 0xfe})},
		"invalid utf-8 in a key":     protocol.Object{string([]byte{0xff, 0xfe}): "a"},
	}
	for name, value := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := protocol.Encode(value); err == nil {
				t.Fatal("value was encoded")
			}
		})
	}
}

func TestEncodeSortsKeysByByteOrderNotByLocale(t *testing.T) {
	// A locale-aware comparison would order these differently; CJ1 is defined on
	// unsigned bytes so that two hosts always sign the same preimage.
	encoded, err := protocol.Encode(protocol.Object{"a": 1, "B": 2, "_": 3, "á": 4, "A": 5})
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if want := `{"A":5,"B":2,"_":3,"a":1,"á":4}`; encoded != want {
		t.Fatalf("encoded %s, want %s", encoded, want)
	}
}

func newTestSession(t *testing.T) *protocol.Session {
	t.Helper()
	session, err := protocol.NewSession(protocol.SessionOptions{
		RelationshipID: "rel-farm-0007",
		SessionID:      "ses-000042",
		SessionKey:     []byte("a-session-key-derived-from-the-credential"),
	})
	if err != nil {
		t.Fatalf("new session: %v", err)
	}
	return session
}

func TestCountersAdvanceOnlyOnASuccessfulSeal(t *testing.T) {
	session := newTestSession(t)
	if session.NextCounter() != protocol.FirstCounter {
		t.Fatalf("first counter = %d, want %d", session.NextCounter(), protocol.FirstCounter)
	}

	if _, err := session.Seal("heartbeat",
		protocol.Object{"connectivity_state": "ready", "revision": 1}, ""); err != nil {
		t.Fatalf("seal: %v", err)
	}
	if session.NextCounter() != 2 {
		t.Fatalf("counter = %d, want 2", session.NextCounter())
	}

	// A body the schema refuses must not burn a counter value, or the peer would
	// see an unexplained gap.
	if _, err := session.Seal("heartbeat", protocol.Object{"connectivity_state": "online"}, ""); err == nil {
		t.Fatal("an invalid body was sealed")
	}
	if session.NextCounter() != 2 {
		t.Fatalf("a failed seal advanced the counter to %d", session.NextCounter())
	}
}

func TestSealRefusesAKindTheTransportDoesNotCarry(t *testing.T) {
	session := newTestSession(t)
	_, err := session.Seal("session_open", protocol.Object{
		"relationship_id": "rel-farm-0007",
		"client_nonce":    strings.Repeat("a", 64),
		"child_revision":  0,
	}, "")
	if got := protocol.CodeOf(err); got != protocol.CodeInvalidMessage {
		t.Fatalf("error code = %s, want %s", got, protocol.CodeInvalidMessage)
	}
}

func TestSealRefusesAFrameOverTheModemCeiling(t *testing.T) {
	session := newTestSession(t)
	// A payload just under the string limit, repeated until the frame is too big.
	payload := protocol.Object{}
	for index := 0; index < 4; index++ {
		payload[string(rune('a'+index))] = strings.Repeat("p", protocol.StringBytes)
	}
	_, err := session.Seal("service_response", protocol.Object{"payload": payload}, "")
	if got := protocol.CodeOf(err); got != protocol.CodeMessageTooLarge {
		t.Fatalf("error code = %s, want %s", got, protocol.CodeMessageTooLarge)
	}
}

func TestTwoSessionsSharingAKeyExchangeInBothDirections(t *testing.T) {
	child, parent := newTestSession(t), newTestSession(t)

	upward, err := child.Seal("heartbeat", protocol.Object{"connectivity_state": "ready", "revision": 4}, "")
	if err != nil {
		t.Fatalf("child seal: %v", err)
	}
	if _, err := parent.Open(upward); err != nil {
		t.Fatalf("parent open: %v", err)
	}

	downward, err := parent.Seal("config_snapshot", protocol.Object{
		"revision": 4, "role": "computer",
		"configuration": protocol.Object{
			"computer_id": "cmp-harvester", "hostname": "harvester", "address": "192.168.1.20",
			"customer_network_id": "net-farm", "router_address": "192.168.1.1",
			"dns_address": "192.168.1.1",
		},
	}, "")
	if err != nil {
		t.Fatalf("parent seal: %v", err)
	}
	message, err := child.Open(downward)
	if err != nil {
		t.Fatalf("child open: %v", err)
	}
	if message.Kind != "config_snapshot" {
		t.Fatalf("kind = %s, want config_snapshot", message.Kind)
	}
	// Each direction keeps its own counter space.
	if message.Counter != protocol.FirstCounter {
		t.Fatalf("counter = %d, want %d", message.Counter, protocol.FirstCounter)
	}
}

func TestGatewayRefusesABatchOverItsNarrowerCeiling(t *testing.T) {
	events := protocol.Array{}
	for index := 0; index < protocol.TrafficBatchEvents+1; index++ {
		events = append(events, protocol.Object{
			"event_id": "evt-" + strings.Repeat("x", 1), "observed_at_ms": 0,
			"world_id": "world-overworld", "direction": "local", "kind": "heartbeat",
			"outcome": "delivered", "bytes": 0,
		})
	}
	_, err := protocol.EncodeGatewayFrame(protocol.GatewayFrame{
		Kind: "traffic_batch",
		Body: protocol.Object{
			"first_sequence": 1, "last_sequence": int64(len(events)), "events": events,
		},
	})
	if got := protocol.CodeOf(err); got != protocol.CodeMessageTooLarge {
		t.Fatalf("error code = %s, want %s", got, protocol.CodeMessageTooLarge)
	}
}

func TestErrorBodyRefusesACodeOutsideTheCatalog(t *testing.T) {
	if _, err := protocol.ErrorBody("teapot", "", nil); err == nil {
		t.Fatal("an unknown code produced an error body")
	}
	body, err := protocol.ErrorBody("busy", "", nil)
	if err != nil {
		t.Fatalf("error body: %v", err)
	}
	if retryable, _ := body["retryable"].(bool); !retryable {
		t.Fatal("busy must be reported as retryable")
	}
	if _, present := body["details"]; present {
		t.Fatal("an optional field is omitted, never encoded as an empty substitute")
	}
}

func TestNewSessionRefusesIncompleteState(t *testing.T) {
	cases := map[string]protocol.SessionOptions{
		"no relationship": {SessionID: "ses-1", SessionKey: []byte("k")},
		"no session":      {RelationshipID: "rel-1", SessionKey: []byte("k")},
		"no key":          {RelationshipID: "rel-1", SessionID: "ses-1"},
		"bad identifier":  {RelationshipID: "Rel-1", SessionID: "ses-1", SessionKey: []byte("k")},
	}
	for name, options := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := protocol.NewSession(options); err == nil {
				t.Fatal("an incomplete session was created")
			}
		})
	}
}
