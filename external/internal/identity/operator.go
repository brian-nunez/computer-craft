package identity

import (
	"context"
	"crypto/pbkdf2"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/brian-nunez/computer-craft/external/internal/protocol"
	"github.com/brian-nunez/computer-craft/external/internal/store"
)

// Operator sign-in.
//
// A dashboard password is the one secret a human types, so it is stored the way
// a password has to be: salted and iterated, never as a plain digest. A leaked
// database yields neither a password nor a live session.

const (
	// SessionLifetime is how long a browser stays signed in. Short enough that a
	// forgotten tab is not a standing key, long enough to do a day's work.
	SessionLifetime = 12 * time.Hour

	// PasswordIterations is recorded per operator, so raising it later does not
	// invalidate existing passwords.
	PasswordIterations = 200000
	saltBytes          = 16
	sessionTokenBytes  = 32

	// MinimumPassword is what an Operator has to type. A passphrase is better
	// than a word, and the wizard says so.
	MinimumPassword = 10
)

// ErrSignIn is what every failed sign-in returns, whatever actually went wrong.
// Distinguishing "no such operator" from "wrong password" would tell someone
// probing which names exist.
var ErrSignIn = &protocol.Error{
	Code:    protocol.CodeAuthenticationFail,
	Message: "that operator name and password do not match",
}

func derive(password, salt string, iterations int) (string, error) {
	raw, err := hex.DecodeString(salt)
	if err != nil {
		return "", fmt.Errorf("decode salt: %w", err)
	}
	key, err := pbkdf2.Key(sha256.New, password, raw, iterations, 32)
	if err != nil {
		return "", fmt.Errorf("derive: %w", err)
	}
	return hex.EncodeToString(key), nil
}

// PutOperator creates or replaces an operator's password. It is how
// `craftnetd operator` works, and the only way a password is ever set.
func (s *Service) PutOperator(ctx context.Context, backing store.Store, name, password string) error {
	if name == "" {
		return errors.New("an operator needs a name")
	}
	if len(password) < MinimumPassword {
		return fmt.Errorf("a password needs at least %d characters; a passphrase is better than a word",
			MinimumPassword)
	}

	raw := make([]byte, saltBytes)
	if err := s.entropy(raw); err != nil {
		return fmt.Errorf("draw a salt: %w", err)
	}
	salt := hex.EncodeToString(raw)

	digest, err := derive(password, salt, PasswordIterations)
	if err != nil {
		return err
	}

	now := s.now().UTC()
	return backing.Do(ctx, func(tx store.Tx) error {
		created := now
		if existing, err := tx.Operator(name); err == nil {
			created = existing.CreatedAt
		} else if !errors.Is(err, store.ErrNotFound) {
			return err
		}
		return tx.PutOperator(store.Operator{
			Name: name, Salt: salt, PasswordSHA: digest,
			Iterations: PasswordIterations, CreatedAt: created,
		})
	})
}

// DisableOperator stops an operator signing in. Any session they still hold
// stops working at its next request, because Authenticate resolves the operator
// every time rather than trusting the session alone. Their audit history is
// untouched: what they did stays recorded.
func (s *Service) DisableOperator(ctx context.Context, backing store.Store, name string) error {
	now := s.now().UTC()
	return backing.Do(ctx, func(tx store.Tx) error {
		operator, err := tx.Operator(name)
		if err != nil {
			return err
		}
		operator.DisabledAt = &now
		return tx.PutOperator(operator)
	})
}

// SignIn checks a name and password and issues a session token. The token is
// returned once; only its digest is stored.
func (s *Service) SignIn(ctx context.Context, backing store.Store, name, password string) (string, time.Time, error) {
	var operator store.Operator
	err := backing.Do(ctx, func(tx store.Tx) error {
		found, err := tx.Operator(name)
		if err != nil {
			return err
		}
		operator = found
		return nil
	})
	if errors.Is(err, store.ErrNotFound) {
		// Derive anyway, so a missing operator takes as long to refuse as a
		// wrong password and cannot be found by timing.
		_, _ = derive(password, hex.EncodeToString(make([]byte, saltBytes)), PasswordIterations)
		return "", time.Time{}, ErrSignIn
	}
	if err != nil {
		return "", time.Time{}, err
	}

	digest, err := derive(password, operator.Salt, operator.Iterations)
	if err != nil {
		return "", time.Time{}, err
	}
	if !equalDigest(digest, operator.PasswordSHA) || operator.Disabled() {
		return "", time.Time{}, ErrSignIn
	}

	raw := make([]byte, sessionTokenBytes)
	if err := s.entropy(raw); err != nil {
		return "", time.Time{}, fmt.Errorf("draw a session token: %w", err)
	}
	token := hex.EncodeToString(raw)

	issued := s.now().UTC()
	expires := issued.Add(SessionLifetime)
	err = backing.Do(ctx, func(tx store.Tx) error {
		return tx.PutSession(store.Session{
			TokenSHA: Digest(token), Operator: name,
			IssuedAt: issued, ExpiresAt: expires,
		})
	})
	if err != nil {
		return "", time.Time{}, err
	}
	return token, expires, nil
}

// Authenticate resolves a session token to the operator holding it. An expired
// session is refused and removed rather than merely refused.
func (s *Service) Authenticate(ctx context.Context, backing store.Store, token string) (store.Operator, error) {
	if token == "" {
		return store.Operator{}, ErrSignIn
	}
	digest := Digest(token)
	now := s.now().UTC()

	var operator store.Operator
	expired := false
	err := backing.Do(ctx, func(tx store.Tx) error {
		session, err := tx.Session(digest)
		if err != nil {
			return err
		}
		if !now.Before(session.ExpiresAt) {
			// Removing it is the point, so this commits rather than returning
			// the refusal from inside the transaction and rolling the removal
			// back with it.
			expired = true
			return tx.DeleteSession(digest)
		}
		found, err := tx.Operator(session.Operator)
		if err != nil {
			return err
		}
		if found.Disabled() {
			return ErrSignIn
		}
		operator = found
		return nil
	})
	if errors.Is(err, store.ErrNotFound) {
		return store.Operator{}, ErrSignIn
	}
	if err != nil {
		return store.Operator{}, err
	}
	if expired {
		return store.Operator{}, ErrSignIn
	}
	return operator, nil
}

// SignOut ends one session.
func (s *Service) SignOut(ctx context.Context, backing store.Store, token string) error {
	if token == "" {
		return nil
	}
	return backing.Do(ctx, func(tx store.Tx) error {
		return tx.DeleteSession(Digest(token))
	})
}

// PruneSessions removes what has expired.
func (s *Service) PruneSessions(ctx context.Context, backing store.Store) (int64, error) {
	now := s.now().UTC()
	var removed int64
	err := backing.Do(ctx, func(tx store.Tx) error {
		count, err := tx.PruneSessions(now)
		if err != nil {
			return err
		}
		removed = count
		return nil
	})
	return removed, err
}
