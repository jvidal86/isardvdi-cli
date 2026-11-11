//go:build !windows

// Package fsperm keeps secrets private to the current user.
package fsperm

import (
	"fmt"
	"os"
	"syscall"
)

// Private refuses a path another user owns and removes group/other permissions from ours
// (as ssh does). It returns a note to show when it changed something. A missing path is fine.
func Private(path string) (note string, err error) {
	fi, err := os.Lstat(path)
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) != os.Getuid() {
		return "", fmt.Errorf("Refusing to use %s: it is owned by another user.", path)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		if err := os.Chmod(path, fi.Mode().Perm()&^0o077); err != nil {
			return "", err
		}
		return fmt.Sprintf("Fixed the permissions of %s (other users could access it).", path), nil
	}
	return "", nil
}
