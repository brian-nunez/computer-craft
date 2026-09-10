// Package protocol implements the CraftNet v1 wire: canonical JSON, SHA-256 and
// HMAC-SHA-256, key derivation, strict message schemas, the operational frame,
// the Gateway envelope, Ed25519 Access Tokens, size limits, and the stable error
// catalog.
//
// It is one of two implementations of that wire. The other is the Lua package
// craftnet-protocol, and neither is the specification: the fixture catalog under
// spec/protocol/v1 is, both replay it, and CI fails if they disagree about a
// single case. See docs/protocol/v1.md for what the catalog encodes and why.
//
// Callers exchange semantic messages. Nothing above this package calculates a
// MAC, a counter, a body hash, or a canonical form.
package protocol
