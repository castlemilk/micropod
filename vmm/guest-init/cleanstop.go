package main

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

func readBootID(p string) string {
	b, err := os.ReadFile(p)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// cleanStopKeep is how many clean stops the record remembers. The engine keeps
// a unit marked dirty by any boot the record names; it does not recover in a
// boot whose engine never started (a failed start.sh, the first boot of a
// replaced OS disk), so that boot's own clean stop must not hide the earlier
// one the marks belong to.
const cleanStopKeep = 16

// writeCleanStop adds bootID to the record, durably: the record's recent boot
// ids plus this one, one per line, newest last, written to a temp file, fsynced,
// renamed over the record, then the directory fsynced. It writes nothing
// without a boot id or when the directory does not exist yet (no engine ever
// ran on this disk).
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
	var ids []string
	if b, err := readRegular(path); err == nil {
		for _, id := range strings.Fields(string(b)) {
			if id != bootID {
				ids = append(ids, id)
			}
		}
	}
	ids = append(ids, bootID)
	if len(ids) > cleanStopKeep {
		ids = ids[len(ids)-cleanStopKeep:]
	}
	tmp := path + ".tmp"
	if err := os.Remove(tmp); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0644)
	if err != nil {
		return err
	}
	_, err = f.WriteString(strings.Join(ids, "\n") + "\n")
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

// readRegular reads a regular file without following a symlink at its name.
func readRegular(path string) ([]byte, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if st, err := f.Stat(); err != nil || !st.Mode().IsRegular() {
		return nil, errors.New(path + " is not a regular file")
	}
	return io.ReadAll(io.LimitReader(f, 64<<10))
}
