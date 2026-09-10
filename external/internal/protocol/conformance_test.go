package protocol_test

import (
	"crypto/ed25519"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// The catalog under spec/protocol/v1 is the executable compatibility source of
// truth. Every case here is also replayed by the Lua suite, and the two must
// classify each one identically.

const catalogRoot = "../../../spec/protocol/v1"

func loadFixture(t *testing.T, relative string) protocol.Object {
	t.Helper()
	contents, err := os.ReadFile(filepath.Join(catalogRoot, filepath.FromSlash(relative)))
	if err != nil {
		t.Fatalf("read fixture %s: %v", relative, err)
	}
	// The catalog is authored to stay inside the wire limits so that it can be
	// read back by the same strict decoder it exercises. Limit behaviour itself
	// is asserted by the limits fixture, which builds its inputs from recipes.
	value, err := protocol.Decode(string(contents), protocol.DefaultLimits())
	if err != nil {
		t.Fatalf("decode fixture %s: %v", relative, err)
	}
	object, ok := value.(protocol.Object)
	if !ok {
		t.Fatalf("fixture %s is not an object", relative)
	}
	return object
}

func field[T any](t *testing.T, object protocol.Object, key string) T {
	t.Helper()
	value, ok := object[key].(T)
	if !ok {
		t.Fatalf("fixture field %q is missing or has the wrong type (%T)", key, object[key])
	}
	return value
}

func caseName(t *testing.T, item protocol.Object) string {
	t.Helper()
	return field[string](t, item, "name")
}

func TestCatalogIsListedForBothImplementations(t *testing.T) {
	manifest := loadFixture(t, "manifest.json")
	if version, _ := manifest["wire_version"].(int64); version != protocol.Version {
		t.Fatalf("manifest wire_version = %v, want %d", manifest["wire_version"], protocol.Version)
	}
	fixtures := field[protocol.Array](t, manifest, "fixtures")
	if len(fixtures) == 0 {
		t.Fatal("the catalog lists no fixtures")
	}
	shared := 0
	for _, entry := range fixtures {
		item := entry.(protocol.Object)
		for _, consumer := range field[protocol.Array](t, item, "consumers") {
			if consumer == "lua" {
				shared++
			}
		}
	}
	if shared == 0 {
		t.Fatal("no fixture is replayed by the Lua implementation")
	}
}

func TestCanonicalEncodings(t *testing.T) {
	document := loadFixture(t, "cj1/canonical.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		name := caseName(t, item)
		t.Run(name, func(t *testing.T) {
			value, err := protocol.Decode(field[string](t, item, "text"), protocol.DefaultLimits())
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			encoded, err := protocol.Encode(value)
			if err != nil {
				t.Fatalf("encode: %v", err)
			}
			if want := field[string](t, item, "canonical"); encoded != want {
				t.Fatalf("canonical form\n got: %s\nwant: %s", encoded, want)
			}
			// Canonical form is a fixed point: re-encoding must not drift.
			again, err := protocol.Decode(encoded, protocol.DefaultLimits())
			if err != nil {
				t.Fatalf("re-decode: %v", err)
			}
			stable, err := protocol.Encode(again)
			if err != nil {
				t.Fatalf("re-encode: %v", err)
			}
			if stable != encoded {
				t.Fatalf("canonical form is not stable: %s then %s", encoded, stable)
			}
		})
	}
}

func TestRejectedCanonicalInputs(t *testing.T) {
	document := loadFixture(t, "cj1/rejected.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			_, err := protocol.Decode(field[string](t, item, "text"), protocol.DefaultLimits())
			if err == nil {
				t.Fatal("input was accepted")
			}
			if got, want := protocol.CodeOf(err), field[string](t, item, "error"); got != want {
				t.Fatalf("error code = %s, want %s (%v)", got, want, err)
			}
		})
	}
}

func TestPublishedSHA256Vectors(t *testing.T) {
	document := loadFixture(t, "hash/sha256.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			var input []byte
			if raw, ok := item["input_hex"].(string); ok {
				decoded, err := hex.DecodeString(raw)
				if err != nil {
					t.Fatalf("input_hex: %v", err)
				}
				input = decoded
			} else {
				filler := field[string](t, item, "input_repeat")
				count := field[int64](t, item, "input_repeat_count")
				input = []byte(strings.Repeat(filler, int(count)))
			}
			if got := protocol.SHA256Hex(input); got != field[string](t, item, "digest") {
				t.Fatalf("digest = %s, want %s", got, item["digest"])
			}
		})
	}
}

func TestPublishedHMACVectors(t *testing.T) {
	document := loadFixture(t, "hash/hmac-sha256.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			key, err := hex.DecodeString(field[string](t, item, "key_hex"))
			if err != nil {
				t.Fatalf("key_hex: %v", err)
			}
			message, err := hex.DecodeString(field[string](t, item, "message_hex"))
			if err != nil {
				t.Fatalf("message_hex: %v", err)
			}
			if got := protocol.HMACHex(key, message); got != field[string](t, item, "mac") {
				t.Fatalf("mac = %s, want %s", got, item["mac"])
			}
		})
	}
}

func TestKeyDerivationChain(t *testing.T) {
	document := loadFixture(t, "derivation/keys.json")
	rootSecret, err := hex.DecodeString(field[string](t, document, "root_secret_hex"))
	if err != nil {
		t.Fatalf("root_secret_hex: %v", err)
	}

	labels := field[protocol.Object](t, document, "labels")
	for name, want := range map[string]string{
		"enrollment": protocol.LabelEnrollment, "relationship": protocol.LabelRelationship,
		"session": protocol.LabelSession, "nonce": protocol.LabelNonce,
	} {
		if got, _ := labels[name].(string); got != want {
			t.Fatalf("label %s = %q, want %q", name, got, want)
		}
	}

	enrollmentEntry := field[protocol.Object](t, document, "enrollment_secret")
	enrollmentSecret, err := protocol.EnrollmentSecret(rootSecret,
		field[string](t, enrollmentEntry, "child_role"),
		field[int64](t, enrollmentEntry, "token_use_counter"))
	if err != nil {
		t.Fatalf("enrollment secret: %v", err)
	}
	if got := hex.EncodeToString(enrollmentSecret); got != field[string](t, enrollmentEntry, "value") {
		t.Fatalf("enrollment secret = %s, want %s", got, enrollmentEntry["value"])
	}

	credentialEntry := field[protocol.Object](t, document, "relationship_credential")
	credential, err := protocol.RelationshipCredential(enrollmentSecret,
		field[protocol.Object](t, credentialEntry, "transcript"))
	if err != nil {
		t.Fatalf("relationship credential: %v", err)
	}
	if got := hex.EncodeToString(credential); got != field[string](t, credentialEntry, "value") {
		t.Fatalf("relationship credential = %s, want %s", got, credentialEntry["value"])
	}

	// A re-enrolling child carries its identity into the transcript, so the same
	// secret and nonces must not reproduce the first credential.
	reEntry := field[protocol.Object](t, document, "re_enrollment_credential")
	reCredential, err := protocol.RelationshipCredential(enrollmentSecret,
		field[protocol.Object](t, reEntry, "transcript"))
	if err != nil {
		t.Fatalf("re-enrollment credential: %v", err)
	}
	if got := hex.EncodeToString(reCredential); got != field[string](t, reEntry, "value") {
		t.Fatalf("re-enrollment credential = %s, want %s", got, reEntry["value"])
	}
	if hex.EncodeToString(reCredential) == hex.EncodeToString(credential) {
		t.Fatal("re-enrollment reproduced the first enrollment credential")
	}

	sessionEntry := field[protocol.Object](t, document, "session_key")
	sessionKey, err := protocol.SessionKey(credential, field[protocol.Object](t, sessionEntry, "transcript"))
	if err != nil {
		t.Fatalf("session key: %v", err)
	}
	if got := hex.EncodeToString(sessionKey); got != field[string](t, sessionEntry, "value") {
		t.Fatalf("session key = %s, want %s", got, sessionEntry["value"])
	}

	for _, entry := range field[protocol.Array](t, document, "nonces") {
		item := entry.(protocol.Object)
		nonce, err := protocol.Nonce(credential,
			field[string](t, item, "role"), field[int64](t, item, "generation"))
		if err != nil {
			t.Fatalf("nonce: %v", err)
		}
		if nonce != field[string](t, item, "value") {
			t.Fatalf("nonce = %s, want %s", nonce, item["value"])
		}
	}
}

func TestAcceptedMessageBodies(t *testing.T) {
	document := loadFixture(t, "messages/accepted.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			kind := field[string](t, item, "kind")
			transport := protocol.Transport(field[string](t, item, "transport"))
			if !protocol.Allows(transport, kind) {
				t.Fatalf("transport %s does not carry %s", transport, kind)
			}
			value, err := protocol.Decode(field[string](t, item, "body"), protocol.DefaultLimits())
			if err != nil {
				t.Fatalf("decode body: %v", err)
			}
			body, ok := value.(protocol.Object)
			if !ok {
				t.Fatal("body is not an object")
			}
			if err := protocol.ValidateBody(kind, body); err != nil {
				t.Fatalf("validate: %v", err)
			}
		})
	}
}

func TestRejectedMessageBodies(t *testing.T) {
	document := loadFixture(t, "messages/rejected.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			kind := field[string](t, item, "kind")
			value, err := protocol.Decode(field[string](t, item, "body"), protocol.DefaultLimits())
			if err != nil {
				if got := protocol.CodeOf(err); got != field[string](t, item, "error") {
					t.Fatalf("decode error = %s, want %s", got, item["error"])
				}
				return
			}
			body, ok := value.(protocol.Object)
			if !ok {
				return // a non-object body is refused by the frame layer
			}
			err = protocol.ValidateBody(kind, body)
			if err == nil {
				t.Fatal("body was accepted")
			}
			if got, want := protocol.CodeOf(err), field[string](t, item, "error"); got != want {
				t.Fatalf("error code = %s, want %s (%v)", got, want, err)
			}
		})
	}
}

func fixtureSession(t *testing.T, document protocol.Object) *protocol.Session {
	t.Helper()
	key, err := hex.DecodeString(field[string](t, document, "session_key_hex"))
	if err != nil {
		t.Fatalf("session_key_hex: %v", err)
	}
	session, err := protocol.NewSession(protocol.SessionOptions{
		RelationshipID: field[string](t, document, "relationship_id"),
		SessionID:      field[string](t, document, "session_id"),
		SessionKey:     key,
	})
	if err != nil {
		t.Fatalf("new session: %v", err)
	}
	return session
}

func TestAcceptedFrames(t *testing.T) {
	document := loadFixture(t, "frames/accepted.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			message, err := fixtureSession(t, document).Open(field[string](t, item, "text"))
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if message.Kind != field[string](t, item, "kind") {
				t.Fatalf("kind = %s, want %s", message.Kind, item["kind"])
			}
			if message.Counter != field[int64](t, item, "counter") {
				t.Fatalf("counter = %d, want %v", message.Counter, item["counter"])
			}
			if message.RequestID != field[string](t, item, "request_id") {
				t.Fatalf("request_id = %q, want %q", message.RequestID, item["request_id"])
			}
		})
	}
}

func TestRejectedFrames(t *testing.T) {
	document := loadFixture(t, "frames/rejected.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			_, err := fixtureSession(t, document).Open(field[string](t, item, "text"))
			if err == nil {
				t.Fatal("frame was accepted")
			}
			if got, want := protocol.CodeOf(err), field[string](t, item, "error"); got != want {
				t.Fatalf("error code = %s, want %s (%v)", got, want, err)
			}
		})
	}
}

func TestFrameSequencesFailClosed(t *testing.T) {
	document := loadFixture(t, "frames/sequences.json")
	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			session := fixtureSession(t, document)
			for index, step := range field[protocol.Array](t, item, "steps") {
				stepObject := step.(protocol.Object)
				message, err := session.Open(field[string](t, stepObject, "text"))
				expect := field[string](t, stepObject, "expect")
				if expect == "accepted" {
					if err != nil {
						t.Fatalf("step %d: %v", index+1, err)
					}
					if want := field[int64](t, stepObject, "counter"); message.Counter != want {
						t.Fatalf("step %d: counter = %d, want %d", index+1, message.Counter, want)
					}
					continue
				}
				if err == nil {
					t.Fatalf("step %d was accepted, want %s", index+1, expect)
				}
				if got := protocol.CodeOf(err); got != expect {
					t.Fatalf("step %d: error code = %s, want %s", index+1, got, expect)
				}
			}
		})
	}
}

func TestEnrollmentExchange(t *testing.T) {
	document := loadFixture(t, "handshake/enrollment.json")
	secret, err := hex.DecodeString(field[string](t, document, "enrollment_secret_hex"))
	if err != nil {
		t.Fatalf("enrollment_secret_hex: %v", err)
	}
	requestID := field[string](t, document, "request_id")

	for _, entry := range field[protocol.Array](t, document, "messages") {
		item := entry.(protocol.Object)
		kind := field[string](t, item, "kind")
		t.Run(kind, func(t *testing.T) {
			message, err := protocol.OpenHandshake(secret, field[string](t, item, "text"), 0)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if message.Kind != kind {
				t.Fatalf("kind = %s, want %s", message.Kind, kind)
			}
			if message.RequestID != requestID {
				t.Fatalf("request_id = %s, want %s", message.RequestID, requestID)
			}
		})
	}

	credential, err := protocol.RelationshipCredential(secret, field[protocol.Object](t, document, "transcript"))
	if err != nil {
		t.Fatalf("relationship credential: %v", err)
	}
	if got := hex.EncodeToString(credential); got != field[string](t, document, "relationship_credential") {
		t.Fatalf("relationship credential = %s, want %s", got, document["relationship_credential"])
	}

	for _, entry := range field[protocol.Array](t, document, "rejected") {
		item := entry.(protocol.Object)
		t.Run("rejected/"+caseName(t, item), func(t *testing.T) {
			_, err := protocol.OpenHandshake(secret, field[string](t, item, "text"), 0)
			if err == nil {
				t.Fatal("handshake was accepted")
			}
			if got, want := protocol.CodeOf(err), field[string](t, item, "error"); got != want {
				t.Fatalf("error code = %s, want %s (%v)", got, want, err)
			}
		})
	}
}

func TestSessionExchange(t *testing.T) {
	document := loadFixture(t, "handshake/session.json")
	credential, err := hex.DecodeString(field[string](t, document, "relationship_credential_hex"))
	if err != nil {
		t.Fatalf("relationship_credential_hex: %v", err)
	}
	for _, entry := range field[protocol.Array](t, document, "messages") {
		item := entry.(protocol.Object)
		kind := field[string](t, item, "kind")
		t.Run(kind, func(t *testing.T) {
			message, err := protocol.OpenHandshake(credential, field[string](t, item, "text"), 0)
			if err != nil {
				t.Fatalf("open: %v", err)
			}
			if message.Kind != kind {
				t.Fatalf("kind = %s, want %s", message.Kind, kind)
			}
		})
	}

	sessionKey, err := protocol.SessionKey(credential, field[protocol.Object](t, document, "transcript"))
	if err != nil {
		t.Fatalf("session key: %v", err)
	}
	if got := hex.EncodeToString(sessionKey); got != field[string](t, document, "session_key") {
		t.Fatalf("session key = %s, want %s", got, document["session_key"])
	}
	if want := field[int64](t, document, "first_counter"); want != protocol.FirstCounter {
		t.Fatalf("first counter = %d, want %d", protocol.FirstCounter, want)
	}
}

// buildLimitInput constructs a limits case from its recipe. Embedding the text
// literally would make the fixture file itself exceed the string limit.
func buildLimitInput(t *testing.T, item protocol.Object) string {
	t.Helper()
	switch recipe := field[string](t, item, "recipe"); recipe {
	case "string":
		length := int(field[int64](t, item, "length"))
		return `{"s":"` + strings.Repeat(field[string](t, item, "filler"), length) + `"}`
	case "object_keys":
		count := int(field[int64](t, item, "count"))
		pairs := make([]string, 0, count)
		for index := 0; index < count; index++ {
			pairs = append(pairs, `"k`+itoa(index)+`":0`)
		}
		return "{" + strings.Join(pairs, ",") + "}"
	case "array_elements":
		count := int(field[int64](t, item, "count"))
		elements := make([]string, 0, count)
		for index := 0; index < count; index++ {
			elements = append(elements, "0")
		}
		return "[" + strings.Join(elements, ",") + "]"
	case "depth":
		count := int(field[int64](t, item, "count"))
		return strings.Repeat("[", count) + strings.Repeat("]", count)
	case "modem_frame":
		// The padding is split into chunks because no single string may exceed the
		// string limit, so a frame at the modem ceiling cannot be one long value.
		chunks := field[protocol.Array](t, item, "chunks")
		pieces := make([]string, 0, len(chunks))
		for _, chunk := range chunks {
			size, ok := chunk.(int64)
			if !ok {
				t.Fatalf("chunk size %v is not an integer", chunk)
			}
			pieces = append(pieces, `"`+strings.Repeat("p", int(size))+`"`)
		}
		text := `{"pad":[` + strings.Join(pieces, ",") + `]}`
		if want := int(field[int64](t, item, "length")); len(text) != want {
			t.Fatalf("built %d bytes, want %d", len(text), want)
		}
		return text
	default:
		t.Fatalf("unknown limit recipe %q", recipe)
		return ""
	}
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	digits := ""
	for value > 0 {
		digits = string(rune('0'+value%10)) + digits
		value /= 10
	}
	return digits
}

func TestLimitEdges(t *testing.T) {
	document := loadFixture(t, "limits/edges.json")

	declared := field[protocol.Object](t, document, "limits")
	for name, want := range map[string]int64{
		"modem_frame_bytes": protocol.ModemFrameBytes, "modem_payload_bytes": protocol.ModemPayloadBytes,
		"gateway_frame_bytes": protocol.GatewayFrameBytes, "traffic_batch_bytes": protocol.TrafficBatchBytes,
		"traffic_batch_events": protocol.TrafficBatchEvents, "topology_entities": protocol.TopologyEntities,
		"string_bytes": protocol.StringBytes, "depth": protocol.Depth,
		"object_keys": protocol.ObjectKeys, "array_elements": protocol.ArrayElements,
		"relationship_in_flight": protocol.RelationshipInFlight,
		"gateway_in_flight":      protocol.GatewayInFlight,
		"access_token_seconds":   protocol.AccessTokenSeconds,
	} {
		if got, _ := declared[name].(int64); got != want {
			t.Fatalf("limit %s = %v, want %d", name, declared[name], want)
		}
	}

	for _, entry := range field[protocol.Array](t, document, "cases") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			text := buildLimitInput(t, item)
			expect := field[string](t, item, "expect")

			var err error
			if field[string](t, item, "recipe") == "modem_frame" {
				// The modem ceiling is enforced before JSON decoding.
				if err = protocol.CheckModemFrameSize(text); err == nil {
					_, err = protocol.Decode(text, protocol.DefaultLimits())
				}
			} else {
				_, err = protocol.Decode(text, protocol.DefaultLimits())
			}

			if expect == "accepted" {
				if err != nil {
					t.Fatalf("input at the limit was refused: %v", err)
				}
				return
			}
			if err == nil {
				t.Fatal("input past the limit was accepted")
			}
			if got := protocol.CodeOf(err); got != expect {
				t.Fatalf("error code = %s, want %s (%v)", got, expect, err)
			}
		})
	}
}

func TestErrorCatalogMatchesTheSpecification(t *testing.T) {
	document := loadFixture(t, "errors/catalog.json")
	codes := field[protocol.Array](t, document, "codes")
	if len(codes) != len(protocol.Catalog) {
		t.Fatalf("catalog holds %d codes, the fixture lists %d", len(protocol.Catalog), len(codes))
	}
	for index, entry := range codes {
		item := entry.(protocol.Object)
		code := field[string](t, item, "code")
		if protocol.Catalog[index].Code != code {
			t.Fatalf("catalog[%d] = %s, want %s", index, protocol.Catalog[index].Code, code)
		}
		if !protocol.KnownCode(code) {
			t.Fatalf("code %s is not known", code)
		}
		retryable, ok := protocol.Retryable(code)
		if !ok {
			t.Fatalf("code %s has no retryability", code)
		}
		if want := field[bool](t, item, "retryable"); retryable != want {
			t.Fatalf("code %s retryable = %v, want %v", code, retryable, want)
		}
	}
}

func TestGatewayFrames(t *testing.T) {
	document := loadFixture(t, "gateway/frames.json")

	hello, err := protocol.DecodeGatewayHello(field[string](t, document, "hello"))
	if err != nil {
		t.Fatalf("hello: %v", err)
	}
	if hello.WorldID == "" || hello.CentralID == "" {
		t.Fatal("hello is missing its identities")
	}
	welcome, err := protocol.DecodeGatewayWelcome(field[string](t, document, "welcome"))
	if err != nil {
		t.Fatalf("welcome: %v", err)
	}
	if welcome.GatewaySessionID == "" {
		t.Fatal("welcome is missing its Gateway Session")
	}

	for _, entry := range field[protocol.Array](t, document, "frames") {
		item := entry.(protocol.Object)
		t.Run(caseName(t, item), func(t *testing.T) {
			frame, err := protocol.DecodeGatewayFrame(field[string](t, item, "text"))
			if err != nil {
				t.Fatalf("decode: %v", err)
			}
			if frame.Kind != field[string](t, item, "kind") {
				t.Fatalf("kind = %s, want %s", frame.Kind, item["kind"])
			}
		})
	}

	for _, entry := range field[protocol.Array](t, document, "rejected") {
		item := entry.(protocol.Object)
		t.Run("rejected/"+caseName(t, item), func(t *testing.T) {
			_, err := protocol.DecodeGatewayFrame(field[string](t, item, "text"))
			if err == nil {
				t.Fatal("frame was accepted")
			}
			if got, want := protocol.CodeOf(err), field[string](t, item, "error"); got != want {
				t.Fatalf("error code = %s, want %s (%v)", got, want, err)
			}
		})
	}
}

func TestAccessTokenFixture(t *testing.T) {
	document := loadFixture(t, "tokens/access-token.json")
	seed, err := hex.DecodeString(field[string](t, document, "private_key_seed"))
	if err != nil {
		t.Fatalf("private_key_seed: %v", err)
	}
	private := ed25519.NewKeyFromSeed(seed)
	public := private.Public().(ed25519.PublicKey)
	if got := hex.EncodeToString(public); got != field[string](t, document, "public_key") {
		t.Fatalf("public key = %s, want %s", got, document["public_key"])
	}

	keyID := field[string](t, document, "key_id")
	keys := map[string]ed25519.PublicKey{keyID: public}
	token := field[string](t, document, "token")
	issuedAt := field[int64](t, document, "issued_at")
	expiresAt := field[int64](t, document, "expires_at")
	if expiresAt-issuedAt > protocol.AccessTokenSeconds {
		t.Fatalf("fixture token lives longer than %d seconds", protocol.AccessTokenSeconds)
	}

	expect := protocol.AccessTokenExpectation{
		Issuer: "craftnet-external", Operation: "market.quote",
		WorldID: "world-overworld", CustomerNetworkID: "net-farm", ComputerID: "cmp-harvester",
	}
	valid := time.Unix(issuedAt+1, 0)
	claims, err := protocol.VerifyAccessToken(keys, token, valid, expect)
	if err != nil {
		t.Fatalf("verify: %v", err)
	}
	if claims.TokenID != "jti-000017" {
		t.Fatalf("jti = %s, want jti-000017", claims.TokenID)
	}

	t.Run("expiry is enforced", func(t *testing.T) {
		_, err := protocol.VerifyAccessToken(keys, token, time.Unix(expiresAt, 0), expect)
		if got := protocol.CodeOf(err); got != protocol.CodeAccessTokenExpired {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeAccessTokenExpired)
		}
	})

	t.Run("an unauthorized operation is refused", func(t *testing.T) {
		other := expect
		other.Operation = "market.settle"
		_, err := protocol.VerifyAccessToken(keys, token, valid, other)
		if got := protocol.CodeOf(err); got != protocol.CodeForbiddenOperation {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeForbiddenOperation)
		}
	})

	t.Run("another customer network is refused", func(t *testing.T) {
		other := expect
		other.CustomerNetworkID = "net-home"
		_, err := protocol.VerifyAccessToken(keys, token, valid, other)
		if got := protocol.CodeOf(err); got != protocol.CodeAuthenticationFail {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeAuthenticationFail)
		}
	})

	t.Run("another computer is refused", func(t *testing.T) {
		other := expect
		other.ComputerID = "cmp-silo"
		_, err := protocol.VerifyAccessToken(keys, token, valid, other)
		if got := protocol.CodeOf(err); got != protocol.CodeAuthenticationFail {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeAuthenticationFail)
		}
	})

	t.Run("a revoked token is refused", func(t *testing.T) {
		other := expect
		other.Revoked = func(tokenID string) bool { return tokenID == "jti-000017" }
		_, err := protocol.VerifyAccessToken(keys, token, valid, other)
		if got := protocol.CodeOf(err); got != protocol.CodeCredentialRevoked {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeCredentialRevoked)
		}
	})

	t.Run("an unknown signing key is refused", func(t *testing.T) {
		_, err := protocol.VerifyAccessToken(map[string]ed25519.PublicKey{}, token, valid, expect)
		if got := protocol.CodeOf(err); got != protocol.CodeAuthenticationFail {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeAuthenticationFail)
		}
	})

	t.Run("a tampered signature is refused", func(t *testing.T) {
		segments := strings.Split(token, ".")
		tampered := segments[0] + "." + segments[1] + "." + strings.Repeat("A", len(segments[2]))
		_, err := protocol.VerifyAccessToken(keys, tampered, valid, expect)
		if got := protocol.CodeOf(err); got != protocol.CodeAuthenticationFail {
			t.Fatalf("error code = %s, want %s", got, protocol.CodeAuthenticationFail)
		}
	})
}
