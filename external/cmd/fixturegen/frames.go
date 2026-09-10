package main

import (
	"fmt"
	"strings"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

const (
	fixtureSessionKeyHex = "5f4dcc3b5aa765d61d8327deb882cf995f4dcc3b5aa765d61d8327deb882cf99"
	fixtureRelationship  = "rel-farm-0007"
	fixtureSession       = "ses-000042"
)

func newFixtureSession() *protocol.Session {
	session, err := protocol.NewSession(protocol.SessionOptions{
		RelationshipID: fixtureRelationship,
		SessionID:      fixtureSession,
		SessionKey:     mustHex(fixtureSessionKeyHex),
	})
	if err != nil {
		fail(err)
	}
	return session
}

func sealOne(kind string, body protocol.Object, requestID string) string {
	text, err := newFixtureSession().Seal(kind, body, requestID)
	if err != nil {
		fail(fmt.Errorf("seal %s: %w", kind, err))
	}
	return text
}

// mutate decodes a frame, applies a change, and re-encodes it canonically.
func mutate(text string, change func(protocol.Object)) string {
	value, err := protocol.Decode(text, protocol.DefaultLimits())
	if err != nil {
		fail(err)
	}
	envelope, ok := value.(protocol.Object)
	if !ok {
		fail(fmt.Errorf("frame is not an object"))
	}
	change(envelope)
	mutated, err := protocol.Encode(envelope)
	if err != nil {
		fail(err)
	}
	return mutated
}

// writeFrames records authenticated operational frames: the ones that must open
// cleanly, the tampering that must fail, and the counter sequences that prove
// replay and out-of-order delivery fail closed.
func writeFrames() {
	heartbeat := protocol.Object{"connectivity_state": "ready", "revision": int64(4)}
	dnsQuery := protocol.Object{"name": "harvester.farm.acme.craft"}

	accepted := protocol.Array{
		protocol.Object{
			"name": "uncorrelated notification signs an empty request id",
			"text": sealOne("heartbeat", heartbeat, ""),
			"kind": "heartbeat", "counter": protocol.FirstCounter, "request_id": "",
		},
		protocol.Object{
			"name": "correlated request carries its request id",
			"text": sealOne("dns_query", dnsQuery, "req-104"),
			"kind": "dns_query", "counter": protocol.FirstCounter, "request_id": "req-104",
		},
	}
	record("frames/accepted.json", "frame", "valid", both(), protocol.Object{
		"schema":          int64(1),
		"note":            "Open each text with a fresh session and confirm the kind, counter, and request id.",
		"session_key_hex": fixtureSessionKeyHex,
		"relationship_id": fixtureRelationship,
		"session_id":      fixtureSession,
		"cases":           accepted,
	})

	valid := sealOne("heartbeat", heartbeat, "")
	correlated := sealOne("dns_query", dnsQuery, "req-104")

	rejected := protocol.Array{
		protocol.Object{
			"name":  "a changed body field no longer matches its body hash",
			"text":  strings.Replace(valid, `"revision":4`, `"revision":9`, 1),
			"error": protocol.CodeInvalidMessage,
		},
		protocol.Object{
			"name": "a changed body with a recomputed hash fails the mac",
			"text": func() string {
				tampered := protocol.Object{"connectivity_state": "ready", "revision": int64(9)}
				hash, err := protocol.BodyHash(tampered)
				if err != nil {
					fail(err)
				}
				return mutate(valid, func(envelope protocol.Object) {
					envelope["body"] = tampered
					envelope["body_hash"] = hash
				})
			}(),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a changed counter fails the mac",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["counter"] = int64(2) }),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a changed request id fails the mac",
			"text":  mutate(correlated, func(envelope protocol.Object) { envelope["request_id"] = "req-105" }),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a dropped request id fails the mac",
			"text":  mutate(correlated, func(envelope protocol.Object) { delete(envelope, "request_id") }),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a frame naming another relationship is refused",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["relationship_id"] = "rel-other-0001" }),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a frame naming another session is refused",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["session_id"] = "ses-000043" }),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name": "a corrupted mac is refused",
			"text": mutate(valid, func(envelope protocol.Object) {
				envelope["mac"] = strings.Repeat("0", 64)
			}),
			"error": protocol.CodeAuthenticationFail,
		},
		protocol.Object{
			"name":  "a future major version is refused",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["v"] = int64(2) }),
			"error": protocol.CodeUnsupportedVersion,
		},
		protocol.Object{
			"name":  "an unknown control field is refused",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["priority"] = "high" }),
			"error": protocol.CodeInvalidMessage,
		},
		protocol.Object{
			"name":  "a missing mac is refused",
			"text":  mutate(valid, func(envelope protocol.Object) { delete(envelope, "mac") }),
			"error": protocol.CodeInvalidMessage,
		},
		protocol.Object{
			"name":  "a counter of zero is refused before authentication",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["counter"] = int64(0) }),
			"error": protocol.CodeInvalidMessage,
		},
		protocol.Object{
			"name":  "a handshake kind is not carried by the operational transport",
			"text":  mutate(valid, func(envelope protocol.Object) { envelope["kind"] = "session_open" }),
			"error": protocol.CodeInvalidMessage,
		},
	}
	record("frames/rejected.json", "frame", "invalid", both(), protocol.Object{
		"schema":          int64(1),
		"note":            "Open each text with a fresh session. Every case must fail with this code.",
		"session_key_hex": fixtureSessionKeyHex,
		"relationship_id": fixtureRelationship,
		"session_id":      fixtureSession,
		"cases":           rejected,
	})

	// One session sealing three frames in order, so a replayer has real traffic
	// to work with.
	sender := newFixtureSession()
	first, err := sender.Seal("heartbeat", protocol.Object{"connectivity_state": "connecting", "revision": int64(1)}, "")
	if err != nil {
		fail(err)
	}
	second, err := sender.Seal("heartbeat", protocol.Object{"connectivity_state": "ready", "revision": int64(2)}, "")
	if err != nil {
		fail(err)
	}
	third, err := sender.Seal("heartbeat", protocol.Object{"connectivity_state": "ready", "revision": int64(3)}, "")
	if err != nil {
		fail(err)
	}

	sequences := protocol.Array{
		protocol.Object{
			"name": "counters must strictly increase",
			"steps": protocol.Array{
				protocol.Object{"text": first, "expect": "accepted", "counter": int64(1)},
				protocol.Object{"text": second, "expect": "accepted", "counter": int64(2)},
				protocol.Object{"text": second, "expect": protocol.CodeReplayRejected},
				protocol.Object{"text": first, "expect": protocol.CodeReplayRejected},
				protocol.Object{"text": third, "expect": "accepted", "counter": int64(3)},
			},
		},
		protocol.Object{
			"name": "a skipped counter is accepted but never revisited",
			"steps": protocol.Array{
				protocol.Object{"text": third, "expect": "accepted", "counter": int64(3)},
				protocol.Object{"text": first, "expect": protocol.CodeReplayRejected},
				protocol.Object{"text": second, "expect": protocol.CodeReplayRejected},
			},
		},
	}
	record("frames/sequences.json", "frame_sequence", "invalid", both(), protocol.Object{
		"schema":          int64(1),
		"note":            "Replay each sequence against one fresh session, in order.",
		"session_key_hex": fixtureSessionKeyHex,
		"relationship_id": fixtureRelationship,
		"session_id":      fixtureSession,
		"cases":           sequences,
	})
}
