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
// on cacheRoot). The host reports cacheDiskPresent from this, never from
// caches.ext4 existing: an init that failed to mount it carries on with
// the caches on the root disk, which the next --replace-disk discards.
type cacheDiskState struct {
	Device    string `json:"device,omitempty"`
	Mounted   bool   `json:"mounted"`
	SizeBytes uint64 `json:"sizeBytes,omitempty"`
	FreeBytes uint64 `json:"freeBytes,omitempty"`
}

// Replaced in tests.
var (
	cacheDiskDevice = "/dev/vdb"
	mountInfoPath   = "/proc/self/mountinfo"
)

// observeCacheDisk reports whether cacheDiskDevice is mounted on
// cacheRoot. No device means no cache disk is attached (not mounted); an
// unreadable mountinfo means the guest cannot tell (nil).
func observeCacheDisk() *cacheDiskState {
	if _, err := os.Stat(cacheDiskDevice); err != nil {
		return &cacheDiskState{Mounted: false}
	}
	info, err := os.ReadFile(mountInfoPath)
	if err != nil {
		return nil
	}
	state := &cacheDiskState{Device: cacheDiskDevice, Mounted: mountedOn(info, cacheDiskDevice, cacheRoot)}
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
