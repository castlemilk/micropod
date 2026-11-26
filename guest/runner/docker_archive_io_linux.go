package main

import (
	"archive/tar"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const maxArchivePath = 4095

type dockerArchivePath struct {
	absolute, name string
	directory      bool
}

func parseArchivePath(raw string) (dockerArchivePath, error) {
	if raw == "" || len(raw) > maxArchivePath || strings.IndexByte(raw, 0) >= 0 {
		return dockerArchivePath{}, fail(http.StatusBadRequest, "a valid container archive path is required")
	}
	absolute := path.Clean("/" + raw)
	name := path.Base(absolute)
	dot := path.Base(raw) == "."
	if dot {
		name = "."
	}
	return dockerArchivePath{absolute, name, dot || strings.HasSuffix(raw, "/")}, nil
}

type dockerArchiveStat struct {
	Name       string      `json:"name"`
	Size       int64       `json:"size"`
	Mode       os.FileMode `json:"mode"`
	Mtime      time.Time   `json:"mtime"`
	LinkTarget string      `json:"linkTarget"`
}

func archiveReadable(mode os.FileMode) bool {
	return mode.IsRegular() || mode.IsDir() || mode&os.ModeSymlink != 0
}

func archiveOpen(dir *os.File, relative string, flags uint64) (*os.File, error) {
	if relative == "" {
		fd, err := unix.FcntlInt(dir.Fd(), unix.F_DUPFD_CLOEXEC, 0)
		if err != nil {
			return nil, err
		}
		return os.NewFile(uintptr(fd), "."), nil
	}
	fd, err := unix.Openat2(int(dir.Fd()), relative, &unix.OpenHow{
		Flags:   flags | unix.O_PATH | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_IN_ROOT | unix.RESOLVE_NO_MAGICLINKS | unix.RESOLVE_NO_XDEV | unix.RESOLVE_NO_SYMLINKS,
	})
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), relative), nil
}

func archiveReadFD(file *os.File) (*os.File, error) {
	// A checked O_PATH handle can be reopened without resolving the container
	// path again. Never open an unchecked device, pipe, or socket for I/O.
	return os.Open(archiveFDPath(file))
}

func archiveFDPath(file *os.File) string {
	return "/proc/self/fd/" + strconv.FormatUint(uint64(file.Fd()), 10)
}

func (v dockerArchiveView) linkTarget(name, target string) (string, error) {
	if target == "" || len(target) > maxArchivePath || strings.IndexByte(target, 0) >= 0 {
		return "", unix.EINVAL
	}
	// Resolve relative links with ordinary leading ".." components. After a
	// named component, ".." depends on whether that component is a symlink.
	// Reject that ambiguous form instead of changing what the link means.
	seenName := false
	climbs := 0
	for component := range strings.SplitSeq(target, "/") {
		switch component {
		case "", ".":
		case "..":
			if seenName {
				return "", unix.EINVAL
			}
			climbs++
		default:
			seenName = true
		}
	}
	if path.IsAbs(target) {
		if v.mount != "" {
			return "", unix.EXDEV
		}
		target = path.Clean(target)
	} else {
		parent := path.Dir(name)
		if v.mount != "" && climbs != 0 {
			relative := v.relative(parent)
			if relative == "" || climbs > 1+strings.Count(relative, "/") {
				return "", unix.EXDEV
			}
		}
		target = path.Join(parent, target)
	}
	if !v.includes(target) {
		return "", unix.EXDEV
	}
	return target, nil
}

// Let the kernel reject symlinks on ordinary opens. If one is encountered,
// resolve it against the selected view and check logical mount boundaries
// before reopening. Each kernel open still rejects symlinks and mount jumps.
func (v dockerArchiveView) openResolved(absolute string, flags uint64) (*os.File, string, error) {
	for links := 0; links < 40; links++ {
		if !v.includes(absolute) {
			return nil, "", unix.EXDEV
		}
		relative := v.relative(absolute)
		f, err := archiveOpen(v.root, relative, flags)
		if !errors.Is(err, unix.ELOOP) {
			return f, absolute, err
		}
		parts := strings.Split(relative, "/")
		prefix := v.mount
		if prefix == "" {
			prefix = "/"
		}
		replaced := false
		for i, part := range parts {
			prefix = path.Join(prefix, part)
			probe, err := archiveOpen(v.root, strings.Join(parts[:i+1], "/"), unix.O_NOFOLLOW)
			if err != nil {
				return nil, "", err
			}
			info, err := probe.Stat()
			if err == nil && info.Mode()&os.ModeSymlink != 0 {
				var target string
				target, err = archiveReadLink(probe)
				if err == nil {
					target, err = v.linkTarget(prefix, target)
					absolute = path.Join(target, strings.Join(parts[i+1:], "/"))
					replaced = true
				}
			}
			probe.Close()
			if err != nil {
				return nil, "", err
			}
			if replaced {
				break
			}
		}
		if !replaced {
			return nil, "", unix.ELOOP
		}
	}
	return nil, "", unix.ELOOP
}

func (v dockerArchiveView) stat(p dockerArchivePath) (*os.File, dockerArchiveStat, dockerArchivePath, error) {
	flags := uint64(unix.O_NOFOLLOW)
	if p.directory {
		flags = unix.O_DIRECTORY
	}
	f, resolved, err := v.openResolved(p.absolute, flags)
	if err != nil {
		return nil, dockerArchiveStat{}, p, archivePathError(p.absolute, err)
	}
	info, err := f.Stat()
	if err != nil {
		f.Close()
		return nil, dockerArchiveStat{}, p, err
	}
	if p.directory && !info.IsDir() {
		f.Close()
		return nil, dockerArchiveStat{}, p, fail(http.StatusNotFound, "archive path is not a directory: "+p.absolute)
	}
	stat := dockerArchiveStat{Name: p.name, Size: info.Size(), Mode: info.Mode(), Mtime: info.ModTime().UTC()}
	if info.Mode()&os.ModeSymlink != 0 {
		stat.LinkTarget, err = archiveReadLink(f)
		if err != nil {
			f.Close()
			return nil, dockerArchiveStat{}, p, err
		}
	}
	p.absolute = resolved
	return f, stat, p, nil
}

func archiveReadLink(f *os.File) (string, error) {
	var target [maxArchivePath + 1]byte
	n, err := unix.Readlinkat(int(f.Fd()), "", target[:])
	if err != nil {
		return "", err
	}
	if n == len(target) {
		return "", unix.ENAMETOOLONG
	}
	return string(target[:n]), nil
}

func (v dockerArchiveView) writeTar(ctx context.Context, destination io.Writer, p dockerArchivePath, f *os.File, stat dockerArchiveStat) error {
	name := stat.Name
	if name == "/" {
		name = "."
	}
	out := tar.NewWriter(destination)
	if err := v.writeTarEntry(ctx, out, p.absolute, name, f, make(map[archiveInode]string)); err != nil {
		return err
	}
	return out.Close()
}

type archiveInode struct{ dev, ino uint64 }

func (v dockerArchiveView) writeTarEntry(ctx context.Context, out *tar.Writer, absolute, name string, f *os.File, links map[archiveInode]string) error {
	if err := ctx.Err(); err != nil {
		return err
	}
	info, err := f.Stat()
	if err != nil {
		return err
	}
	if !archiveReadable(info.Mode()) {
		return nil
	}
	var target string
	if info.Mode()&os.ModeSymlink != 0 {
		target, err = archiveReadLink(f)
		if err != nil {
			return err
		}
	}
	h, err := tar.FileInfoHeader(info, target)
	if err != nil {
		return err
	}
	h.Name = name
	if info.IsDir() {
		h.Name += "/"
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok && info.Mode().IsRegular() && stat.Nlink > 1 {
		inode := archiveInode{stat.Dev, stat.Ino}
		if previous, ok := links[inode]; ok {
			h.Typeflag, h.Linkname, h.Size = tar.TypeLink, previous, 0
			return out.WriteHeader(h)
		}
		links[inode] = name
	}
	if err := out.WriteHeader(h); err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return nil
	}
	stream, err := archiveReadFD(f)
	if err != nil {
		return err
	}
	defer stream.Close()
	if !info.IsDir() {
		_, err := io.CopyN(out, archiveContextReader{ctx, stream}, h.Size)
		return err
	}
	for {
		entries, err := stream.Readdirnames(128)
		for _, entry := range entries {
			childPath := path.Join(absolute, entry)
			if !v.includes(childPath) {
				continue
			}
			child, openErr := archiveOpen(f, entry, unix.O_NOFOLLOW)
			if errors.Is(openErr, unix.ENOENT) || errors.Is(openErr, unix.EXDEV) {
				continue // A live entry disappeared or is a separate mount.
			}
			if openErr != nil {
				return openErr
			}
			writeErr := v.writeTarEntry(ctx, out, childPath, name+"/"+entry, child, links)
			child.Close()
			if writeErr != nil {
				return writeErr
			}
		}
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

type archiveContextReader struct {
	ctx context.Context
	io.Reader
}

func (r archiveContextReader) Read(p []byte) (int, error) {
	if err := r.ctx.Err(); err != nil {
		return 0, err
	}
	return r.Reader.Read(p)
}

func (v dockerArchiveView) extract(ctx context.Context, p dockerArchivePath, source io.Reader, preserveOwner bool) error {
	destination, resolved, err := v.openResolved(p.absolute, unix.O_DIRECTORY)
	if errors.Is(err, unix.ENOTDIR) {
		return fail(http.StatusBadRequest, "the archive destination must be a directory")
	}
	if err != nil {
		return archivePathError(p.absolute, err)
	}
	defer destination.Close()
	info, err := destination.Stat()
	if err != nil {
		return err
	}
	if !info.IsDir() {
		return fail(http.StatusBadRequest, "the archive destination must be a directory")
	}

	in := tar.NewReader(archiveContextReader{ctx, source})
	directories := make(map[string]archiveMetadata)
	for {
		h, err := in.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return archiveUploadError(p.absolute, err)
		}
		entry, err := archiveEntryPath(h.Name)
		if err != nil {
			return err
		}
		absolute := path.Join(resolved, entry)
		if !v.includes(absolute) {
			return fail(http.StatusForbidden, "archive entry crosses a mount boundary: "+absolute)
		}
		switch h.Typeflag {
		case tar.TypeDir:
			if entry != "." {
				var directory *os.File
				directory, err = archiveDirectory(destination, entry)
				if err == nil {
					directories[entry] = archiveMetadataFor(h, preserveOwner)
					err = directory.Close()
				}
			}
		case tar.TypeReg, tar.TypeSymlink, tar.TypeLink:
			if entry == "." {
				return fail(http.StatusBadRequest, "an entry cannot replace the archive destination directory")
			}
			err = v.archiveWriteEntry(ctx, destination, resolved, entry, h, in, preserveOwner)
		default:
			return fail(http.StatusBadRequest, "archive uploads support files, directories and links within the container filesystem")
		}
		if err != nil {
			return archiveUploadError(absolute, err)
		}
	}
	return restoreArchiveDirectories(ctx, destination, directories)
}

func archiveEntryPath(raw string) (string, error) {
	if raw == "" || len(raw) > maxArchivePath || path.IsAbs(raw) || strings.IndexByte(raw, 0) >= 0 {
		return "", fail(http.StatusBadRequest, "invalid tar entry path")
	}
	for part := range strings.SplitSeq(raw, "/") {
		if part == ".." {
			return "", fail(http.StatusBadRequest, "invalid tar entry path")
		}
	}
	return path.Clean(raw), nil
}

// Resolve one directory component at a time so creation and the next lookup
// operate on a verified directory descriptor. Existing symlinks, separate
// mounts and mismatched file types are never traversed or replaced.
func archiveDirectory(root *os.File, relative string) (*os.File, error) {
	dir, err := archiveOpen(root, "", 0)
	if err != nil || relative == "." {
		return dir, err
	}
	for part := range strings.SplitSeq(relative, "/") {
		next, err := archiveOpen(dir, part, unix.O_DIRECTORY|unix.O_NOFOLLOW)
		if errors.Is(err, unix.ENOENT) {
			made := unix.Mkdirat(int(dir.Fd()), part, 0700)
			if made != nil && !errors.Is(made, unix.EEXIST) {
				dir.Close()
				return nil, made
			}
			next, err = archiveOpen(dir, part, unix.O_DIRECTORY|unix.O_NOFOLLOW)
			if err == nil && made == nil {
				err = unix.Fchmodat(int(next.Fd()), "", 0755, unix.AT_EMPTY_PATH)
			}
		}
		dir.Close()
		if err != nil {
			if next != nil {
				next.Close()
			}
			return nil, err
		}
		dir = next
	}
	return dir, nil
}

type archiveMetadata struct {
	uid, gid int
	mode     uint32
	modified time.Time
	owner    bool
	symlink  bool
}

func archiveMetadataFor(h *tar.Header, preserveOwner bool) archiveMetadata {
	// File permissions and the sticky bit are safe on shared bind sources.
	// Creating set-ID files through this API would extend that authority.
	return archiveMetadata{h.Uid, h.Gid, uint32(h.Mode) & 01777, h.ModTime, preserveOwner, h.Typeflag == tar.TypeSymlink}
}

func (m archiveMetadata) apply(f *os.File) error {
	fd := int(f.Fd())
	if m.owner {
		if m.uid < 0 || m.gid < 0 || uint64(m.uid) >= 1<<32-1 || uint64(m.gid) >= 1<<32-1 {
			return fail(http.StatusBadRequest, "invalid archive ownership")
		}
		if err := unix.Fchownat(fd, "", m.uid, m.gid, unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW); err != nil {
			return err
		}
	}
	if !m.symlink {
		if err := unix.Fchmodat(fd, "", m.mode, unix.AT_EMPTY_PATH); err != nil {
			return err
		}
	}
	if m.modified.IsZero() {
		return nil
	}
	stamp := unix.Timespec{Sec: m.modified.Unix(), Nsec: int64(m.modified.Nanosecond())}
	return unix.UtimesNanoAt(fd, "", []unix.Timespec{stamp, stamp}, unix.AT_EMPTY_PATH|unix.AT_SYMLINK_NOFOLLOW)
}

func restoreArchiveDirectories(ctx context.Context, root *os.File, directories map[string]archiveMetadata) error {
	names := make([]string, 0, len(directories))
	for name := range directories {
		names = append(names, name)
	}
	slices.Sort(names)
	// Descendants precede ancestors so restrictive directory permissions and
	// child creation cannot interfere with the restored metadata.
	for _, name := range slices.Backward(names) {
		if err := ctx.Err(); err != nil {
			return err
		}
		f, err := archiveOpen(root, name, unix.O_DIRECTORY|unix.O_NOFOLLOW)
		if err == nil {
			err = errors.Join(directories[name].apply(f), f.Close())
		}
		if err != nil {
			return archiveUploadError(name, err)
		}
	}
	return ctx.Err()
}

func (v dockerArchiveView) archiveWriteEntry(ctx context.Context, root *os.File, absolute, entry string, h *tar.Header, source io.Reader, preserveOwner bool) error {
	dir, err := archiveDirectory(root, path.Dir(entry))
	if err != nil {
		return err
	}
	defer dir.Close()
	fd, name := int(dir.Fd()), path.Base(entry)
	var existing unix.Stat_t
	if err := unix.Fstatat(fd, name, &existing, unix.AT_SYMLINK_NOFOLLOW); err == nil {
		switch existing.Mode & unix.S_IFMT {
		case unix.S_IFREG, unix.S_IFLNK:
		default:
			return fail(http.StatusBadRequest, "a regular file cannot replace the existing archive entry")
		}
	} else if !errors.Is(err, unix.ENOENT) {
		return err
	}
	temp := ".micropod-copy-" + engineID()
	switch h.Typeflag {
	case tar.TypeReg:
		err = archiveStageFile(fd, temp, h, source, preserveOwner)
	case tar.TypeSymlink:
		err = v.archiveStageSymlink(fd, temp, path.Join(absolute, entry), h, preserveOwner)
	case tar.TypeLink:
		err = v.archiveStageHardlink(root, absolute, fd, temp, h.Linkname)
	}
	if err != nil {
		return err
	}
	defer unix.Unlinkat(fd, temp, 0)
	if err := ctx.Err(); err != nil {
		return err
	}
	// Publish only complete entries. Rename does not follow a destination
	// symlink, and the kernel prevents replacement of a directory.
	return unix.Renameat(fd, temp, fd, name)
}

func archiveStageFile(fd int, name string, h *tar.Header, source io.Reader, preserveOwner bool) error {
	created, err := unix.Openat(fd, name, unix.O_WRONLY|unix.O_CREAT|unix.O_EXCL|unix.O_CLOEXEC, 0600)
	if err != nil {
		return err
	}
	f := os.NewFile(uintptr(created), name)
	_, err = io.CopyN(f, source, h.Size)
	if err == nil {
		err = archiveMetadataFor(h, preserveOwner).apply(f)
	}
	if err := errors.Join(err, f.Close()); err != nil {
		unix.Unlinkat(fd, name, 0)
		return err
	}
	return nil
}

func (v dockerArchiveView) archiveStageSymlink(fd int, name, absolute string, h *tar.Header, preserveOwner bool) error {
	target, err := v.linkTarget(absolute, h.Linkname)
	if err != nil {
		return err
	}
	f, _, err := v.openResolved(target, 0)
	if err != nil && !errors.Is(err, unix.ENOENT) {
		return err
	}
	if f != nil {
		f.Close()
	}
	if err := unix.Symlinkat(h.Linkname, fd, name); err != nil {
		return err
	}
	link, err := unix.Openat(fd, name, unix.O_PATH|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err == nil {
		f := os.NewFile(uintptr(link), name)
		err = errors.Join(archiveMetadataFor(h, preserveOwner).apply(f), f.Close())
	}
	if err != nil {
		unix.Unlinkat(fd, name, 0)
	}
	return err
}

func (v dockerArchiveView) archiveStageHardlink(root *os.File, absolute string, fd int, name, linkname string) error {
	target, err := archiveEntryPath(linkname)
	if err != nil {
		return err
	}
	if target == "." || !v.includes(path.Join(absolute, target)) {
		return fail(http.StatusBadRequest, "hardlink target must be a regular file in the same archive destination")
	}
	from, err := archiveOpen(root, target, unix.O_NOFOLLOW)
	if err != nil {
		return archiveUploadError(target, err)
	}
	defer from.Close()
	info, err := from.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() || info.Mode()&(os.ModeSetuid|os.ModeSetgid) != 0 {
		return fail(http.StatusBadRequest, "hardlink target must be an ordinary file")
	}
	// Link to the checked inode, without reopening the container path.
	return unix.Linkat(unix.AT_FDCWD, archiveFDPath(from), fd, name, unix.AT_SYMLINK_FOLLOW)
}

func archiveUploadError(path string, err error) error {
	if errors.Is(err, tar.ErrHeader) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, io.EOF) {
		return fail(http.StatusBadRequest, "invalid or truncated tar archive")
	}
	if errors.Is(err, unix.ENOTDIR) {
		return fail(http.StatusBadRequest, "archive entry conflicts with an existing file: "+path)
	}
	return archivePathError(path, err)
}

func archivePathError(path string, err error) error {
	switch {
	case errors.Is(err, unix.ENOENT), errors.Is(err, unix.ENOTDIR):
		return fail(http.StatusNotFound, "no such container path: "+path)
	case errors.Is(err, unix.EACCES), errors.Is(err, unix.EPERM), errors.Is(err, unix.EROFS),
		errors.Is(err, unix.ELOOP), errors.Is(err, unix.EXDEV):
		return fail(http.StatusForbidden, "archive path is inaccessible: "+path)
	case errors.Is(err, unix.ENAMETOOLONG), errors.Is(err, unix.EINVAL), errors.Is(err, unix.EISDIR):
		return fail(http.StatusBadRequest, "invalid archive path: "+path)
	}
	return fmt.Errorf("archive %s: %w", path, err)
}
