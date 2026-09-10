package provisioning_test

import (
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/provisioning"
	"github.com/brian-nunez/computer-craft/external/internal/testsupport"
)

func TestBundleSecretsAreDistinctAndFullLength(t *testing.T) {
	bundle, err := provisioning.New(provisioning.Options{})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}
	for name, value := range map[string]string{
		"world key": bundle.WorldKey, "gateway credential": bundle.GatewayCredential,
	} {
		raw, err := hex.DecodeString(value)
		if err != nil {
			t.Fatalf("%s is not lowercase hexadecimal: %v", name, err)
		}
		if len(raw) != provisioning.SecretBytes {
			t.Fatalf("%s is %d bytes, want %d", name, len(raw), provisioning.SecretBytes)
		}
	}
	if bundle.WorldKey == bundle.GatewayCredential {
		t.Fatal("the World Key and Gateway Credential must be independent secrets")
	}
}

func TestSuccessiveBundlesDoNotRepeat(t *testing.T) {
	seen := make(map[string]struct{}, 16)
	for index := 0; index < 16; index++ {
		bundle, err := provisioning.New(provisioning.Options{})
		if err != nil {
			t.Fatalf("new bundle: %v", err)
		}
		if _, repeated := seen[bundle.WorldKey]; repeated {
			t.Fatal("crypto/rand returned a repeated World Key")
		}
		seen[bundle.WorldKey] = struct{}{}
	}
}

// A stuck entropy source must fail loudly rather than provision a World whose
// every derived credential collides.
func TestAStuckEntropySourceIsRefused(t *testing.T) {
	_, err := provisioning.New(provisioning.Options{
		Reader: func(destination []byte) error {
			for index := range destination {
				destination[index] = 0
			}
			return nil
		},
	})
	if err == nil {
		t.Fatal("a source that returns the same secret twice was accepted")
	}
	if !strings.Contains(err.Error(), "same secret twice") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestBundleRoundTripsThroughDisk(t *testing.T) {
	random := testsupport.Random(t)
	created := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)
	bundle, err := provisioning.New(provisioning.Options{
		WorldID:   "world-overworld",
		CentralID: "central-overworld",
		Now:       func() time.Time { return created },
		Reader: func(destination []byte) error {
			for index := range destination {
				destination[index] = byte(random.UintN(256))
			}
			return nil
		},
	})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}

	path := filepath.Join(testsupport.StateDir(t), "bundle.json")
	if err := bundle.Write(path); err != nil {
		t.Fatalf("write: %v", err)
	}

	info, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat: %v", err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("bundle permissions are %o, want 600", mode)
	}

	loaded, err := provisioning.Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if loaded.WorldKey != bundle.WorldKey || loaded.GatewayCredential != bundle.GatewayCredential {
		t.Fatal("the reloaded bundle does not carry the same secrets")
	}
	if loaded.CreatedAt != created.Format(time.RFC3339) {
		t.Fatalf("created_at = %s, want %s", loaded.CreatedAt, created.Format(time.RFC3339))
	}
}

// Replacing a World Key silently would orphan every credential already derived
// from it, so writing over an existing bundle is refused.
func TestWriteRefusesToReplaceAnExistingBundle(t *testing.T) {
	path := filepath.Join(testsupport.StateDir(t), "bundle.json")
	first, err := provisioning.New(provisioning.Options{})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}
	if err := first.Write(path); err != nil {
		t.Fatalf("write: %v", err)
	}

	second, err := provisioning.New(provisioning.Options{})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}
	if err := second.Write(path); err == nil {
		t.Fatal("an existing bundle was overwritten")
	}

	reloaded, err := provisioning.Load(path)
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if reloaded.WorldKey != first.WorldKey {
		t.Fatal("the original World Key did not survive the refused write")
	}
}

func TestAnInvalidIdentityIsRefused(t *testing.T) {
	for _, identity := range []string{"World-Overworld", "-world", "", strings.Repeat("w", 65)} {
		if identity == "" {
			continue // an empty value takes the default
		}
		if _, err := provisioning.New(provisioning.Options{WorldID: identity}); err == nil {
			t.Fatalf("identity %q was accepted", identity)
		}
	}
}

// The fingerprint exists so an operator can confirm which bundle a Central
// Server is running against without any secret reaching a screen or a log.
func TestFingerprintRevealsNoSecret(t *testing.T) {
	bundle, err := provisioning.New(provisioning.Options{})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}
	fingerprint := bundle.Fingerprint()
	if len(fingerprint) != 8 {
		t.Fatalf("fingerprint is %d characters, want 8", len(fingerprint))
	}
	if strings.Contains(bundle.WorldKey, fingerprint) {
		t.Fatal("the fingerprint appears inside the World Key")
	}
	if strings.Contains(bundle.GatewayCredential, fingerprint) {
		t.Fatal("the fingerprint appears inside the Gateway Credential")
	}
}

// A Central Server derives ISP enrollment secrets from the World Key, so a
// freshly provisioned bundle must feed the derivation chain directly.
func TestBundleDrivesTheDerivationChain(t *testing.T) {
	bundle, err := provisioning.New(provisioning.Options{})
	if err != nil {
		t.Fatalf("new bundle: %v", err)
	}
	worldKey, err := hex.DecodeString(bundle.WorldKey)
	if err != nil {
		t.Fatalf("world key: %v", err)
	}

	first, err := protocol.EnrollmentSecret(worldKey, "isp", 0)
	if err != nil {
		t.Fatalf("enrollment secret: %v", err)
	}
	second, err := protocol.EnrollmentSecret(worldKey, "isp", 1)
	if err != nil {
		t.Fatalf("enrollment secret: %v", err)
	}
	if hex.EncodeToString(first) == hex.EncodeToString(second) {
		t.Fatal("two token uses derived the same one-time enrollment secret")
	}

	other, err := protocol.EnrollmentSecret(worldKey, "router", 0)
	if err != nil {
		t.Fatalf("enrollment secret: %v", err)
	}
	if hex.EncodeToString(first) == hex.EncodeToString(other) {
		t.Fatal("two child roles derived the same one-time enrollment secret")
	}
}
