//go:build linux

package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// defaultMax matches the API's 32 MiB file limit.
const defaultMax = 32 << 20

// entry is a stat result: the API's FileStat / DirEntry.
type entry struct {
	Name  string `json:"name,omitempty"`
	Type  string `json:"type"`
	Size  int64  `json:"size"`
	Mode  uint32 `json:"mode"`
	Mtime int64  `json:"mtime"`
}

func lstat(path string) (entry, error) {
	var st syscall.Stat_t
	if err := syscall.Lstat(path, &st); err != nil {
		return entry{}, &fs.PathError{Op: "stat", Path: path, Err: err}
	}
	return entry{Type: fileType(st.Mode), Size: st.Size, Mode: st.Mode, Mtime: st.Mtim.Sec}, nil
}

func fileType(mode uint32) string {
	switch mode & syscall.S_IFMT {
	case syscall.S_IFREG:
		return "file"
	case syscall.S_IFDIR:
		return "dir"
	case syscall.S_IFLNK:
		return "symlink"
	}
	return "other"
}

// readFile streams a file to stdout, refusing directories and anything
// over --max bytes.
func readFile(args []string, stdout io.Writer) error {
	f, err := parse(args, 1, "--max")
	if err != nil {
		return err
	}
	limit := int64(defaultMax)
	if v, ok := f.set["--max"]; ok {
		if limit, err = strconv.ParseInt(v, 10, 64); err != nil || limit < 0 {
			return usageError("--max wants a byte count")
		}
	}
	path := f.pos[0]
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if info.IsDir() {
		return &fs.PathError{Op: "read", Path: path, Err: syscall.EISDIR}
	}
	if info.Mode().IsRegular() && info.Size() > limit {
		return &fs.PathError{Op: "read", Path: path, Err: syscall.EFBIG}
	}
	// Files like /proc/* report size 0: read one past the limit to know.
	n, err := io.Copy(stdout, io.LimitReader(file, limit+1))
	if err != nil {
		return err
	}
	if n > limit {
		return &fs.PathError{Op: "read", Path: path, Err: syscall.EFBIG}
	}
	return nil
}

// writeFile replaces (or appends to) a file with stdin. --mode sets the
// raw permission bits (setuid/setgid/sticky included).
func writeFile(args []string, stdin io.Reader) error {
	f, err := parse(args, 1, "--mode")
	if err != nil {
		return err
	}
	path := f.pos[0]
	mode, hasMode, err := modeFlag(f.set["--mode"], f.has("--mode"))
	if err != nil {
		return err
	}
	if f.has("--parents") {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return err
		}
	}
	flags := os.O_WRONLY | os.O_CREATE
	if f.has("--append") {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	file, err := os.OpenFile(path, flags, 0o666)
	if err != nil {
		return err
	}
	if _, err := io.Copy(file, stdin); err != nil {
		file.Close()
		return &fs.PathError{Op: "write", Path: path, Err: unwrapErrno(err)}
	}
	if hasMode {
		if err := syscall.Fchmod(int(file.Fd()), mode); err != nil {
			file.Close()
			return &fs.PathError{Op: "chmod", Path: path, Err: err}
		}
	}
	return file.Close()
}

func modeFlag(value string, present bool) (uint32, bool, error) {
	if !present {
		return 0, false, nil
	}
	mode, err := strconv.ParseUint(value, 8, 32)
	if err != nil || mode > 0o7777 {
		return 0, false, usageError("mode wants octal permission bits, e.g. 644")
	}
	return uint32(mode), true, nil
}

func statPath(args []string, stdout io.Writer) error {
	f, err := parse(args, 1)
	if err != nil {
		return err
	}
	st, err := lstat(f.pos[0])
	if err != nil {
		return err
	}
	return json.NewEncoder(stdout).Encode(st)
}

// listDir writes one JSON line per entry (not recursive, no . or ..).
func listDir(args []string, stdout io.Writer) error {
	f, err := parse(args, 1)
	if err != nil {
		return err
	}
	dir := f.pos[0]
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	out := bufio.NewWriter(stdout)
	enc := json.NewEncoder(out)
	for _, e := range entries {
		st, err := lstat(filepath.Join(dir, e.Name()))
		if err != nil {
			continue // removed while listing
		}
		st.Name = e.Name()
		if err := enc.Encode(st); err != nil {
			return err
		}
	}
	return out.Flush()
}

func makeDir(args []string) error {
	f, err := parse(args, 1)
	if err != nil {
		return err
	}
	if f.has("--parents") {
		return os.MkdirAll(f.pos[0], 0o755)
	}
	return os.Mkdir(f.pos[0], 0o755)
}

// remove deletes a file or an empty directory; a non-empty directory only
// with --recursive. A missing path is ENOENT either way.
func remove(args []string) error {
	f, err := parse(args, 1)
	if err != nil {
		return err
	}
	path := f.pos[0]
	if _, err := os.Lstat(path); err != nil {
		return err
	}
	if f.has("--recursive") {
		return os.RemoveAll(path)
	}
	return os.Remove(path)
}

// rename moves FROM to exactly TO (rename(2) semantics, not "into a
// directory"); across filesystems it copies, then deletes FROM.
func rename(args []string) error {
	f, err := parse(args, 2)
	if err != nil {
		return err
	}
	from, to := f.pos[0], f.pos[1]
	err = os.Rename(from, to)
	if !errors.Is(err, syscall.EXDEV) {
		return err
	}
	if err := copyTree(from, to, true); err != nil {
		return err
	}
	return os.RemoveAll(from)
}

// copyPath copies FROM to exactly TO: a file (mode kept), a symlink as a
// symlink, a directory tree with --recursive (merged into an existing TO).
func copyPath(args []string) error {
	f, err := parse(args, 2)
	if err != nil {
		return err
	}
	return copyTree(f.pos[0], f.pos[1], f.has("--recursive"))
}

func copyTree(from, to string, recursive bool) error {
	info, err := os.Lstat(from)
	if err != nil {
		return err
	}
	switch {
	case info.Mode()&fs.ModeSymlink != 0:
		target, err := os.Readlink(from)
		if err != nil {
			return err
		}
		return os.Symlink(target, to)
	case info.IsDir():
		if !recursive {
			return &fs.PathError{Op: "copy", Path: from, Err: syscall.EISDIR}
		}
		src, dst := filepath.Clean(from), filepath.Clean(to)
		if dst == src || strings.HasPrefix(dst, src+"/") {
			return &fs.PathError{Op: "copy into itself", Path: to, Err: syscall.EINVAL}
		}
		if err := os.MkdirAll(to, info.Mode().Perm()|0o700); err != nil {
			return err
		}
		entries, err := os.ReadDir(from)
		if err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyTree(filepath.Join(from, e.Name()), filepath.Join(to, e.Name()), true); err != nil {
				return err
			}
		}
		return os.Chmod(to, info.Mode().Perm())
	case info.Mode().IsRegular():
		return copyFile(from, to, info)
	default:
		return &fs.PathError{Op: "copy (not a file, directory or symlink)", Path: from, Err: syscall.EINVAL}
	}
}

func copyFile(from, to string, info fs.FileInfo) error {
	src, err := os.Open(from)
	if err != nil {
		return err
	}
	defer src.Close()
	dst, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, info.Mode().Perm())
	if err != nil {
		return err
	}
	if _, err := io.Copy(dst, src); err != nil {
		dst.Close()
		return &fs.PathError{Op: "copy", Path: to, Err: unwrapErrno(err)}
	}
	if err := dst.Chmod(info.Mode().Perm()); err != nil {
		dst.Close()
		return err
	}
	return dst.Close()
}

func chmod(args []string) error {
	f, err := parse(args, 2)
	if err != nil {
		return err
	}
	mode, _, err := modeFlag(f.pos[0], true)
	if err != nil {
		return err
	}
	if err := syscall.Chmod(f.pos[1], mode); err != nil {
		return &fs.PathError{Op: "chmod", Path: f.pos[1], Err: err}
	}
	return nil
}

// unwrapErrno keeps an errno (ENOSPC, EDQUOT…) visible through io.Copy's
// wrapping.
func unwrapErrno(err error) error {
	var errno syscall.Errno
	if errors.As(err, &errno) {
		return errno
	}
	return err
}
