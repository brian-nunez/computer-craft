package protocol

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

// CraftNet key derivation and message proofs.
//
// Secrets prove an already assigned identity; they are never the identity. Every
// derivation is purpose separated by a label so that a relationship credential
// can never be replayed as a session key, a nonce, or an enrollment secret, and
// every input is canonicalized before it is signed.

const (
	LabelEnrollment   = "craftnet/v1/enrollment\n"
	LabelRelationship = "craftnet/v1/relationship\n"
	LabelSession      = "craftnet/v1/session\n"
	LabelNonce        = "craftnet/v1/nonce\n"
)

func macBytes(key []byte, message string) []byte {
	mac := hmac.New(sha256.New, key)
	mac.Write([]byte(message))
	return mac.Sum(nil)
}

// EnrollmentTranscript is the canonical record both peers derive a relationship
// credential from. ChildID appears only when an existing logical child
// re-enrolls after a revocation, so a first enrollment and a re-enrollment never
// share a transcript and therefore never derive the same credential.
type EnrollmentTranscript struct {
	ChildID        string
	RequestedName  string
	Role           string
	ParentID       string
	RelationshipID string
	ClientNonce    string
	ParentNonce    string
	ParentRevision int64
}

// Object renders the transcript in the exact shape that gets canonicalized.
func (t EnrollmentTranscript) Object() Object {
	value := Object{
		"requested_name":  t.RequestedName,
		"role":            t.Role,
		"parent_id":       t.ParentID,
		"relationship_id": t.RelationshipID,
		"client_nonce":    t.ClientNonce,
		"parent_nonce":    t.ParentNonce,
		"parent_revision": t.ParentRevision,
	}
	if t.ChildID != "" {
		value["child_id"] = t.ChildID
	}
	return value
}

var enrollmentTranscriptShape = shape{
	required: map[string]string{
		"requested_name": "normalized_name", "role": "role", "parent_id": "id",
		"relationship_id": "id", "client_nonce": "nonce", "parent_nonce": "nonce",
		"parent_revision": "revision",
	},
	optional: map[string]string{"child_id": "id"},
}

// SessionTranscript is the canonical record both peers derive a session key
// from. A session ID or nonce may never be reused with the same relationship
// credential.
type SessionTranscript struct {
	RelationshipID string
	SessionID      string
	ClientNonce    string
	ParentNonce    string
	ChildRevision  int64
	ParentRevision int64
}

// Object renders the transcript in the exact shape that gets canonicalized.
func (t SessionTranscript) Object() Object {
	return Object{
		"relationship_id": t.RelationshipID,
		"session_id":      t.SessionID,
		"client_nonce":    t.ClientNonce,
		"parent_nonce":    t.ParentNonce,
		"child_revision":  t.ChildRevision,
		"parent_revision": t.ParentRevision,
	}
}

var sessionTranscriptShape = shape{
	required: map[string]string{
		"relationship_id": "id", "session_id": "id", "client_nonce": "nonce",
		"parent_nonce": "nonce", "child_revision": "revision", "parent_revision": "revision",
	},
}

func canonicalTranscript(definition shape, value Object, path string) (string, error) {
	if err := validateShape(definition, value, path); err != nil {
		return "", err
	}
	return Encode(value)
}

// EnrollmentSecret lets a parent derive a child's one-time enrollment secret
// from its own root secret rather than storing a separate secret per child.
func EnrollmentSecret(rootSecret []byte, childRole string, tokenUseCounter int64) ([]byte, error) {
	if len(rootSecret) == 0 {
		return nil, newError(CodeInternalError, "root secret must not be empty")
	}
	if !scalars["role"](childRole) {
		return nil, newError(CodeInvalidMessage, "child role %q is not a CraftNet role", childRole)
	}
	if tokenUseCounter < 0 {
		return nil, newError(CodeInvalidMessage, "token use counter must be non-negative")
	}
	context := MustEncode(Array{Version, childRole, tokenUseCounter})
	return macBytes(rootSecret, LabelEnrollment+context), nil
}

// RelationshipCredential is the durable credential both peers commit after a
// successful enrollment. The parent invalidates the one-time secret only after
// enroll_accept is durably committed.
func RelationshipCredential(enrollmentSecret []byte, transcript Object) ([]byte, error) {
	text, err := canonicalTranscript(enrollmentTranscriptShape, transcript, "enrollment_transcript")
	if err != nil {
		return nil, err
	}
	return macBytes(enrollmentSecret, LabelRelationship+text), nil
}

// SessionKey is fresh for every reconnect; reconnection never resumes old
// traffic.
func SessionKey(relationshipCredential []byte, transcript Object) ([]byte, error) {
	text, err := canonicalTranscript(sessionTranscriptShape, transcript, "session_transcript")
	if err != nil {
		return nil, err
	}
	return macBytes(relationshipCredential, LabelSession+text), nil
}

// Nonce is derived, never drawn from a general-purpose random source in world.
// Uniqueness comes from a durable per-relationship generation counter whose
// increment is committed before the nonce is transmitted.
func Nonce(relationshipCredential []byte, role string, generation int64) (string, error) {
	if !scalars["role"](role) {
		return "", newError(CodeInvalidMessage, "role %q is not a CraftNet role", role)
	}
	if generation < 0 {
		return "", newError(CodeInvalidMessage, "generation must be non-negative")
	}
	context := MustEncode(Array{Version, role, generation})
	return hex.EncodeToString(macBytes(relationshipCredential, LabelNonce+context)), nil
}

// HandshakeProof covers the whole unsigned outer object of an enrollment or
// session-establishment message.
func HandshakeProof(secret []byte, kind, requestID string, body Object) (string, error) {
	text, err := Encode(Array{Version, kind, requestID, body})
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(macBytes(secret, text)), nil
}

// BodyHash is SHA256(CJ1(body)).
func BodyHash(body Object) (string, error) {
	text, err := Encode(body)
	if err != nil {
		return "", err
	}
	digest := sha256.Sum256([]byte(text))
	return hex.EncodeToString(digest[:]), nil
}

// MACInput is the exact operational signing preimage. Messages with no request
// correlation use the empty string for request_id.
func MACInput(kind, relationshipID, sessionID, requestID string, counter int64, bodyHash string) (string, error) {
	return Encode(Array{Version, kind, relationshipID, sessionID, requestID, counter, bodyHash})
}

// MAC computes the operational message authentication code.
func MAC(sessionKey []byte, kind, relationshipID, sessionID, requestID string, counter int64, bodyHash string) (string, error) {
	text, err := MACInput(kind, relationshipID, sessionID, requestID, counter, bodyHash)
	if err != nil {
		return "", err
	}
	return hex.EncodeToString(macBytes(sessionKey, text)), nil
}

// EqualMAC compares two hexadecimal MACs in constant time.
func EqualMAC(left, right string) bool {
	return hmac.Equal([]byte(left), []byte(right))
}
