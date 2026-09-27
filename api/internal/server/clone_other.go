//go:build !darwin

package server

import "fmt"

// cloneImage needs clonefile(2), which only APFS on macOS provides. The
// apiserver wraps Apple's `container` CLI and only ever runs on macOS; this
// stub keeps the package compiling (and `go vet` honest) elsewhere.
func cloneImage(src, dst string) error {
	return fmt.Errorf("clone %s -> %s: volume clones require macOS (clonefile)", src, dst)
}
