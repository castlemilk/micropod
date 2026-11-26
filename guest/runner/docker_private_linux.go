package main

import (
	"errors"
	"fmt"
	"log"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// The machine's own directory on the host (MICROPOD_ENGINE_PRIVATE, which
// guest init sets from mp.private_b64 when the directory lies inside the
// workspace share): machine.json, the OS and cache disks, the payloads the
// VMM boots and run/guest-config, whose cache-policy.json decides every
// container's cache trust tier. The standard machine keeps it in
// ~/.micropod/hvf and the default workspace is the home directory, so a bind
// of a workspace path could otherwise reach it: directly, through a relative
// symlink a checkout carries (openMount resolves those beneath the
// workspace), or as part of a bind that covers it (-v $HOME:/h). A container
// could then rewrite the policy the host owns, or read every store through
// the cache disk. So a bind source inside it is refused, and a bind that
// covers it gets an empty read-only directory mounted over it.
//
// Both are decided by identity (device and inode), never by spelling: the
// host's file system ignores case and a symlink can name the directory by
// another path, but neither changes the inode a lookup ends on. Nor does a
// rename: a container that writes the workspace can move the directory, or
// one above it, under another name, so where a bind covers it is found at
// every open, walking up from the directory itself.

type fileID struct{ dev, ino uint64 }

func statID(st *unix.Stat_t) fileID { return fileID{uint64(st.Dev), st.Ino} }

type privateRoot struct {
	path string
	id   fileID
	// dir is the machine directory, held open from boot: wherever it is
	// moved, a walk up from it passes the directories that cover it now.
	dir *os.File
	// mask is the empty directory bound read-only over path in a bind that
	// covers it.
	mask string
}

// privateMaskDir is the empty directory privateRoot.mask names.
var privateMaskDir = filepath.Join(engineRoot, "private-mask")

// loadPrivateRoot opens p, reads its identity and prepares the mask
// directory. An empty p protects nothing (nil).
func loadPrivateRoot(p, maskDir string) (*privateRoot, error) {
	if p == "" {
		return nil, nil
	}
	if !path.IsAbs(p) || path.Clean(p) != p || p == "/" {
		return nil, fmt.Errorf("the machine directory %q is not a canonical absolute path", p)
	}
	fd, err := unix.Open(p, unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, fmt.Errorf("the machine directory %s: %w", p, err)
	}
	dir := os.NewFile(uintptr(fd), p)
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		dir.Close()
		return nil, fmt.Errorf("the machine directory %s: %w", p, err)
	}
	r := &privateRoot{path: p, id: statID(&st), dir: dir, mask: maskDir}
	if err := makeMaskDir(maskDir); err != nil {
		dir.Close()
		return nil, err
	}
	return r, nil
}

// makeMaskDir makes maskDir an empty read-only directory: whatever an earlier
// boot left there is removed.
func makeMaskDir(maskDir string) error {
	if err := os.RemoveAll(maskDir); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(maskDir), 0700); err != nil {
		return err
	}
	if err := os.Mkdir(maskDir, 0555); err != nil {
		return err
	}
	return os.Chmod(maskDir, 0555)
}

// errInsideMachine is what check returns for a bind source inside the
// machine's directory.
var errInsideMachine = errors.New("is inside the machine's own directory, which no container may bind")

// check decides a bind of the opened source f at the container path target:
// an error for a source inside the machine directory (the directory itself
// included), the container path to mask for a directory source that covers
// it, or "" for any other source.
func (r *privateRoot) check(f *os.File, source, target string) (string, error) {
	if r == nil {
		return "", nil
	}
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return "", err
	}
	if st.Mode&unix.S_IFMT == unix.S_IFDIR {
		rel, err := r.coveredBy(f, statID(&st))
		if err != nil {
			return "", fail(400, fmt.Sprintf("bind source %s: %v", source, err))
		}
		if rel != "" {
			return path.Join(target, rel), nil
		}
	}
	inside, err := r.inside(f)
	if errors.Is(err, errFileMoved) {
		return "", fail(400, fmt.Sprintf("bind source %s: %v", source, err))
	}
	if err != nil {
		return "", err
	}
	if inside {
		return "", fail(400, fmt.Sprintf("bind source %s %v", source, errInsideMachine))
	}
	return "", nil
}

// errMachineMoved is what coveredBy returns when the way down to the machine
// directory does not lead to it: it moved while it was found.
var errMachineMoved = errors.New("covers the machine's own directory, which moved while it was found")

// coveredBy is the path below the directory dir (id is its identity) at which
// the machine directory lies now, "" when it does not lie below dir. dir
// covers it when a walk up from the held machine directory passes dir; the
// kernel's path for the machine directory names the way down, which must lead
// from dir to that very directory through no symlink (errMachineMoved
// otherwise). The walk costs the directory's depth, whatever dir holds.
func (r *privateRoot) coveredBy(dir *os.File, id fileID) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstat(int(r.dir.Fd()), &st); err != nil {
		return "", err
	}
	if st.Nlink == 0 {
		return "", nil // removed: nothing is left to cover
	}
	depth, found := 0, false
	if err := walkUp(r.dir, func(up fileID) bool {
		if found = up == id && depth > 0; found {
			return false
		}
		depth++
		return true
	}); err != nil || !found {
		return "", err
	}
	p, err := os.Readlink(dockerMountFDPath(r.dir))
	names := strings.Split(strings.Trim(p, "/"), "/")
	if err != nil || !path.IsAbs(p) || strings.HasSuffix(p, " (deleted)") || len(names) < depth {
		return "", errMachineMoved
	}
	rel := path.Join(names[len(names)-depth:]...)
	fd, err := unix.Openat2(int(dir.Fd()), rel, &unix.OpenHow{Flags: unix.O_PATH | unix.O_DIRECTORY | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_XDEV})
	if err != nil {
		return "", errMachineMoved
	}
	err = unix.Fstat(fd, &st)
	unix.Close(fd)
	if err != nil || statID(&st) != r.id {
		return "", errMachineMoved
	}
	return rel, nil
}

// errFileMoved is what walkUp returns for a file whose directory it cannot
// find again.
var errFileMoved = errors.New("the file moved or was unlinked while it was opened")

// inside reports whether the opened f is the machine directory or lies below
// it (walkUp).
func (r *privateRoot) inside(f *os.File) (bool, error) {
	inside := false
	err := walkUp(f, func(id fileID) bool {
		inside = id == r.id
		return !inside
	})
	return inside, err
}

// walkUp calls visit with the identity of the opened f and then of every
// directory above it, nearest first, up to the file system root or until
// visit returns false: a directory from itself, a file from the directory
// that holds it, found by the path the kernel resolved it to and checked to
// hold this very file (errFileMoved when it does not). Each step is one
// lookup of "..", so a walk costs the depth of f, never the size of a tree.
func walkUp(f *os.File, visit func(fileID) bool) error {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return err
	}
	if st.Mode&unix.S_IFMT == unix.S_IFDIR {
		return walkUpDir(int(f.Fd()), st, visit)
	}
	id := statID(&st)
	if !visit(id) {
		return nil
	}
	dir, err := parentOf(f, id)
	if err != nil {
		return fmt.Errorf("%w: %v", errFileMoved, err)
	}
	defer unix.Close(dir)
	if err := unix.Fstat(dir, &st); err != nil {
		return err
	}
	return walkUpDir(dir, st, visit)
}

// walkUpDir is walkUp from the directory dir (st is its stat), walking ".."
// up to the file system root.
func walkUpDir(dir int, st unix.Stat_t, visit func(fileID) bool) error {
	cur, owned := dir, false
	defer func() {
		if owned {
			unix.Close(cur)
		}
	}()
	for range 4096 {
		if !visit(statID(&st)) {
			return nil
		}
		next, err := unix.Openat(cur, "..", unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
		if err != nil {
			return err
		}
		var up unix.Stat_t
		if err := unix.Fstat(next, &up); err != nil {
			unix.Close(next)
			return err
		}
		if statID(&up) == statID(&st) { // "/" is its own parent
			unix.Close(next)
			return nil
		}
		if owned {
			unix.Close(cur)
		}
		cur, owned, st = next, true, up
	}
	return errors.New("the path is nested too deep")
}

// parentOf opens the directory that holds the file f (whose identity is id)
// now, refusing one whose entry no longer names that file.
func parentOf(f *os.File, id fileID) (int, error) {
	p, err := os.Readlink(dockerMountFDPath(f))
	if err != nil {
		return -1, err
	}
	if !path.IsAbs(p) || strings.HasSuffix(p, " (deleted)") {
		return -1, errors.New("the file is no longer linked")
	}
	dir, err := unix.Open(path.Dir(p), unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return -1, err
	}
	var st unix.Stat_t
	if err := unix.Fstatat(dir, path.Base(p), &st, unix.AT_SYMLINK_NOFOLLOW); err != nil || statID(&st) != id {
		unix.Close(dir)
		return -1, errors.New("the file moved while it was opened")
	}
	return dir, nil
}

// maskMount is the read-only empty directory over the machine directory in a
// bind that covers it.
func (r *privateRoot) maskMount(containerPath string) *cri.Mount {
	return &cri.Mount{HostPath: r.mask, ContainerPath: containerPath, Readonly: true}
}

// engineMachineDir loads the engine's protection of the machine directory;
// without one it logs why and protects nothing.
func engineMachineDir() *privateRoot {
	r, err := loadPrivateRoot(os.Getenv("MICROPOD_ENGINE_PRIVATE"), privateMaskDir)
	if err != nil {
		log.Printf("binds are not checked against the machine directory: %v", err)
		return nil
	}
	return r
}
