package main

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"time"
)

// Growing a disk (`micropod machine disk grow`).
//
// The machine's disks are ext4 with sparse_super2 and no resize inode, which
// the kernel will not grow while mounted ("Online resizing not supported
// with sparse_super2"), so the grow is offline, with e2fsprogs (the tool
// bundle's e2fsprogs/, Alpine's, run by the root's musl loader: the OS disk
// has none of its own). The host never grows a disk in place: it clones it
// (APFS clonefile), extends the clone and boots a maintenance machine with
// the clone as the second disk (/dev/vdb) and mp.disk_grow=1; the OS disk is
// the machine's own, booted as always, and nothing but this runs. Guest init
// replays the clone's journal (a mount and an unmount), checks it, grows it
// to the device's size, checks it again, prints one result line and powers
// off. The host renames the clone over the disk only once the clone's
// superblock says it grew: a kill at any point before leaves the disk as it
// was, after it the disk is the grown, checked clone.

const (
	diskGrowParam  = "mp.disk_grow"
	diskGrowDevice = "/dev/vdb"
	diskGrowMount  = "/run/micropod-disk-grow"
	muslLoader     = "/lib/ld-musl-aarch64.so.1"
	// The result line the host reads from the console.
	diskGrowOK     = "MICROPOD_DISK_GROW_OK"
	diskGrowFailed = "MICROPOD_DISK_GROW_FAILED"
)

// ext4Geometry is what a superblock says of a filesystem's size.
type ext4Geometry struct {
	blocks    uint64
	blockSize uint64
}

func (g ext4Geometry) bytes() uint64 { return g.blocks * g.blockSize }

// parseExt4Superblock reads the size fields of an ext4 superblock (the 1024
// bytes at offset 1024).
func parseExt4Superblock(sb []byte) (ext4Geometry, error) {
	if len(sb) < 0x158 {
		return ext4Geometry{}, errors.New("short superblock")
	}
	if binary.LittleEndian.Uint16(sb[0x38:]) != 0xEF53 {
		return ext4Geometry{}, errors.New("not an ext4 filesystem")
	}
	logSize := binary.LittleEndian.Uint32(sb[0x18:])
	if logSize > 6 {
		return ext4Geometry{}, fmt.Errorf("invalid block size 2^%d KiB", logSize)
	}
	blocks := uint64(binary.LittleEndian.Uint32(sb[0x04:]))
	if binary.LittleEndian.Uint32(sb[0x60:])&0x80 != 0 { // 64bit
		blocks |= uint64(binary.LittleEndian.Uint32(sb[0x150:])) << 32
	}
	return ext4Geometry{blocks: blocks, blockSize: 1024 << logSize}, nil
}

func readExt4Geometry(dev string) (ext4Geometry, error) {
	f, err := os.Open(dev)
	if err != nil {
		return ext4Geometry{}, err
	}
	defer f.Close()
	sb := make([]byte, 1024)
	if _, err := f.ReadAt(sb, 1024); err != nil {
		return ext4Geometry{}, fmt.Errorf("read the superblock of %s: %w", dev, err)
	}
	return parseExt4Superblock(sb)
}

// blockDeviceBytes is a block device's size (lseek to its end).
func blockDeviceBytes(dev string) (uint64, error) {
	f, err := os.Open(dev)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	n, err := f.Seek(0, io.SeekEnd)
	if err != nil {
		return 0, err
	}
	return uint64(n), nil
}

// diskGrower runs one grow; its steps are fields so tests can stand in.
type diskGrower struct {
	dev, tools string
	geometry   func(dev string) (ext4Geometry, error)
	size       func(dev string) (uint64, error)
	// replay mounts and unmounts the filesystem, so its journal is replayed
	// and the check and the resize see a clean one.
	replay func(dev string) error
	// run runs an e2fsprogs tool and returns its exit status.
	run func(tool string, args ...string) (int, error)
	log func(format string, args ...any)
}

// grow checks, grows and checks the filesystem on g.dev; it returns the
// geometry before and after.
func (g diskGrower) grow() (before, after ext4Geometry, err error) {
	size, err := g.size(g.dev)
	if err != nil {
		return before, after, fmt.Errorf("size of %s: %w", g.dev, err)
	}
	before, err = g.geometry(g.dev)
	if err != nil {
		return before, after, err
	}
	if size < before.bytes() {
		return before, after, fmt.Errorf("%s holds %d bytes, less than its filesystem's %d: a disk is never shrunk", g.dev, size, before.bytes())
	}
	if err := g.replay(g.dev); err != nil {
		return before, after, err
	}
	start := time.Now()
	// e2fsck: 0 nothing to fix, 1 fixed; anything else and the clone is not
	// grown (the host keeps the disk it has).
	if code, err := g.run("e2fsck", "-f", "-y", g.dev); err != nil || code > 1 {
		return before, after, fmt.Errorf("e2fsck before the grow: exit %d %v", code, err)
	}
	g.log("checked %s in %v", g.dev, time.Since(start).Round(time.Millisecond))
	start = time.Now()
	if code, err := g.run("resize2fs", g.dev); err != nil || code != 0 {
		return before, after, fmt.Errorf("resize2fs: exit %d %v", code, err)
	}
	g.log("grew %s in %v", g.dev, time.Since(start).Round(time.Millisecond))
	start = time.Now()
	if code, err := g.run("e2fsck", "-f", "-n", g.dev); err != nil || code != 0 {
		return before, after, fmt.Errorf("e2fsck after the grow found problems: exit %d %v", code, err)
	}
	g.log("checked %s again in %v", g.dev, time.Since(start).Round(time.Millisecond))
	after, err = g.geometry(g.dev)
	if err != nil {
		return before, after, err
	}
	if after.blocks < before.blocks {
		return before, after, fmt.Errorf("the filesystem shrank from %d to %d blocks", before.blocks, after.blocks)
	}
	return before, after, nil
}
