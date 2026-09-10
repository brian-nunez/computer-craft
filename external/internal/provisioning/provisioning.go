// Package provisioning generates the root secrets a World needs before any
// CraftOS role can enroll anything.
//
// The External Application owns this step: the Central Server derives ISP
// enrollment and relationship secrets from the World Key, and an ISP derives
// Router secrets from its own credential, so nothing in world ever invents a
// root secret or reuses a checked-in fixture credential.
package provisioning

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// SecretBytes is the length of every root secret this package generates.
const SecretBytes = 32

// Bundle is one World's provisioning material. It is written with owner-only
// permissions and never enters the repository, a log, or a snapshot.
type Bundle struct {
	WorldID              string
	CentralID            string
	GatewayURL           string
	GatewayCredentialRef string
	WorldKey             string
	GatewayCredential    string
	CreatedAt            string
}

// Options configures a new Bundle. Empty identity fields take their defaults.
type Options struct {
	WorldID              string
	CentralID            string
	GatewayURL           string
	GatewayCredentialRef string
	Now                  func() time.Time
	// Reader supplies entropy. It is nil in production, which means crypto/rand.
	Reader func([]byte) error
}

func secret(read func([]byte) error) (string, error) {
	raw := make([]byte, SecretBytes)
	if read == nil {
		if _, err := rand.Read(raw); err != nil {
			return "", fmt.Errorf("draw entropy: %w", err)
		}
	} else if err := read(raw); err != nil {
		return "", fmt.Errorf("draw entropy: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

func orDefault(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

// New generates a World Key and Gateway Credential.
func New(options Options) (*Bundle, error) {
	bundle := &Bundle{
		WorldID:              orDefault(options.WorldID, "world-development"),
		CentralID:            orDefault(options.CentralID, "central-development"),
		GatewayURL:           orDefault(options.GatewayURL, "wss://localhost:8443/gateway"),
		GatewayCredentialRef: orDefault(options.GatewayCredentialRef, "gwc-development"),
	}
	for name, value := range map[string]string{
		"world_id": bundle.WorldID, "central_id": bundle.CentralID,
		"gateway_credential_ref": bundle.GatewayCredentialRef,
	} {
		if err := protocol.ValidateIdentifier(value); err != nil {
			return nil, fmt.Errorf("%s: %w", name, err)
		}
	}

	worldKey, err := secret(options.Reader)
	if err != nil {
		return nil, err
	}
	gatewayCredential, err := secret(options.Reader)
	if err != nil {
		return nil, err
	}
	if worldKey == gatewayCredential {
		return nil, fmt.Errorf("the entropy source returned the same secret twice")
	}
	bundle.WorldKey = worldKey
	bundle.GatewayCredential = gatewayCredential

	now := options.Now
	if now == nil {
		now = time.Now
	}
	bundle.CreatedAt = now().UTC().Format(time.RFC3339)
	return bundle, nil
}

// Object renders the bundle in the canonical form it is stored as.
func (b *Bundle) Object() protocol.Object {
	return protocol.Object{
		"schema":                 int64(1),
		"wire_version":           protocol.Version,
		"world_id":               b.WorldID,
		"central_id":             b.CentralID,
		"gateway_url":            b.GatewayURL,
		"gateway_credential_ref": b.GatewayCredentialRef,
		"world_key":              b.WorldKey,
		"gateway_credential":     b.GatewayCredential,
		"created_at":             b.CreatedAt,
	}
}

// Fingerprint identifies a bundle in logs and on screen without revealing any
// secret value: it is the first eight hexadecimal characters of the World Key's
// digest, which is safe to print and enough to tell two bundles apart.
func (b *Bundle) Fingerprint() string {
	digest := sha256.Sum256([]byte(b.WorldKey))
	return hex.EncodeToString(digest[:])[:8]
}

// Write stores the bundle at path with owner-only permissions. It refuses to
// overwrite an existing file, because replacing a World Key silently would
// orphan every credential already derived from it.
func (b *Bundle) Write(path string) error {
	if directory := filepath.Dir(path); directory != "" {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			return fmt.Errorf("create bundle directory: %w", err)
		}
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		if os.IsExist(err) {
			return fmt.Errorf("%s already exists; provisioning never replaces a World Key", path)
		}
		return fmt.Errorf("create bundle: %w", err)
	}
	defer file.Close()

	text, err := protocol.Encode(b.Object())
	if err != nil {
		return fmt.Errorf("encode bundle: %w", err)
	}
	if _, err := file.WriteString(text + "\n"); err != nil {
		return fmt.Errorf("write bundle: %w", err)
	}
	return nil
}

// Load reads a bundle written by Write.
func Load(path string) (*Bundle, error) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read bundle: %w", err)
	}
	value, err := protocol.Decode(string(contents), protocol.DefaultLimits())
	if err != nil {
		return nil, fmt.Errorf("decode bundle: %w", err)
	}
	object, ok := value.(protocol.Object)
	if !ok {
		return nil, fmt.Errorf("bundle is not an object")
	}
	text := func(key string) string {
		value, _ := object[key].(string)
		return value
	}
	if version, _ := object["wire_version"].(int64); version != protocol.Version {
		return nil, fmt.Errorf("bundle declares wire version %v, want %d", object["wire_version"], protocol.Version)
	}
	return &Bundle{
		WorldID:              text("world_id"),
		CentralID:            text("central_id"),
		GatewayURL:           text("gateway_url"),
		GatewayCredentialRef: text("gateway_credential_ref"),
		WorldKey:             text("world_key"),
		GatewayCredential:    text("gateway_credential"),
		CreatedAt:            text("created_at"),
	}, nil
}
