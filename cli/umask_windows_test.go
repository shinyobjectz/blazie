//go:build windows

package main

import "testing"

// Windows has no umask, and no POSIX mode bits for the chmod to survive either.
// The test that uses this skips rather than pretending to have proved anything.
func withUmask(t *testing.T, _ int) func() {
	t.Helper()
	t.Skip("umask is a POSIX idea; file modes mean something else here")
	return func() {}
}
