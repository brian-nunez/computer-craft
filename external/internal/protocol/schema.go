package protocol

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"
)

// Strict CraftNet v1 message schemas.
//
// Every authentication and control message is validated field by field before
// dispatch, and unknown fields are rejected. External Operation payload objects
// are the one deliberate exception: they are application defined and may carry
// fields this version has never seen.

// Version is the CraftNet wire major version implemented here.
const Version int64 = 1

var (
	idPattern            = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)
	normalizedOnePattern = regexp.MustCompile(`^[a-z0-9]$`)
	normalizedPattern    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]*[a-z0-9]$`)
	operationPattern     = regexp.MustCompile(`^[a-z0-9._-]+$`)
	hexPattern           = regexp.MustCompile(`^[0-9a-f]+$`)
	timestampPattern     = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$`)
)

type ruleFunc func(any) bool

func stringValue(value any) (string, bool) {
	text, ok := value.(string)
	return text, ok
}

// integerValue accepts both int and int64 so that a hand-built Object validates
// exactly as it encodes.
func integerValue(value any) (int64, bool) {
	switch number := value.(type) {
	case int64:
		return number, true
	case int:
		return int64(number), true
	}
	return 0, false
}

func isID(value any) bool {
	text, ok := stringValue(value)
	return ok && len(text) >= 1 && len(text) <= 64 && idPattern.MatchString(text)
}

// Normalized names are lowercase ASCII letters, digits, and internal hyphens,
// and they begin and end with a letter or digit.
func isNormalizedName(value any) bool {
	text, ok := stringValue(value)
	if !ok || len(text) < 1 || len(text) > 32 {
		return false
	}
	if len(text) == 1 {
		return normalizedOnePattern.MatchString(text)
	}
	return normalizedPattern.MatchString(text)
}

func isDisplayName(value any) bool {
	text, ok := stringValue(value)
	return ok && len(text) >= 1 && len(text) <= 32
}

func isOperationName(value any) bool {
	text, ok := stringValue(value)
	return ok && len(text) >= 1 && len(text) <= 64 && operationPattern.MatchString(text)
}

func isHex(value any, bytes int) bool {
	text, ok := stringValue(value)
	return ok && len(text) == bytes*2 && hexPattern.MatchString(text)
}

func isNonce(value any) bool  { return isHex(value, 32) }
func isDigest(value any) bool { return isHex(value, 32) }

func isInteger(value any) bool {
	_, ok := integerValue(value)
	return ok
}

func isNonNegative(value any) bool {
	number, ok := integerValue(value)
	return ok && number >= 0
}

func isPositive(value any) bool {
	number, ok := integerValue(value)
	return ok && number >= 1
}

func isChannel(value any) bool {
	number, ok := integerValue(value)
	return ok && number >= 0 && number <= 65535
}

func isBoolean(value any) bool {
	_, ok := value.(bool)
	return ok
}

func isObject(value any) bool {
	_, ok := value.(Object)
	return ok
}

func isArray(value any) bool {
	_, ok := value.(Array)
	return ok
}

func isString(value any) bool {
	_, ok := stringValue(value)
	return ok
}

func isTimestamp(value any) bool {
	text, ok := stringValue(value)
	return ok && timestampPattern.MatchString(text)
}

func octets(value any) ([4]int, bool) {
	var parts [4]int
	text, ok := stringValue(value)
	if !ok {
		return parts, false
	}
	pieces := strings.Split(text, ".")
	if len(pieces) != 4 {
		return parts, false
	}
	for index, piece := range pieces {
		if piece == "" || len(piece) > 3 {
			return parts, false
		}
		if len(piece) > 1 && piece[0] == '0' {
			return parts, false
		}
		number, err := strconv.Atoi(piece)
		if err != nil || number > 255 {
			return parts, false
		}
		parts[index] = number
	}
	return parts, true
}

// Customer addresses live in RFC 1918 space; overlapping reuse across Customer
// Networks is expected and is disambiguated by scope, never by the address.
func isCustomerAddress(value any) bool {
	parts, ok := octets(value)
	if !ok {
		return false
	}
	switch {
	case parts[0] == 10:
		return true
	case parts[0] == 172 && parts[1] >= 16 && parts[1] <= 31:
		return true
	case parts[0] == 192 && parts[1] == 168:
		return true
	}
	return false
}

// Provider Addresses live in the RFC 6598 shared space 100.64.0.0/10.
func isProviderAddress(value any) bool {
	parts, ok := octets(value)
	return ok && parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
}

func enumRule(allowed ...string) ruleFunc {
	set := make(map[string]struct{}, len(allowed))
	for _, name := range allowed {
		set[name] = struct{}{}
	}
	return func(value any) bool {
		text, ok := stringValue(value)
		if !ok {
			return false
		}
		_, member := set[text]
		return member
	}
}

var scalars = map[string]ruleFunc{
	"id":                 isID,
	"normalized_name":    isNormalizedName,
	"display_name":       isDisplayName,
	"operation_name":     isOperationName,
	"nonce":              isNonce,
	"digest":             isDigest,
	"integer":            isInteger,
	"non_negative":       isNonNegative,
	"revision":           isNonNegative,
	"positive":           isPositive,
	"channel":            isChannel,
	"boolean":            isBoolean,
	"object":             isObject,
	"array":              isArray,
	"string":             isString,
	"milliseconds":       isNonNegative,
	"timestamp":          isTimestamp,
	"customer_address":   isCustomerAddress,
	"provider_address":   isProviderAddress,
	"role":               enumRule("central", "isp", "router", "computer"),
	"connectivity_state": enumRule("connecting", "ready", "degraded", "disconnected", "revoked"),
	"network_status":     enumRule("enabled", "disabled"),
	"direction":          enumRule("inbound", "outbound", "local"),
	"topology_change":    enumRule("added", "updated", "removed"),
	"entity_type":        enumRule("isp", "customer_network", "router", "computer"),
	"command_status":     enumRule("applied", "rejected"),
}

// shape describes one object: its required and optional fields plus an optional
// consistency check that runs after every field validates.
type shape struct {
	required map[string]string
	optional map[string]string
	check    func(Object) (string, string)
}

// listOf marks a rule as "an array of this rule".
func listOf(rule string) string { return "[]" + rule }

var composites = map[string]shape{
	"source": {required: map[string]string{
		"computer_id": "id", "customer_network_id": "id", "local_address": "customer_address",
	}},
	"destination": {
		required: map[string]string{"customer_network_id": "id"},
		optional: map[string]string{"computer_id": "id", "address": "customer_address"},
		check: func(value Object) (string, string) {
			_, hasComputer := value["computer_id"]
			_, hasAddress := value["address"]
			if hasComputer == hasAddress {
				return "destination must contain exactly one of computer_id or address", ""
			}
			return "", ""
		},
	},
	"address_binding": {required: map[string]string{
		"computer_id": "id", "hostname": "normalized_name", "address": "customer_address",
	}},
	"provider_allocation": {required: map[string]string{
		"first": "provider_address", "last": "provider_address",
	}},
	"error_body": {
		required: map[string]string{"code": "string", "message": "string", "retryable": "boolean"},
		optional: map[string]string{"details": "object"},
	},
	"traffic_event": {
		required: map[string]string{
			"event_id": "id", "observed_at_ms": "milliseconds", "world_id": "id",
			"direction": "direction", "kind": "operation_name", "outcome": "operation_name",
			"bytes": "non_negative",
		},
		optional: map[string]string{
			"request_id": "id", "command_id": "id", "isp_id": "id",
			"customer_network_id": "id", "router_id": "id", "computer_id": "id",
			"operation": "operation_name",
		},
	},
	"ancestry": {required: map[string]string{
		"world_id": "id", "isp_id": "id", "customer_network_id": "id",
		"router_id": "id", "computer_id": "id", "local_address": "customer_address",
	}},
}

var configurations = map[string]shape{
	"computer": {required: map[string]string{
		"computer_id": "id", "hostname": "normalized_name", "address": "customer_address",
		"customer_network_id": "id", "router_address": "customer_address", "dns_address": "customer_address",
	}},
	"router": {
		required: map[string]string{
			"customer_network_id": "id", "customer_network_name": "normalized_name",
			"router_address": "customer_address", "dns_address": "customer_address",
			"pool_first": "customer_address", "pool_last": "customer_address",
			"lan_operational_channel": "channel", "provider_address": "provider_address",
			"isp_id": "id",
		},
		optional: map[string]string{"bindings": listOf("address_binding")},
	},
	"isp": {required: map[string]string{
		"isp_id": "id", "isp_name": "normalized_name",
		"provider_allocations": listOf("provider_allocation"), "operational_channel": "channel",
	}},
	"central": {required: map[string]string{
		"world_id": "id", "central_id": "id", "gateway_url": "string",
		"gateway_credential_ref": "id", "provider_allocations": listOf("provider_allocation"),
	}},
}

// What a parent assigns to a child is not the same as a child's complete
// configuration. An ISP owns a Customer Router's identity, name, and Provider
// Address; it does not own that router's LAN address, pool, or channel, and at
// enrollment it has never even been told them. So enroll_accept and
// config_snapshot validate against what the parent is authoritative for, while
// `configurations` stays the complete self-description a role publishes.
var assignments = map[string]shape{
	"computer": configurations["computer"],
	"router": {
		required: map[string]string{
			"customer_network_id":   "id",
			"customer_network_name": "normalized_name",
			"provider_address":      "provider_address",
			"isp_id":                "id",
		},
		optional: map[string]string{"operational_channel": "channel"},
	},
	"isp":     configurations["isp"],
	"central": configurations["central"],
}

// validateCredentialUse fixes which credential an operation may present.
// device.register offers the authenticated ancestry as its only attestation;
// every other combination is rejected rather than quietly preferred. The rule
// lives here because both legs of the external path enforce it: the in-world
// external_call a Computer sends, and the external_request the Central Server
// puts on the Gateway.
func validateCredentialUse(value Object) (string, string) {
	operation, _ := stringValue(value["operation"])
	_, hasToken := value["access_token"]
	_, hasCredential := value["device_credential"]
	_, hasNonce := value["registration_nonce"]
	wantToken, wantCredential, wantNonce := true, false, false
	switch operation {
	case "device.register":
		wantToken, wantCredential, wantNonce = false, false, true
	case "token.issue", "device.rotate":
		wantToken, wantCredential, wantNonce = false, true, false
	}
	if hasToken != wantToken || hasCredential != wantCredential || hasNonce != wantNonce {
		return fmt.Sprintf("operation %q does not permit this credential combination", operation), ""
	}
	return "", ""
}

var bodies = map[string]shape{
	"discover": {required: map[string]string{"role": "role", "client_nonce": "nonce"}},
	"offer": {required: map[string]string{
		"parent_id": "id", "parent_role": "role", "display_name": "display_name",
		"discovery_channel": "channel", "client_nonce": "nonce",
	}},
	"enroll_open": {
		required: map[string]string{"role": "role", "requested_name": "normalized_name", "client_nonce": "nonce"},
		optional: map[string]string{"client_id": "id"},
	},
	"enroll_challenge": {required: map[string]string{
		"parent_id": "id", "relationship_id": "id", "client_nonce": "nonce",
		"parent_nonce": "nonce", "parent_revision": "revision",
	}},
	"enroll_confirm": {required: map[string]string{
		"relationship_id": "id", "client_nonce": "nonce", "parent_nonce": "nonce",
		"child_revision": "revision",
	}},
	"enroll_accept": {required: map[string]string{
		"child_id": "id", "relationship_id": "id", "operational_channel": "channel",
		"configuration": "object", "parent_revision": "revision",
	}},
	"enroll_error": composites["error_body"],
	"session_open": {required: map[string]string{
		"relationship_id": "id", "client_nonce": "nonce", "child_revision": "revision",
	}},
	"session_challenge": {required: map[string]string{
		"relationship_id": "id", "session_id": "id", "client_nonce": "nonce",
		"parent_nonce": "nonce", "parent_revision": "revision",
	}},
	"session_confirm": {required: map[string]string{
		"relationship_id": "id", "session_id": "id", "client_nonce": "nonce", "parent_nonce": "nonce",
	}},
	"heartbeat": {required: map[string]string{"connectivity_state": "connectivity_state", "revision": "revision"}},
	"ack": {
		required: map[string]string{"acked_request_id": "id"},
		optional: map[string]string{"result_revision": "revision"},
	},
	"config_request": {required: map[string]string{"known_revision": "revision"}},
	"config_snapshot": {
		required: map[string]string{"revision": "revision", "role": "role", "configuration": "object"},
		check: func(value Object) (string, string) {
			role, _ := stringValue(value["role"])
			configuration, _ := value["configuration"].(Object)
			if err := ValidateAssignment(role, configuration); err != nil {
				return err.Error(), CodeOf(err)
			}
			return "", ""
		},
	},
	"dns_query": {required: map[string]string{"name": "string"}},
	"dns_result": {required: map[string]string{
		"canonical_name": "string", "customer_network_id": "id",
		"computer_id": "id", "address": "customer_address",
	}},
	"route_register": {required: map[string]string{
		"customer_network_id": "id", "customer_network_name": "normalized_name",
		"router_id": "id", "router_provider_address": "provider_address",
		"isp_id": "id", "revision": "revision",
	}},
	"route_remove": {required: map[string]string{"customer_network_id": "id", "revision": "revision"}},
	"service_request": {
		required: map[string]string{
			"source": "source", "destination": "destination",
			"service": "operation_name", "payload": "object",
		},
		optional: map[string]string{"source_flow_id": "id", "destination_flow_id": "id"},
	},
	"service_response": {
		required: map[string]string{"payload": "object"},
		optional: map[string]string{"source_flow_id": "id", "destination_flow_id": "id"},
	},
	// external_call is how a Computer names the External Application in world.
	// It carries no destination: a service_request destination is scoped to a
	// Customer Network, and the External Application is not one. The kind itself
	// is the destination. The answer comes back as an ordinary service_response,
	// so a reply retraces its NAT Flow by exactly one rule regardless of what it
	// answers.
	"external_call": {
		required: map[string]string{
			"source": "source", "operation": "operation_name", "payload": "object",
		},
		optional: map[string]string{
			"source_flow_id": "id", "access_token": "string",
			"device_credential": "string", "registration_nonce": "nonce",
		},
		check: validateCredentialUse,
	},
	"error": composites["error_body"],
	"topology_snapshot": {
		required: map[string]string{
			"revision": "revision", "world": "object", "isps": "array",
			"routers": "array", "computers": "array", "network_statuses": "array",
		},
		check: func(value Object) (string, string) {
			total := 0
			for _, field := range []string{"isps", "routers", "computers", "network_statuses"} {
				list, _ := value[field].(Array)
				total += len(list)
			}
			if total > TopologyEntities {
				return fmt.Sprintf("topology snapshot exceeds %d entities", TopologyEntities), CodeMessageTooLarge
			}
			return "", ""
		},
	},
	"topology_change": {required: map[string]string{
		"revision": "revision", "change": "topology_change",
		"entity_type": "entity_type", "entity": "object",
	}},
	"traffic_batch": {
		required: map[string]string{
			"first_sequence": "positive", "last_sequence": "positive",
			"events": listOf("traffic_event"),
		},
		check: func(value Object) (string, string) {
			events, _ := value["events"].(Array)
			if len(events) > TrafficBatchEvents {
				return fmt.Sprintf("batch exceeds %d events", TrafficBatchEvents), CodeMessageTooLarge
			}
			first, _ := integerValue(value["first_sequence"])
			last, _ := integerValue(value["last_sequence"])
			if last < first {
				return "last_sequence precedes first_sequence", ""
			}
			if last-first+1 != int64(len(events)) {
				return "sequence range does not match the event count", ""
			}
			return "", ""
		},
	},
	"network_status_set": {required: map[string]string{
		"command_id": "id", "customer_network_id": "id", "status": "network_status",
	}},
	"command_result": {
		required: map[string]string{"command_id": "id", "status": "command_status", "revision": "revision"},
		optional: map[string]string{"error": "error_body"},
	},
	"external_request": {
		required: map[string]string{
			"ancestry": "ancestry", "source_flow_id": "id",
			"operation": "operation_name", "payload": "object",
		},
		optional: map[string]string{
			"access_token": "string", "device_credential": "string", "registration_nonce": "nonce",
		},
		check: validateCredentialUse,
	},
	"external_response": {required: map[string]string{"payload": "object"}},
	"admin_command": {
		required: map[string]string{
			"action": "operation_name", "customer_network_id": "id", "status": "network_status",
		},
		check: func(value Object) (string, string) {
			if action, _ := stringValue(value["action"]); action != "set_network_status" {
				return "admin_command permits only set_network_status in v1", ""
			}
			return "", ""
		},
	},
}

// Transport names the channel a message kind may travel on.
type Transport string

const (
	// TransportDiscovery is unauthenticated by design and answers nothing in detail.
	TransportDiscovery Transport = "discovery"
	// TransportHandshake carries an outer proof instead of a session MAC.
	TransportHandshake Transport = "handshake"
	// TransportOperational frames are MACed under a live session key.
	TransportOperational Transport = "operational"
	// TransportGateway relies on WSS plus the authenticated Gateway Session.
	TransportGateway Transport = "gateway"
)

func kindSet(names ...string) map[string]struct{} {
	set := make(map[string]struct{}, len(names))
	for _, name := range names {
		set[name] = struct{}{}
	}
	return set
}

var transports = map[Transport]map[string]struct{}{
	TransportDiscovery: kindSet("discover", "offer"),
	TransportHandshake: kindSet("enroll_open", "enroll_challenge", "enroll_confirm",
		"enroll_accept", "enroll_error", "session_open", "session_challenge", "session_confirm"),
	TransportOperational: kindSet("heartbeat", "ack", "config_request", "config_snapshot",
		"dns_query", "dns_result", "route_register", "route_remove", "service_request",
		"service_response", "external_call", "error", "topology_snapshot", "topology_change",
		"traffic_batch", "network_status_set", "command_result"),
	TransportGateway: kindSet("heartbeat", "ack", "external_request", "external_response",
		"error", "topology_snapshot", "topology_change", "traffic_batch", "admin_command",
		"command_result"),
}

// IsKind reports whether kind is a defined v1 message kind.
func IsKind(kind string) bool {
	_, ok := bodies[kind]
	return ok
}

// Allows reports whether transport carries kind.
func Allows(transport Transport, kind string) bool {
	allowed, ok := transports[transport]
	if !ok {
		return false
	}
	_, member := allowed[kind]
	return member
}

func validateRule(rule string, value any, path string) error {
	if strings.HasPrefix(rule, "[]") {
		list, ok := value.(Array)
		if !ok {
			return newError(CodeInvalidMessage, "%s must be an array", path)
		}
		for index, element := range list {
			if err := validateRule(rule[2:], element, fmt.Sprintf("%s[%d]", path, index+1)); err != nil {
				return err
			}
		}
		return nil
	}
	if scalar, ok := scalars[rule]; ok {
		if !scalar(value) {
			return newError(CodeInvalidMessage, "%s is not a valid %s", path, rule)
		}
		return nil
	}
	if composite, ok := composites[rule]; ok {
		return validateShape(composite, value, path)
	}
	return newError(CodeInternalError, "unknown schema rule %q", rule)
}

func validateShape(definition shape, value any, path string) error {
	object, ok := value.(Object)
	if !ok {
		return newError(CodeInvalidMessage, "%s must be an object", path)
	}
	for field, rule := range definition.required {
		fieldValue, present := object[field]
		if !present {
			return newError(CodeInvalidMessage, "%s.%s is required", path, field)
		}
		if err := validateRule(rule, fieldValue, path+"."+field); err != nil {
			return err
		}
	}
	for field, rule := range definition.optional {
		// An optional field is omitted, never encoded as an empty substitute.
		if fieldValue, present := object[field]; present {
			if err := validateRule(rule, fieldValue, path+"."+field); err != nil {
				return err
			}
		}
	}
	for field := range object {
		_, isRequired := definition.required[field]
		_, isOptional := definition.optional[field]
		if !isRequired && !isOptional {
			return newError(CodeInvalidMessage, "%s has unknown field %q", path, field)
		}
	}
	if definition.check != nil {
		if message, code := definition.check(object); message != "" {
			if code == "" {
				code = CodeInvalidMessage
			}
			return newError(code, "%s", message)
		}
	}
	return nil
}

// ValidateConfiguration checks a role configuration snapshot.
func ValidateConfiguration(role string, configuration Object) error {
	definition, ok := configurations[role]
	if !ok {
		return newError(CodeInvalidMessage, "configuration role %q is unknown", role)
	}
	return validateShape(definition, configuration, "configuration")
}

// ValidateAssignment checks what a parent hands a child, which is narrower than
// that child's complete configuration wherever the child owns some of it.
func ValidateAssignment(role string, configuration Object) error {
	definition, ok := assignments[role]
	if !ok {
		return newError(CodeInvalidMessage, "assignment role %q is unknown", role)
	}
	return validateShape(definition, configuration, "configuration")
}

// ValidateBody checks one message body against its v1 schema.
func ValidateBody(kind string, body Object) error {
	definition, ok := bodies[kind]
	if !ok {
		return newError(CodeInvalidMessage, "unknown message kind %q", kind)
	}
	return validateShape(definition, body, "body")
}

// ValidateIdentifier checks one opaque CraftNet identity value. Identifiers are
// lowercase ASCII, 1 to 64 characters, and never embed a display name or an
// address.
func ValidateIdentifier(value string) error {
	if !isID(value) {
		return newError(CodeInvalidMessage, "%q is not a CraftNet identifier", value)
	}
	return nil
}

// IsOperationName reports whether value is a valid External Operation or
// service name: 1 to 64 lowercase letters, digits, dots, underscores, hyphens.
func IsOperationName(value string) bool {
	return isOperationName(value)
}
