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
// another path, but neither changes the inode a lookup ends on.

type fileID struct{ dev, ino uint64 }

func statID(st *unix.Stat_t) fileID { return fileID{uint64(st.Dev), st.Ino} }

type privateRoot struct {
	path string
	id   fileID
	// ancestors maps every directory above path, up to "/", to path's
	// location below it: a bind of one of them covers path.
	ancestors map[fileID]string
	// mask is the empty directory bound read-only over path in a bind that
	// covers it.
	mask string
}

// privateMaskDir is the empty directory privateRoot.mask names.
var privateMaskDir = filepath.Join(engineRoot, "private-mask")

// loadPrivateRoot reads the identities of p and its ancestors and prepares the
// mask directory. An empty p protects nothing (nil).
func loadPrivateRoot(p, maskDir string) (*privateRoot, error) {
	if p == "" {
		return nil, nil
	}
	if !path.IsAbs(p) || path.Clean(p) != p || p == "/" {
		return nil, fmt.Errorf("the machine directory %q is not a canonical absolute path", p)
	}
	var st unix.Stat_t
	if err := unix.Stat(p, &st); err != nil {
		return nil, fmt.Errorf("the machine directory %s: %w", p, err)
	}
	r := &privateRoot{path: p, id: statID(&st), ancestors: map[fileID]string{}, mask: maskDir}
	for dir := path.Dir(p); ; dir = path.Dir(dir) {
		if err := unix.Stat(dir, &st); err != nil {
			return nil, fmt.Errorf("the machine directory's parent %s: %w", dir, err)
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return nil, err
		}
		if _, seen := r.ancestors[statID(&st)]; !seen {
			r.ancestors[statID(&st)] = rel
		}
		if dir == "/" {
			break
		}
	}
	// Always empty: whatever an earlier boot left is removed.
	if err := os.RemoveAll(maskDir); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(maskDir), 0700); err != nil {
		return nil, err
	}
	if err := os.Mkdir(maskDir, 0555); err != nil {
		return nil, err
	}
	if err := os.Chmod(maskDir, 0555); err != nil {
		return nil, err
	}
	return r, nil
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
	id := statID(&st)
	if id == r.id {
		return "", fail(400, fmt.Sprintf("bind source %s %v", source, errInsideMachine))
	}
	start := int(f.Fd())
	if st.Mode&unix.S_IFMT == unix.S_IFDIR {
		if rel, covers := r.ancestors[id]; covers {
			return path.Join(target, rel), nil
		}
	} else {
		// A file: walk up from the directory that holds it, found by the
		// path the kernel resolved it to and checked to hold this very file.
		dir, err := parentOf(f, id)
		if err != nil {
			return "", fail(400, fmt.Sprintf("bind source %s: %v", source, err))
		}
		defer unix.Close(dir)
		start = dir
	}
	inside, err := r.below(start)
	if err != nil {
		return "", err
	}
	if inside {
		return "", fail(400, fmt.Sprintf("bind source %s %v", source, errInsideMachine))
	}
	return "", nil
}

// below reports whether the directory dir is the machine directory or lies
// below it, walking ".." up to the file system root.
func (r *privateRoot) below(dir int) (bool, error) {
	cur, owned := dir, false
	defer func() {
		if owned {
			unix.Close(cur)
		}
	}()
	for range 4096 {
		var st unix.Stat_t
		if err := unix.Fstat(cur, &st); err != nil {
			return false, err
		}
		if statID(&st) == r.id {
			return true, nil
		}
		next, err := unix.Openat(cur, "..", unix.O_PATH|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
		if err != nil {
			return false, err
		}
		var up unix.Stat_t
		if err := unix.Fstat(next, &up); err != nil {
			unix.Close(next)
			return false, err
		}
		if statID(&up) == statID(&st) { // "/" is its own parent
			unix.Close(next)
			return false, nil
		}
		if owned {
			unix.Close(cur)
		}
		cur, owned = next, true
	}
	return false, errors.New("bind source is nested too deep")
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
