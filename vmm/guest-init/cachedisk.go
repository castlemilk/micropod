package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The persistent cache disk (caches.ext4): the host attaches it as the second
// virtio-blk device (/dev/vdb) and passes mp.cache_disk=1. Guest init mounts
// it at cacheDiskMount before it starts the engine, so the engine's crash
// recovery and every store it creates are on that disk. It tells the engine
// the outcome in MICROPOD_CACHE_DISK (guest/runner caches_linux.go,
// cacheDiskUnavailable).
//
// BuildKit's state is not on it. BuildKit runs on the containerd worker: its
// metadata (cache.db, the records of every RUN --mount=type=cache) refers to
// containerd snapshots and content under /var/lib/containerd on the OS disk.
// Both stay on the OS disk together, so replacing disk.ext4 (machine install
// --replace-disk) starts BuildKit empty and consistent instead of leaving it
// metadata whose snapshots are gone. An earlier version bound the cache
// disk's _buildkit directory over BuildKit's root; retireSplitBuildkit moves
// what that left into .trash, which the engine empties.
const (
	cacheDiskArg    = "mp.cache_disk"
	cacheDiskDevice = "/dev/vdb"
	cacheDiskMount  = "/var/lib/micropod/caches"
	cacheDiskEnv    = "MICROPOD_CACHE_DISK"
)

// splitBuildkitDir is where that earlier version kept BuildKit's root on the
// cache disk (overridable in tests).
var splitBuildkitDir = cacheDiskMount + "/_buildkit"

// retireSplitBuildkit moves an earlier boot's BuildKit root on the cache disk
// (splitBuildkitDir) into the cache disk's .trash, where the engine's crash
// fence deletes it in the background (guest/runner emptyCacheTrash). Its
// metadata names snapshots of an OS disk that may be gone, so nothing may
// mount or read it again. It returns where the directory went ("" when there
// was none).
func retireSplitBuildkit() (string, error) {
	if _, err := os.Lstat(splitBuildkitDir); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	trash := filepath.Join(filepath.Dir(splitBuildkitDir), ".trash")
	if err := os.MkdirAll(trash, 0700); err != nil {
		return "", err
	}
	dest := filepath.Join(trash, fmt.Sprintf("buildkit-split-%d", time.Now().UnixNano()))
	if err := os.Rename(splitBuildkitDir, dest); err != nil {
		return "", err
	}
	return dest, nil
}

// What became of the cache disk this boot.
const (
	// No cache disk: the stores live on the OS disk below cacheDiskMount,
	// with their marks, .trash and clean-stop record, as before.
	cacheDiskNone = ""
	// Mounted at cacheDiskMount.
	cacheDiskMounted = "mounted"
	// The host attached one (or /dev/vdb exists) but it is missing or would
	// not mount: shared caches are off for the boot. Nothing may create
	// stores below the mount point on the OS disk, where the next boot's
	// mount would hide them.
	cacheDiskUnavailable = "unavailable"
)

// cacheDiskRequested reports whether the host attached a cache disk
// (mp.cache_disk=1). Any other value is returned as an error to log.
func cacheDiskRequested(params map[string]string) (bool, error) {
	value, ok := params[cacheDiskArg]
	switch {
	case !ok || value == "0":
		return false, nil
	case value == "1":
		return true, nil
	default:
		return true, fmt.Errorf("%s=%q (want 1); treating the cache disk as attached", cacheDiskArg, value)
	}
}

// cacheDiskDevicePresent waits briefly for the device node: virtio-blk probes
// before init runs, but a requested disk gets a moment before it counts as
// missing.
func cacheDiskDevicePresent(dev string, requested bool) bool {
	wait := 0
	if requested {
		wait = 100
	}
	for i := 0; ; i++ {
		if _, err := os.Stat(dev); err == nil {
			return true
		}
		if i >= wait {
			return false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Overridable in tests.
var (
	// cleanStopRecord is where a stop records, as this boot's id, that every
	// process had exited and the final sync had returned. It lives with the
	// shared caches' dirty marks (.meta below cacheDiskMount), on the
	// filesystem that holds the stores: the cache disk when there is one, so
	// replacing the OS disk keeps it next to the marks it decides. The
	// engine's next start reads it: a unit still marked dirty by that boot
	// holds nothing that missed the disk, so it is kept instead of discarded
	// (guest/runner caches_dirty_linux.go).
	cleanStopRecord = cacheDiskMount + "/.meta/clean-stop"
	// legacyCleanStopRecord is the record's earlier place on the OS disk; the
	// engine still honours it on the same filesystem until a new record
	// exists, and a successful new record removes it.
	legacyCleanStopRecord = "/var/lib/micropod/clean-stop"
)

const bootIDFile = "/proc/sys/kernel/random/boot_id"

// recordCleanStop writes the clean-stop record for this boot, unless the
// engine had no shared caches (the cache disk was unavailable).
func recordCleanStop(cacheDisk, bootID string) error {
	if cacheDisk == cacheDiskUnavailable {
		return nil
	}
	if err := writeCleanStop(cleanStopRecord, bootID); err != nil {
		return err
	}
	if bootID == "" {
		return nil
	}
	if err := os.Remove(legacyCleanStopRecord); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
