package identity_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/identity"
	"github.com/brian-nunez/computer-craft/external/internal/operations"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/store/memory"
)

var epoch = time.Date(2026, 9, 9, 12, 0, 0, 0, time.UTC)

var ancestry = store.Ancestry{
	WorldID:           "world-overworld",
	ISPID:             "isp-acme",
	CustomerNetworkID: "network-farm",
	RouterID:          "router-farm",
	ComputerID:        "computer-farm-harvester",
	LocalAddress:      "192.168.1.20",
}

type fixture struct {
	service *identity.Service
	backing store.Store
	clock   time.Time
	bundle  *identity.Bundle
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	held := &fixture{backing: memory.New(), clock: epoch}

	// A fixed counter for entropy, so every secret in a run is distinct and the
	// run is reproducible.
	var counter byte
	service, err := identity.New(identity.Options{
		Now: func() time.Time { return held.clock },
		Entropy: func(destination []byte) error {
			counter++
			for index := range destination {
				destination[index] = counter + byte(index)
			}
			return nil
		},
	})
	if err != nil {
		t.Fatalf("build: %v", err)
	}
	held.service = service

	bundle, err := service.ProvisionWorld(context.Background(), held.backing,
		"world-overworld", "central-main", "ws://example/gateway")
	if err != nil {
		t.Fatalf("provision: %v", err)
	}
	held.bundle = bundle
	return held
}

func TestAGatewayCredentialAuthenticatesOnlyItsOwnWorld(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()

	if _, err := held.service.AuthenticateGateway(ctx, held.backing,
		"world-overworld", held.bundle.GatewayCredential); err != nil {
		t.Fatalf("the right credential was refused: %v", err)
	}

	if _, err := held.service.AuthenticateGateway(ctx, held.backing,
		"world-nether", held.bundle.GatewayCredential); err == nil {
		t.Fatal("a credential authenticated another World")
	}

	// An unknown World and a wrong secret look the same from outside.
	_, unknown := held.service.AuthenticateGateway(ctx, held.backing, "world-nether", "x")
	_, wrong := held.service.AuthenticateGateway(ctx, held.backing, "world-overworld", "x")
	if protocol.CodeOf(unknown) != protocol.CodeOf(wrong) {
		t.Fatalf("an unknown World is distinguishable from a wrong secret: %s vs %s",
			protocol.CodeOf(unknown), protocol.CodeOf(wrong))
	}
}

func TestDeviceRegistrationIsIdempotentForOneAncestry(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()

	firstSecret, firstDevice, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	// Registering again issues a fresh credential and keeps the identity, so a
	// Computer that lost its credential recovers without an Operator deleting
	// anything.
	secondSecret, secondDevice, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("re-register: %v", err)
	}
	if secondDevice.DeviceID != firstDevice.DeviceID {
		t.Fatal("re-registering changed the device identity")
	}
	if secondSecret == firstSecret {
		t.Fatal("re-registering reused the old credential")
	}
	if !secondDevice.RegisteredAt.Equal(firstDevice.RegisteredAt) {
		t.Fatal("re-registering moved the original registration time")
	}

	// And the old credential no longer works.
	if _, err := held.service.AuthenticateDevice(ctx, held.backing, ancestry, firstSecret); err == nil {
		t.Fatal("the superseded credential still authenticates")
	}
	if _, err := held.service.AuthenticateDevice(ctx, held.backing, ancestry, secondSecret); err != nil {
		t.Fatalf("the new credential was refused: %v", err)
	}
}

func TestADeviceThatMovedIsRefused(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	if _, _, err := held.service.RegisterDevice(ctx, held.backing, ancestry); err != nil {
		t.Fatalf("register: %v", err)
	}

	// The same Computer identity, arriving from another Customer Network.
	moved := ancestry
	moved.CustomerNetworkID = "network-home"
	moved.RouterID = "router-home"

	if _, _, err := held.service.RegisterDevice(ctx, held.backing, moved); err == nil {
		t.Fatal("a device registered under another ancestry was quietly rewritten")
	} else if protocol.CodeOf(err) != protocol.CodeAuthenticationFail {
		t.Fatalf("code = %s", protocol.CodeOf(err))
	}
}

func TestADeviceCredentialIsCheckedAgainstItsAncestry(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	secret, _, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	elsewhere := ancestry
	elsewhere.CustomerNetworkID = "network-home"
	if _, err := held.service.AuthenticateDevice(ctx, held.backing, elsewhere, secret); err == nil {
		t.Fatal("a valid credential was accepted from another Customer Network")
	}
}

func TestARevokedDeviceKeepsItsIdentity(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	secret, device, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	if err := held.service.RevokeDevice(ctx, held.backing, device.DeviceID, "operator"); err != nil {
		t.Fatalf("revoke: %v", err)
	}

	_, err = held.service.AuthenticateDevice(ctx, held.backing, ancestry, secret)
	if protocol.CodeOf(err) != protocol.CodeCredentialRevoked {
		t.Fatalf("code = %s, want %s", protocol.CodeOf(err), protocol.CodeCredentialRevoked)
	}

	// Revocation stops traffic; it does not delete the device.
	if err := held.backing.Do(ctx, func(tx store.Tx) error {
		if _, err := tx.Device(device.DeviceID); err != nil {
			t.Fatalf("the device was deleted: %v", err)
		}
		return nil
	}); err != nil {
		t.Fatalf("read: %v", err)
	}
}

func TestATokenLivesExactlyTwoMinutes(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	_, device, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}

	token, expires, err := held.service.IssueToken(ctx, held.backing, device, []string{"echo"})
	if err != nil {
		t.Fatalf("issue: %v", err)
	}
	if lifetime := expires.Sub(held.clock.Truncate(time.Second)); lifetime != protocol.AccessTokenSeconds*time.Second {
		t.Fatalf("lifetime = %v, want %ds", lifetime, protocol.AccessTokenSeconds)
	}

	if _, err := held.service.AuthorizeToken(ctx, held.backing, token, "echo", ancestry); err != nil {
		t.Fatalf("a fresh token was refused: %v", err)
	}

	held.clock = held.clock.Add(protocol.AccessTokenSeconds * time.Second)
	_, err = held.service.AuthorizeToken(ctx, held.backing, token, "echo", ancestry)
	if protocol.CodeOf(err) != protocol.CodeAccessTokenExpired {
		t.Fatalf("code = %s, want %s", protocol.CodeOf(err), protocol.CodeAccessTokenExpired)
	}
}

func TestATokenAuthorizesOnlyWhatItNames(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	_, device, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	token, _, err := held.service.IssueToken(ctx, held.backing, device, []string{"echo"})
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	_, err = held.service.AuthorizeToken(ctx, held.backing, token, "time.now", ancestry)
	if protocol.CodeOf(err) != protocol.CodeForbiddenOperation {
		t.Fatalf("code = %s, want %s", protocol.CodeOf(err), protocol.CodeForbiddenOperation)
	}
}

// A token the application never issued cannot be vouched for, so it is treated
// as revoked rather than trusted on its signature alone.
func TestAnUnknownTokenIdentifierFailsClosed(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	_, device, err := held.service.RegisterDevice(ctx, held.backing, ancestry)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	token, _, err := held.service.IssueToken(ctx, held.backing, device, []string{"echo"})
	if err != nil {
		t.Fatalf("issue: %v", err)
	}

	claims, err := held.service.AuthorizeToken(ctx, held.backing, token, "echo", ancestry)
	if err != nil {
		t.Fatalf("authorize: %v", err)
	}

	// Forget it ever existed, as a restored-from-backup database might.
	forgetful := memory.New()
	if err := forgetful.Do(ctx, func(tx store.Tx) error {
		return tx.PutWorld(store.World{WorldID: ancestry.WorldID})
	}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	_, err = held.service.AuthorizeToken(ctx, forgetful, token, "echo", ancestry)
	if protocol.CodeOf(err) != protocol.CodeCredentialRevoked {
		t.Fatalf("code = %s, want %s", protocol.CodeOf(err), protocol.CodeCredentialRevoked)
	}
	_ = claims
}

func TestProvisioningRequiresIdentifiers(t *testing.T) {
	held := newFixture(t)
	ctx := context.Background()
	for _, bad := range []string{"World-Overworld", "-world", ""} {
		if _, err := held.service.ProvisionWorld(ctx, held.backing, bad, "central-main", ""); err == nil {
			t.Fatalf("%q was accepted as a World identity", bad)
		}
	}
}

func TestARegisteredDeviceNeedsItsWorld(t *testing.T) {
	held := newFixture(t)
	elsewhere := ancestry
	elsewhere.WorldID = "world-nether"
	_, _, err := held.service.RegisterDevice(context.Background(), held.backing, elsewhere)
	if !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("error = %v, want ErrNotFound", err)
	}
}

//--------------------------------------------------------------------------
// The allowlist
//--------------------------------------------------------------------------

func TestAnUnregisteredOperationIsRefused(t *testing.T) {
	registry := operations.NewRegistry()
	_, err := registry.Execute(context.Background(), operations.Call{Operation: "market.settle"})
	if protocol.CodeOf(err) != protocol.CodeForbiddenOperation {
		t.Fatalf("code = %s, want %s", protocol.CodeOf(err), protocol.CodeForbiddenOperation)
	}
}

func TestRegisteringTwiceIsAMistake(t *testing.T) {
	registry := operations.NewRegistry()
	handler := func(context.Context, operations.Call) (operations.Result, error) {
		return operations.Result{}, nil
	}
	if err := registry.Register("echo", operations.Policy{}, handler); err != nil {
		t.Fatalf("first: %v", err)
	}
	if err := registry.Register("echo", operations.Policy{}, handler); err == nil {
		t.Fatal("the same operation was registered twice")
	}
	if err := registry.Register("Echo", operations.Policy{}, handler); err == nil {
		t.Fatal("an operation name was accepted with an uppercase letter")
	}
	if err := registry.Register("echo.two", operations.Policy{}, nil); err == nil {
		t.Fatal("an operation was registered with no handler")
	}
}
