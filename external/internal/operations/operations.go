// Package operations is the extension seam.
//
// A named External Operation is a handler plus a policy, registered at the
// composition root. Adding a capability means adding one of those -- not a new
// CraftNet route, a new Gateway Session, a new message family, or a proxy to an
// arbitrary URL. An adapter to a local model or another real application lives
// behind a handler and stops there.
//
// There is deliberately no generic provider interface. One will earn its place
// when two real adapters need different behaviour, and not before.
package operations

import (
	"context"
	"errors"
	"fmt"
	"sort"
	"sync"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// Credential says which secret an operation requires. The combination is fixed
// per operation and checked before a handler ever runs.
type Credential int

const (
	// CredentialAncestry is device.register: the authenticated CraftNet path is
	// the whole attestation, and there is no secret to present yet.
	CredentialAncestry Credential = iota
	// CredentialDevice is token.issue and device.rotate.
	CredentialDevice
	// CredentialAccessToken is every ordinary operation.
	CredentialAccessToken
)

// Policy is everything about an operation that is not its behaviour.
type Policy struct {
	Credential Credential
	// Description is shown to an Operator. It is not a comment: it is what the
	// dashboard will list.
	Description string
}

// Call is one validated invocation. Ancestry is the path CraftNet verified;
// nothing in it was taken from the caller's own claim.
type Call struct {
	Operation string
	Ancestry  store.Ancestry
	Payload   protocol.Object
	Device    *store.Device
	Claims    *protocol.AccessTokenClaims
}

// Result is what a handler produces. Payload is application defined and may
// carry fields this version has never seen.
type Result struct {
	Payload protocol.Object
}

// Handler runs one operation.
type Handler func(context.Context, Call) (Result, error)

// ErrUnknownOperation is returned for a name nobody registered. It becomes
// forbidden_operation on the wire: the allowlist is the point.
var ErrUnknownOperation = errors.New("unknown operation")

type entry struct {
	policy  Policy
	handler Handler
}

// Registry holds the allowlist.
type Registry struct {
	mutex   sync.RWMutex
	entries map[string]entry
}

// NewRegistry builds an empty allowlist. Empty means nothing is callable, which
// is the right default.
func NewRegistry() *Registry {
	return &Registry{entries: map[string]entry{}}
}

// Register adds one operation. Registering the same name twice is a mistake at
// the composition root rather than a silent replacement.
func (r *Registry) Register(name string, policy Policy, handler Handler) error {
	if !protocol.IsOperationName(name) {
		return fmt.Errorf("%q is not an operation name", name)
	}
	if handler == nil {
		return fmt.Errorf("%q needs a handler", name)
	}
	r.mutex.Lock()
	defer r.mutex.Unlock()
	if _, exists := r.entries[name]; exists {
		return fmt.Errorf("%q is already registered", name)
	}
	r.entries[name] = entry{policy: policy, handler: handler}
	return nil
}

// Policy returns what an operation requires, or false when it is not allowed.
func (r *Registry) Policy(name string) (Policy, bool) {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	found, ok := r.entries[name]
	return found.policy, ok
}

// Names lists the allowlist, which is what a dashboard shows.
func (r *Registry) Names() []string {
	r.mutex.RLock()
	defer r.mutex.RUnlock()
	names := make([]string, 0, len(r.entries))
	for name := range r.entries {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// Execute dispatches a validated call. It does not authenticate: whoever built
// the Call is responsible for having done that, which is why Call carries a
// verified ancestry rather than a claimed one.
func (r *Registry) Execute(ctx context.Context, call Call) (Result, error) {
	r.mutex.RLock()
	found, ok := r.entries[call.Operation]
	r.mutex.RUnlock()
	if !ok {
		return Result{}, &protocol.Error{
			Code:    protocol.CodeForbiddenOperation,
			Message: fmt.Sprintf("%q is not an allowed operation", call.Operation),
		}
	}
	return found.handler(ctx, call)
}
