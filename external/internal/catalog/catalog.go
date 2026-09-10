// Package catalog validates the repository's ccpm package metadata without
// changing ccpm's installation behavior.
package catalog

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

const rawPrefix = "https://raw.githubusercontent.com/brian-nunez/computer-craft/main/"

type registry struct {
	Schema   int                        `json:"schema"`
	Packages map[string]registryPackage `json:"packages"`
}

type registryPackage struct {
	Versions map[string]registryVersion `json:"versions"`
}

type registryVersion struct {
	Manifest string `json:"manifest"`
}

type packageManifest struct {
	Name         string            `json:"name"`
	Version      string            `json:"version"`
	Dependencies map[string]string `json:"dependencies"`
	Files        map[string]string `json:"files"`
}

// Validate checks that registry entries, local manifests, dependency names,
// and package source files agree.
func Validate(repositoryRoot string) error {
	var index registry
	if err := readStrict(filepath.Join(repositoryRoot, "registry.json"), &index); err != nil {
		return fmt.Errorf("registry: %w", err)
	}
	if index.Schema != 1 {
		return fmt.Errorf("registry schema = %d, want 1", index.Schema)
	}
	if len(index.Packages) == 0 {
		return errors.New("registry has no packages")
	}

	listedManifests := make(map[string]struct{})
	listedSources := make(map[string]struct{})
	for packageName, packageEntry := range index.Packages {
		if !safeSegment(packageName) {
			return fmt.Errorf("unsafe package name %q", packageName)
		}
		if len(packageEntry.Versions) == 0 {
			return fmt.Errorf("package %q has no versions", packageName)
		}
		for version, versionEntry := range packageEntry.Versions {
			if !safeVersion(version) {
				return fmt.Errorf("package %q has invalid version %q", packageName, version)
			}
			relativeManifest := path.Join("packages", packageName, version+".json")
			if versionEntry.Manifest != rawPrefix+relativeManifest {
				return fmt.Errorf("%s manifest URL does not match repository convention", packageName+"@"+version)
			}
			listedManifests[relativeManifest] = struct{}{}

			var manifest packageManifest
			if err := readStrict(filepath.Join(repositoryRoot, filepath.FromSlash(relativeManifest)), &manifest); err != nil {
				return fmt.Errorf("%s: %w", packageName+"@"+version, err)
			}
			if manifest.Name != packageName || manifest.Version != version {
				return fmt.Errorf("%s manifest identity is %s@%s", packageName+"@"+version, manifest.Name, manifest.Version)
			}
			if manifest.Dependencies == nil || manifest.Files == nil || len(manifest.Files) == 0 {
				return fmt.Errorf("%s must declare dependency and non-empty file objects", packageName+"@"+version)
			}
			for dependency, constraint := range manifest.Dependencies {
				if _, exists := index.Packages[dependency]; !exists {
					return fmt.Errorf("%s depends on unknown package %q", packageName+"@"+version, dependency)
				}
				if strings.TrimSpace(constraint) == "" {
					return fmt.Errorf("%s has an empty constraint for %q", packageName+"@"+version, dependency)
				}
			}
			for fileName, sourceURL := range manifest.Files {
				if !safeRelative(fileName) {
					return fmt.Errorf("%s has unsafe file path %q", packageName+"@"+version, fileName)
				}
				relativeSource := path.Join("packages", packageName, "files", fileName)
				if sourceURL != rawPrefix+relativeSource {
					return fmt.Errorf("%s source URL for %q does not match repository convention", packageName+"@"+version, fileName)
				}
				info, err := os.Stat(filepath.Join(repositoryRoot, filepath.FromSlash(relativeSource)))
				if err != nil || !info.Mode().IsRegular() {
					return fmt.Errorf("%s source file %q is unavailable", packageName+"@"+version, relativeSource)
				}
				listedSources[relativeSource] = struct{}{}
			}
		}
	}

	// Every source file on disk must be listed by some version of its package.
	// Without this check a new module could ship in the repository and simply
	// never reach a Computer, failing at require time rather than at install.
	sourcePattern := filepath.Join(repositoryRoot, "packages", "*", "files", "*")
	localSources, err := filepath.Glob(sourcePattern)
	if err != nil {
		return fmt.Errorf("find package sources: %w", err)
	}
	for _, localSource := range localSources {
		info, err := os.Stat(localSource)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		relative, err := filepath.Rel(repositoryRoot, localSource)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if _, listed := listedSources[relative]; !listed {
			return fmt.Errorf("package source %q is not listed in any manifest", relative)
		}
	}

	manifestPattern := filepath.Join(repositoryRoot, "packages", "*", "*.json")
	localManifests, err := filepath.Glob(manifestPattern)
	if err != nil {
		return fmt.Errorf("find package manifests: %w", err)
	}
	for _, localManifest := range localManifests {
		relative, err := filepath.Rel(repositoryRoot, localManifest)
		if err != nil {
			return err
		}
		relative = filepath.ToSlash(relative)
		if _, listed := listedManifests[relative]; !listed {
			return fmt.Errorf("local package manifest %q is not listed in registry", relative)
		}
	}
	return nil
}

func readStrict(filePath string, target any) error {
	contents, err := os.ReadFile(filePath)
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(contents))
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

func safeSegment(value string) bool {
	return value != "" && value != "." && value != ".." && !strings.ContainsAny(value, "/\\")
}

func safeVersion(value string) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if part == "" {
			return false
		}
		for _, character := range part {
			if character < '0' || character > '9' {
				return false
			}
		}
	}
	return true
}

func safeRelative(value string) bool {
	return value != "" && !path.IsAbs(value) && path.Clean(value) == value && !strings.HasPrefix(value, "../") && !strings.Contains(value, "\\")
}
