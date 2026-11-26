package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// cleanStopRecord is where a stop records, as this boot's id, that every
// process had exited and the final sync had returned. The engine's next start
// reads it: a shared cache unit still marked dirty by that boot holds nothing
// that missed the disk, so it is kept instead of discarded (guest/runner
// caches_dirty_linux.go, cleanStopPath).
const cleanStopRecord = "/var/lib/micropod/clean-stop"

const bootIDFile = "/proc/sys/kernel/random/boot_id"

func readBootID(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// writeCleanStop replaces the record with bootID, durably: temp file, fsync,
// rename, fsync of the directory. It writes nothing without a boot id or when
// the directory does not exist yet (no engine ever ran on this disk).
func writeCleanStop(path, bootID string) error {
	if bootID == "" {
		return nil
	}
	dir := filepath.Dir(path)
	if st, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
		return nil
	} else if err != nil {
		return err
	} else if !st.IsDir() {
		return errors.New(dir + " is not a directory")
	}
	tmp := path + ".tmp"
	if err := os.Remove(tmp); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0644)
	if err != nil {
		return err
	}
	_, err = f.WriteString(bootID + "\n")
	err = errors.Join(err, f.Sync(), f.Close())
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	return errors.Join(d.Sync(), d.Close())
}
