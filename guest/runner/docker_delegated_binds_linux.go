package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// What a container created through a delegated Docker socket may bind: only
// paths inside the binds of the container that socket belongs to, read-only
// where the owner reaches them only read-only, resolved below them at every
// open (create, start and a docker cp into it stopped). The workspace is the
// Mac user's home directory, so without this a trusted job could hand a child
// any of it.
//
// The create decides by spelling (delegatedBinds), so docker inspect shows
// what the child gets; every open then decides again by identity, against
// the descriptors the running owner's own binds were made from
// (creatorHold): an owner that writes a parent of its read-only bind can
// rename a directory above it, or plant a symlink to it, and no spelling of
// the read-only bind names it any more.

// delegatedBinds holds a child's binds to its creator's: each bind source must
// be one of owner's own bind sources or lie below one. It returns each bind's
// root (target -> owner's bind source), below which every open of the bind
// resolves (openMountWithin), so a symlink the owner plants cannot lead it
// out. A bind is made read-only in spec where the owner reaches its source
// only read-only (ownerReach), and a read-only bind of the owner's below a
// writable child bind is bound read-only in the child at the same place, as
// it is in the owner (-v $PWD:/w -v $PWD/.git:/w/.git:ro), so binding the
// parent does not hand the child what the host kept from the owner. The
// docker.sock and reaper binds are sockets, not paths, and are decided
// elsewhere (engineSocketGrant).
func delegatedBinds(owner *dockerContainer, spec *dockerConfig) (map[string]string, error) {
	mounts, err := spec.mounts()
	if err != nil {
		return nil, fail(400, err.Error())
	}
	ownMounts, err := owner.Config.mounts()
	if err != nil {
		return nil, err
	}
	ownBinds := owner.Config.pathBinds(ownMounts)
	targets := map[string]bool{}
	for _, m := range mounts {
		targets[m.Target] = true
	}
	roots := map[string]string{}
	var nested []dockerMount
	for _, m := range mounts {
		if m.Type != "bind" || dockerSocketMount(m) || spec.cleanupMount(m) {
			continue
		}
		root, writable := ownerReach(ownMounts, ownBinds, m.Source)
		if root == "" {
			return nil, fail(http.StatusForbidden, fmt.Sprintf("a container created through a container's Docker socket may bind only paths inside that container's own binds; %s is not inside any of them", m.Source))
		}
		roots[m.Target] = root
		if !writable {
			if !m.ReadOnly {
				spec.makeReadOnly(m.Target)
			}
			continue
		}
		if m.ReadOnly {
			continue
		}
		for _, own := range ownBinds {
			rel, below := foldRel(m.Source, own.Source)
			if !own.ReadOnly || !below || rel == "" {
				continue
			}
			if _, w := ownerReach(ownMounts, ownBinds, own.Source); w {
				continue // the owner can write it elsewhere
			}
			target := path.Join(m.Target, rel)
			if targets[target] {
				continue // the child mounts something of its own there
			}
			targets[target] = true
			nested = append(nested, dockerMount{Type: "bind", Source: own.Source, Target: target, ReadOnly: true})
			roots[target] = own.Source
		}
	}
	spec.HostConfig.Mounts = append(spec.HostConfig.Mounts, nested...)
	return roots, nil
}

// pathBinds are the binds among mounts (c's own) that are workspace paths:
// not the docker.sock or reaper socket binds.
func (c dockerConfig) pathBinds(mounts []dockerMount) []dockerMount {
	var binds []dockerMount
	for _, m := range mounts {
		if m.Type == "bind" && !dockerSocketMount(m) && !c.cleanupMount(m) {
			binds = append(binds, m)
		}
	}
	return binds
}

// heldBinds are the descriptors a running container's start opened, by
// container path: what its binds and volumes are mounted from, open until it
// exits (dockerContainer.binds).
type heldBinds struct{ byTarget map[string]*os.File }

// mountFiles maps the container path of each of mounts made from one of
// files (through its /proc descriptor path) to that descriptor.
func mountFiles(files []*os.File, mounts []*cri.Mount) map[string]*os.File {
	sources := make(map[string]*os.File, len(files))
	for _, f := range files {
		sources[dockerMountFDPath(f)] = f
	}
	byTarget := make(map[string]*os.File, len(files))
	for _, m := range mounts {
		if f := sources[m.HostPath]; f != nil {
			byTarget[m.ContainerPath] = f
		}
	}
	return byTarget
}

// creatorHold is what the creator of a delegated socket's child holds of the
// workspace now, by identity: each of its binds at the identity its running
// start's descriptor has (a mount pins it, and a rename moves the directory,
// not the identity), whether the creator writes it there, and the binds it
// holds only read-only, to walk up from.
type creatorHold struct {
	byID     map[fileID][]heldBind
	readOnly []heldBind
}

type heldBind struct {
	source string
	f      *os.File
	// writable: the creator binds it writable. only: it binds it read-only
	// and no writable bind of its reaches it (ownerReach on its own binds,
	// which the host made: they cannot change while it runs).
	writable, only bool
}

// creatorHoldLocked is what a container created through createdBy's socket,
// with binds (roots), is held to at an open: nil for none, and for a
// container the host created. Its creator's start must hold its binds open;
// when it does not (it is not running) a request on its socket (viewer) is
// refused, and the host's own start or docker cp of the container keeps the
// create-time decision, as nothing the job runs can make one then. Call with
// s.mu held: the creator's descriptors stay open while it is held.
func (s *dockerEngine) creatorHoldLocked(createdBy, viewer string, roots map[string]string) (*creatorHold, error) {
	if createdBy == "" || len(roots) == 0 {
		return nil, nil
	}
	owner := s.containers[createdBy]
	if owner == nil || owner.binds == nil {
		if viewer == "" {
			return nil, nil
		}
		return nil, fail(http.StatusConflict, "the container this Docker socket belongs to is not running, so the binds it holds cannot be checked")
	}
	ownMounts, err := owner.Config.mounts()
	if err != nil {
		return nil, err
	}
	ownBinds := owner.Config.pathBinds(ownMounts)
	h := &creatorHold{byID: map[fileID][]heldBind{}}
	for _, own := range ownBinds {
		f := owner.binds.byTarget[own.Target]
		if f == nil {
			return nil, fmt.Errorf("the creating container's bind %s is not held open", own.Source)
		}
		var st unix.Stat_t
		if err := unix.Fstat(int(f.Fd()), &st); err != nil {
			return nil, err
		}
		b := heldBind{source: own.Source, f: f, writable: !own.ReadOnly}
		if own.ReadOnly {
			_, w := ownerReach(ownMounts, ownBinds, own.Source)
			b.only = !w
		}
		h.byID[statID(&st)] = append(h.byID[statID(&st)], b)
		if b.only {
			h.readOnly = append(h.readOnly, b)
		}
	}
	return h, nil
}

// admit holds the child's bind m, opened as f, to what its creator holds by
// identity. Walking up from f, the nearest of the creator's binds decides:
// one it writes makes f writable, one it holds only read-only makes it
// read-only, and f below none of them is refused. A writable use (write: the
// bind is writable, or a docker cp writes through it) also needs every bind
// the creator holds only read-only that lies inside f to be covered by
// another of the child's mounts (mounts), as delegatedBinds puts one there:
// walking up from each, the child's mount must be at it or at a directory
// between it and f. Only the depth of each path is walked, never a tree.
func (h *creatorHold) admit(m dockerMount, f *os.File, write bool, mounts []dockerMount) error {
	reached, writable, err := h.reach(f)
	if errors.Is(err, errFileMoved) {
		return fail(400, fmt.Sprintf("bind source %s: %v", m.Source, err))
	}
	if err != nil {
		return err
	}
	if !reached {
		return fail(http.StatusForbidden, fmt.Sprintf("bind source %s is not inside the creating container's binds", m.Source))
	}
	if !write {
		return nil
	}
	if !writable {
		return fail(http.StatusForbidden, fmt.Sprintf("bind source %s is a path the creating container holds only read-only; bind it read-only", m.Source))
	}
	held, err := h.uncovered(f, m.Target, mounts)
	if err != nil {
		return err
	}
	if held != "" {
		return fail(http.StatusForbidden, fmt.Sprintf("bind source %s holds what the creating container binds read-only from %s, at a path no read-only mount of this container covers; bind %s read-only", m.Source, held, m.Source))
	}
	return nil
}

// reach is how the creator reaches the opened f: below one of its binds at
// all, and writable there (admit).
func (h *creatorHold) reach(f *os.File) (reached, writable bool, err error) {
	err = walkUp(f, func(id fileID) bool {
		binds := h.byID[id]
		for _, b := range binds {
			if b.writable {
				reached, writable = true, true
				return false
			}
		}
		for _, b := range binds {
			// A read-only bind the creator also writes elsewhere does
			// not decide: the bind it writes it through is further up.
			reached = true
			if b.only {
				return false
			}
		}
		return true
	})
	return reached, writable, err
}

// uncovered is the source of a bind the creator holds only read-only that
// lies inside the directory f (the child's bind at target) where none of the
// child's other mounts covers it, "" for none. A bind no longer linked
// anywhere lies nowhere.
func (h *creatorHold) uncovered(f *os.File, target string, mounts []dockerMount) (string, error) {
	var st unix.Stat_t
	if err := unix.Fstat(int(f.Fd()), &st); err != nil {
		return "", err
	}
	if st.Mode&unix.S_IFMT != unix.S_IFDIR {
		return "", nil
	}
	dir := statID(&st)
	for _, r := range h.readOnly {
		var held unix.Stat_t
		if err := unix.Fstat(int(r.f.Fd()), &held); err != nil {
			return "", err
		}
		if held.Nlink == 0 {
			continue
		}
		// From the read-only bind up to, not including, f.
		var between []fileID
		inside := false
		if err := walkUp(r.f, func(id fileID) bool {
			if id == dir && len(between) > 0 {
				inside = true
				return false
			}
			between = append(between, id)
			return true
		}); err != nil {
			return "", fmt.Errorf("the creating container's read-only bind %s: %w", r.source, err)
		}
		if inside && !coveredBelow(f, target, mounts, between) {
			return r.source, nil
		}
	}
	return "", nil
}

// coveredBelow reports whether one of mounts lies below target, the child's
// bind of the directory f, at a path that resolves below f, through no
// symlink, to one of the identities in between: the runtime mounts it there,
// over what the bind holds at that path.
func coveredBelow(f *os.File, target string, mounts []dockerMount, between []fileID) bool {
	for _, m := range mounts {
		if m.Target == target || !pathWithin(target, m.Target) {
			continue
		}
		rel, _ := filepath.Rel(target, m.Target)
		fd, err := unix.Openat2(int(f.Fd()), rel, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC,
			Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS | unix.RESOLVE_NO_XDEV})
		if err != nil {
			continue
		}
		var st unix.Stat_t
		err = unix.Fstat(fd, &st)
		unix.Close(fd)
		if err == nil && slices.Contains(between, statID(&st)) {
			return true
		}
	}
	return false
}

// ownerReach is how the owner reaches the workspace path source through its
// binds (ownBinds, among all its mounts ownMounts): root is the source of one
// of its binds that source lies below by spelling, as the bind resolves (""
// for none), and writable whether any of them reaches it writable in the
// owner's own mount namespace. A writable bind does not reach a path that a
// longer read-only bind of the same file shadows there (the host's file
// system ignores case, so neither does that comparison).
func ownerReach(ownMounts, ownBinds []dockerMount, source string) (root string, writable bool) {
	for _, own := range ownBinds {
		if !pathWithin(own.Source, source) {
			continue
		}
		rel, _ := filepath.Rel(own.Source, source)
		at := path.Join(own.Target, rel)
		ro := own.ReadOnly
		var shadow *dockerMount
		for i, other := range ownMounts {
			if _, covers := foldRel(other.Target, at); covers && len(other.Target) > len(own.Target) && (shadow == nil || len(other.Target) > len(shadow.Target)) {
				shadow = &ownMounts[i]
			}
		}
		if shadow != nil && shadow.Type == "bind" && shadow.ReadOnly {
			if under, _ := foldRel(shadow.Target, at); foldSame(path.Join(shadow.Source, under), source) {
				ro = true
			}
		}
		if root == "" || !ro && !writable {
			root, writable = own.Source, !ro
		}
	}
	return root, writable
}

// foldRel is p relative to base ("" for base itself) when p is base or below
// it, comparing each component as the host's file system does, ignoring case.
func foldRel(base, p string) (string, bool) {
	split := func(s string) []string {
		if s = strings.Trim(s, "/"); s == "" {
			return nil
		}
		return strings.Split(s, "/")
	}
	b, q := split(base), split(p)
	if len(q) < len(b) {
		return "", false
	}
	for i := range b {
		if !strings.EqualFold(b[i], q[i]) {
			return "", false
		}
	}
	return strings.Join(q[len(b):], "/"), true
}

// foldSame reports whether a and b name the same path, ignoring case.
func foldSame(a, b string) bool {
	rel, ok := foldRel(a, b)
	return ok && rel == ""
}

// delegatedBindRoots is what holds c's binds at a start or a docker cp: nil
// for a container the host created (its binds resolve from the workspace),
// else its roots, empty when it has no binds, so none can resolve elsewhere.
func (c *dockerContainer) delegatedBindRoots() map[string]string {
	if c.CreatedBy == "" {
		return nil
	}
	if c.BindRoots == nil {
		return map[string]string{}
	}
	return c.BindRoots
}

// pathWithin reports whether path is base or below it (both clean and absolute).
func pathWithin(base, path string) bool {
	rel, err := filepath.Rel(base, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, "../")
}

// makeReadOnly makes the bind or mount at target read-only.
func (spec *dockerConfig) makeReadOnly(target string) {
	for i := range spec.HostConfig.Mounts {
		if spec.HostConfig.Mounts[i].Target == target {
			spec.HostConfig.Mounts[i].ReadOnly = true
		}
	}
	for i, b := range spec.HostConfig.Binds {
		p := strings.Split(b, ":")
		if len(p) >= 2 && p[1] == target {
			spec.HostConfig.Binds[i] = p[0] + ":" + p[1] + ":ro"
		}
	}
}

// openMountWithin opens path, a bind source of a container made through a
// delegated socket, below base, its creator's bind source (delegatedBinds).
// held, when set, is the descriptor the running creator's start made that
// bind from (creatorHold.rootOf): path resolves below it, as the creator
// binds it, whatever symlinks led there in the workspace (openMount follows
// relative ones beneath it). Without one (the host's own start of a child
// whose creator is stopped) base is resolved below the workspace through no
// symlink at all, so nothing that can write its parent can turn it into a
// way out, and one that has a symlink is refused (403). Either way path then
// resolves below base, so a symlink the creator plants in its own bind stays
// inside it.
func openMountWithin(workspace, base, path string, held *os.File) (*os.File, error) {
	if workspace == "" {
		return nil, errors.New("configure MICROPOD_CI_WORKSPACE for bind mounts")
	}
	if !pathWithin(workspace, base) || !pathWithin(base, path) {
		return nil, errors.New("bind source is outside the creating container's binds")
	}
	var baseFD int
	var err error
	if held != nil {
		baseFD, err = unix.FcntlInt(held.Fd(), unix.F_DUPFD_CLOEXEC, 0)
		if err != nil {
			return nil, err
		}
	} else {
		ws, err := os.Open(workspace)
		if err != nil {
			return nil, err
		}
		relBase, _ := filepath.Rel(workspace, base)
		baseFD, err = unix.Openat2(int(ws.Fd()), relBase, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS})
		ws.Close()
		if err != nil {
			return nil, fail(http.StatusForbidden, fmt.Sprintf("bind source %s: the creating container's bind %s, which is not running to resolve it as it binds it, must then be a path with no symlink in the workspace: %v", path, base, err))
		}
	}
	fd := baseFD
	if rel, _ := filepath.Rel(base, path); rel != "." {
		fd, err = unix.Openat2(baseFD, rel, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_MAGICLINKS})
		unix.Close(baseFD)
		if err != nil {
			return nil, fmt.Errorf("bind source %s: %w", path, err)
		}
	}
	f := os.NewFile(uintptr(fd), path)
	st, err := f.Stat()
	if err != nil || (!st.IsDir() && !st.Mode().IsRegular()) {
		f.Close()
		return nil, errors.New("bind source must be a directory or regular file")
	}
	return f, nil
}

// rootOf is the descriptor the creator's running start made its bind of
// source from; nil when it holds none (h nil included). Valid while s.mu,
// under which h was made, is held.
func (h *creatorHold) rootOf(source string) *os.File {
	if h == nil {
		return nil
	}
	for _, binds := range h.byID {
		for _, b := range binds {
			if b.source == source {
				return b.f
			}
		}
	}
	return nil
}
