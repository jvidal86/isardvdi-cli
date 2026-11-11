package secrets

import (
	"os"

	"github.com/godbus/dbus/v5"
)

// systemKeyringRunning: use only a keyring service that is already running. Asking a session
// without one (WSL, servers) starts a daemon that waits for an unlock nobody sees, and every
// command hangs.
func systemKeyringRunning() bool {
	if os.Getenv("DBUS_SESSION_BUS_ADDRESS") == "" {
		return false
	}
	conn, err := dbus.ConnectSessionBus()
	if err != nil {
		return false
	}
	defer conn.Close()
	var has bool
	err = conn.BusObject().Call("org.freedesktop.DBus.NameHasOwner", 0, "org.freedesktop.secrets").Store(&has)
	return err == nil && has
}
