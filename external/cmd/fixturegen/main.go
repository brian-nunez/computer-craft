// Command fixturegen writes the CraftNet v1 cross-language fixture catalog.
//
// The catalog under spec/protocol/v1 is the executable compatibility source of
// truth: Lua and Go both replay it and must classify every case identically.
// Published SHA-256 and HMAC vectors are carried here as literals from their
// standards rather than computed, so that they check the implementation instead
// of agreeing with it.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

type manifestEntry struct {
	Path      string
	Kind      string
	Expect    string
	Consumers []string
}

var (
	entries []manifestEntry
	files   = map[string]protocol.Object{}
)

func record(path, kind, expect string, consumers []string, document protocol.Object) {
	entries = append(entries, manifestEntry{Path: path, Kind: kind, Expect: expect, Consumers: consumers})
	files[path] = document
}

func both() []string   { return []string{"lua", "go"} }
func goOnly() []string { return []string{"go"} }

func fail(err error) {
	fmt.Fprintf(os.Stderr, "fixturegen: %v\n", err)
	os.Exit(1)
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: fixturegen <spec/protocol/v1>")
		os.Exit(2)
	}
	root := os.Args[1]

	writeCanonical()
	writeRejectedCanonical()
	writeHashVectors()
	writeDerivation()
	writeMessages()
	writeFrames()
	writeHandshakes()
	writeLimits()
	writeErrorCatalog()
	writeGatewayFrames()
	writeAccessTokens()

	for path, document := range files {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			fail(err)
		}
		if err := os.WriteFile(full, []byte(pretty(document)+"\n"), 0o644); err != nil {
			fail(err)
		}
	}

	sort.Slice(entries, func(left, right int) bool { return entries[left].Path < entries[right].Path })
	listed := make(protocol.Array, 0, len(entries))
	for _, entry := range entries {
		consumers := make(protocol.Array, 0, len(entry.Consumers))
		for _, consumer := range entry.Consumers {
			consumers = append(consumers, consumer)
		}
		listed = append(listed, protocol.Object{
			"path":      entry.Path,
			"kind":      entry.Kind,
			"expect":    entry.Expect,
			"consumers": consumers,
		})
	}
	manifest := protocol.Object{
		"schema":       int64(1),
		"wire_version": protocol.Version,
		"fixtures":     listed,
	}
	if err := os.WriteFile(filepath.Join(root, "manifest.json"), []byte(pretty(manifest)+"\n"), 0o644); err != nil {
		fail(err)
	}
	fmt.Printf("wrote %d fixture files and the manifest\n", len(files))
}
