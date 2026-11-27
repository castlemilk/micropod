package main

import (
	"fmt"
	"os"
	"strings"
	"sync"
	"sync/atomic"

	"golang.org/x/sys/unix"
)

// The engine's records (containers, networks, volumes) live on the guest's OS
// disk, a journaled ext4 filesystem. There every fsync of a directory is a
// full journal commit (ext4_fsync_journal: ext4_force_commit), and one commit
// makes durable everything the filesystem completed before it: the journal is
// one sequence of transactions, and a commit writes its record behind a
// pre-flush. A commit costs the host disk two ordered flushes (the device has
// no FUA), and the record pattern "fsync the file, rename it, fsync the
// directory" paid for two of them per save.
//
// writeOut is the first half of that fsync without its commit: it writes f's
// dirty pages and waits for them (sync_file_range WAIT_BEFORE|WRITE|
// WAIT_AFTER, what fsync's file_write_and_wait_range does). When it returns,
// the blocks are allocated and the file's size updated in the journal's
// running or an earlier transaction, an unwritten extent is converted (ext4
// ends a page's writeback only after that conversion), and the data is on the
// device. So no commit that carries a later rename of f can carry a torn or
// empty f, and the next commit's pre-flush puts the data on stable storage:
// a following directory sync makes a renamed record durable with the one
// commit, and without it the rename alone is still atomic across a crash.
//
// Anywhere else (tmpfs or overlayfs in tests, an ext4 without a journal) it is
// fsync, which leaves that pattern as it was.
var writeOut = func(f *os.File) error {
	if !onJournaledExt4(f) {
		return f.Sync()
	}
	for {
		err := unix.SyncFileRange(int(f.Fd()), 0, 0, unix.SYNC_FILE_RANGE_WAIT_BEFORE|unix.SYNC_FILE_RANGE_WRITE|unix.SYNC_FILE_RANGE_WAIT_AFTER)
		if err != unix.EINTR {
			return err
		}
	}
}

// writeFileOut is os.WriteFile followed by writeOut.
func writeFileOut(path string, data []byte, mode os.FileMode) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, mode)
	if err != nil {
		return err
	}
	_, err = f.Write(data)
	if err == nil {
		err = writeOut(f)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func onJournaledExt4(f *os.File) bool {
	var fs unix.Statfs_t
	if unix.Fstatfs(int(f.Fd()), &fs) != nil || fs.Type != unix.EXT4_SUPER_MAGIC {
		return false
	}
	var st unix.Stat_t
	if unix.Fstat(int(f.Fd()), &st) != nil {
		return false
	}
	return journaled(st.Dev)
}

// recordCommits and recordWrites count the container records' durable saves
// and the ones that need only be whole (dockerRecord.writeIn), for the
// engine's metrics.
var recordCommits, recordWrites atomic.Int64

var journaledDevices sync.Map // device number -> bool

// journaled reports whether the ext4 filesystem on dev has a loaded internal
// journal: jbd2 names it <block device>-8 under /proc/fs/jbd2 (inode 8).
func journaled(dev uint64) bool {
	if v, ok := journaledDevices.Load(dev); ok {
		return v.(bool)
	}
	ok := false
	if b, err := os.ReadFile(fmt.Sprintf("/sys/dev/block/%d:%d/uevent", unix.Major(dev), unix.Minor(dev))); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			if name, found := strings.CutPrefix(line, "DEVNAME="); found && name != "" && !strings.Contains(name, "/") {
				_, err := os.Stat("/proc/fs/jbd2/" + name + "-8")
				ok = err == nil
			}
		}
	}
	journaledDevices.Store(dev, ok)
	return ok
}
