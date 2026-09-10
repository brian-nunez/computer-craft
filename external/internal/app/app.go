// Package app is the composition root.
//
// It is the one place that knows how the modules fit together, and the one
// place an operation is registered. Everything it builds is returned so a test
// can assemble the same application without a process, a port, or a file.
package app

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/gateway"
	"github.com/brian-nunez/computer-craft/external/internal/identity"
	"github.com/brian-nunez/computer-craft/external/internal/operations"
	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
	"github.com/brian-nunez/computer-craft/external/internal/web"
	"github.com/brian-nunez/computer-craft/external/internal/worldview"
)

// App is the assembled application.
type App struct {
	Store      store.Store
	Identities *identity.Service
	Operations *operations.Registry
	Gateways   *gateway.Registry
	View       *worldview.Service
	Web        *web.Server
}

// Options configures an App.
type Options struct {
	Store       store.Store
	Now         func() time.Time
	Entropy     func([]byte) error
	SigningSeed []byte
	Retention   time.Duration
	Logf        func(string, ...any)
	// SecureCookies marks the dashboard session cookie HTTPS-only. It is off
	// for a loopback development run and on behind TLS.
	SecureCookies bool
}

// New assembles everything and registers the operations this release allows.
func New(options Options) (*App, error) {
	if options.Store == nil {
		return nil, errors.New("an application needs a store")
	}
	now := options.Now
	if now == nil {
		now = time.Now
	}

	identities, err := identity.New(identity.Options{
		Now: now, Entropy: options.Entropy, SigningSeed: options.SigningSeed,
	})
	if err != nil {
		return nil, err
	}

	allowlist := operations.NewRegistry()
	gateways := gateway.NewRegistry(gateway.Options{
		Store: options.Store, Identities: identities, Operations: allowlist, Now: now,
	})
	view := worldview.New(worldview.Options{
		Store: options.Store, Now: now, Retention: options.Retention,
		Connected: func(worldID string) (time.Time, bool) {
			session, ok := gateways.Session(worldID)
			if !ok {
				return time.Time{}, false
			}
			return session.LastSeen(), true
		},
	})

	application := &App{
		Store: options.Store, Identities: identities, Operations: allowlist,
		Gateways: gateways, View: view,
	}
	application.Web = web.New(web.Options{
		Gateways: gateways, View: view, Identities: identities,
		Store: options.Store, Now: now, Logf: options.Logf,
		SecureCookies: options.SecureCookies,
	})

	if err := application.registerOperations(now); err != nil {
		return nil, err
	}
	return application, nil
}

// DefaultOperations are the names this release allows. Anything else is refused
// with forbidden_operation, which is the whole point of an allowlist.
var DefaultOperations = []string{"device.register", "token.issue", "echo", "time.now", "test.identity"}

func (a *App) registerOperations(now func() time.Time) error {
	// device.register is the one operation with no secret to present: the
	// authenticated CraftNet ancestry is the attestation.
	err := a.Operations.Register("device.register", operations.Policy{
		Credential:  operations.CredentialAncestry,
		Description: "Issue this Computer a durable Device Credential",
	}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
		secret, device, err := a.Identities.RegisterDevice(ctx, a.Store, call.Ancestry)
		if err != nil {
			return operations.Result{}, err
		}
		return operations.Result{Payload: protocol.Object{
			"device_id":         device.DeviceID,
			"device_credential": secret,
		}}, nil
	})
	if err != nil {
		return err
	}

	// token.issue exchanges a Device Credential for a two-minute Access Token.
	err = a.Operations.Register("token.issue", operations.Policy{
		Credential:  operations.CredentialDevice,
		Description: "Exchange a Device Credential for a two-minute Access Token",
	}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
		if call.Device == nil {
			return operations.Result{}, &protocol.Error{
				Code:    protocol.CodeAuthenticationFail,
				Message: "a Device Credential is required",
			}
		}
		wanted := requestedOperations(call.Payload)
		token, expires, err := a.Identities.IssueToken(ctx, a.Store, *call.Device, wanted)
		if err != nil {
			return operations.Result{}, err
		}
		return operations.Result{Payload: protocol.Object{
			"access_token": token,
			"expires_at":   expires.Format(time.RFC3339),
			"operations":   asArray(wanted),
		}}, nil
	})
	if err != nil {
		return err
	}

	err = a.Operations.Register("echo", operations.Policy{
		Credential:  operations.CredentialAccessToken,
		Description: "Return the payload unchanged",
	}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
		return operations.Result{Payload: call.Payload}, nil
	})
	if err != nil {
		return err
	}

	err = a.Operations.Register("time.now", operations.Policy{
		Credential:  operations.CredentialAccessToken,
		Description: "Return the External Application's clock",
	}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
		return operations.Result{Payload: protocol.Object{
			"now": now().UTC().Format(time.RFC3339),
		}}, nil
	})
	if err != nil {
		return err
	}

	// test.identity reports the ancestry the application actually verified, so
	// an acceptance run can see the whole path rather than infer it. It carries
	// no credential value, only the path.
	return a.Operations.Register("test.identity", operations.Policy{
		Credential:  operations.CredentialAccessToken,
		Description: "Report the verified CraftNet path this call arrived on",
	}, func(ctx context.Context, call operations.Call) (operations.Result, error) {
		return operations.Result{Payload: protocol.Object{
			"world_id":            call.Ancestry.WorldID,
			"isp_id":              call.Ancestry.ISPID,
			"customer_network_id": call.Ancestry.CustomerNetworkID,
			"router_id":           call.Ancestry.RouterID,
			"computer_id":         call.Ancestry.ComputerID,
			"local_address":       call.Ancestry.LocalAddress,
		}}, nil
	})
}

// requestedOperations reads which operations a token should authorize, falling
// back to the ordinary ones. device.register and token.issue are never among
// them: those are reached with the ancestry and the Device Credential.
func requestedOperations(payload protocol.Object) []string {
	wanted := make([]string, 0, 4)
	if list, ok := payload["operations"].(protocol.Array); ok {
		for _, raw := range list {
			if name, ok := raw.(string); ok && name != "device.register" && name != "token.issue" {
				wanted = append(wanted, name)
			}
		}
	}
	if len(wanted) == 0 {
		wanted = []string{"echo", "time.now", "test.identity"}
	}
	return wanted
}

func asArray(values []string) protocol.Array {
	list := make(protocol.Array, 0, len(values))
	for _, value := range values {
		list = append(list, value)
	}
	return list
}

// Prune removes Traffic Events past the retention window.
func (a *App) Prune(ctx context.Context) (int64, error) {
	return a.View.Prune(ctx)
}

// PruneDaily runs retention until the context ends. Audit records are never
// touched: pruning telemetry must not prune the record of a decision.
func (a *App) PruneDaily(ctx context.Context, every time.Duration, logf func(string, ...any)) {
	if every <= 0 {
		every = 24 * time.Hour
	}
	ticker := time.NewTicker(every)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			removed, err := a.Prune(ctx)
			if err != nil && logf != nil {
				logf("retention: %v", err)
			} else if logf != nil && removed > 0 {
				logf("retention: pruned %d Traffic Events", removed)
			}
		}
	}
}

// Describe lists the allowlist, which is what an Operator checks when a call is
// refused.
func (a *App) Describe() string {
	names := a.Operations.Names()
	return fmt.Sprintf("%d operations: %v", len(names), names)
}
