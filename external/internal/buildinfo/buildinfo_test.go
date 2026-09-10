package buildinfo

import "testing"

func TestSkeletonVersionMetadata(t *testing.T) {
	if Version == "" {
		t.Fatal("Version must not be empty")
	}
	if WireVersion != 1 {
		t.Fatalf("WireVersion = %d, want 1", WireVersion)
	}
}
