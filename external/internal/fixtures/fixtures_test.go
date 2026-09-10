package fixtures

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestValidateEmptyCatalog(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName, `{"schema":1,"wire_version":1,"fixtures":[]}`)
	if err := Validate(root); err != nil {
		t.Fatalf("Validate() error = %v", err)
	}
}

func TestValidateRejectsMalformedManifest(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName, `{"schema":0,"wire_version":1,"fixtures":[]}`)
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "schema") {
		t.Fatalf("Validate() error = %v, want schema failure", err)
	}
}

func TestValidateRejectsUnlistedJSON(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName, `{"schema":1,"wire_version":1,"fixtures":[]}`)
	writeTestFile(t, root, "ignored.json", `{}`)
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "not listed") {
		t.Fatalf("Validate() error = %v, want unlisted fixture failure", err)
	}
}

func writeTestFile(t *testing.T, root, name, contents string) {
	t.Helper()
	filePath := filepath.Join(root, name)
	if err := os.MkdirAll(filepath.Dir(filePath), 0o755); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filePath, []byte(contents), 0o600); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
}

func TestValidateRejectsAFixtureWithNoConsumer(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName,
		`{"schema":1,"wire_version":1,"fixtures":[{"path":"a.json","kind":"cj1","expect":"valid","consumers":[]}]}`)
	writeTestFile(t, root, "a.json", `{}`)
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "consumers") {
		t.Fatalf("Validate() error = %v, want missing consumer failure", err)
	}
}

func TestValidateRejectsAnUnknownConsumer(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName,
		`{"schema":1,"wire_version":1,"fixtures":[{"path":"a.json","kind":"cj1","expect":"valid","consumers":["rust"]}]}`)
	writeTestFile(t, root, "a.json", `{}`)
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "not a CraftNet implementation") {
		t.Fatalf("Validate() error = %v, want unknown consumer failure", err)
	}
}

func TestValidateRejectsAFixtureThatIsNotJSON(t *testing.T) {
	root := t.TempDir()
	writeTestFile(t, root, manifestName,
		`{"schema":1,"wire_version":1,"fixtures":[{"path":"a.json","kind":"cj1","expect":"valid","consumers":["go"]}]}`)
	writeTestFile(t, root, "a.json", `{"unterminated":`)
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "not valid JSON") {
		t.Fatalf("Validate() error = %v, want malformed fixture failure", err)
	}
}
