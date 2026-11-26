package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// What a container created through a delegated Docker socket may bind: only
// paths inside the binds of the container that socket belongs to, read-only
// where the owner reaches them only read-only, resolved below them at every
// open (create, start and a docker cp into it stopped). The workspace is the
// Mac user's home directory, so without this a trusted job could hand a child
// any of it.

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
	var ownBinds []dockerMount
	for _, own := range ownMounts {
		if own.Type == "bind" && !dockerSocketMount(own) && !owner.Config.cleanupMount(own) {
			ownBinds = append(ownBinds, own)
		}
	}
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
// base is resolved below the workspace through no symlink at all, so nothing
// that can write its parent can turn it into a way out; path then resolves
// below base, so a symlink the creator plants in its own bind stays inside it.
func openMountWithin(workspace, base, path string) (*os.File, error) {
	if workspace == "" {
		return nil, errors.New("configure MICROPOD_CI_WORKSPACE for bind mounts")
	}
	if !pathWithin(workspace, base) || !pathWithin(base, path) {
		return nil, errors.New("bind source is outside the creating container's binds")
	}
	ws, err := os.Open(workspace)
	if err != nil {
		return nil, err
	}
	defer ws.Close()
	relBase, _ := filepath.Rel(workspace, base)
	baseFD, err := unix.Openat2(int(ws.Fd()), relBase, &unix.OpenHow{Flags: unix.O_PATH | unix.O_CLOEXEC, Resolve: unix.RESOLVE_BENEATH | unix.RESOLVE_NO_SYMLINKS})
	if err != nil {
		return nil, fmt.Errorf("bind source %s: the creating container's bind %s must be a path with no symlink in the workspace: %w", path, base, err)
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
