package main

import (
	"fmt"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// writeLimits records the structural bounds as recipes rather than as literal
// text. A 16 KiB frame embedded in a fixture would itself exceed the 8 KiB
// string limit the fixture files are read under, so both languages build the
// input from the recipe and then assert the outcome.
//
// Recipes:
//   - string:         an object whose one value is `filler` repeated `length` times
//   - object_keys:    an object with `count` distinct keys
//   - array_elements: an array of `count` zeroes
//   - depth:          `count` nested arrays
//   - modem_frame:    an object of the form {"pad":["p"*c1,"p"*c2,...]} whose
//     encoded text is exactly `length` bytes. The padding is split into `chunks`
//     because no single string may exceed the 8 KiB string limit, so a frame at
//     the 16 KiB modem ceiling cannot be one long value.
//
// padChunks lays out the padding string lengths that make {"pad":[...]} encode
// to exactly total bytes, with no chunk exceeding half the string limit.
func padChunks(total int) protocol.Array {
	const prefix = len(`{"pad":[`)
	const suffix = len(`]}`)
	const maximumChunk = protocol.StringBytes / 2

	remaining := total - prefix - suffix
	chunks := protocol.Array{}
	for remaining > 0 {
		separator := 0
		if len(chunks) > 0 {
			separator = 1
		}
		size := remaining - 2 - separator
		if size > maximumChunk {
			size = maximumChunk
		}
		if size < 1 {
			fail(fmt.Errorf("cannot lay out padding for %d bytes", total))
		}
		chunks = append(chunks, int64(size))
		remaining -= 2 + separator + size
	}
	return chunks
}

func writeLimits() {
	cases := protocol.Array{
		protocol.Object{
			"name":   "a string exactly at the limit is accepted",
			"recipe": "string", "length": int64(protocol.StringBytes), "filler": "a",
			"expect": "accepted",
		},
		protocol.Object{
			"name":   "a string one byte past the limit is refused",
			"recipe": "string", "length": int64(protocol.StringBytes + 1), "filler": "a",
			"expect": protocol.CodeMessageTooLarge,
		},
		protocol.Object{
			"name":   "an object with exactly the maximum keys is accepted",
			"recipe": "object_keys", "count": int64(protocol.ObjectKeys),
			"expect": "accepted",
		},
		protocol.Object{
			"name":   "an object one key past the maximum is refused",
			"recipe": "object_keys", "count": int64(protocol.ObjectKeys + 1),
			"expect": protocol.CodeMessageTooLarge,
		},
		protocol.Object{
			"name":   "an array with exactly the maximum elements is accepted",
			"recipe": "array_elements", "count": int64(protocol.ArrayElements),
			"expect": "accepted",
		},
		protocol.Object{
			"name":   "an array one element past the maximum is refused",
			"recipe": "array_elements", "count": int64(protocol.ArrayElements + 1),
			"expect": protocol.CodeMessageTooLarge,
		},
		protocol.Object{
			"name":   "nesting exactly at the depth limit is accepted",
			"recipe": "depth", "count": int64(protocol.Depth),
			"expect": "accepted",
		},
		protocol.Object{
			"name":   "nesting one level past the limit is refused",
			"recipe": "depth", "count": int64(protocol.Depth + 1),
			"expect": protocol.CodeMessageTooLarge,
		},
		protocol.Object{
			"name":   "a modem frame exactly at the limit is accepted",
			"recipe": "modem_frame", "length": int64(protocol.ModemFrameBytes),
			"chunks": padChunks(protocol.ModemFrameBytes),
			"expect": "accepted",
		},
		protocol.Object{
			"name":   "a modem frame one byte past the limit is refused",
			"recipe": "modem_frame", "length": int64(protocol.ModemFrameBytes + 1),
			"chunks": padChunks(protocol.ModemFrameBytes + 1),
			"expect": protocol.CodeMessageTooLarge,
		},
	}

	record("limits/edges.json", "limits", "invalid", both(), protocol.Object{
		"schema": int64(1),
		"note": "Build each input from its recipe, then decode it. CraftNet performs no " +
			"fragmentation: an oversized caller is told to shrink its own payload.",
		"limits": protocol.Object{
			"modem_frame_bytes":      int64(protocol.ModemFrameBytes),
			"modem_payload_bytes":    int64(protocol.ModemPayloadBytes),
			"gateway_frame_bytes":    int64(protocol.GatewayFrameBytes),
			"traffic_batch_bytes":    int64(protocol.TrafficBatchBytes),
			"traffic_batch_events":   int64(protocol.TrafficBatchEvents),
			"topology_entities":      int64(protocol.TopologyEntities),
			"string_bytes":           int64(protocol.StringBytes),
			"depth":                  int64(protocol.Depth),
			"object_keys":            int64(protocol.ObjectKeys),
			"array_elements":         int64(protocol.ArrayElements),
			"relationship_in_flight": int64(protocol.RelationshipInFlight),
			"gateway_in_flight":      int64(protocol.GatewayInFlight),
			"access_token_seconds":   int64(protocol.AccessTokenSeconds),
		},
		"cases": cases,
	})
}

// writeErrorCatalog records the stable v1 catalog so that both implementations
// must carry exactly these codes, with exactly this retryability.
func writeErrorCatalog() {
	codes := make(protocol.Array, 0, len(protocol.Catalog))
	for _, entry := range protocol.Catalog {
		codes = append(codes, protocol.Object{
			"code":      entry.Code,
			"retryable": entry.Retryable,
			"meaning":   entry.Meaning,
		})
	}
	record("errors/catalog.json", "error_catalog", "valid", both(), protocol.Object{
		"schema": int64(1),
		"note": "Codes are wire constants. Retryable describes whether a fresh attempt could " +
			"succeed; it never authorizes automatic replay.",
		"codes": codes,
	})
}
