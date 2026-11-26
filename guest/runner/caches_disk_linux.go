package main

import (
	"bufio"
	"bytes"
	"os"
	"strings"
	"syscall"
)

// cacheDiskState is the guest's own account of the persistent cache disk
// (the host's caches.ext4, attached as /dev/vdb and mounted by mp-hvf-init
// on cacheRoot): the cacheDisk object of GET /micropod/caches. The host
// reports the disk mounted from this, never from caches.ext4 existing, and
// shows the inventory's top-level unavailable when shared caches are off for
// the boot.
//
//	{"state": "mounted", "device": "/dev/vdb", "mounted": true,
//	 "sizeBytes": 107374182400, "freeBytes": 96636764160}
type cacheDiskState struct {
	// State is guest init's outcome for this boot (MICROPOD_CACHE_DISK,
	// cacheDiskInit): "mounted", "unavailable" (the host attached a disk
	// that is missing or did not mount, so shared caches are off) or "none"
	// (no cache disk: the stores live on the OS disk).
	State string `json:"state"`
	// Device is the cache disk's device node, when it exists.
	Device string `json:"device,omitempty"`
	// Mounted is what mountinfo shows: Device mounted at cacheRoot.
	Mounted bool `json:"mounted"`
	// MountInfoError says why the guest could not read mountinfo; Mounted
	// is then false because the guest cannot tell.
	MountInfoError string `json:"mountInfoError,omitempty"`
	SizeBytes      uint64 `json:"sizeBytes,omitempty"`
	FreeBytes      uint64 `json:"freeBytes,omitempty"`
}

// Replaced in tests.
var (
	cacheDiskDevice = "/dev/vdb"
	mountInfoPath   = "/proc/self/mountinfo"
)

// observeCacheDisk reports guest init's outcome and whether cacheDiskDevice
// is mounted on cacheRoot. No device means no cache disk is attached (not
// mounted).
func observeCacheDisk() cacheDiskState {
	state := cacheDiskState{State: strings.TrimSpace(cacheDiskInit)}
	if state.State == "" {
		state.State = "none"
	}
	if _, err := os.Stat(cacheDiskDevice); err != nil {
		return state
	}
	state.Device = cacheDiskDevice
	info, err := os.ReadFile(mountInfoPath)
	if err != nil {
		state.MountInfoError = err.Error()
		return state
	}
	state.Mounted = mountedOn(info, cacheDiskDevice, cacheRoot)
	if state.Mounted {
		var st syscall.Statfs_t
		if syscall.Statfs(cacheRoot, &st) == nil {
			state.SizeBytes = st.Blocks * uint64(st.Bsize)
			state.FreeBytes = st.Bavail * uint64(st.Bsize)
		}
	}
	return state
}

// mountedOn reports whether mountinfo (proc(5) format) has source mounted
// at target. Fields before " - " are id, parent, major:minor, root, mount
// point, options...; after it come fstype and source.
func mountedOn(mountinfo []byte, source, target string) bool {
	scanner := bufio.NewScanner(bytes.NewReader(mountinfo))
	for scanner.Scan() {
		line := scanner.Text()
		before, after, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}
		fields := strings.Fields(before)
		tail := strings.Fields(after)
		if len(fields) < 5 || len(tail) < 2 {
			continue
		}
		if unescapeMountPath(fields[4]) == target && unescapeMountPath(tail[1]) == source {
			return true
		}
	}
	return false
}

// unescapeMountPath undoes mountinfo's octal escapes for space, tab,
// newline and backslash.
func unescapeMountPath(raw string) string {
	return strings.NewReplacer(`\040`, " ", `\011`, "\t", `\012`, "\n", `\134`, `\`).Replace(raw)
}
