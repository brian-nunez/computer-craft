package main

import (
	"fmt"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

func sampleSource() protocol.Object {
	return protocol.Object{
		"computer_id":         "cmp-harvester",
		"customer_network_id": "net-farm",
		"local_address":       "192.168.1.20",
	}
}

func sampleISPConfiguration() protocol.Object {
	return protocol.Object{
		"isp_id":              "isp-acme",
		"isp_name":            "acme",
		"operational_channel": int64(2100),
		"provider_allocations": protocol.Array{
			protocol.Object{"first": "100.64.0.0", "last": "100.64.255.255"},
		},
	}
}

func sampleRouterConfiguration() protocol.Object {
	return protocol.Object{
		"customer_network_id":     "net-farm",
		"customer_network_name":   "farm",
		"router_address":          "192.168.1.1",
		"dns_address":             "192.168.1.1",
		"pool_first":              "192.168.1.20",
		"pool_last":               "192.168.1.200",
		"lan_operational_channel": int64(3100),
		"provider_address":        "100.64.7.9",
		"isp_id":                  "isp-acme",
		"bindings": protocol.Array{
			protocol.Object{"computer_id": "cmp-harvester", "hostname": "harvester", "address": "192.168.1.20"},
		},
	}
}

// writeMessages records one representative accepted body for every v1 message
// kind, and a rejection for every scalar and structural rule that matters.
func writeMessages() {
	accepted := []struct {
		name      string
		transport string
		kind      string
		body      protocol.Object
	}{
		{"discover", "discovery", "discover", protocol.Object{
			"role": "computer", "client_nonce": fixtureClientNonce}},
		{"offer", "discovery", "offer", protocol.Object{
			"parent_id": "rtr-farm", "parent_role": "router", "display_name": "Farm Router",
			"discovery_channel": int64(65000), "client_nonce": fixtureClientNonce}},
		{"enroll_open first join", "handshake", "enroll_open", protocol.Object{
			"role": "computer", "requested_name": "harvester", "client_nonce": fixtureClientNonce}},
		{"enroll_open re-enrollment", "handshake", "enroll_open", protocol.Object{
			"role": "computer", "requested_name": "harvester",
			"client_id": "cmp-harvester", "client_nonce": fixtureClientNonce}},
		{"enroll_challenge", "handshake", "enroll_challenge", protocol.Object{
			"parent_id": "rtr-farm", "relationship_id": "rel-farm-0007",
			"client_nonce": fixtureClientNonce, "parent_nonce": fixtureParentNonce,
			"parent_revision": int64(4)}},
		{"enroll_confirm", "handshake", "enroll_confirm", protocol.Object{
			"relationship_id": "rel-farm-0007", "client_nonce": fixtureClientNonce,
			"parent_nonce": fixtureParentNonce, "child_revision": int64(0)}},
		{"enroll_accept", "handshake", "enroll_accept", protocol.Object{
			"child_id": "cmp-harvester", "relationship_id": "rel-farm-0007",
			"operational_channel": int64(3100), "parent_revision": int64(4),
			"configuration": protocol.Object{
				"computer_id": "cmp-harvester", "hostname": "harvester",
				"address": "192.168.1.20", "customer_network_id": "net-farm",
				"router_address": "192.168.1.1", "dns_address": "192.168.1.1"}}},
		{"enroll_error", "handshake", "enroll_error", protocol.Object{
			"code": "name_conflict", "message": "That hostname is already taken on this network.",
			"retryable": false}},
		{"session_open", "handshake", "session_open", protocol.Object{
			"relationship_id": "rel-farm-0007", "client_nonce": fixtureSessionNonce,
			"child_revision": int64(3)}},
		{"session_challenge", "handshake", "session_challenge", protocol.Object{
			"relationship_id": "rel-farm-0007", "session_id": "ses-000042",
			"client_nonce": fixtureSessionNonce, "parent_nonce": fixtureParentSession,
			"parent_revision": int64(4)}},
		{"session_confirm", "handshake", "session_confirm", protocol.Object{
			"relationship_id": "rel-farm-0007", "session_id": "ses-000042",
			"client_nonce": fixtureSessionNonce, "parent_nonce": fixtureParentSession}},
		{"heartbeat", "operational", "heartbeat", protocol.Object{
			"connectivity_state": "ready", "revision": int64(4)}},
		{"ack without a revision", "operational", "ack", protocol.Object{
			"acked_request_id": "req-104"}},
		{"ack with a revision", "operational", "ack", protocol.Object{
			"acked_request_id": "req-104", "result_revision": int64(5)}},
		{"config_request", "operational", "config_request", protocol.Object{
			"known_revision": int64(0)}},
		{"config_snapshot for a router", "operational", "config_snapshot", protocol.Object{
			"revision": int64(4), "role": "router", "configuration": sampleRouterConfiguration()}},
		{"config_snapshot for an isp", "operational", "config_snapshot", protocol.Object{
			"revision": int64(9), "role": "isp", "configuration": sampleISPConfiguration()}},
		{"config_snapshot for central", "operational", "config_snapshot", protocol.Object{
			"revision": int64(2), "role": "central", "configuration": protocol.Object{
				"world_id": "world-overworld", "central_id": "central-overworld",
				"gateway_url": "wss://craftnet.example/gateway", "gateway_credential_ref": "gwc-0001",
				"provider_allocations": protocol.Array{
					protocol.Object{"first": "100.64.0.0", "last": "100.127.255.255"}}}}},
		{"dns_query", "operational", "dns_query", protocol.Object{
			"name": "harvester.farm.acme.craft"}},
		{"dns_result", "operational", "dns_result", protocol.Object{
			"canonical_name": "harvester.farm.acme.craft", "customer_network_id": "net-farm",
			"computer_id": "cmp-harvester", "address": "192.168.1.20"}},
		{"route_register", "operational", "route_register", protocol.Object{
			"customer_network_id": "net-farm", "customer_network_name": "farm",
			"router_id": "rtr-farm", "router_provider_address": "100.64.7.9",
			"isp_id": "isp-acme", "revision": int64(11)}},
		{"route_remove", "operational", "route_remove", protocol.Object{
			"customer_network_id": "net-farm", "revision": int64(12)}},
		{"service_request to a hostname", "operational", "service_request", protocol.Object{
			"source":      sampleSource(),
			"destination": protocol.Object{"customer_network_id": "net-home", "computer_id": "cmp-kitchen"},
			"service":     "inventory.read",
			"payload":     protocol.Object{"slot": int64(3), "unknown_application_field": true}}},
		{"service_request to an address with flows", "operational", "service_request", protocol.Object{
			"source":         sampleSource(),
			"destination":    protocol.Object{"customer_network_id": "net-home", "address": "192.168.1.21"},
			"service":        "inventory.read",
			"payload":        protocol.Object{},
			"source_flow_id": "flow-a1", "destination_flow_id": "flow-b2"}},
		{"service_response", "operational", "service_response", protocol.Object{
			"payload": protocol.Object{"items": protocol.Array{}}, "source_flow_id": "flow-a1"}},
		{"error with details", "operational", "error", protocol.Object{
			"code": "route_not_found", "message": "That network is not reachable right now.",
			"retryable": false, "details": protocol.Object{"customer_network_id": "net-home"}}},
		{"topology_snapshot", "gateway", "topology_snapshot", protocol.Object{
			"revision": int64(31),
			"world":    protocol.Object{"world_id": "world-overworld", "display_name": "Overworld"},
			"isps": protocol.Array{
				protocol.Object{"isp_id": "isp-acme", "display_name": "Acme"}},
			"routers": protocol.Array{
				protocol.Object{"router_id": "rtr-farm", "isp_id": "isp-acme"}},
			"computers": protocol.Array{
				protocol.Object{"computer_id": "cmp-harvester", "customer_network_id": "net-farm"}},
			"network_statuses": protocol.Array{
				protocol.Object{"customer_network_id": "net-farm", "status": "enabled"}}}},
		{"topology_change", "gateway", "topology_change", protocol.Object{
			"revision": int64(32), "change": "added", "entity_type": "computer",
			"entity": protocol.Object{"computer_id": "cmp-silo", "customer_network_id": "net-farm"}}},
		{"traffic_batch", "gateway", "traffic_batch", protocol.Object{
			"first_sequence": int64(880), "last_sequence": int64(881),
			"events": protocol.Array{
				protocol.Object{
					"event_id": "evt-880", "observed_at_ms": int64(1024000), "world_id": "world-overworld",
					"direction": "outbound", "kind": "service_request", "outcome": "delivered",
					"bytes": int64(240), "customer_network_id": "net-farm", "computer_id": "cmp-harvester"},
				protocol.Object{
					"event_id": "evt-881", "observed_at_ms": int64(1024500), "world_id": "world-overworld",
					"direction": "inbound", "kind": "service_response", "outcome": "request_timeout",
					"bytes": int64(0), "request_id": "req-104"}}}},
		{"network_status_set", "operational", "network_status_set", protocol.Object{
			"command_id": "cmd-0009", "customer_network_id": "net-farm", "status": "disabled"}},
		{"command_result applied", "gateway", "command_result", protocol.Object{
			"command_id": "cmd-0009", "status": "applied", "revision": int64(33)}},
		{"command_result rejected", "gateway", "command_result", protocol.Object{
			"command_id": "cmd-0010", "status": "rejected", "revision": int64(33),
			"error": protocol.Object{"code": "revision_conflict",
				"message": "The dashboard was showing an older state.", "retryable": true}}},
		{"external_request for an ordinary operation", "gateway", "external_request", protocol.Object{
			"ancestry": protocol.Object{
				"world_id": "world-overworld", "isp_id": "isp-acme",
				"customer_network_id": "net-farm", "router_id": "rtr-farm",
				"computer_id": "cmp-harvester", "local_address": "192.168.1.20"},
			"source_flow_id": "flow-a1", "operation": "market.quote",
			"access_token": "opaque.bearer.token",
			"payload":      protocol.Object{"symbol": "wheat"}}},
		{"external_request registering a device", "gateway", "external_request", protocol.Object{
			"ancestry": protocol.Object{
				"world_id": "world-overworld", "isp_id": "isp-acme",
				"customer_network_id": "net-farm", "router_id": "rtr-farm",
				"computer_id": "cmp-harvester", "local_address": "192.168.1.20"},
			"source_flow_id": "flow-a2", "operation": "device.register",
			"registration_nonce": fixtureClientNonce,
			"payload":            protocol.Object{}}},
		{"external_request issuing a token", "gateway", "external_request", protocol.Object{
			"ancestry": protocol.Object{
				"world_id": "world-overworld", "isp_id": "isp-acme",
				"customer_network_id": "net-farm", "router_id": "rtr-farm",
				"computer_id": "cmp-harvester", "local_address": "192.168.1.20"},
			"source_flow_id": "flow-a3", "operation": "token.issue",
			"device_credential": "opaque-device-credential",
			"payload":           protocol.Object{}}},
		{"external_response", "gateway", "external_response", protocol.Object{
			"payload": protocol.Object{"price": int64(19), "currency": "emerald"}}},
		{"admin_command", "gateway", "admin_command", protocol.Object{
			"action": "set_network_status", "customer_network_id": "net-farm", "status": "enabled"}},
	}

	acceptedCases := make(protocol.Array, 0, len(accepted))
	for _, item := range accepted {
		if err := protocol.ValidateBody(item.kind, item.body); err != nil {
			fail(fmt.Errorf("accepted message %q: %w", item.name, err))
		}
		if !protocol.Allows(protocol.Transport(item.transport), item.kind) {
			fail(fmt.Errorf("accepted message %q: %s does not carry %s", item.name, item.transport, item.kind))
		}
		acceptedCases = append(acceptedCases, protocol.Object{
			"name": item.name, "transport": item.transport, "kind": item.kind,
			"body": protocol.MustEncode(item.body),
		})
	}
	record("messages/accepted.json", "message", "valid", both(), protocol.Object{
		"schema": int64(1),
		"note": "Decode body, validate it against kind, and confirm transport carries kind. " +
			"Every case must be accepted.",
		"cases": acceptedCases,
	})

	rejected := []struct {
		name, kind, body, code string
	}{
		{"unknown kind", "not_a_kind", `{}`, protocol.CodeInvalidMessage},
		{"missing required field", "heartbeat", `{"connectivity_state":"ready"}`, protocol.CodeInvalidMessage},
		{"unknown field", "heartbeat", `{"connectivity_state":"ready","revision":1,"extra":true}`, protocol.CodeInvalidMessage},
		{"optional field encoded as an empty substitute", "ack", `{"acked_request_id":"req-1","result_revision":null}`, protocol.CodeInvalidMessage},
		{"enum outside the set", "heartbeat", `{"connectivity_state":"online","revision":1}`, protocol.CodeInvalidMessage},
		{"revision must not be negative", "heartbeat", `{"connectivity_state":"ready","revision":-1}`, protocol.CodeInvalidMessage},
		{"identifier with an uppercase letter", "ack", `{"acked_request_id":"Req-1"}`, protocol.CodeInvalidMessage},
		{"identifier starting with a hyphen", "ack", `{"acked_request_id":"-req"}`, protocol.CodeInvalidMessage},
		{"identifier that is empty", "ack", `{"acked_request_id":""}`, protocol.CodeInvalidMessage},
		{"nonce that is too short", "discover", `{"role":"computer","client_nonce":"aabb"}`, protocol.CodeInvalidMessage},
		{"nonce in uppercase hex", "discover",
			`{"role":"computer","client_nonce":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}`,
			protocol.CodeInvalidMessage},
		{"role outside the set", "discover",
			`{"role":"gateway","client_nonce":"` + fixtureClientNonce + `"}`, protocol.CodeInvalidMessage},
		{"channel above the modem range", "offer",
			`{"parent_id":"rtr-farm","parent_role":"router","display_name":"Farm","discovery_channel":70000,"client_nonce":"` + fixtureClientNonce + `"}`,
			protocol.CodeInvalidMessage},
		{"customer address outside rfc 1918", "dns_result",
			`{"canonical_name":"h.farm.acme.craft","customer_network_id":"net-farm","computer_id":"cmp-h","address":"8.8.8.8"}`,
			protocol.CodeInvalidMessage},
		{"provider address outside rfc 6598", "route_register",
			`{"customer_network_id":"net-farm","customer_network_name":"farm","router_id":"rtr-farm","router_provider_address":"10.0.0.1","isp_id":"isp-acme","revision":1}`,
			protocol.CodeInvalidMessage},
		{"normalized name ending in a hyphen", "enroll_open",
			`{"role":"computer","requested_name":"harvester-","client_nonce":"` + fixtureClientNonce + `"}`,
			protocol.CodeInvalidMessage},
		{"normalized name with an uppercase letter", "enroll_open",
			`{"role":"computer","requested_name":"Harvester","client_nonce":"` + fixtureClientNonce + `"}`,
			protocol.CodeInvalidMessage},
		{"destination naming neither computer nor address", "service_request",
			`{"source":{"computer_id":"cmp-h","customer_network_id":"net-farm","local_address":"192.168.1.20"},"destination":{"customer_network_id":"net-home"},"service":"s.read","payload":{}}`,
			protocol.CodeInvalidMessage},
		{"destination naming both computer and address", "service_request",
			`{"source":{"computer_id":"cmp-h","customer_network_id":"net-farm","local_address":"192.168.1.20"},"destination":{"customer_network_id":"net-home","computer_id":"cmp-k","address":"192.168.1.21"},"service":"s.read","payload":{}}`,
			protocol.CodeInvalidMessage},
		{"configuration that does not match its role", "config_snapshot",
			`{"revision":1,"role":"isp","configuration":{"computer_id":"cmp-h","hostname":"h","address":"192.168.1.20","customer_network_id":"net-farm","router_address":"192.168.1.1","dns_address":"192.168.1.1"}}`,
			protocol.CodeInvalidMessage},
		{"traffic batch whose range disagrees with its events", "traffic_batch",
			`{"first_sequence":1,"last_sequence":5,"events":[{"event_id":"evt-1","observed_at_ms":0,"world_id":"world-o","direction":"local","kind":"heartbeat","outcome":"delivered","bytes":0}]}`,
			protocol.CodeInvalidMessage},
		{"traffic event carrying a payload", "traffic_batch",
			`{"first_sequence":1,"last_sequence":1,"events":[{"event_id":"evt-1","observed_at_ms":0,"world_id":"world-o","direction":"local","kind":"heartbeat","outcome":"delivered","bytes":0,"payload":{"secret":"value"}}]}`,
			protocol.CodeInvalidMessage},
		{"admin command outside the v1 allowlist", "admin_command",
			`{"action":"delete_world","customer_network_id":"net-farm","status":"enabled"}`,
			protocol.CodeInvalidMessage},
		{"device registration also presenting a token", "external_request",
			`{"ancestry":{"world_id":"world-o","isp_id":"isp-a","customer_network_id":"net-farm","router_id":"rtr-farm","computer_id":"cmp-h","local_address":"192.168.1.20"},"source_flow_id":"flow-a","operation":"device.register","registration_nonce":"` + fixtureClientNonce + `","access_token":"t","payload":{}}`,
			protocol.CodeInvalidMessage},
		{"ordinary operation presenting a device credential", "external_request",
			`{"ancestry":{"world_id":"world-o","isp_id":"isp-a","customer_network_id":"net-farm","router_id":"rtr-farm","computer_id":"cmp-h","local_address":"192.168.1.20"},"source_flow_id":"flow-a","operation":"market.quote","device_credential":"c","payload":{}}`,
			protocol.CodeInvalidMessage},
		{"body that is an array", "heartbeat", `[]`, protocol.CodeInvalidMessage},
		{"body that is a string", "heartbeat", `"ready"`, protocol.CodeInvalidMessage},
	}

	rejectedCases := make(protocol.Array, 0, len(rejected))
	for _, item := range rejected {
		value, err := protocol.Decode(item.body, protocol.DefaultLimits())
		if err != nil {
			fail(fmt.Errorf("rejected message %q did not decode: %w", item.name, err))
		}
		object, isObject := value.(protocol.Object)
		if isObject {
			err = protocol.ValidateBody(item.kind, object)
		} else {
			err = fmt.Errorf("not an object")
		}
		if err == nil {
			fail(fmt.Errorf("rejected message %q was accepted", item.name))
		}
		rejectedCases = append(rejectedCases, protocol.Object{
			"name": item.name, "kind": item.kind, "body": item.body, "error": item.code,
		})
	}
	record("messages/rejected.json", "message", "invalid", both(), protocol.Object{
		"schema": int64(1),
		"note":   "Decode body and validate it against kind. Every case must fail with this code.",
		"cases":  rejectedCases,
	})
}
