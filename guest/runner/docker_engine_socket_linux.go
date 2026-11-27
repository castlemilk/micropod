package main

import (
	"context"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
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
// The socket is the owner's alone (delegatedAPI, docker_delegated_linux.go):
// through it the owner sees only itself and what it created there; its
// children stay in its cache scope and bind only paths inside the owner's
// own binds. Images and the BuildKit cache stay the machine's, so by default
// only a trusted container gets one: an untrusted or read-only container, or
// any container under an untrusted policy default that the host did not
// label trusted, is refused at create instead of being given it. The
// Testcontainers reaper's own bind (cleanupMount) is unaffected: it still
// gets the session-scoped cleanup socket.
//
// A machine whose owner accepts that its jobs share one engine says so in
// the policy (dockerSocket: "any", cachePolicy.DockerSocket): the host may
// then hand a container of any tier the same socket. Only the grant changes.
// The socket is still its owner's alone, a request on it is still that
// container's and never the host's, so what an untrusted owner creates there
// is untrusted too and reads the shared dependency caches through the same
// copy-on-write views; its builds keep their `RUN --mount=type=cache`
// directories apart from the trusted ones (buildCacheNamespace). What it
// does share is what every socket shares: the machine's image store (it can
// pull, build, tag and remove images) and BuildKit's layer cache.

// dockerEnvPath is the empty file Docker puts at /.dockerenv in every
// container. Clients read it to learn they run in a container: Testcontainers
// then dials a sibling's mapped port at the network gateway
// (openGatewayRelay) instead of localhost.
var dockerEnvPath = filepath.Join(filepath.Dir(engineGate), "dockerenv")

var dockerEnvOnce sync.Once

// dockerEnvMount is the read-only /.dockerenv bind, unless the container
// mounts something there itself; nil when the file cannot be made.
func dockerEnvMount(spec dockerConfig) *cri.Mount {
	if mounts, err := spec.mounts(); err == nil {
		for _, m := range mounts {
			if filepath.Clean(m.Target) == "/.dockerenv" {
				return nil
			}
		}
	}
	dockerEnvOnce.Do(func() {
		if err := os.WriteFile(dockerEnvPath, nil, 0o444); err != nil && !os.IsExist(err) {
			log.Printf("/.dockerenv for containers: %v", err)
		}
	})
	if st, err := os.Stat(dockerEnvPath); err != nil || !st.Mode().IsRegular() {
		return nil
	}
	return &cri.Mount{HostPath: dockerEnvPath, ContainerPath: "/.dockerenv", Readonly: true}
}

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
	pol := s.cachePolicy.get()
	if !origin.hostFacing {
		if pol.socketForAnyTier() && s.ownsFamilySocket(viewerOf(ctx)) {
			// Its creator's own socket, shared: see openEngineSocket.
			return true, nil
		}
		return false, fail(403, "a container created through a container's Docker socket cannot be given a Docker socket: only the host delegates the machine's Docker API (with `micropod cache policy --docker-socket any`, it shares its creator's)")
	}
	tier, from, err := resolveCacheTrust(pol, spec, origin)
	if err != nil {
		return false, err
	}
	if tier != trustTrusted && !pol.socketForAnyTier() {
		return false, fail(403, "only a trusted container can be given the machine's Docker socket (it can do anything the host can on this machine); this one is "+tier+" ("+from+"); label it io.micropod.cache.trust=trusted on the machine's own socket, or let containers of any tier have one with `micropod cache policy --docker-socket any`")
	}
	return true, nil
}

// openEngineSocket starts the container's delegated Docker API when its
// create was granted one; "" and a no-op close otherwise. The socket lives
// beside the engine's other private sockets and goes with the container's
// run: close stops serving it and removes it.
//
// A container the host created owns the family its socket shows. One made
// through such a socket and given a socket itself (dockerSocket: any;
// engineSocketGrant) gets no family of its own: its socket shows its
// creator's family, the one it is in, so what it creates there is a sibling
// that goes when the family's owner goes. What it creates is held to its own
// tier and cache scope (never above its creator's, which capped its own) and,
// like every member of the family, to the owner's binds and limits. A GitHub
// Actions runner in a container needs exactly this: it binds docker.sock into
// every `container:` job it starts.
func (s *dockerEngine) openEngineSocket(c *dockerContainer) (string, func(), error) {
	if !c.EngineSocket || privateRootless() {
		return "", func() {}, nil
	}
	family := c.ID
	if c.CreatedBy != "" {
		family = c.CreatedBy
	}
	return serveFamilyEngine(delegatedAPI{s}, filepath.Dir(engineGate), family, c.ID)
}

// ownsFamilySocket reports whether viewer is a container the host created
// and granted a delegated socket: the only kind whose socket a child may
// share.
func (s *dockerEngine) ownsFamilySocket(viewer string) bool {
	if viewer == "" {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	owner := s.containers[viewer]
	return owner != nil && owner.ownsFamily()
}

// serveContainerEngine serves handler on a new socket under parent on which
// every request is owner's: a container's, never the host's (cacheOrigin),
// and seen as owner sees the engine (withViewer).
func serveContainerEngine(handler http.Handler, parent, owner string) (string, func(), error) {
	return serveFamilyEngine(handler, parent, owner, owner)
}

// serveFamilyEngine is serveContainerEngine for a socket whose holder is not
// the family's owner: requests see what family sees (withViewer) and create
// as holder (cacheOrigin: its tier and cache scope).
func serveFamilyEngine(handler http.Handler, parent, family, holder string) (string, func(), error) {
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
	origin := cacheOrigin{creator: holder}
	base := withViewer(withCacheOrigin(context.Background(), origin), family)
	server := &http.Server{Handler: handler, BaseContext: func(net.Listener) context.Context { return base },
		ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 30 * time.Second, IdleTimeout: 60 * time.Second, MaxHeaderBytes: 32 << 10}
	go func() { _ = server.Serve(l) }()
	return name, func() {
		server.Close()
		l.Close()
		os.RemoveAll(dir)
	}, nil
}
