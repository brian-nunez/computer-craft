package main

import (
	"encoding/hex"
	"fmt"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

func sealHandshakeOrFail(secret []byte, kind, requestID string, body protocol.Object) string {
	text, err := protocol.SealHandshake(secret, kind, requestID, body, 0)
	if err != nil {
		fail(fmt.Errorf("seal %s: %w", kind, err))
	}
	return text
}

// writeHandshakes records the complete enrollment and session-establishment
// exchanges. Replaying them must reproduce the same durable relationship
// credential and the same session key on both sides, in both languages.
func writeHandshakes() {
	rootSecret := mustHex(fixtureRootSecretHex)
	enrollmentSecret, err := protocol.EnrollmentSecret(rootSecret, "computer", 0)
	if err != nil {
		fail(err)
	}

	const (
		requestID      = "req-enroll-1"
		parentID       = "rtr-farm"
		relationshipID = "rel-farm-0007"
		childID        = "cmp-harvester"
	)

	openBody := protocol.Object{
		"role": "computer", "requested_name": "harvester", "client_nonce": fixtureClientNonce,
	}
	challengeBody := protocol.Object{
		"parent_id": parentID, "relationship_id": relationshipID,
		"client_nonce": fixtureClientNonce, "parent_nonce": fixtureParentNonce,
		"parent_revision": int64(4),
	}
	confirmBody := protocol.Object{
		"relationship_id": relationshipID, "client_nonce": fixtureClientNonce,
		"parent_nonce": fixtureParentNonce, "child_revision": int64(0),
	}
	computerConfiguration := protocol.Object{
		"computer_id": childID, "hostname": "harvester", "address": "192.168.1.20",
		"customer_network_id": "net-farm", "router_address": "192.168.1.1",
		"dns_address": "192.168.1.1",
	}
	acceptBody := protocol.Object{
		"child_id": childID, "relationship_id": relationshipID,
		"operational_channel": int64(3100), "configuration": computerConfiguration,
		"parent_revision": int64(4),
	}

	transcript := protocol.EnrollmentTranscript{
		RequestedName:  "harvester",
		Role:           "computer",
		ParentID:       parentID,
		RelationshipID: relationshipID,
		ClientNonce:    fixtureClientNonce,
		ParentNonce:    fixtureParentNonce,
		ParentRevision: 4,
	}
	credential, err := protocol.RelationshipCredential(enrollmentSecret, transcript.Object())
	if err != nil {
		fail(err)
	}

	record("handshake/enrollment.json", "enrollment", "valid", both(), protocol.Object{
		"schema": int64(1),
		"note": "Verify every proof under the enrollment secret, then derive the relationship " +
			"credential from the transcript. A LAN Password enrolls a Computer exactly this way.",
		"enrollment_secret_hex": hex.EncodeToString(enrollmentSecret),
		"request_id":            requestID,
		"messages": protocol.Array{
			protocol.Object{"kind": "enroll_open",
				"text": sealHandshakeOrFail(enrollmentSecret, "enroll_open", requestID, openBody)},
			protocol.Object{"kind": "enroll_challenge",
				"text": sealHandshakeOrFail(enrollmentSecret, "enroll_challenge", requestID, challengeBody)},
			protocol.Object{"kind": "enroll_confirm",
				"text": sealHandshakeOrFail(enrollmentSecret, "enroll_confirm", requestID, confirmBody)},
			protocol.Object{"kind": "enroll_accept",
				"text": sealHandshakeOrFail(enrollmentSecret, "enroll_accept", requestID, acceptBody)},
		},
		"transcript":              transcript.Object(),
		"relationship_credential": hex.EncodeToString(credential),
		"rejected": protocol.Array{
			protocol.Object{
				"name":  "a proof made with the wrong secret is refused",
				"kind":  "enroll_open",
				"text":  sealHandshakeOrFail(mustHex(fixtureSessionKeyHex), "enroll_open", requestID, openBody),
				"error": protocol.CodeAuthenticationFail,
			},
			protocol.Object{
				"name": "a changed body invalidates the proof",
				"kind": "enroll_challenge",
				"text": mutate(
					sealHandshakeOrFail(enrollmentSecret, "enroll_challenge", requestID, challengeBody),
					func(envelope protocol.Object) {
						body, _ := envelope["body"].(protocol.Object)
						body["parent_revision"] = int64(5)
					}),
				"error": protocol.CodeAuthenticationFail,
			},
		},
	})

	const sessionID = "ses-000042"
	sessionRequestID := "req-session-1"

	sessionOpenBody := protocol.Object{
		"relationship_id": relationshipID, "client_nonce": fixtureSessionNonce,
		"child_revision": int64(3),
	}
	sessionChallengeBody := protocol.Object{
		"relationship_id": relationshipID, "session_id": sessionID,
		"client_nonce": fixtureSessionNonce, "parent_nonce": fixtureParentSession,
		"parent_revision": int64(4),
	}
	sessionConfirmBody := protocol.Object{
		"relationship_id": relationshipID, "session_id": sessionID,
		"client_nonce": fixtureSessionNonce, "parent_nonce": fixtureParentSession,
	}

	sessionTranscript := protocol.SessionTranscript{
		RelationshipID: relationshipID,
		SessionID:      sessionID,
		ClientNonce:    fixtureSessionNonce,
		ParentNonce:    fixtureParentSession,
		ChildRevision:  3,
		ParentRevision: 4,
	}
	sessionKey, err := protocol.SessionKey(credential, sessionTranscript.Object())
	if err != nil {
		fail(err)
	}

	record("handshake/session.json", "session", "valid", both(), protocol.Object{
		"schema": int64(1),
		"note": "Proofs use the durable relationship credential. Reconnection derives a new " +
			"session key rather than resuming old traffic, and the first counter is 1.",
		"relationship_credential_hex": hex.EncodeToString(credential),
		"request_id":                  sessionRequestID,
		"messages": protocol.Array{
			protocol.Object{"kind": "session_open",
				"text": sealHandshakeOrFail(credential, "session_open", sessionRequestID, sessionOpenBody)},
			protocol.Object{"kind": "session_challenge",
				"text": sealHandshakeOrFail(credential, "session_challenge", sessionRequestID, sessionChallengeBody)},
			protocol.Object{"kind": "session_confirm",
				"text": sealHandshakeOrFail(credential, "session_confirm", sessionRequestID, sessionConfirmBody)},
		},
		"transcript":    sessionTranscript.Object(),
		"session_key":   hex.EncodeToString(sessionKey),
		"first_counter": protocol.FirstCounter,
	})
}
