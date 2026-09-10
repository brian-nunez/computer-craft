package protocol

// Authenticated operational frames.
//
// A receiver validates types, size, relationship, session, strictly increasing
// counter, body hash, and MAC -- in that order -- before anything is dispatched.
// Callers above this file never see a MAC, a counter, or a canonical form.

// FirstCounter is the counter value of the first operational message in a
// freshly established Authenticated Session.
const FirstCounter int64 = 1

var envelopeShape = shape{
	required: map[string]string{
		"v": "integer", "kind": "operation_name", "relationship_id": "id",
		"session_id": "id", "counter": "positive", "body": "object",
		"body_hash": "digest", "mac": "digest",
	},
	optional: map[string]string{"request_id": "id"},
}

var handshakeShape = shape{
	required: map[string]string{
		"v": "integer", "kind": "operation_name", "request_id": "id",
		"body": "object", "proof": "digest",
	},
}

var discoveryShape = shape{
	required: map[string]string{"v": "integer", "kind": "operation_name", "body": "object"},
}

// Message is one validated inbound message.
type Message struct {
	Kind      string
	Body      Object
	RequestID string
	Counter   int64
}

// Session holds the live counter state for one Authenticated Session.
// Reconnection always creates a new session rather than resuming old traffic.
type Session struct {
	relationshipID        string
	sessionID             string
	sessionKey            []byte
	transport             Transport
	maximumBytes          int
	outboundCounter       int64
	highestInboundCounter int64
}

// SessionOptions configures a new Session.
type SessionOptions struct {
	RelationshipID string
	SessionID      string
	SessionKey     []byte
	Transport      Transport
	MaximumBytes   int
}

// NewSession creates the counter state for an established session.
func NewSession(options SessionOptions) (*Session, error) {
	if !isID(options.RelationshipID) {
		return nil, newError(CodeInvalidMessage, "relationship_id must be a CraftNet ID")
	}
	if !isID(options.SessionID) {
		return nil, newError(CodeInvalidMessage, "session_id must be a CraftNet ID")
	}
	if len(options.SessionKey) == 0 {
		return nil, newError(CodeInternalError, "session_key must be derived from the relationship credential")
	}
	transport := options.Transport
	if transport == "" {
		transport = TransportOperational
	}
	maximum := options.MaximumBytes
	if maximum <= 0 {
		maximum = ModemFrameBytes
	}
	return &Session{
		relationshipID:  options.RelationshipID,
		sessionID:       options.SessionID,
		sessionKey:      options.SessionKey,
		transport:       transport,
		maximumBytes:    maximum,
		outboundCounter: FirstCounter,
	}, nil
}

// NextCounter reports the counter the next sealed frame will carry.
func (s *Session) NextCounter() int64 { return s.outboundCounter }

// Seal produces the wire text for one outbound message and only then commits
// the counter, so a failed encode never burns a counter value.
func (s *Session) Seal(kind string, body Object, requestID string) (string, error) {
	if !Allows(s.transport, kind) {
		return "", newError(CodeInvalidMessage, "kind %q is not carried by this transport", kind)
	}
	if err := ValidateBody(kind, body); err != nil {
		return "", err
	}
	if requestID != "" && !isID(requestID) {
		return "", newError(CodeInvalidMessage, "request_id must be a CraftNet ID when present")
	}

	bodyHash, err := BodyHash(body)
	if err != nil {
		return "", err
	}
	counter := s.outboundCounter
	mac, err := MAC(s.sessionKey, kind, s.relationshipID, s.sessionID, requestID, counter, bodyHash)
	if err != nil {
		return "", err
	}

	envelope := Object{
		"v": Version, "kind": kind, "relationship_id": s.relationshipID,
		"session_id": s.sessionID, "counter": counter, "body": body,
		"body_hash": bodyHash, "mac": mac,
	}
	if requestID != "" {
		envelope["request_id"] = requestID
	}

	text, err := Encode(envelope)
	if err != nil {
		return "", err
	}
	if len(text) > s.maximumBytes {
		return "", newError(CodeMessageTooLarge, "frame exceeds %d bytes", s.maximumBytes)
	}
	s.outboundCounter = counter + 1
	return text, nil
}

// Open validates and authenticates one inbound frame. The counter is committed
// only after the MAC verifies, so a forged frame cannot advance the window.
func (s *Session) Open(text string) (*Message, error) {
	// A receiver discards oversized frames before JSON decoding.
	if len(text) > s.maximumBytes {
		return nil, newError(CodeMessageTooLarge, "frame exceeds %d bytes", s.maximumBytes)
	}
	value, err := Decode(text, DefaultLimits())
	if err != nil {
		return nil, err
	}
	envelope, ok := value.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "frame must be an object")
	}
	if err := validateShape(envelopeShape, envelope, "frame"); err != nil {
		return nil, err
	}
	if version, _ := integerValue(envelope["v"]); version != Version {
		return nil, newError(CodeUnsupportedVersion, "frame declares version %v", envelope["v"])
	}

	kind, _ := stringValue(envelope["kind"])
	if !Allows(s.transport, kind) {
		return nil, newError(CodeInvalidMessage, "kind %q is not carried by this transport", kind)
	}
	if relationship, _ := stringValue(envelope["relationship_id"]); relationship != s.relationshipID {
		return nil, newError(CodeAuthenticationFail, "frame names another relationship")
	}
	if session, _ := stringValue(envelope["session_id"]); session != s.sessionID {
		return nil, newError(CodeAuthenticationFail, "frame names another session")
	}

	counter, _ := integerValue(envelope["counter"])
	if counter <= s.highestInboundCounter {
		return nil, newError(CodeReplayRejected, "counter %d is not greater than %d",
			counter, s.highestInboundCounter)
	}

	body, _ := envelope["body"].(Object)
	bodyHash, err := BodyHash(body)
	if err != nil {
		return nil, err
	}
	if declared, _ := stringValue(envelope["body_hash"]); declared != bodyHash {
		return nil, newError(CodeInvalidMessage, "body_hash does not cover the body")
	}

	requestID, _ := stringValue(envelope["request_id"])
	expected, err := MAC(s.sessionKey, kind, s.relationshipID, s.sessionID, requestID, counter, bodyHash)
	if err != nil {
		return nil, err
	}
	declaredMAC, _ := stringValue(envelope["mac"])
	if !EqualMAC(expected, declaredMAC) {
		return nil, newError(CodeAuthenticationFail, "message authentication code does not verify")
	}

	// Only an authenticated frame may be dispatched, so the body schema is
	// checked last and a violation is reported without advancing the counter.
	if err := ValidateBody(kind, body); err != nil {
		return nil, err
	}

	s.highestInboundCounter = counter
	return &Message{Kind: kind, Body: body, RequestID: requestID, Counter: counter}, nil
}

// SealHandshake builds the unsigned outer object used before a session key
// exists. proof is an HMAC over the whole canonical outer message under the
// one-time enrollment secret, LAN Password, or relationship credential.
func SealHandshake(secret []byte, kind, requestID string, body Object, maximumBytes int) (string, error) {
	if !Allows(TransportHandshake, kind) {
		return "", newError(CodeInvalidMessage, "kind %q is not a handshake message", kind)
	}
	if err := ValidateBody(kind, body); err != nil {
		return "", err
	}
	if !isID(requestID) {
		return "", newError(CodeInvalidMessage, "request_id must be a CraftNet ID")
	}
	proof, err := HandshakeProof(secret, kind, requestID, body)
	if err != nil {
		return "", err
	}
	text, err := Encode(Object{
		"v": Version, "kind": kind, "request_id": requestID, "body": body, "proof": proof,
	})
	if err != nil {
		return "", err
	}
	if maximumBytes <= 0 {
		maximumBytes = ModemFrameBytes
	}
	if len(text) > maximumBytes {
		return "", newError(CodeMessageTooLarge, "handshake exceeds %d bytes", maximumBytes)
	}
	return text, nil
}

// OpenHandshake verifies the outer proof. Discovery-channel callers must not
// return the detail to the peer; it exists for local logging and tests.
func OpenHandshake(secret []byte, text string, maximumBytes int) (*Message, error) {
	if maximumBytes <= 0 {
		maximumBytes = ModemFrameBytes
	}
	if len(text) > maximumBytes {
		return nil, newError(CodeMessageTooLarge, "handshake exceeds %d bytes", maximumBytes)
	}
	value, err := Decode(text, DefaultLimits())
	if err != nil {
		return nil, err
	}
	envelope, ok := value.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "handshake must be an object")
	}
	if err := validateShape(handshakeShape, envelope, "handshake"); err != nil {
		return nil, err
	}
	if version, _ := integerValue(envelope["v"]); version != Version {
		return nil, newError(CodeUnsupportedVersion, "handshake declares version %v", envelope["v"])
	}
	kind, _ := stringValue(envelope["kind"])
	if !Allows(TransportHandshake, kind) {
		return nil, newError(CodeInvalidMessage, "kind %q is not a handshake message", kind)
	}
	body, _ := envelope["body"].(Object)
	requestID, _ := stringValue(envelope["request_id"])
	expected, err := HandshakeProof(secret, kind, requestID, body)
	if err != nil {
		return nil, err
	}
	declared, _ := stringValue(envelope["proof"])
	if !EqualMAC(expected, declared) {
		return nil, newError(CodeAuthenticationFail, "handshake proof does not verify")
	}
	if err := ValidateBody(kind, body); err != nil {
		return nil, err
	}
	return &Message{Kind: kind, Body: body, RequestID: requestID}, nil
}

// SealDiscovery builds an unauthenticated discovery message. Discovery only
// finds a parent and begins enrollment; it carries no secret and no state.
func SealDiscovery(kind string, body Object) (string, error) {
	if !Allows(TransportDiscovery, kind) {
		return "", newError(CodeInvalidMessage, "kind %q is not a discovery message", kind)
	}
	if err := ValidateBody(kind, body); err != nil {
		return "", err
	}
	return Encode(Object{"v": Version, "kind": kind, "body": body})
}

// OpenDiscovery validates an unauthenticated discovery message.
func OpenDiscovery(text string) (*Message, error) {
	if len(text) > ModemFrameBytes {
		return nil, newError(CodeMessageTooLarge, "discovery message exceeds %d bytes", ModemFrameBytes)
	}
	value, err := Decode(text, DefaultLimits())
	if err != nil {
		return nil, err
	}
	envelope, ok := value.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "discovery message must be an object")
	}
	if err := validateShape(discoveryShape, envelope, "discovery"); err != nil {
		return nil, err
	}
	if version, _ := integerValue(envelope["v"]); version != Version {
		return nil, newError(CodeUnsupportedVersion, "discovery declares version %v", envelope["v"])
	}
	kind, _ := stringValue(envelope["kind"])
	if !Allows(TransportDiscovery, kind) {
		return nil, newError(CodeInvalidMessage, "kind %q is not a discovery message", kind)
	}
	body, _ := envelope["body"].(Object)
	if err := ValidateBody(kind, body); err != nil {
		return nil, err
	}
	return &Message{Kind: kind, Body: body}, nil
}
