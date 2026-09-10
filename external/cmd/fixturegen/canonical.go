package main

import (
	"encoding/hex"
	"fmt"
	"strings"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// writeCanonical records inputs whose decode-then-encode round trip must
// produce the canonical text byte for byte in both languages.
func writeCanonical() {
	inputs := []struct{ name, text string }{
		{"empty object", `{}`},
		{"empty array", `[]`},
		{"keys sort by unsigned byte order", `{"b":1,"A":2,"a":3,"_":4}`},
		{"nested containers keep array order", `{"z":[3,1,2],"a":{"y":true,"x":null}}`},
		{"insignificant whitespace is dropped", "  {\n  \"a\" : [ 1 , 2 ]\n}  "},
		{"negative zero and the exact maximum", `{"n":-42,"z":-0,"p":9007199254740991}`},
		{"the exact minimum", `{"n":-9007199254740991}`},
		{"control characters escape lowercase", `{"s":"a\nb\tc\u0000d"}`},
		{"quote and backslash escape", `{"s":"say \"hi\" \\ bye"}`},
		{"solidus is emitted unescaped", `{"s":"a\/b"}`},
		{"multibyte utf8 survives", `{"s":"café 日本"}`},
		{"surrogate pair becomes one scalar", `{"s":"😀"}`},
		{"escaped ascii key normalizes and re-sorts", `{"b":1,"a":2}`},
		{"booleans and null", `[true,false,null]`},
		{"nesting exactly at the depth limit", strings.Repeat("[", 16) + strings.Repeat("]", 16)},
		{"an object holding every scalar type", `{"i":0,"s":"","b":false,"n":null,"a":[],"o":{}}`},
	}

	cases := make(protocol.Array, 0, len(inputs))
	for _, input := range inputs {
		value, err := protocol.Decode(input.text, protocol.DefaultLimits())
		if err != nil {
			fail(fmt.Errorf("canonical case %q: %w", input.name, err))
		}
		canonical, err := protocol.Encode(value)
		if err != nil {
			fail(fmt.Errorf("canonical case %q: %w", input.name, err))
		}
		cases = append(cases, protocol.Object{
			"name":      input.name,
			"text":      input.text,
			"canonical": canonical,
		})
	}
	record("cj1/canonical.json", "cj1", "valid", both(), protocol.Object{
		"schema": int64(1),
		"note":   "Decode text, re-encode it, and compare against canonical byte for byte.",
		"cases":  cases,
	})
}

// writeRejectedCanonical records inputs the canonical form cannot round trip.
// Each names the exact catalog code both languages must produce.
func writeRejectedCanonical() {
	rejections := []struct{ name, text, code string }{
		{"duplicate key", `{"a":1,"a":2}`, protocol.CodeInvalidMessage},
		{"duplicate key hidden behind an escape", `{"\u0061":1,"a":2}`, protocol.CodeInvalidMessage},
		{"fractional number", `{"n":1.5}`, protocol.CodeInvalidMessage},
		{"exponent number", `{"n":1e3}`, protocol.CodeInvalidMessage},
		{"integer above the exact range", `{"n":9007199254740992}`, protocol.CodeInvalidMessage},
		{"integer below the exact range", `{"n":-9007199254740992}`, protocol.CodeInvalidMessage},
		{"leading zero", `{"n":01}`, protocol.CodeInvalidMessage},
		{"sparse array", `[1,,2]`, protocol.CodeInvalidMessage},
		{"trailing comma in an array", `[1,2,]`, protocol.CodeInvalidMessage},
		{"trailing comma in an object", `{"a":1,}`, protocol.CodeInvalidMessage},
		{"unquoted key", `{a:1}`, protocol.CodeInvalidMessage},
		{"single quoted key", `{'a':1}`, protocol.CodeInvalidMessage},
		{"unescaped control character", "{\"s\":\"a\tb\"}", protocol.CodeInvalidMessage},
		{"lone high surrogate", `{"s":"\ud83d"}`, protocol.CodeInvalidMessage},
		{"lone low surrogate", `{"s":"\ude00"}`, protocol.CodeInvalidMessage},
		{"unknown escape", `{"s":"\x41"}`, protocol.CodeInvalidMessage},
		{"trailing data", `{"a":1} {"b":2}`, protocol.CodeInvalidMessage},
		{"empty input", ``, protocol.CodeInvalidMessage},
		{"bare identifier", `undefined`, protocol.CodeInvalidMessage},
		{"unterminated object", `{"a":1`, protocol.CodeInvalidMessage},
		{"unterminated string", `{"a":"b`, protocol.CodeInvalidMessage},
		{"nesting one past the depth limit", strings.Repeat("[", 17) + strings.Repeat("]", 17), protocol.CodeMessageTooLarge},
	}

	cases := make(protocol.Array, 0, len(rejections))
	for _, item := range rejections {
		if _, err := protocol.Decode(item.text, protocol.DefaultLimits()); err == nil {
			fail(fmt.Errorf("rejection case %q unexpectedly decoded", item.name))
		} else if got := protocol.CodeOf(err); got != item.code {
			fail(fmt.Errorf("rejection case %q produced %s, want %s", item.name, got, item.code))
		}
		cases = append(cases, protocol.Object{"name": item.name, "text": item.text, "error": item.code})
	}
	record("cj1/rejected.json", "cj1", "invalid", both(), protocol.Object{
		"schema": int64(1),
		"note":   "Each text must be rejected with exactly this catalog code.",
		"cases":  cases,
	})
}

// writeHashVectors carries published SHA-256 and HMAC-SHA-256 vectors so the
// pure-Lua implementation is checked against its standards, not against Go.
func writeHashVectors() {
	sha := protocol.Array{
		protocol.Object{"name": "empty input", "input_hex": "",
			"digest": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"},
		protocol.Object{"name": "abc", "input_hex": hex.EncodeToString([]byte("abc")),
			"digest": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"},
		protocol.Object{"name": "two block message",
			"input_hex": hex.EncodeToString([]byte("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")),
			"digest":    "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"},
		protocol.Object{"name": "one million a", "input_repeat": "a", "input_repeat_count": int64(1000000),
			"digest": "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"},
		protocol.Object{"name": "padding boundary 55", "input_repeat": "a", "input_repeat_count": int64(55),
			"digest": "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"},
		protocol.Object{"name": "padding boundary 56", "input_repeat": "a", "input_repeat_count": int64(56),
			"digest": "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"},
		protocol.Object{"name": "padding boundary 64", "input_repeat": "a", "input_repeat_count": int64(64),
			"digest": "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"},
	}
	record("hash/sha256.json", "sha256", "valid", both(), protocol.Object{
		"schema": int64(1),
		"source": "NIST FIPS 180-4 examples and standard padding-boundary digests",
		"note":   "A case supplies either input_hex or an input_repeat pair.",
		"cases":  sha,
	})

	macs := protocol.Array{
		protocol.Object{"name": "rfc4231 case 1", "key_hex": strings.Repeat("0b", 20),
			"message_hex": hex.EncodeToString([]byte("Hi There")),
			"mac":         "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"},
		protocol.Object{"name": "rfc4231 case 2", "key_hex": hex.EncodeToString([]byte("Jefe")),
			"message_hex": hex.EncodeToString([]byte("what do ya want for nothing?")),
			"mac":         "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"},
		protocol.Object{"name": "rfc4231 case 3", "key_hex": strings.Repeat("aa", 20),
			"message_hex": strings.Repeat("dd", 50),
			"mac":         "773ea91e36800e46854db8ebd09181a72959098b3ef8c122d9635514ced565fe"},
		protocol.Object{"name": "rfc4231 case 4", "key_hex": "0102030405060708090a0b0c0d0e0f10111213141516171819",
			"message_hex": strings.Repeat("cd", 50),
			"mac":         "82558a389a443c0ea4cc819899f2083a85f0faa3e578f8077a2e3ff46729665b"},
		protocol.Object{"name": "rfc4231 case 6 key longer than the block", "key_hex": strings.Repeat("aa", 131),
			"message_hex": hex.EncodeToString([]byte("Test Using Larger Than Block-Size Key - Hash Key First")),
			"mac":         "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"},
		protocol.Object{"name": "rfc4231 case 7 long key and long message", "key_hex": strings.Repeat("aa", 131),
			"message_hex": hex.EncodeToString([]byte("This is a test using a larger than block-size key and a larger than block-size data. The key needs to be hashed before being used by the HMAC algorithm.")),
			"mac":         "9b09ffa71b942fcb27635fbcd5b0e944bfdc63644f0713938a7f51535c3a35e2"},
	}
	record("hash/hmac-sha256.json", "hmac_sha256", "valid", both(), protocol.Object{
		"schema": int64(1),
		"source": "RFC 4231 test cases 1, 2, 3, 4, 6, and 7",
		"cases":  macs,
	})
}
