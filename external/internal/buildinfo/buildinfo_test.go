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

// A release build stamps the tag into Version. A build that was not stamped has
// to say so, so that an acceptance report can never name a version that no
// release actually produced.
func TestADevelopmentBuildSaysSo(t *testing.T) {
	if Version != "0.1.0-dev" {
		t.Skipf("this binary was stamped as %q, so it is a release build", Version)
	}
}
