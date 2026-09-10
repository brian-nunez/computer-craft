package main

import (
	"crypto/ed25519"
	"encoding/hex"
	"fmt"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
)

// writeGatewayFrames records the Gateway handshake and frame shapes. CraftOS
// never speaks WebSocket -- only the Central Server's Go counterpart does -- so
// these are consumed by Go alone.
func writeGatewayFrames() {
	hello, err := protocol.EncodeGatewayHello(protocol.GatewayHello{
		WorldID: "world-overworld", CentralID: "central-overworld",
		LastTopologyRevision: 31, LastTrafficSequence: 879,
	})
	if err != nil {
		fail(err)
	}
	welcome, err := protocol.EncodeGatewayWelcome(protocol.GatewayWelcome{
		GatewaySessionID: "gws-000003", AcceptedTopologyRevision: 31,
		AcceptedTrafficSequence: 879, ServerTime: "2026-09-09T12:00:00Z",
	})
	if err != nil {
		fail(err)
	}

	externalRequest, err := protocol.EncodeGatewayFrame(protocol.GatewayFrame{
		Kind:      "external_request",
		RequestID: "req-104",
		Body: protocol.Object{
			"ancestry": protocol.Object{
				"world_id": "world-overworld", "isp_id": "isp-acme",
				"customer_network_id": "net-farm", "router_id": "rtr-farm",
				"computer_id": "cmp-harvester", "local_address": "192.168.1.20"},
			"source_flow_id": "flow-a1", "operation": "market.quote",
			"access_token": "opaque.bearer.token",
			"payload":      protocol.Object{"symbol": "wheat"},
		},
	})
	if err != nil {
		fail(err)
	}
	adminCommand, err := protocol.EncodeGatewayFrame(protocol.GatewayFrame{
		Kind:      "admin_command",
		CommandID: "cmd-0009",
		Body: protocol.Object{
			"action": "set_network_status", "customer_network_id": "net-farm", "status": "disabled"},
	})
	if err != nil {
		fail(err)
	}

	record("gateway/frames.json", "gateway_frame", "valid", goOnly(), protocol.Object{
		"schema": int64(1),
		"note": "The Gateway relies on WSS plus the authenticated Gateway Session rather than a " +
			"second message HMAC, so these frames carry no proof.",
		"authorization_header": "Authorization: Bearer <Gateway Credential>",
		"hello":                hello,
		"welcome":              welcome,
		"frames": protocol.Array{
			protocol.Object{"name": "external_request", "kind": "external_request",
				"request_id": "req-104", "text": externalRequest},
			protocol.Object{"name": "admin_command", "kind": "admin_command",
				"command_id": "cmd-0009", "text": adminCommand},
		},
		"rejected": protocol.Array{
			protocol.Object{"name": "an operational-only kind is not carried by the Gateway",
				"text":  `{"v":1,"kind":"dns_query","body":{"name":"h.farm.acme.craft"}}`,
				"error": protocol.CodeInvalidMessage},
			protocol.Object{"name": "a future major version is refused",
				"text":  `{"v":2,"kind":"heartbeat","body":{"connectivity_state":"ready","revision":1}}`,
				"error": protocol.CodeUnsupportedVersion},
			protocol.Object{"name": "an unknown envelope field is refused",
				"text":  `{"v":1,"kind":"heartbeat","body":{"connectivity_state":"ready","revision":1},"priority":"high"}`,
				"error": protocol.CodeInvalidMessage},
		},
	})
}

// writeAccessTokens records Ed25519 Access Token fixtures. CraftOS treats a
// token as an opaque bearer string and never decodes one, so these are consumed
// by Go alone.
func writeAccessTokens() {
	// A fixed seed keeps the fixture reproducible. This is fixture material, not
	// a credential: the External Application generates real keys with crypto/rand.
	seed := mustHex("9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")
	private := ed25519.NewKeyFromSeed(seed)
	public := private.Public().(ed25519.PublicKey)

	issuedAt := time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC).Unix()
	claims := protocol.AccessTokenClaims{
		Issuer:            "craftnet-external",
		Subject:           "cmp-harvester",
		WorldID:           "world-overworld",
		CustomerNetworkID: "net-farm",
		Operations:        []string{"market.quote", "market.trade"},
		IssuedAt:          issuedAt,
		ExpiresAt:         issuedAt + protocol.AccessTokenSeconds,
		TokenID:           "jti-000017",
	}
	token, err := protocol.IssueAccessToken(private, "kid-0001", claims)
	if err != nil {
		fail(err)
	}

	overLong := claims
	overLong.ExpiresAt = issuedAt + protocol.AccessTokenSeconds + 1
	if _, err := protocol.IssueAccessToken(private, "kid-0001", overLong); err == nil {
		fail(fmt.Errorf("a token longer than two minutes must not be issuable"))
	}

	record("tokens/access-token.json", "access_token", "valid", goOnly(), protocol.Object{
		"schema": int64(1),
		"note": "CraftOS transports the token opaquely. The External Application validates " +
			"signature, issuer, audience, expiry, revocation, operation, and exact ancestry.",
		"algorithm":          protocol.AccessTokenAlgorithm,
		"audience":           protocol.AccessTokenAudience,
		"maximum_lifetime_s": int64(protocol.AccessTokenSeconds),
		"key_id":             "kid-0001",
		"private_key_seed":   hex.EncodeToString(seed),
		"public_key":         hex.EncodeToString(public),
		"issued_at":          issuedAt,
		"expires_at":         claims.ExpiresAt,
		"token":              token,
		"claims": protocol.Object{
			"iss": claims.Issuer, "aud": protocol.AccessTokenAudience, "sub": claims.Subject,
			"world_id": claims.WorldID, "customer_network_id": claims.CustomerNetworkID,
			"operations": protocol.Array{"market.quote", "market.trade"},
			"iat":        claims.IssuedAt, "exp": claims.ExpiresAt, "jti": claims.TokenID,
		},
	})
}
