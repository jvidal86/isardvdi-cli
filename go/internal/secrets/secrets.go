// Package secrets stores the API key and the login token: in the system keyring when there is
// one (Secret Service on Linux, Credential Manager on Windows, Keychain on macOS), else in a
// private file. "<file>.in-keyring" (it holds no secret) records that the keyring has the
// value, so a locked or unreachable keyring is an error instead of "no key", which would fall
// back to a sign-in and log the web browser out.
package secrets

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/jvidal86/isardvdi-cli/internal/config"
)

// Service is the keyring service name.
const Service = "isardvdi-cli"

var (
	// ErrNotFound: there is no such secret.
	ErrNotFound = errors.New("not found")
	// ErrKeyring: the keyring has it, but it can't be read now (locked, or no desktop session).
	ErrKeyring = errors.New("the system keyring can't be read now")
)

// Keyring is the part of a system keyring the store uses.
type Keyring interface {
	Set(service, name, secret string) error
	Get(service, name string) (string, error)
	Delete(service, name string) error
}

// Store keeps secrets in Dir. A nil Keyring means files only.
type Store struct {
	Dir     string
	Keyring Keyring
	Warn    func(string) // notes for the user; may be nil
}

// New returns a store in dir using the system keyring, unless ISARDVDI_KEYRING=0 or none runs.
func New(dir string) *Store {
	s := &Store{Dir: dir}
	if os.Getenv("ISARDVDI_KEYRING") != "0" && systemKeyringRunning() {
		s.Keyring = systemKeyring{}
	}
	return s
}

func (s *Store) file(name string) string   { return filepath.Join(s.Dir, name) }
func (s *Store) marker(name string) string { return s.file(name) + ".in-keyring" }
func (s *Store) warn(m string) {
	if s.Warn != nil {
		s.Warn(m)
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// Exists tells whether a secret is stored, without reading it.
func (s *Store) Exists(name string) bool { return exists(s.file(name)) || exists(s.marker(name)) }

// Where says where a secret lives, for messages.
func (s *Store) Where(name string) string {
	if exists(s.marker(name)) {
		return "the system keyring"
	}
	return s.file(name)
}

// withTimeout runs f, giving up after 60 s: a keyring waiting for an unlock nobody sees must
// not hang every command.
func withTimeout(f func() error) error {
	done := make(chan error, 1)
	go func() { done <- f() }()
	select {
	case err := <-done:
		return err
	case <-time.After(60 * time.Second):
		return errors.New("timed out")
	}
}

// Load returns the secret: ErrNotFound if there is none, ErrKeyring if the keyring has it but
// can't be read.
func (s *Store) Load(name string) (string, error) {
	if exists(s.marker(name)) {
		if s.Keyring == nil {
			return "", ErrKeyring
		}
		var v string
		err := withTimeout(func() (e error) { v, e = s.Keyring.Get(Service, name); return })
		if err != nil || v == "" {
			return "", ErrKeyring
		}
		return v, nil
	}
	b, err := os.ReadFile(s.file(name))
	if os.IsNotExist(err) {
		return "", ErrNotFound
	}
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// Save stores a secret: in the keyring if possible (read back before anything is deleted: a
// secret must never be lost to a half-working keyring), else in a private file.
func (s *Store) Save(name, value string) error {
	if s.Keyring != nil {
		err := withTimeout(func() error { return s.Keyring.Set(Service, name, value) })
		if err == nil {
			var back string
			err = withTimeout(func() (e error) { back, e = s.Keyring.Get(Service, name); return })
			if err == nil && back == value {
				if err := config.WriteFile(s.marker(name), nil); err != nil { // marker first: never a key without one
					return err
				}
				os.Remove(s.file(name))
				return nil
			}
		}
	}
	if err := config.WriteFile(s.file(name), []byte(value)); err != nil {
		return err
	}
	// Then remove an older keyring copy, or forget/revoke would miss it.
	if exists(s.marker(name)) {
		if s.Keyring == nil || withTimeout(func() error { return s.Keyring.Delete(Service, name) }) != nil {
			s.warn(fmt.Sprintf("Note: an older '%s' may remain in the keyring (item '%s %s').", name, Service, name))
		}
		os.Remove(s.marker(name))
	}
	return nil
}

// Clear removes a secret from the keyring and the file.
func (s *Store) Clear(name string) {
	if exists(s.marker(name)) {
		if s.Keyring == nil || withTimeout(func() error { return s.Keyring.Delete(Service, name) }) != nil {
			s.warn(fmt.Sprintf("Could not remove '%s' from the keyring (is it locked?). Remove the item\n'%s %s' with your keyring manager.", name, Service, name))
		}
	}
	os.Remove(s.file(name))
	os.Remove(s.marker(name))
}
