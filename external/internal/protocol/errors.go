package protocol

import (
	"errors"
	"fmt"
)

// Error is a CraftNet protocol failure carrying a stable v1 catalog code.
type Error struct {
	Code    string
	Message string
}

func (e *Error) Error() string {
	return e.Code + ": " + e.Message
}

func newError(code, format string, arguments ...any) *Error {
	return &Error{Code: code, Message: fmt.Sprintf(format, arguments...)}
}

// CodeOf reports the catalog code carried by err, or the empty string when err
// did not originate in this package.
func CodeOf(err error) string {
	if err == nil {
		return ""
	}
	var protocolError *Error
	if errors.As(err, &protocolError) {
		return protocolError.Code
	}
	return ""
}

// CatalogEntry describes one stable v1 error code.
type CatalogEntry struct {
	Code      string
	Retryable bool
	Meaning   string
}

// Catalog is the complete stable v1 error catalog. Codes change only through an
// explicit wire-version decision. Retryable describes whether a fresh attempt
// could succeed; it never authorizes automatic replay.
var Catalog = []CatalogEntry{
	{"invalid_message", false, "JSON, type, required-field, or canonical-form validation failed"},
	{"unsupported_version", false, "Peer does not implement the requested major version"},
	{"message_too_large", false, "Frame, payload, snapshot, or batch exceeds a limit"},
	{"busy", true, "Bounded in-flight capacity is exhausted"},
	{"authentication_failed", false, "Enrollment, session, Gateway, or device proof failed"},
	{"replay_rejected", false, "Session ID, nonce, request, or counter was reused or out of order"},
	{"credential_revoked", false, "Durable relationship, device, or Gateway credential is revoked"},
	{"access_token_expired", true, "The two-minute Access Token is expired"},
	{"forbidden_operation", false, "Credential is valid but does not authorize the operation"},
	{"name_not_found", false, "DNS name has no authoritative record"},
	{"name_conflict", false, "Requested ISP, network, or hostname already exists in its scope"},
	{"pool_exhausted", false, "No Customer or Provider Address is available"},
	{"address_conflict", false, "Address is already bound in the relevant scope"},
	{"router_unavailable", true, "Destination or local Customer Router is disconnected"},
	{"upstream_unavailable", true, "Immediate parent relationship is unavailable"},
	{"route_not_found", false, "Central route map has no destination Customer Network"},
	{"inbound_denied", false, "No matching Exposed Service permits a new remote request"},
	{"nat_flow_missing", false, "Reply refers to an expired or unknown NAT Flow"},
	{"network_disabled", false, "Central Network Status disables the Customer Network"},
	{"gateway_unavailable", true, "Central Server lacks a ready Gateway Session"},
	{"request_timeout", true, "No terminal response arrived before the operation deadline"},
	{"revision_conflict", true, "Command or update was based on stale authoritative state"},
	{"internal_error", true, "An unexpected owner-side failure occurred without exposing internals"},
}

var catalogByCode = func() map[string]CatalogEntry {
	index := make(map[string]CatalogEntry, len(Catalog))
	for _, entry := range Catalog {
		index[entry.Code] = entry
	}
	return index
}()

// KnownCode reports whether code is part of the stable v1 catalog.
func KnownCode(code string) bool {
	_, ok := catalogByCode[code]
	return ok
}

// Retryable reports whether a fresh attempt with this code could succeed.
func Retryable(code string) (bool, bool) {
	entry, ok := catalogByCode[code]
	return entry.Retryable, ok
}

// ErrorBody builds the wire body for an error message. message is player-safe
// prose; details carries only non-secret structured context.
func ErrorBody(code, message string, details Object) (Object, error) {
	entry, ok := catalogByCode[code]
	if !ok {
		return nil, newError(CodeInvalidMessage, "unknown error code %q", code)
	}
	if message == "" {
		message = entry.Meaning
	}
	body := Object{"code": code, "message": message, "retryable": entry.Retryable}
	if details != nil {
		body["details"] = details
	}
	return body, nil
}

// Stable v1 catalog codes referenced directly by this package.
const (
	CodeInvalidMessage     = "invalid_message"
	CodeUnsupportedVersion = "unsupported_version"
	CodeMessageTooLarge    = "message_too_large"
	CodeBusy               = "busy"
	CodeAuthenticationFail = "authentication_failed"
	CodeReplayRejected     = "replay_rejected"
	CodeCredentialRevoked  = "credential_revoked"
	CodeAccessTokenExpired = "access_token_expired"
	CodeForbiddenOperation = "forbidden_operation"
	CodeGatewayUnavailable = "gateway_unavailable"
	CodeRequestTimeout     = "request_timeout"
	CodeRevisionConflict   = "revision_conflict"
	CodeInternalError      = "internal_error"
)
