package main

import (
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// What a container created through a delegated Docker socket may bind: only
// paths inside the binds of the container that socket belongs to, read-only
// where those are, resolved below them at every open (create, start and a
// docker cp into it stopped). The workspace is the Mac user's home directory,
// so without this a trusted job could hand a child any of it.

// delegatedBinds holds a child's binds to its creator's: each bind source must
// be one of owner's own bind sources or lie below one, and is read-only when
// every such bind of owner's is. It returns each bind's root (target ->
// owner's bind source), below which every open of the bind resolves
// (openMountWithin), so a symlink the owner plants cannot lead it out; spec is
// made read-only where owner's binds are. The docker.sock and reaper binds are
// sockets, not paths, and are decided elsewhere (engineSocketGrant).
func delegatedBinds(owner *dockerContainer, spec *dockerConfig) (map[string]string, error) {
	mounts, err := spec.mounts()
	if err != nil {
		return nil, fail(400, err.Error())
	}
	ownMounts, err := owner.Config.mounts()
	if err != nil {
		return nil, err
	}
	roots := map[string]string{}
	for _, m := range mounts {
		if m.Type != "bind" || dockerSocketMount(m) || spec.cleanupMount(m) {
			continue
		}
		root, writable := "", false
		for _, own := range ownMounts {
			if own.Type != "bind" || dockerSocketMount(own) || owner.Config.cleanupMount(own) || !pathWithin(own.Source, m.Source) {
				continue
			}
			if root == "" || !own.ReadOnly && !writable {
				root, writable = own.Source, !own.ReadOnly
			}
		}
		if root == "" {
			return nil, fail(http.StatusForbidden, fmt.Sprintf("a container created through a container's Docker socket may bind only paths inside that container's own binds; %s is not inside any of them", m.Source))
		}
		if !writable && !m.ReadOnly {
			spec.makeReadOnly(m.Target)
		}
		roots[m.Target] = root
	}
	return roots, nil
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
