package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"golang.org/x/sys/unix"
	"os"
)

type identity struct {
	FSType  string `json:"fs_type"`
	Magic   string `json:"fs_magic"`
	MountID uint64 `json:"mount_id"`
	Device  string `json:"device"`
	Inode   uint64 `json:"inode"`
	Size    uint64 `json:"size_bytes"`
	DAX     *bool  `json:"dax"`
}

type receipt struct {
	Target *identity `json:"target,omitempty"`
	report
}

func inspect(fd int) (identity, unix.Statx_t, error) {
	var st unix.Statx_t
	var fs unix.Statfs_t
	const required = unix.STATX_TYPE | unix.STATX_INO | unix.STATX_SIZE | unix.STATX_MNT_ID | unix.STATX_MTIME | unix.STATX_CTIME
	if err := unix.Statx(fd, "", unix.AT_EMPTY_PATH, required, &st); err != nil {
		return identity{}, st, err
	}
	if st.Mask&required != required || st.Mode&unix.S_IFMT != unix.S_IFREG {
		return identity{}, st, errors.New("need a regular file with statx mount, size, inode and time fields")
	}
	if err := unix.Fstatfs(fd, &fs); err != nil {
		return identity{}, st, err
	}
	dev := fmt.Sprintf("%d:%d", st.Dev_major, st.Dev_minor)
	mounts, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return identity{}, st, err
	}
	defer mounts.Close()
	kind, err := mountType(mounts, st.Mnt_id, dev)
	if err != nil {
		return identity{}, st, err
	}
	id := identity{FSType: kind, Magic: fmt.Sprintf("%#x", fs.Type), MountID: st.Mnt_id, Device: dev, Inode: st.Ino, Size: st.Size}
	if st.Attributes_mask&unix.STATX_ATTR_DAX != 0 {
		dax := st.Attributes&unix.STATX_ATTR_DAX != 0
		id.DAX = &dax
	}
	return id, st, nil
}

func probe(path, expected string) receipt {
	fail := func(id *identity, reason string) receipt { return receipt{id, report{Verdict: "error", Why: reason}} }
	fd, err := unix.Open(path, unix.O_RDONLY|unix.O_CLOEXEC|unix.O_NOFOLLOW|unix.O_NONBLOCK, 0)
	if err != nil {
		return fail(nil, err.Error())
	}
	defer unix.Close(fd)
	id, before, err := inspect(fd)
	if err != nil {
		return fail(nil, err.Error())
	}
	magic := map[string]string{"ext4": fmt.Sprintf("%#x", unix.EXT4_SUPER_MAGIC), "overlay": fmt.Sprintf("%#x", unix.OVERLAYFS_SUPER_MAGIC)}
	if id.FSType != expected || id.Magic != magic[expected] {
		return fail(&id, "filesystem differs from requested control")
	}
	if expected == "ext4" && (id.DAX == nil || *id.DAX) {
		return fail(&id, "ext4 probe requires verified non-DAX inode")
	}
	r := compare(id.Size, func(b []byte, flagged bool) (int, error) {
		flags := 0
		if flagged {
			flags = unix.RWF_DONTCACHE
		}
		return unix.Preadv2(fd, [][]byte{b}, 0, flags)
	})
	afterID, after, err := inspect(fd)
	if err != nil || afterID.MountID != id.MountID || afterID.FSType != id.FSType || afterID.Magic != id.Magic ||
		before.Ino != after.Ino || before.Size != after.Size || before.Mtime != after.Mtime || before.Ctime != after.Ctime {
		r.Verdict = "error"
		r.Why = "file or mount changed during probe, or recheck failed"
	}
	return receipt{&id, r}
}

func main() {
	expect := flag.String("expect-fs", "", "expected mount type: ext4 or overlay")
	flag.Parse()
	if flag.NArg() != 1 || (*expect != "ext4" && *expect != "overlay") {
		fmt.Fprintln(os.Stderr, "usage: dontcache -expect-fs ext4|overlay EXISTING_REGULAR_FILE")
		os.Exit(2)
	}
	result := probe(flag.Arg(0), *expect)
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	os.Exit(exitCode(result.Verdict))
}
