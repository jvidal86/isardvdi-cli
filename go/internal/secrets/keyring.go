package secrets

import (
	"errors"

	gokeyring "github.com/zalando/go-keyring"
)

// systemKeyring is the operating system's keyring through go-keyring.
type systemKeyring struct{}

func (systemKeyring) Set(service, name, secret string) error {
	return gokeyring.Set(service, name, secret)
}

func (systemKeyring) Get(service, name string) (string, error) {
	v, err := gokeyring.Get(service, name)
	if errors.Is(err, gokeyring.ErrNotFound) {
		return "", ErrNotFound
	}
	return v, err
}

func (systemKeyring) Delete(service, name string) error {
	err := gokeyring.Delete(service, name)
	if errors.Is(err, gokeyring.ErrNotFound) {
		return nil
	}
	return err
}
