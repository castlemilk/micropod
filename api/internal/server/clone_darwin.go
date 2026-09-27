//go:build darwin

package server

import (
	"errors"
	"fmt"
	"os"

	"golang.org/x/sys/unix"
)

// cloneImage replaces dst with an APFS clone of src (clonefile(2): O(1),
// copy-on-write, byte-identical). The clone lands in a sibling temp file and
// is renamed over dst so a crash mid-way never leaves a truncated image, and
// no temp file survives on the failure path.
func cloneImage(src, dst string) error {
	tmp := dst + ".clone-tmp"
	if err := os.Remove(tmp); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale %s: %w", tmp, err)
	}
	if err := unix.Clonefile(src, tmp, 0); err != nil {
		return fmt.Errorf("clonefile %s -> %s: %w", src, tmp, err)
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("rename %s -> %s: %w", tmp, dst, err)
	}
	return nil
}
