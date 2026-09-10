package protocol

import (
	"crypto/ed25519"
	"encoding/base64"
	"strings"
	"time"
)

// Ed25519 Access Tokens.
//
// The External Application creates and validates these tokens; CraftOS
// transports them as opaque bearer strings and never decodes one. A captured
// token is insufficient on its own because the application also requires a
// valid Gateway Credential and an exactly matching authenticated ancestry.

// AccessTokenAudience is the only audience CraftNet v1 accepts.
const AccessTokenAudience = "craftnet-gateway"

// AccessTokenAlgorithm is the only signing algorithm CraftNet v1 accepts.
const AccessTokenAlgorithm = "EdDSA"

var base64URL = base64.RawURLEncoding

// AccessTokenClaims are the required v1 claims.
type AccessTokenClaims struct {
	Issuer            string
	Subject           string
	WorldID           string
	CustomerNetworkID string
	Operations        []string
	IssuedAt          int64
	ExpiresAt         int64
	TokenID           string
}

func (c AccessTokenClaims) object() Object {
	operations := make(Array, 0, len(c.Operations))
	for _, operation := range c.Operations {
		operations = append(operations, operation)
	}
	return Object{
		"iss": c.Issuer, "aud": AccessTokenAudience, "sub": c.Subject,
		"world_id": c.WorldID, "customer_network_id": c.CustomerNetworkID,
		"operations": operations, "iat": c.IssuedAt, "exp": c.ExpiresAt, "jti": c.TokenID,
	}
}

var accessTokenHeaderShape = shape{
	required: map[string]string{"alg": "string", "typ": "string", "kid": "id"},
}

var accessTokenClaimsShape = shape{
	required: map[string]string{
		"iss": "string", "aud": "string", "sub": "id", "world_id": "id",
		"customer_network_id": "id", "operations": "[]operation_name",
		"iat": "non_negative", "exp": "non_negative", "jti": "id",
	},
}

// IssueAccessToken signs a two-minute Access Token. The claim set is encoded in
// canonical form so that the same claims always produce the same token bytes.
func IssueAccessToken(key ed25519.PrivateKey, keyID string, claims AccessTokenClaims) (string, error) {
	if len(key) != ed25519.PrivateKeySize {
		return "", newError(CodeInternalError, "an Ed25519 private key is required")
	}
	if !isID(keyID) {
		return "", newError(CodeInvalidMessage, "kid must be a CraftNet ID")
	}
	if claims.ExpiresAt-claims.IssuedAt > AccessTokenSeconds {
		return "", newError(CodeInvalidMessage, "an Access Token may not live longer than %d seconds", AccessTokenSeconds)
	}
	if claims.ExpiresAt <= claims.IssuedAt {
		return "", newError(CodeInvalidMessage, "exp must follow iat")
	}
	if len(claims.Operations) == 0 {
		return "", newError(CodeForbiddenOperation, "an Access Token must authorize at least one operation")
	}

	header := Object{"alg": AccessTokenAlgorithm, "typ": "JWT", "kid": keyID}
	if err := validateShape(accessTokenHeaderShape, header, "header"); err != nil {
		return "", err
	}
	claimSet := claims.object()
	if err := validateShape(accessTokenClaimsShape, claimSet, "claims"); err != nil {
		return "", err
	}

	headerText, err := Encode(header)
	if err != nil {
		return "", err
	}
	claimsText, err := Encode(claimSet)
	if err != nil {
		return "", err
	}
	signingInput := base64URL.EncodeToString([]byte(headerText)) + "." +
		base64URL.EncodeToString([]byte(claimsText))
	signature := ed25519.Sign(key, []byte(signingInput))
	return signingInput + "." + base64URL.EncodeToString(signature), nil
}

// AccessTokenExpectation is the exact context a token must match. Ancestry is
// compared exactly: a valid token presented from another Customer Network or
// another Computer is rejected.
type AccessTokenExpectation struct {
	Issuer            string
	Operation         string
	WorldID           string
	CustomerNetworkID string
	ComputerID        string
	// Revoked reports whether this token identifier has been revoked. A nil
	// function means no revocation state is available and nothing is revoked.
	Revoked func(tokenID string) bool
}

// VerifyAccessToken validates signature, issuer, audience, expiry, revocation
// state, allowed operation, and exact ancestry match, in that order.
func VerifyAccessToken(publicKeys map[string]ed25519.PublicKey, token string, now time.Time, expect AccessTokenExpectation) (*AccessTokenClaims, error) {
	segments := strings.Split(token, ".")
	if len(segments) != 3 {
		return nil, newError(CodeInvalidMessage, "an Access Token has three segments")
	}
	headerBytes, err := base64URL.DecodeString(segments[0])
	if err != nil {
		return nil, newError(CodeInvalidMessage, "token header is not base64url")
	}
	claimBytes, err := base64URL.DecodeString(segments[1])
	if err != nil {
		return nil, newError(CodeInvalidMessage, "token claims are not base64url")
	}
	signature, err := base64URL.DecodeString(segments[2])
	if err != nil {
		return nil, newError(CodeInvalidMessage, "token signature is not base64url")
	}

	headerValue, err := Decode(string(headerBytes), DefaultLimits())
	if err != nil {
		return nil, err
	}
	header, ok := headerValue.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "token header must be an object")
	}
	if err := validateShape(accessTokenHeaderShape, header, "header"); err != nil {
		return nil, err
	}
	if algorithm, _ := stringValue(header["alg"]); algorithm != AccessTokenAlgorithm {
		return nil, newError(CodeAuthenticationFail, "unsupported token algorithm")
	}
	if tokenType, _ := stringValue(header["typ"]); tokenType != "JWT" {
		return nil, newError(CodeInvalidMessage, "unsupported token type")
	}
	keyID, _ := stringValue(header["kid"])
	publicKey, known := publicKeys[keyID]
	if !known {
		return nil, newError(CodeAuthenticationFail, "unknown token signing key")
	}
	if !ed25519.Verify(publicKey, []byte(segments[0]+"."+segments[1]), signature) {
		return nil, newError(CodeAuthenticationFail, "token signature does not verify")
	}

	claimValue, err := Decode(string(claimBytes), DefaultLimits())
	if err != nil {
		return nil, err
	}
	claimSet, ok := claimValue.(Object)
	if !ok {
		return nil, newError(CodeInvalidMessage, "token claims must be an object")
	}
	if err := validateShape(accessTokenClaimsShape, claimSet, "claims"); err != nil {
		return nil, err
	}

	issuer, _ := stringValue(claimSet["iss"])
	if expect.Issuer != "" && issuer != expect.Issuer {
		return nil, newError(CodeAuthenticationFail, "token was issued by another authority")
	}
	if audience, _ := stringValue(claimSet["aud"]); audience != AccessTokenAudience {
		return nil, newError(CodeAuthenticationFail, "token names another audience")
	}

	issuedAt, _ := integerValue(claimSet["iat"])
	expiresAt, _ := integerValue(claimSet["exp"])
	if expiresAt-issuedAt > AccessTokenSeconds {
		return nil, newError(CodeInvalidMessage, "token lifetime exceeds %d seconds", AccessTokenSeconds)
	}
	if now.Unix() >= expiresAt {
		return nil, newError(CodeAccessTokenExpired, "token expired at %d", expiresAt)
	}
	if now.Unix() < issuedAt {
		return nil, newError(CodeAuthenticationFail, "token is not valid yet")
	}

	tokenID, _ := stringValue(claimSet["jti"])
	if expect.Revoked != nil && expect.Revoked(tokenID) {
		return nil, newError(CodeCredentialRevoked, "token %s is revoked", tokenID)
	}

	rawOperations, _ := claimSet["operations"].(Array)
	operations := make([]string, 0, len(rawOperations))
	authorized := false
	for _, entry := range rawOperations {
		operation, _ := stringValue(entry)
		operations = append(operations, operation)
		if operation == expect.Operation {
			authorized = true
		}
	}
	if expect.Operation != "" && !authorized {
		return nil, newError(CodeForbiddenOperation, "token does not authorize %q", expect.Operation)
	}

	subject, _ := stringValue(claimSet["sub"])
	worldID, _ := stringValue(claimSet["world_id"])
	networkID, _ := stringValue(claimSet["customer_network_id"])
	if expect.ComputerID != "" && subject != expect.ComputerID {
		return nil, newError(CodeAuthenticationFail, "token subject does not match the authenticated Computer")
	}
	if expect.WorldID != "" && worldID != expect.WorldID {
		return nil, newError(CodeAuthenticationFail, "token names another World")
	}
	if expect.CustomerNetworkID != "" && networkID != expect.CustomerNetworkID {
		return nil, newError(CodeAuthenticationFail, "token names another Customer Network")
	}

	return &AccessTokenClaims{
		Issuer: issuer, Subject: subject, WorldID: worldID,
		CustomerNetworkID: networkID, Operations: operations,
		IssuedAt: issuedAt, ExpiresAt: expiresAt, TokenID: tokenID,
	}, nil
}
