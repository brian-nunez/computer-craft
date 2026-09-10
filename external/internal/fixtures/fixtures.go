// Package fixtures validates the language-neutral protocol fixture catalog.
package fixtures

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const manifestName = "manifest.json"

type manifest struct {
	Schema      int     `json:"schema"`
	WireVersion int     `json:"wire_version"`
	Fixtures    []entry `json:"fixtures"`
}

type entry struct {
	Path   string `json:"path"`
	Kind   string `json:"kind"`
	Expect string `json:"expect"`
}

// Validate checks the catalog structure and ensures every JSON fixture is
// listed exactly once. Protocol-specific fixture semantics arrive in
// Milestone 1.
func Validate(root string) error {
	contents, err := os.ReadFile(filepath.Join(root, manifestName))
	if err != nil {
		return fmt.Errorf("read manifest: %w", err)
	}

	var catalog manifest
	if err := decodeStrict(contents, &catalog); err != nil {
		return fmt.Errorf("decode manifest: %w", err)
	}
	if catalog.Schema != 1 {
		return fmt.Errorf("schema = %d, want 1", catalog.Schema)
	}
	if catalog.WireVersion != 1 {
		return fmt.Errorf("wire_version = %d, want 1", catalog.WireVersion)
	}
	if catalog.Fixtures == nil {
		return errors.New("fixtures must be an array")
	}

	listed := make(map[string]struct{}, len(catalog.Fixtures))
	for index, fixture := range catalog.Fixtures {
		if err := validateEntry(fixture); err != nil {
			return fmt.Errorf("fixtures[%d]: %w", index, err)
		}
		if _, exists := listed[fixture.Path]; exists {
			return fmt.Errorf("fixture %q is listed more than once", fixture.Path)
		}
		listed[fixture.Path] = struct{}{}

		data, err := os.ReadFile(filepath.Join(root, filepath.FromSlash(fixture.Path)))
		if err != nil {
			return fmt.Errorf("read fixture %q: %w", fixture.Path, err)
		}
		if !json.Valid(data) {
			return fmt.Errorf("fixture %q is not valid JSON", fixture.Path)
		}
	}

	seen := make(map[string]struct{})
	err = filepath.WalkDir(root, func(filePath string, item fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if item.IsDir() || filepath.Ext(item.Name()) != ".json" {
			return nil
		}
		relative, err := filepath.Rel(root, filePath)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if relative == manifestName {
			return nil
		}
		if _, ok := listed[relative]; !ok {
			return fmt.Errorf("JSON fixture %q is not listed in manifest", relative)
		}
		seen[relative] = struct{}{}
		return nil
	})
	if err != nil {
		return fmt.Errorf("walk fixtures: %w", err)
	}
	for fixturePath := range listed {
		if _, ok := seen[fixturePath]; !ok {
			return fmt.Errorf("listed fixture %q was not found", fixturePath)
		}
	}
	return nil
}

func validateEntry(fixture entry) error {
	if fixture.Path == "" || path.IsAbs(fixture.Path) || path.Clean(fixture.Path) != fixture.Path || strings.HasPrefix(fixture.Path, "../") {
		return fmt.Errorf("unsafe fixture path %q", fixture.Path)
	}
	if path.Ext(fixture.Path) != ".json" || fixture.Path == manifestName {
		return fmt.Errorf("fixture path %q must name a non-manifest JSON file", fixture.Path)
	}
	if fixture.Kind == "" {
		return errors.New("kind must not be empty")
	}
	if fixture.Expect != "valid" && fixture.Expect != "invalid" {
		return fmt.Errorf("expect = %q, want valid or invalid", fixture.Expect)
	}
	return nil
}

func decodeStrict(data []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if err := decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple JSON values")
		}
		return fmt.Errorf("trailing data: %w", err)
	}
	return nil
}
