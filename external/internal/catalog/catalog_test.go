package catalog

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSafeVersion(t *testing.T) {
	for _, valid := range []string{"0.1.0", "1.0.0", "12.34.56"} {
		if !safeVersion(valid) {
			t.Errorf("safeVersion(%q) = false, want true", valid)
		}
	}
	for _, invalid := range []string{"", "1", "1.0", "v1.0.0", "1.0.0-beta", "1..0"} {
		if safeVersion(invalid) {
			t.Errorf("safeVersion(%q) = true, want false", invalid)
		}
	}
}

func TestSafeRelative(t *testing.T) {
	for _, valid := range []string{"init.lua", "lib/codec.lua"} {
		if !safeRelative(valid) {
			t.Errorf("safeRelative(%q) = false, want true", valid)
		}
	}
	for _, invalid := range []string{"", "/init.lua", "../secret", "lib/../init.lua", `lib\init.lua`} {
		if safeRelative(invalid) {
			t.Errorf("safeRelative(%q) = true, want false", invalid)
		}
	}
}

// A module that ships in the repository but is missing from its manifest would
// never reach a Computer, failing at load time rather than at install time.
func TestValidateRejectsAnUnlistedPackageSource(t *testing.T) {
	root := t.TempDir()
	write := func(name, contents string) {
		t.Helper()
		filePath := filepath.Join(root, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(filePath), 0o755); err != nil {
			t.Fatalf("MkdirAll: %v", err)
		}
		if err := os.WriteFile(filePath, []byte(contents), 0o600); err != nil {
			t.Fatalf("WriteFile: %v", err)
		}
	}

	write("registry.json", `{"schema":1,"packages":{"demo":{"versions":{"0.1.0":{"manifest":"`+
		rawPrefix+`packages/demo/0.1.0.json"}}}}}`)
	write("packages/demo/0.1.0.json", `{"name":"demo","version":"0.1.0","dependencies":{},"files":{"init.lua":"`+
		rawPrefix+`packages/demo/files/init.lua"}}`)
	write("packages/demo/files/init.lua", "return {}\n")

	if err := Validate(root); err != nil {
		t.Fatalf("Validate() error = %v, want success", err)
	}

	write("packages/demo/files/helper.lua", "return {}\n")
	err := Validate(root)
	if err == nil || !strings.Contains(err.Error(), "not listed in any manifest") {
		t.Fatalf("Validate() error = %v, want unlisted source failure", err)
	}
}
