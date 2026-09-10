package testsupport

import (
	"os"
	"path/filepath"
	"testing"
)

func TestRandomIsDeterministic(t *testing.T) {
	t.Setenv("CRAFTNET_TEST_SEED", "42")
	left, right := Random(t), Random(t)
	for range 8 {
		if left.Uint64() != right.Uint64() {
			t.Fatal("generators with the same seed diverged")
		}
	}
}

func TestStateDirUsesConfiguredRoot(t *testing.T) {
	root := t.TempDir()
	t.Setenv("CRAFTNET_TEST_TMPDIR", root)
	state := StateDir(t)
	relative, err := filepath.Rel(root, state)
	if err != nil || relative == "." || relative == ".." {
		t.Fatalf("StateDir() = %q, want child of %q", state, root)
	}
	if _, err := os.Stat(state); err != nil {
		t.Fatalf("StateDir() path unavailable: %v", err)
	}
}
