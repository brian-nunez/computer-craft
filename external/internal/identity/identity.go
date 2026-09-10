// Package identity owns everything the External Application knows about who is
// asking.
//
// It provisions Worlds, hashes and revokes bearer credentials, issues and
// verifies Ed25519 Access Tokens, and authorizes a call against its exact
// CraftNet ancestry. Nothing here writes SQL or speaks HTTP; it takes a
// transaction and returns values and typed errors.
//
// Two rules run through all of it. A secret is never stored in the clear -- only
// enough to verify one that is presented. And an ancestry is compared exactly:
// a perfectly valid credential presented from another Customer Network is
// refused, because the credential says who you are and the ancestry says where
// you are.
package identity

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// SecretBytes is the length of every bearer secret this package generates.
const SecretBytes = 32

// Credential kinds.
const (
	KindGateway = "gateway"
	KindDevice  = "device"
)

// Service issues and checks identities. `now` and `entropy` are injected so a
// test can place an expiry exactly and reproduce a run.
type Service struct {
	now       func() time.Time
	entropy   func([]byte) error
	signKey   ed25519.PrivateKey
	verifyKey ed25519.PublicKey
	keyID     string
	issuer    string
}

// Options configures a Service.
type Options struct {
	Now     func() time.Time
	Entropy func([]byte) error
	// SigningSeed is the Ed25519 seed for Access Tokens. Empty means generate
	// one, which is right for a development run and wrong for a release.
	SigningSeed []byte
	KeyID       string
	Issuer      string
}

// New builds the service.
func New(options Options) (*Service, error) {
	service := &Service{
		now:     options.Now,
		entropy: options.Entropy,
		keyID:   options.KeyID,
		issuer:  options.Issuer,
	}
	if service.now == nil {
		service.now = time.Now
	}
	if service.entropy == nil {
		service.entropy = func(destination []byte) error {
			_, err := rand.Read(destination)
			return err
		}
	}
	if service.keyID == "" {
		service.keyID = "kid-0001"
	}
	if service.issuer == "" {
		service.issuer = "craftnet-external"
	}

	seed := options.SigningSeed
	if len(seed) == 0 {
		seed = make([]byte, ed25519.SeedSize)
		if err := service.entropy(seed); err != nil {
			return nil, fmt.Errorf("draw a signing seed: %w", err)
		}
	}
	if len(seed) != ed25519.SeedSize {
		return nil, fmt.Errorf("a signing seed is %d bytes", ed25519.SeedSize)
	}
	service.signKey = ed25519.NewKeyFromSeed(seed)
	service.verifyKey = service.signKey.Public().(ed25519.PublicKey)
	return service, nil
}

// VerifyKeys is what an Access Token is checked against.
func (s *Service) VerifyKeys() map[string]ed25519.PublicKey {
	return map[string]ed25519.PublicKey{s.keyID: s.verifyKey}
}

// Digest is how a bearer secret is stored: never the secret, only this.
func Digest(secret string) string {
	sum := sha256.Sum256([]byte(secret))
	return hex.EncodeToString(sum[:])
}

// equalDigest compares in constant time, so a wrong secret takes as long to
// refuse as a right one.
func equalDigest(left, right string) bool {
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func (s *Service) secret() (string, error) {
	raw := make([]byte, SecretBytes)
	if err := s.entropy(raw); err != nil {
		return "", fmt.Errorf("draw entropy: %w", err)
	}
	return hex.EncodeToString(raw), nil
}

//--------------------------------------------------------------------------
// Provisioning
//--------------------------------------------------------------------------

// Bundle is what an Operator carries into the Central Server's wizard. It is
// returned exactly once, at provisioning; afterwards the application holds only
// digests and cannot produce it again.
type Bundle struct {
	WorldID              string
	CentralID            string
	GatewayURL           string
	GatewayCredentialRef string
	WorldKey             string
	GatewayCredential    string
	CreatedAt            time.Time
}

// ProvisionWorld generates a World Key and a Gateway Credential and records
// what is needed to verify them. Provisioning an existing World is refused
// rather than silently reissuing: replacing a World Key orphans every credential
// derived from it.
func (s *Service) ProvisionWorld(ctx context.Context, backing store.Store, worldID, centralID, gatewayURL string) (*Bundle, error) {
	if err := protocol.ValidateIdentifier(worldID); err != nil {
		return nil, fmt.Errorf("world_id: %w", err)
	}
	if err := protocol.ValidateIdentifier(centralID); err != nil {
		return nil, fmt.Errorf("central_id: %w", err)
	}

	worldKey, err := s.secret()
	if err != nil {
		return nil, err
	}
	gatewayCredential, err := s.secret()
	if err != nil {
		return nil, err
	}
	if worldKey == gatewayCredential {
		return nil, errors.New("the entropy source returned the same secret twice")
	}

	reference := "gwc-" + worldID
	created := s.now().UTC()

	err = backing.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.World(worldID); err == nil {
			return fmt.Errorf("%w: %s is already provisioned", store.ErrConflict, worldID)
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}

		if err := tx.PutWorld(store.World{
			WorldID:              worldID,
			CentralID:            centralID,
			GatewayCredentialRef: reference,
			GatewayCredentialSHA: Digest(gatewayCredential),
			WorldKeySHA:          Digest(worldKey),
			CreatedAt:            created,
		}); err != nil {
			return err
		}
		if err := tx.PutCredential(store.Credential{
			Reference: reference,
			Kind:      KindGateway,
			Subject:   centralID,
			WorldID:   worldID,
			DigestSHA: Digest(gatewayCredential),
			IssuedAt:  created,
		}); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: worldID, Actor: "provisioning", Action: "world.provision",
			Subject: worldID, Detail: centralID, Recorded: created,
		})
	})
	if err != nil {
		return nil, err
	}

	return &Bundle{
		WorldID:              worldID,
		CentralID:            centralID,
		GatewayURL:           gatewayURL,
		GatewayCredentialRef: reference,
		WorldKey:             worldKey,
		GatewayCredential:    gatewayCredential,
		CreatedAt:            created,
	}, nil
}

//--------------------------------------------------------------------------
// Gateway authentication
//--------------------------------------------------------------------------

// AuthenticateGateway checks the credential a Central Server presented in its
// Authorization header. A revoked credential is refused with its own code, so an
// Operator can tell "wrong secret" from "withdrawn".
func (s *Service) AuthenticateGateway(ctx context.Context, backing store.Store, worldID, presented string) (store.World, error) {
	var world store.World
	err := backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.World(worldID)
		if err != nil {
			return err
		}
		credential, err := tx.Credential(found.GatewayCredentialRef)
		if err != nil {
			return err
		}
		if credential.Revoked() {
			return &protocol.Error{
				Code:    protocol.CodeCredentialRevoked,
				Message: "that Gateway Credential has been revoked",
			}
		}
		if !equalDigest(credential.DigestSHA, Digest(presented)) {
			return &protocol.Error{
				Code:    protocol.CodeAuthenticationFail,
				Message: "the Gateway Credential does not match",
			}
		}
		world = found
		return nil
	})
	if errors.Is(err, store.ErrNotFound) {
		// An unknown World and a wrong secret look the same from outside.
		return store.World{}, &protocol.Error{
			Code:    protocol.CodeAuthenticationFail,
			Message: "the Gateway Credential does not match",
		}
	}
	return world, err
}

//--------------------------------------------------------------------------
// Devices
//--------------------------------------------------------------------------

// RegisterDevice issues a durable Device Credential for a Computer, on the
// strength of the ancestry CraftNet already verified. There is no secret to
// present: the authenticated path is the attestation, which is exactly why
// device.register is the one operation that carries no credential.
//
// Registering again from the same ancestry returns a fresh credential and keeps
// the identity, so a Computer that lost its credential can recover without an
// Operator deleting anything.
func (s *Service) RegisterDevice(ctx context.Context, backing store.Store, ancestry store.Ancestry) (string, store.Device, error) {
	secret, err := s.secret()
	if err != nil {
		return "", store.Device{}, err
	}

	deviceID := ancestry.WorldID + "-" + ancestry.ComputerID
	reference := "dev-" + deviceID
	now := s.now().UTC()
	device := store.Device{
		DeviceID:          deviceID,
		WorldID:           ancestry.WorldID,
		ISPID:             ancestry.ISPID,
		CustomerNetworkID: ancestry.CustomerNetworkID,
		RouterID:          ancestry.RouterID,
		ComputerID:        ancestry.ComputerID,
		LocalAddress:      ancestry.LocalAddress,
		CredentialRef:     reference,
		RegisteredAt:      now,
	}

	err = backing.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.World(ancestry.WorldID); err != nil {
			return err
		}
		// A Computer that moves to another Customer Network is a different
		// device, and its old registration is not quietly rewritten.
		if existing, err := tx.Device(deviceID); err == nil {
			if !existing.AncestryOf().Matches(ancestry) {
				return &protocol.Error{
					Code:    protocol.CodeAuthenticationFail,
					Message: "that Computer is registered under a different ancestry",
				}
			}
			device.RegisteredAt = existing.RegisteredAt
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}

		if err := tx.PutCredential(store.Credential{
			Reference: reference,
			Kind:      KindDevice,
			Subject:   deviceID,
			WorldID:   ancestry.WorldID,
			DigestSHA: Digest(secret),
			IssuedAt:  now,
		}); err != nil {
			return err
		}
		if err := tx.PutDevice(device); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: ancestry.WorldID, Actor: ancestry.ComputerID,
			Action: "device.register", Subject: deviceID,
			Detail: ancestry.CustomerNetworkID, Recorded: now,
		})
	})
	if err != nil {
		return "", store.Device{}, err
	}
	return secret, device, nil
}

// AuthenticateDevice checks a Device Credential against the ancestry it arrived
// on. Both have to agree: the credential says who, the ancestry says where.
func (s *Service) AuthenticateDevice(ctx context.Context, backing store.Store, ancestry store.Ancestry, presented string) (store.Device, error) {
	var device store.Device
	err := backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.DeviceByComputer(ancestry.WorldID, ancestry.ComputerID)
		if err != nil {
			return err
		}
		credential, err := tx.Credential(found.CredentialRef)
		if err != nil {
			return err
		}
		if credential.Revoked() {
			return &protocol.Error{
				Code:    protocol.CodeCredentialRevoked,
				Message: "that Device Credential has been revoked",
			}
		}
		if !equalDigest(credential.DigestSHA, Digest(presented)) {
			return &protocol.Error{
				Code:    protocol.CodeAuthenticationFail,
				Message: "the Device Credential does not match",
			}
		}
		if !found.AncestryOf().Matches(ancestry) {
			return &protocol.Error{
				Code:    protocol.CodeAuthenticationFail,
				Message: "that credential belongs to another CraftNet path",
			}
		}
		device = found
		return nil
	})
	if errors.Is(err, store.ErrNotFound) {
		return store.Device{}, &protocol.Error{
			Code:    protocol.CodeAuthenticationFail,
			Message: "the Device Credential does not match",
		}
	}
	return device, err
}

// RevokeDevice withdraws a Device Credential. The device keeps its identity and
// its registration; only new authenticated traffic stops.
func (s *Service) RevokeDevice(ctx context.Context, backing store.Store, deviceID, actor string) error {
	now := s.now().UTC()
	return backing.Do(ctx, func(tx store.Tx) error {
		device, err := tx.Device(deviceID)
		if err != nil {
			return err
		}
		if err := tx.RevokeCredential(device.CredentialRef, now); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: device.WorldID, Actor: actor, Action: "device.revoke",
			Subject: deviceID, Recorded: now,
		})
	})
}

//--------------------------------------------------------------------------
// Access Tokens
//--------------------------------------------------------------------------

// IssueToken mints a two-minute Access Token for a registered device. The token
// is recorded by identifier only, so it can be revoked before it expires
// without the application ever having held it.
func (s *Service) IssueToken(ctx context.Context, backing store.Store, device store.Device, operations []string) (string, time.Time, error) {
	if len(operations) == 0 {
		return "", time.Time{}, &protocol.Error{
			Code:    protocol.CodeForbiddenOperation,
			Message: "an Access Token must authorize at least one operation",
		}
	}

	raw := make([]byte, 8)
	if err := s.entropy(raw); err != nil {
		return "", time.Time{}, err
	}
	tokenID := "jti-" + hex.EncodeToString(raw)

	issued := s.now().UTC().Truncate(time.Second)
	expires := issued.Add(protocol.AccessTokenSeconds * time.Second)

	token, err := protocol.IssueAccessToken(s.signKey, s.keyID, protocol.AccessTokenClaims{
		Issuer:            s.issuer,
		Subject:           device.ComputerID,
		WorldID:           device.WorldID,
		CustomerNetworkID: device.CustomerNetworkID,
		Operations:        operations,
		IssuedAt:          issued.Unix(),
		ExpiresAt:         expires.Unix(),
		TokenID:           tokenID,
	})
	if err != nil {
		return "", time.Time{}, err
	}

	err = backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutToken(store.IssuedToken{
			TokenID:   tokenID,
			WorldID:   device.WorldID,
			DeviceID:  device.DeviceID,
			IssuedAt:  issued,
			ExpiresAt: expires,
		})
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return token, expires, nil
}

// AuthorizeToken checks an Access Token against the operation being called and
// the ancestry it arrived on. Signature, issuer, audience, expiry, revocation,
// operation, and exact ancestry all have to hold.
func (s *Service) AuthorizeToken(ctx context.Context, backing store.Store, token, operation string, ancestry store.Ancestry) (*protocol.AccessTokenClaims, error) {
	// Revocation is looked up at most once per token identifier, and outside any
	// transaction: the verification below may not need it at all.
	revoked := map[string]bool{}

	claims, err := protocol.VerifyAccessToken(s.VerifyKeys(), token, s.now().UTC(),
		protocol.AccessTokenExpectation{
			Issuer:            s.issuer,
			Operation:         operation,
			WorldID:           ancestry.WorldID,
			CustomerNetworkID: ancestry.CustomerNetworkID,
			ComputerID:        ancestry.ComputerID,
			Revoked: func(tokenID string) bool {
				if held, ok := revoked[tokenID]; ok {
					return held
				}
				var withdrawn bool
				_ = backing.Do(ctx, func(tx store.Tx) error {
					record, err := tx.Token(tokenID)
					if err != nil {
						// A token the application never issued is not one it can
						// vouch for. Treating it as revoked fails closed.
						withdrawn = true
						return nil
					}
					withdrawn = record.RevokedAt != nil
					return nil
				})
				revoked[tokenID] = withdrawn
				return withdrawn
			},
		})
	if err != nil {
		return nil, err
	}
	return claims, nil
}

// RevokeToken withdraws one Access Token before it expires.
func (s *Service) RevokeToken(ctx context.Context, backing store.Store, tokenID, actor string) error {
	now := s.now().UTC()
	return backing.Do(ctx, func(tx store.Tx) error {
		token, err := tx.Token(tokenID)
		if err != nil {
			return err
		}
		if err := tx.RevokeToken(tokenID, now); err != nil {
			return err
		}
		return tx.AppendAudit(store.AuditRecord{
			WorldID: token.WorldID, Actor: actor, Action: "token.revoke",
			Subject: tokenID, Recorded: now,
		})
	})
}
