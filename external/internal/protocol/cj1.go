package protocol

import (
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

// CraftNet Canonical JSON 1.
//
// CJ1 is both the strict wire decoder and the only representation ever handed
// to HMAC. Decoding rejects everything the canonical form cannot round trip --
// duplicate keys, fractional numbers, values outside the exact integer range,
// unescaped control characters, and invalid UTF-8 -- so that a signature always
// covers exactly the bytes a peer validated.

// ExactIntegerMaximum is JavaScript's exact integer range, which bounds every
// CraftNet protocol number.
const ExactIntegerMaximum int64 = 9007199254740991

// Null is the decoded form of a JSON null. It is a distinct type because a Go
// nil inside a map cannot be told apart from an absent field.
type Null struct{}

// Object is a decoded JSON object. Duplicate keys are rejected at decode time,
// and encoding sorts keys by unsigned UTF-8 byte order.
type Object map[string]any

// Array is a decoded JSON array. Element order is preserved exactly.
type Array []any

type decoder struct {
	text     string
	position int
	limits   StructuralLimits
}

// Decode parses CJ1 text into the strict value model.
func Decode(text string, limits StructuralLimits) (any, error) {
	state := &decoder{text: text, limits: limits.resolve()}
	value, err := state.parseValue(1)
	if err != nil {
		return nil, err
	}
	state.skipWhitespace()
	if state.position < len(state.text) {
		return nil, newError(CodeInvalidMessage, "trailing data after the top-level value")
	}
	return value, nil
}

func (d *decoder) skipWhitespace() {
	for d.position < len(d.text) {
		switch d.text[d.position] {
		case ' ', '\t', '\n', '\r':
			d.position++
		default:
			return
		}
	}
}

func (d *decoder) peek() byte {
	if d.position >= len(d.text) {
		return 0
	}
	return d.text[d.position]
}

func (d *decoder) parseValue(depth int) (any, error) {
	if depth > d.limits.Depth {
		return nil, newError(CodeMessageTooLarge, "nesting exceeds depth %d", d.limits.Depth)
	}
	d.skipWhitespace()
	if d.position >= len(d.text) {
		return nil, newError(CodeInvalidMessage, "unexpected end of input")
	}
	switch character := d.peek(); {
	case character == '{':
		return d.parseObject(depth)
	case character == '[':
		return d.parseArray(depth)
	case character == '"':
		return d.parseString()
	case character == '-' || (character >= '0' && character <= '9'):
		return d.parseNumber()
	case strings.HasPrefix(d.text[d.position:], "true"):
		d.position += 4
		return true, nil
	case strings.HasPrefix(d.text[d.position:], "false"):
		d.position += 5
		return false, nil
	case strings.HasPrefix(d.text[d.position:], "null"):
		d.position += 4
		return Null{}, nil
	}
	return nil, newError(CodeInvalidMessage, "unexpected token at byte %d", d.position+1)
}

func (d *decoder) parseObject(depth int) (any, error) {
	d.position++ // consume '{'
	result := Object{}
	d.skipWhitespace()
	if d.peek() == '}' {
		d.position++
		return result, nil
	}
	count := 0
	for {
		d.skipWhitespace()
		if d.peek() != '"' {
			return nil, newError(CodeInvalidMessage, "expected an object key at byte %d", d.position+1)
		}
		key, err := d.parseString()
		if err != nil {
			return nil, err
		}
		if _, exists := result[key]; exists {
			return nil, newError(CodeInvalidMessage, "duplicate object key %q", key)
		}
		count++
		if count > d.limits.ObjectKeys {
			return nil, newError(CodeMessageTooLarge, "object exceeds %d keys", d.limits.ObjectKeys)
		}
		d.skipWhitespace()
		if d.peek() != ':' {
			return nil, newError(CodeInvalidMessage, "expected ':' at byte %d", d.position+1)
		}
		d.position++
		value, err := d.parseValue(depth + 1)
		if err != nil {
			return nil, err
		}
		result[key] = value
		d.skipWhitespace()
		switch d.peek() {
		case ',':
			d.position++
		case '}':
			d.position++
			return result, nil
		default:
			return nil, newError(CodeInvalidMessage, "expected ',' or '}' at byte %d", d.position+1)
		}
	}
}

func (d *decoder) parseArray(depth int) (any, error) {
	d.position++ // consume '['
	result := Array{}
	d.skipWhitespace()
	if d.peek() == ']' {
		d.position++
		return result, nil
	}
	for {
		if len(result) >= d.limits.ArrayElements {
			return nil, newError(CodeMessageTooLarge, "array exceeds %d elements", d.limits.ArrayElements)
		}
		value, err := d.parseValue(depth + 1)
		if err != nil {
			return nil, err
		}
		result = append(result, value)
		d.skipWhitespace()
		switch d.peek() {
		case ',':
			d.position++
		case ']':
			d.position++
			return result, nil
		default:
			return nil, newError(CodeInvalidMessage, "expected ',' or ']' at byte %d", d.position+1)
		}
	}
}

func (d *decoder) parseString() (string, error) {
	d.position++ // consume '"'
	var builder strings.Builder
	for {
		if d.position >= len(d.text) {
			return "", newError(CodeInvalidMessage, "unterminated string")
		}
		character := d.text[d.position]
		switch {
		case character < 0x20:
			return "", newError(CodeInvalidMessage, "unescaped control character in string")
		case character == '"':
			d.position++
			value := builder.String()
			if len(value) > d.limits.StringBytes {
				return "", newError(CodeMessageTooLarge, "string exceeds %d bytes", d.limits.StringBytes)
			}
			if !utf8.ValidString(value) {
				return "", newError(CodeInvalidMessage, "string is not valid UTF-8")
			}
			return value, nil
		case character == '\\':
			d.position++
			if d.position >= len(d.text) {
				return "", newError(CodeInvalidMessage, "unterminated escape sequence")
			}
			escape := d.text[d.position]
			d.position++
			switch escape {
			case '"':
				builder.WriteByte('"')
			case '\\':
				builder.WriteByte('\\')
			case '/':
				builder.WriteByte('/')
			case 'b':
				builder.WriteByte('\b')
			case 'f':
				builder.WriteByte('\f')
			case 'n':
				builder.WriteByte('\n')
			case 'r':
				builder.WriteByte('\r')
			case 't':
				builder.WriteByte('\t')
			case 'u':
				codePoint, err := d.parseHex4()
				if err != nil {
					return "", err
				}
				if codePoint >= 0xd800 && codePoint <= 0xdbff {
					if !strings.HasPrefix(d.text[d.position:], `\u`) {
						return "", newError(CodeInvalidMessage, "high surrogate without a low surrogate")
					}
					d.position += 2
					low, err := d.parseHex4()
					if err != nil {
						return "", err
					}
					if low < 0xdc00 || low > 0xdfff {
						return "", newError(CodeInvalidMessage, "invalid low surrogate")
					}
					codePoint = 0x10000 + (codePoint-0xd800)*0x400 + (low - 0xdc00)
				} else if codePoint >= 0xdc00 && codePoint <= 0xdfff {
					return "", newError(CodeInvalidMessage, "unpaired low surrogate")
				}
				builder.WriteRune(rune(codePoint))
			default:
				return "", newError(CodeInvalidMessage, "unknown escape sequence")
			}
		default:
			start := d.position
			for d.position < len(d.text) {
				next := d.text[d.position]
				if next == '"' || next == '\\' || next < 0x20 {
					break
				}
				d.position++
			}
			builder.WriteString(d.text[start:d.position])
		}
	}
}

func (d *decoder) parseHex4() (int, error) {
	if d.position+4 > len(d.text) {
		return 0, newError(CodeInvalidMessage, "malformed \\u escape")
	}
	digits := d.text[d.position : d.position+4]
	value, err := strconv.ParseUint(digits, 16, 32)
	if err != nil {
		return 0, newError(CodeInvalidMessage, "malformed \\u escape")
	}
	d.position += 4
	return int(value), nil
}

func (d *decoder) parseNumber() (any, error) {
	start := d.position
	if d.peek() == '-' {
		d.position++
	}
	digitStart := d.position
	for d.position < len(d.text) && d.text[d.position] >= '0' && d.text[d.position] <= '9' {
		d.position++
	}
	if d.position == digitStart {
		return nil, newError(CodeInvalidMessage, "malformed number at byte %d", start+1)
	}
	digits := d.text[digitStart:d.position]
	if len(digits) > 1 && digits[0] == '0' {
		return nil, newError(CodeInvalidMessage, "number has a leading zero")
	}
	if next := d.peek(); next == '.' || next == 'e' || next == 'E' {
		return nil, newError(CodeInvalidMessage, "fractional and exponent numbers are not canonical")
	}
	value, err := strconv.ParseInt(d.text[start:d.position], 10, 64)
	if err != nil || value > ExactIntegerMaximum || value < -ExactIntegerMaximum {
		return nil, newError(CodeInvalidMessage, "number is outside the exact integer range")
	}
	return value, nil
}

// Encode renders value in canonical form.
func Encode(value any) (string, error) {
	var builder strings.Builder
	if err := encodeValue(value, 1, &builder); err != nil {
		return "", err
	}
	return builder.String(), nil
}

// MustEncode is for internal call sites that have already validated their input
// and must not silently sign a partial structure.
func MustEncode(value any) string {
	text, err := Encode(value)
	if err != nil {
		panic(err)
	}
	return text
}

func encodeValue(value any, depth int, builder *strings.Builder) error {
	if depth > Depth {
		return newError(CodeMessageTooLarge, "nesting exceeds depth %d", Depth)
	}
	switch typed := value.(type) {
	case Null:
		builder.WriteString("null")
	case nil:
		return newError(CodeInvalidMessage, "untyped nil is not canonical; use protocol.Null{}")
	case bool:
		if typed {
			builder.WriteString("true")
		} else {
			builder.WriteString("false")
		}
	case int64:
		return encodeInteger(typed, builder)
	case int:
		return encodeInteger(int64(typed), builder)
	case string:
		return encodeString(typed, builder)
	case Array:
		builder.WriteByte('[')
		for index, element := range typed {
			if index > 0 {
				builder.WriteByte(',')
			}
			if err := encodeValue(element, depth+1, builder); err != nil {
				return err
			}
		}
		builder.WriteByte(']')
	case Object:
		keys := make([]string, 0, len(typed))
		for key := range typed {
			keys = append(keys, key)
		}
		// Go compares strings bytewise, which is exactly CJ1's unsigned UTF-8
		// byte order.
		sort.Strings(keys)
		builder.WriteByte('{')
		for index, key := range keys {
			if index > 0 {
				builder.WriteByte(',')
			}
			if err := encodeString(key, builder); err != nil {
				return err
			}
			builder.WriteByte(':')
			if err := encodeValue(typed[key], depth+1, builder); err != nil {
				return err
			}
		}
		builder.WriteByte('}')
	default:
		return newError(CodeInvalidMessage, "values of type %T are not canonical", value)
	}
	return nil
}

func encodeInteger(value int64, builder *strings.Builder) error {
	if value > ExactIntegerMaximum || value < -ExactIntegerMaximum {
		return newError(CodeInvalidMessage, "only exact integers are canonical")
	}
	builder.WriteString(strconv.FormatInt(value, 10))
	return nil
}

const lowercaseHex = "0123456789abcdef"

func encodeString(value string, builder *strings.Builder) error {
	if !utf8.ValidString(value) {
		return newError(CodeInvalidMessage, "string is not valid UTF-8")
	}
	builder.WriteByte('"')
	for index := 0; index < len(value); index++ {
		character := value[index]
		switch {
		case character == '"':
			builder.WriteString(`\"`)
		case character == '\\':
			builder.WriteString(`\\`)
		case character < 0x20:
			builder.WriteString(`\u00`)
			builder.WriteByte(lowercaseHex[character>>4])
			builder.WriteByte(lowercaseHex[character&0x0f])
		default:
			builder.WriteByte(character)
		}
	}
	builder.WriteByte('"')
	return nil
}
