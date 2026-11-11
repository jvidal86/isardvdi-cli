//go:build !linux

package secrets

// systemKeyringRunning: Windows Credential Manager and the macOS Keychain are always there.
func systemKeyringRunning() bool { return true }
