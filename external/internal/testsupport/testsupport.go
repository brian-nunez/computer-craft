// Package testsupport centralizes deterministic randomness and isolated test
// state for Go tests.
package testsupport

import (
	"math/rand/v2"
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

const DefaultSeed uint64 = 12648430 // 0xC0FFEE

// Seed returns the configured deterministic test seed.
func Seed(t testing.TB) uint64 {
	t.Helper()
	raw := os.Getenv("CRAFTNET_TEST_SEED")
	if raw == "" {
		return DefaultSeed
	}
	seed, err := strconv.ParseUint(raw, 0, 64)
	if err != nil {
		t.Fatalf("invalid CRAFTNET_TEST_SEED %q: %v", raw, err)
	}
	return seed
}

// Random returns a reproducible generator scoped to one test.
func Random(t testing.TB) *rand.Rand {
	t.Helper()
	seed := Seed(t)
	return rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15))
}

// StateDir creates an isolated directory beneath CRAFTNET_TEST_TMPDIR when it
// is supplied, or beneath the operating system's test temporary root.
func StateDir(t testing.TB) string {
	t.Helper()
	base := os.Getenv("CRAFTNET_TEST_TMPDIR")
	if base == "" {
		return t.TempDir()
	}
	directory, err := os.MkdirTemp(base, "go-state-")
	if err != nil {
		t.Fatalf("create temporary state directory: %v", err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(directory); err != nil {
			t.Errorf("remove temporary state directory: %v", err)
		}
	})
	return filepath.Clean(directory)
}
