package main

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Tool caches live under cacheRoot. Only the unit directories below
// scopes/<scope>/ are ever mounted into containers; .meta (locks, last-used
// stamps, layout) and .trash are outside every mount, so nothing a container
// does (rm -rf, `go clean -modcache`) can delete them.
//
//	/var/lib/micropod/caches            root 0711
//	  scopes/                           root 0711
//	    <scope>/                        root 0755  (bound at /micropod/cache)
//	      <kind>/                       root 0777 + default ACL
//	      <kind>/u<uid>/                root 0777 + default ACL (partitioned kinds)
//	  .meta/layout.json                 {"version":1}
//	  .meta/<scope>/<unit>.lock         flock: LOCK_SH per running container, LOCK_EX for exclusive kinds
//	  .meta/<scope>/<unit>.used         mtime = last container start or exit
//	  .trash/                           root 0700
//
// A variable only so tests can point it at a temporary directory.
var cacheRoot = "/var/lib/micropod/caches"

const aclDefaultXattr = "system.posix_acl_default"

// u::rwx g::rwx o::rwx as a v2 little-endian POSIX ACL xattr: a 4-byte header,
// then (tag u16, perm u16, id u32) for USER_OBJ, GROUP_OBJ and OTHER.
//
// Inherited by every directory and file created below a store, it makes the
// kernel ignore the creating process's umask: Go asks for 0777 directories and
// 0666 files and gets exactly that, so entries written by one uid stay
// writable for every other uid (measured: root then uid 1000 compiled 2
// packages forever without it, 0 with it). The kernel never stores an access
// ACL that only repeats the mode bits, so only the default ACL is written and
// verified; the directory's own bits are set with chmod.
var cacheACL = []byte{
	0x02, 0x00, 0x00, 0x00,
	0x01, 0x00, 0x07, 0x00, 0xff, 0xff, 0xff, 0xff,
	0x04, 0x00, 0x07, 0x00, 0xff, 0xff, 0xff, 0xff,
	0x20, 0x00, 0x07, 0x00, 0xff, 0xff, 0xff, 0xff,
}

// cacheUnit names the lock and last-used stamp of one store: the kind, or
// kind.u<uid> for a partitioned kind.
func cacheUnit(kind string, uid *uint32) string {
	if uid == nil {
		return kind
	}
	return kind + ".u" + strconv.FormatUint(uint64(*uid), 10)
}

// cacheStoreSub is a store's path relative to its scope directory.
func cacheStoreSub(kind string, uid *uint32) string {
	if uid == nil {
		return kind
	}
	return kind + "/u" + strconv.FormatUint(uint64(*uid), 10)
}

// openDirNoFollow opens name below parent as a directory, never following a
// symlink in the last component. display names the result for messages and
// /proc/self/fd bind sources.
func openDirNoFollow(parent int, name, display string) (*os.File, error) {
	fd, err := unix.Openat(parent, name, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), display), nil
}

// fixDir makes an opened directory root-owned with exactly mode, and, when
// acl is set, carries the default ACL. Chmod comes first and independently of
// the xattr: writing an access ACL keeps S_ISVTX and S_ISGID, so only chmod
// removes the sticky bit the previous store layout set.
func fixDir(f *os.File, mode uint32, acl bool) error {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return fmt.Errorf("%s is not a directory", f.Name())
	}
	if st.Uid != 0 || st.Gid != 0 {
		if err := unix.Fchown(int(f.Fd()), 0, 0); err != nil {
			return err
		}
		// chown clears set-ID bits; re-read for the mode check below.
		if err := unix.Fstat(int(f.Fd()), &st); err != nil {
			return err
		}
	}
	if st.Mode&07777 != mode {
		if err := unix.Fchmod(int(f.Fd()), mode); err != nil {
			return err
		}
	}
	if !acl {
		return nil
	}
	buf := make([]byte, 64)
	n, err := unix.Fgetxattr(int(f.Fd()), aclDefaultXattr, buf)
	if err == nil && bytes.Equal(buf[:n], cacheACL) {
		return nil
	}
	if err != nil && !errors.Is(err, unix.ENODATA) && !errors.Is(err, unix.ERANGE) {
		return fmt.Errorf("read default ACL of %s: %w", f.Name(), err)
	}
	if err := unix.Fsetxattr(int(f.Fd()), aclDefaultXattr, cacheACL, 0); err != nil {
		return fmt.Errorf("set default ACL on %s: %w", f.Name(), err)
	}
	return nil
}

// ensureDirAt creates (if needed), opens without following symlinks and fixes
// one directory component below parent. A container can replace any entry of
// a scope it has mounted; a non-directory found there is renamed into .trash
// (when trash is open) and a fresh directory takes its place.
func ensureDirAt(parent *os.File, name string, mode uint32, acl bool, trash *os.File) (*os.File, error) {
	if name == "" || name == "." || name == ".." || strings.Contains(name, "/") {
		return nil, fmt.Errorf("invalid store component %q", name)
	}
	for attempt := 0; ; attempt++ {
		if err := unix.Mkdirat(int(parent.Fd()), name, mode); err != nil && !errors.Is(err, unix.EEXIST) {
			return nil, fmt.Errorf("create %s/%s: %w", parent.Name(), name, err)
		}
		f, err := openDirNoFollow(int(parent.Fd()), name, filepath.Join(parent.Name(), name))
		if err == nil {
			if err := fixDir(f, mode, acl); err != nil {
				f.Close()
				return nil, err
			}
			return f, nil
		}
		if attempt > 0 || trash == nil || !(errors.Is(err, unix.ELOOP) || errors.Is(err, unix.ENOTDIR)) {
			return nil, fmt.Errorf("open %s/%s: %w", parent.Name(), name, err)
		}
		if err := unix.Renameat(int(parent.Fd()), name, int(trash.Fd()), trashName(name)); err != nil {
			return nil, fmt.Errorf("move aside %s/%s: %w", parent.Name(), name, err)
		}
	}
}

// ensureSubdirAt is ensureDirAt for a relative path below a store: every
// component is a root 0777 directory with the default ACL.
func ensureSubdirAt(base *os.File, sub string, trash *os.File) (*os.File, error) {
	cur := base
	for i, name := range strings.Split(sub, "/") {
		next, err := ensureDirAt(cur, name, 0777, true, trash)
		if i > 0 {
			cur.Close()
		}
		if err != nil {
			return nil, err
		}
		cur = next
	}
	return cur, nil
}

func trashName(name string) string {
	var b [6]byte
	_, _ = rand.Read(b[:])
	return name + "." + strconv.FormatInt(time.Now().Unix(), 10) + "." + hex.EncodeToString(b[:])
}

// ensureFileAt creates or opens a regular file below parent with exactly mode
// (cargo's .package-cache lock files, pnpm's index.db). It never follows a
// symlink and refuses non-regular files.
func ensureFileAt(parent *os.File, name string, mode uint32) (*os.File, error) {
	fd, err := unix.Openat(int(parent.Fd()), name, unix.O_RDWR|unix.O_CREAT|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, mode)
	if err != nil {
		return nil, fmt.Errorf("open %s/%s: %w", parent.Name(), name, err)
	}
	f := os.NewFile(uintptr(fd), filepath.Join(parent.Name(), name))
	var st unix.Stat_t
	if err := unix.Fstat(fd, &st); err != nil {
		f.Close()
		return nil, err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFREG {
		f.Close()
		return nil, fmt.Errorf("%s is not a regular file", f.Name())
	}
	if st.Mode&07777 != mode {
		if err := unix.Fchmod(fd, mode); err != nil {
			f.Close()
			return nil, err
		}
	}
	return f, nil
}

// cacheLayout opens the fixed top of the layout: cacheRoot, scopes/, .meta/
// with layout.json, and .trash/. The caller closes all four.
type cacheLayout struct{ root, scopes, meta, trash *os.File }

func (l cacheLayout) Close() {
	for _, f := range []*os.File{l.root, l.scopes, l.meta, l.trash} {
		if f != nil {
			f.Close()
		}
	}
}

func openCacheLayout() (cacheLayout, error) {
	var l cacheLayout
	if err := os.Mkdir(cacheRoot, 0711); err != nil && !errors.Is(err, os.ErrExist) {
		return l, err
	}
	root, err := openDirNoFollow(unix.AT_FDCWD, cacheRoot, cacheRoot)
	if err != nil {
		return l, fmt.Errorf("open %s: %w", cacheRoot, err)
	}
	l.root = root
	if err := fixDir(root, 0711, false); err != nil {
		l.Close()
		return l, err
	}
	for _, d := range []struct {
		name string
		mode uint32
		dst  **os.File
	}{{"scopes", 0711, &l.scopes}, {".meta", 0700, &l.meta}, {".trash", 0700, &l.trash}} {
		f, err := ensureDirAt(root, d.name, d.mode, false, nil)
		if err != nil {
			l.Close()
			return l, err
		}
		*d.dst = f
	}
	if err := unix.Faccessat(int(l.meta.Fd()), "layout.json", unix.F_OK, 0); errors.Is(err, unix.ENOENT) {
		tmp := trashName("layout.json")
		f, err := ensureFileAt(l.meta, tmp, 0600)
		if err == nil {
			_, err = f.WriteString(`{"version":1}` + "\n")
			err = errors.Join(err, f.Close())
		}
		if err == nil {
			err = unix.Renameat(int(l.meta.Fd()), tmp, int(l.meta.Fd()), "layout.json")
		}
		if err != nil {
			l.Close()
			return l, fmt.Errorf("write cache layout: %w", err)
		}
	}
	return l, nil
}

// openScope opens scopes/<scope> (root 0755, no ACL) and .meta/<scope> (0700).
func openScope(l cacheLayout, scope string) (*os.File, error) {
	if !scopeName.MatchString(scope) {
		return nil, fmt.Errorf("invalid cache scope %q", scope)
	}
	meta, err := ensureDirAt(l.meta, scope, 0700, false, nil)
	if err != nil {
		return nil, err
	}
	meta.Close()
	return ensureDirAt(l.scopes, scope, 0755, false, l.trash)
}

// Qualification only: a scope named qual-* or debug-* may hold a store whose
// default ACL was stripped on purpose (the pre-ACL layout, 1777 and no ACL),
// so a test can prove it detects the silent Go miss. The marker lives in
// .meta and is never honoured for any other scope.
func debugCacheScope(scope string) bool {
	return strings.HasPrefix(scope, "qual-") || strings.HasPrefix(scope, "debug-")
}

func debugNoACL(scope, unit string) bool {
	if !debugCacheScope(scope) {
		return false
	}
	_, err := os.Lstat(filepath.Join(cacheRoot, ".meta", scope, unit+".debug-noacl"))
	return err == nil
}

// setStoreACL strips (acl=false) or restores (acl=true) the default ACL of a
// qualification store. Stripping removes the default ACL from every directory
// below the unit and leaves the unit 1777, exactly the previous layout.
func setStoreACL(scope, kind string, uid *uint32, acl bool) (string, error) {
	if !debugCacheScope(scope) {
		return "", fail(400, "the cache debug hook needs a qual-* or debug-* scope")
	}
	unit := cacheUnit(kind, uid)
	marker := filepath.Join(cacheRoot, ".meta", scope, unit+".debug-noacl")
	if acl {
		if err := os.Remove(marker); err != nil && !errors.Is(err, os.ErrNotExist) {
			return "", err
		}
		return ensureStore(scope, kind, uid)
	}
	store, err := ensureStore(scope, kind, uid)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(marker, nil, 0600); err != nil {
		return "", err
	}
	err = filepath.WalkDir(store, func(p string, d os.DirEntry, err error) error {
		if err != nil || !d.IsDir() {
			return err
		}
		if err := unix.Removexattr(p, aclDefaultXattr); err != nil && !errors.Is(err, unix.ENODATA) {
			return err
		}
		return nil
	})
	if err == nil {
		err = os.Chmod(store, 0777|os.ModeSticky)
	}
	return store, err
}

// openStore creates and verifies one store and returns its open directory.
// For a partitioned kind the <kind> parent gets the same root 0777 + ACL
// treatment as the u<uid> directory below it.
func openStore(l cacheLayout, scope string, scopeDir *os.File, kind string, uid *uint32) (*os.File, error) {
	if cacheToolByKind(kind) == nil {
		return nil, fmt.Errorf("unknown cache kind %q", kind)
	}
	if debugNoACL(scope, cacheUnit(kind, uid)) {
		dir, err := ensureDirAt(scopeDir, kind, 0777, false, l.trash)
		if err == nil && uid != nil {
			var part *os.File
			part, err = openDirNoFollow(int(dir.Fd()), "u"+strconv.FormatUint(uint64(*uid), 10), dir.Name())
			dir.Close()
			dir = part
		} else if err == nil {
			// Keep the stripped layout: re-assert 1777 without an ACL.
			err = unix.Fchmod(int(dir.Fd()), 0777|unix.S_ISVTX)
		}
		return dir, err
	}
	dir, err := ensureDirAt(scopeDir, kind, 0777, true, l.trash)
	if err != nil {
		return nil, err
	}
	if uid != nil {
		part, err := ensureDirAt(dir, "u"+strconv.FormatUint(uint64(*uid), 10), 0777, true, l.trash)
		dir.Close()
		if err != nil {
			return nil, err
		}
		dir = part
	}
	if err := prepareStoreKind(kind, dir, l.trash); err != nil {
		dir.Close()
		return nil, err
	}
	return dir, nil
}

// prepareStoreKind applies per-tool fixes a default ACL cannot provide.
func prepareStoreKind(kind string, dir, trash *os.File) error {
	switch kind {
	case "cargo":
		// Shared registry/ and git/ plus the two lock files cargo flocks
		// before it touches them (measured: per-container locks failed 3 of 4
		// concurrent fetches; shared locks 8 of 8 passed). Cargo never
		// replaces these files by rename.
		// src/ holds the per-uid extraction directories; registry/src is only
		// the mount point they are bound over.
		for _, d := range []string{"registry", "registry/src", "git", "src"} {
			f, err := ensureSubdirAt(dir, d, trash)
			if err != nil {
				return err
			}
			f.Close()
		}
		for _, name := range []string{".package-cache", ".package-cache-mutate"} {
			f, err := ensureFileAt(dir, name, 0666)
			if err != nil {
				return err
			}
			f.Close()
		}
	case "pnpm":
		return preparePnpmStore(dir, trash)
	}
	return nil
}

// pnpm 11+ keeps an SQLite index the first writer creates 0664, so another
// uid then fails ("attempt to write a readonly database") or silently
// re-downloads. A pre-created empty 0666 index.db, kept 0666, fixed both.
func preparePnpmStore(dir, trash *os.File) error {
	v11, err := ensureDirAt(dir, "v11", 0777, true, trash)
	if err != nil {
		return err
	}
	fd, err := unix.Openat(int(v11.Fd()), "index.db", unix.O_RDWR|unix.O_CREAT|unix.O_EXCL|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0666)
	if err == nil {
		err = errors.Join(unix.Fchmod(fd, 0666), unix.Close(fd))
	} else if errors.Is(err, unix.EEXIST) {
		err = nil
	}
	v11.Close()
	if err != nil {
		return fmt.Errorf("create pnpm index: %w", err)
	}
	dup, err := unix.Dup(int(dir.Fd()))
	if err != nil {
		return err
	}
	list := os.NewFile(uintptr(dup), dir.Name())
	entries, err := list.ReadDir(-1)
	list.Close()
	if err != nil {
		return err
	}
	for _, e := range entries {
		if !e.IsDir() || !strings.HasPrefix(e.Name(), "v") {
			continue
		}
		v, err := openDirNoFollow(int(dir.Fd()), e.Name(), filepath.Join(dir.Name(), e.Name()))
		if err != nil {
			continue
		}
		for _, name := range []string{"index.db", "index.db-journal", "index.db-wal", "index.db-shm"} {
			fd, err := unix.Openat(int(v.Fd()), name, unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_NONBLOCK|unix.O_CLOEXEC, 0)
			if err != nil {
				continue
			}
			var st unix.Stat_t
			if unix.Fstat(fd, &st) == nil && st.Mode&unix.S_IFMT == unix.S_IFREG && st.Mode&07777 != 0666 {
				_ = unix.Fchmod(fd, 0666)
			}
			unix.Close(fd)
		}
		v.Close()
	}
	return nil
}

// ensureStore creates and verifies scopes/<scope>/<kind>[/u<uid>] and returns
// its path. It is idempotent: it re-applies the owner, mode and default ACL
// when any of them drifted.
func ensureStore(scope, kind string, uid *uint32) (string, error) {
	l, err := openCacheLayout()
	if err != nil {
		return "", err
	}
	defer l.Close()
	scopeDir, err := openScope(l, scope)
	if err != nil {
		return "", err
	}
	defer scopeDir.Close()
	dir, err := openStore(l, scope, scopeDir, kind, uid)
	if err != nil {
		return "", err
	}
	dir.Close()
	return filepath.Join(cacheRoot, "scopes", scope, cacheStoreSub(kind, uid)), nil
}

// unitLock pins a store for a running container. Shared holders block the
// janitor's LOCK_EX|LOCK_NB eviction; exclusive kinds (yarn v1, unsafe for
// concurrent cold writers) take LOCK_EX|LOCK_NB themselves and report busy.
func unitLock(scope, unit string, exclusive bool) (*os.File, error) {
	path := filepath.Join(cacheRoot, ".meta", scope, unit+".lock")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return nil, err
	}
	how := unix.LOCK_SH | unix.LOCK_NB
	if exclusive {
		how = unix.LOCK_EX | unix.LOCK_NB
	}
	if err := unix.Flock(int(f.Fd()), how); err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

// touchUsed records the last use of a store as the mtime of its stamp file.
func touchUsed(scope, unit string) error {
	path := filepath.Join(cacheRoot, ".meta", scope, unit+".used")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	f.Close()
	now := time.Now()
	return os.Chtimes(path, now, now)
}
