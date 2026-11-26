package main

import (
	"context"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

// The machine's Docker API, delegated to one container.
//
// A create on the host-facing socket that binds /var/run/docker.sock (or
// /run/docker.sock) into a trusted container asks for what Docker gives such
// a bind: the engine's API inside that container, so a CI step can run
// Testcontainers, compose or docker build against the machine it runs on
// (Cuttlefish's `dockerSocket: true` nodes). The shared machine never hands
// over its own host-facing socket. The container gets a socket of its own,
// served by the same engine, on which every request is that container's
// (cacheOrigin{creator}): whatever it creates is never more trusted than it
// is, and it cannot pass a socket on (a nested docker.sock bind is refused).
//
// Only a trusted container gets one. Whoever holds the socket can do what
// the host can on this machine (name any tier and scope, bind any workspace
// path, reach every container and BuildKit), so an untrusted or read-only
// container, or any container under an untrusted policy default that the
// host did not label trusted, is refused at create instead of being given
// it. The Testcontainers reaper's own bind (cleanupMount) is unaffected: it
// still gets the session-scoped cleanup socket.

// engineSocketGrant reports whether spec asks for the delegated engine
// socket, and refuses a create that asks without the right to it. In the
// private rootless engine the bind is the job's own engine (openMounts).
func (s *dockerEngine) engineSocketGrant(ctx context.Context, spec dockerConfig) (bool, error) {
	if privateRootless() {
		return false, nil
	}
	mounts, err := spec.mounts()
	if err != nil {
		return false, nil // openMounts reports the malformed request
	}
	wants := false
	for _, m := range mounts {
		if dockerSocketMount(m) && !spec.cleanupMount(m) {
			wants = true
		}
	}
	if !wants {
		return false, nil
	}
	origin := cacheOriginOf(ctx)
	if !origin.hostFacing {
		return false, fail(403, "a container created through a container's Docker socket cannot be given a Docker socket: only the host delegates the machine's Docker API")
	}
	tier, from, err := resolveCacheTrust(s.cachePolicy.get(), spec, origin)
	if err != nil {
		return false, err
	}
	if tier != trustTrusted {
		return false, fail(403, "only a trusted container can be given the machine's Docker socket (it can do anything the host can on this machine); this one is "+tier+" ("+from+"); label it io.micropod.cache.trust=trusted on the machine's own socket")
	}
	return true, nil
}

// openEngineSocket starts the container's delegated Docker API when its
// create was granted one; "" and a no-op close otherwise. The socket lives
// beside the engine's other private sockets and goes with the container's
// run: close stops serving it and removes it.
func (s *dockerEngine) openEngineSocket(c *dockerContainer) (string, func(), error) {
	if !c.EngineSocket || privateRootless() {
		return "", func() {}, nil
	}
	return serveContainerEngine(s, filepath.Dir(engineGate), c.ID)
}

// serveContainerEngine serves handler on a new socket under parent on which
// every request is owner's: a container's, never the host's.
func serveContainerEngine(handler http.Handler, parent, owner string) (string, func(), error) {
	dir, err := os.MkdirTemp(parent, "engine-")
	if err != nil {
		return "", nil, err
	}
	name := filepath.Join(dir, "docker.sock")
	l, err := net.Listen("unix", name)
	if err != nil {
		os.RemoveAll(dir)
		return "", nil, err
	}
	// Any user inside the container may use it, as with Docker's own
	// socket: the directory is the engine's (0700), so the bind into this
	// container is the only way to it.
	if err := os.Chmod(name, 0o666); err != nil {
		l.Close()
		os.RemoveAll(dir)
		return "", nil, err
	}
	origin := cacheOrigin{creator: owner}
	server := &http.Server{Handler: handler, BaseContext: func(net.Listener) context.Context { return withCacheOrigin(context.Background(), origin) },
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
	go func() { _ = server.Serve(l) }()
	return name, func() {
		server.Close()
		l.Close()
		os.RemoveAll(dir)
	}, nil
}
