package catalog

import "testing"

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
