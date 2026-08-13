//go:build !windows

package main

import (
	"syscall"
	"testing"
)

// withUmask sets the process umask and hands back how to put it right.
//
// Process-wide, so tests that use it cannot run in parallel with anything that
// writes a file. There is only one of them and it does not, which is why this
// is a helper rather than a lock.
func withUmask(t *testing.T, mask int) func() {
	t.Helper()
	previous := syscall.Umask(mask)
	return func() { syscall.Umask(previous) }
}
