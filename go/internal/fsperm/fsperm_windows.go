//go:build windows

// Package fsperm keeps secrets private to the current user.
package fsperm

// Private: files under %AppData% are readable only by the user, SYSTEM and administrators by
// default, so there is nothing to fix; Windows has no group/other mode bits.
func Private(path string) (string, error) { return "", nil }
