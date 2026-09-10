package main

import (
	"sort"
	"strconv"
	"strings"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// pretty renders a fixture document as indented JSON with sorted keys. The
// output is deliberately still strict CJ1 input: integers only, no duplicate
// keys, and lowercase control-character escapes, so that every fixture file can
// be read back by the same strict decoders it exercises.
func pretty(value any) string {
	var builder strings.Builder
	write(value, 0, &builder)
	return builder.String()
}

func write(value any, depth int, builder *strings.Builder) {
	indent := strings.Repeat("  ", depth+1)
	closing := strings.Repeat("  ", depth)

	switch typed := value.(type) {
	case protocol.Object:
		if len(typed) == 0 {
			builder.WriteString("{}")
			return
		}
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		builder.WriteString("{\n")
		for index, key := range keys {
			if index > 0 {
				builder.WriteString(",\n")
			}
			builder.WriteString(indent)
			builder.WriteString(protocol.MustEncode(key))
			builder.WriteString(": ")
			write(typed[key], depth+1, builder)
		}
		builder.WriteString("\n")
		builder.WriteString(closing)
		builder.WriteString("}")
	case protocol.Array:
		if len(typed) == 0 {
			builder.WriteString("[]")
			return
		}
		builder.WriteString("[\n")
		for index, element := range typed {
			if index > 0 {
				builder.WriteString(",\n")
			}
			builder.WriteString(indent)
			write(element, depth+1, builder)
		}
		builder.WriteString("\n")
		builder.WriteString(closing)
		builder.WriteString("]")
	case int:
		builder.WriteString(strconv.Itoa(typed))
	default:
		builder.WriteString(protocol.MustEncode(value))
	}
}
