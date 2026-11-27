package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"slices"
	"strings"
	"time"
)

// What a container sees of the engine through its delegated Docker socket.
//
// The host can hand a trusted container the machine's Docker API
// (docker_engine_socket_linux.go) so a CI step can run Testcontainers, compose
// or docker build against the machine it runs on. The machine is shared by
// every job, so that socket is its owner's alone. Through it the owner sees
// and acts on itself and on what it created there (its family: containers,
// networks and volumes), plus the built-in networks and the networks it is
// itself attached to. Every other container, network and volume on the
// machine does not exist on it (404); the engine's own routes (/micropod/*:
// caches, metrics, traces, the container summary) are refused (403), and any
// other route this file does not name is answered as one the engine does not
// implement (501). What the owner creates is capped at its tier
// (cacheOrigin), stays in its cache scope (decideCachesFor) and binds only
// paths inside the owner's own binds (delegatedBinds).
//
// Images and the BuildKit cache are the machine's: a pull, build, load, tag
// or image removal through the socket changes them for every job, as a
// trusted job's writes to the shared stores reach the jobs that read them.

// delegatedFamilyContainers is how many containers, in any state, a
// delegated socket's owner may have created and not removed.
const delegatedFamilyContainers = 256

type apiViewerKey struct{}

// withViewer marks a request as made through owner's delegated socket (or,
// for a reaper owner created there, its cleanup socket).
func withViewer(ctx context.Context, owner string) context.Context {
	return context.WithValue(ctx, apiViewerKey{}, owner)
}

// viewerOf is the container whose delegated socket a request arrived on; ""
// for the host's own socket, which sees everything.
func viewerOf(ctx context.Context) string {
	v, _ := ctx.Value(apiViewerKey{}).(string)
	return v
}

// family is the container that answers for c on a delegated socket: the
// creator of a container made through one, else c itself.
func (c *dockerContainer) family() string {
	if c.CreatedBy != "" {
		return c.CreatedBy
	}
	return c.ID
}

// ownNamesAdvice ends the 409 of a create whose name another job's container,
// network or volume holds. Names are the machine's, and what another job
// created is not there for this socket (404), so a compose project of the
// same name in two jobs at once cannot find the other's to share it.
const ownNamesAdvice = "Jobs that run at once on this machine need names of their own " +
	"(for compose, a project name for each job: -p or COMPOSE_PROJECT_NAME)."

// seesContainer reports whether viewer may see c. Call with s.mu held.
func seesContainer(viewer string, c *dockerContainer) bool {
	return viewer == "" || c.family() == viewer
}

// seesNetworkLocked reports whether viewer may see and use n: one it created,
// or one its own container is attached to. Call with s.mu held.
func (s *dockerEngine) seesNetworkLocked(viewer string, n *workerNetwork) bool {
	if viewer == "" || n.CreatedBy == viewer {
		return true
	}
	owner := s.containers[viewer]
	return owner != nil && (owner.NetworkID == n.ID || owner.secondaryEndpoint(n.ID) >= 0)
}

// seesVolumeLocked reports whether viewer may see and mount v: one created on
// its socket, or one its own container mounts. Call with s.mu held.
func (s *dockerEngine) seesVolumeLocked(viewer string, v volumeInfo) bool {
	if viewer == "" || v.createdBy == viewer {
		return true
	}
	owner := s.containers[viewer]
	if owner == nil {
		return false
	}
	mounts, _ := owner.Config.mounts()
	return slices.ContainsFunc(mounts, func(m dockerMount) bool { return m.Type == "volume" && m.Source == v.Name })
}

// mountsVolumeWritable reports whether c mounts the named volume writable.
func (c *dockerContainer) mountsVolumeWritable(name string) bool {
	mounts, _ := c.Config.mounts()
	return slices.ContainsFunc(mounts, func(m dockerMount) bool { return m.Type == "volume" && m.Source == name && !m.ReadOnly })
}

// lookupFor is lookup among the containers the request's viewer may see, so
// a name or ID prefix never resolves to, or is ambiguous with, another job's.
func (s *dockerEngine) lookupFor(ctx context.Context, key string) (*dockerContainer, error) {
	viewer := viewerOf(ctx)
	if viewer == "" {
		return s.lookup(key)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if c := s.containers[key]; c != nil && seesContainer(viewer, c) {
		return c, nil
	}
	var found *dockerContainer
	for _, c := range s.containers {
		if !seesContainer(viewer, c) {
			continue
		}
		if c.Name == key {
			return c, nil
		}
		if len(key) >= 4 && strings.HasPrefix(c.ID, key) {
			if found != nil {
				return nil, fail(409, "ambiguous container ID")
			}
			found = c
		}
	}
	if found == nil {
		return nil, fail(404, "no such container: "+key)
	}
	return found, nil
}

// delegatedAPI is the engine as a delegated socket serves it: the routes a
// Docker client in a CI step uses, each scoped to the owner by the viewer
// mark serveContainerEngine puts on every request.
type delegatedAPI struct{ engine *dockerEngine }

func (d delegatedAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !delegatedRoute(r.Method, r.URL.Path) {
		start := time.Now()
		// As the engine answers a route it does not implement, so a client
		// that probes (docker inspect walks plugins, swarm objects) behaves
		// as on the host's socket; the engine's own routes say why.
		code, msg := http.StatusNotImplemented, "operation is unavailable on the Micropod native engine"
		if engineOwnRoute(r.URL.Path) {
			code, msg = http.StatusForbidden, "the engine's own routes are unavailable on a container's Docker socket"
		}
		writeJSON(w, code, map[string]string{"message": msg})
		d.engine.metrics.api.recordHTTP("delegated_api", r.Method, r.URL.Path, code, start, time.Since(start), msg)
		return
	}
	d.engine.ServeHTTP(w, r)
}

// engineOwnRoute reports whether a path is one of the engine's own
// (/micropod/*: caches, metrics, traces, the container summary).
func engineOwnRoute(raw string) bool {
	path := strings.TrimPrefix(raw, "/")
	if strings.HasPrefix(path, "v1.") {
		_, path, _ = strings.Cut(path, "/")
	}
	return path == "micropod" || strings.HasPrefix(path, "micropod/")
}

// delegatedRoute reports whether a delegated socket serves the route. The
// container, exec, network and volume handlers and the disk usage report
// scope themselves to the viewer (lookupFor, seesNetworkLocked,
// seesVolumeLocked, systemDiskUsage); images and BuildKit are
// the machine's (a build's own calls scoped by serveDockerBuildControl).
// None of the engine's own routes is served, its BuildKit probe
// (/micropod/buildkit) included: GET /version names the same capability.
// dispatch still validates the API version.
func delegatedRoute(method, raw string) bool {
	path := strings.TrimPrefix(raw, "/")
	if strings.HasPrefix(path, "v1.") {
		_, path, _ = strings.Cut(path, "/")
	}
	read := method == http.MethodGet || method == http.MethodHead
	switch path {
	case "_ping", "version", "info", "events":
		return read
	case "system/df":
		// The report scopes itself: the viewer's containers and volumes, and
		// only their counts on the machine's images (systemDiskUsage).
		return method == http.MethodGet
	case "auth", "grpc", "session":
		return method == http.MethodPost
	case "build/prune":
		// Scopes itself: BuildKit's records are the machine's, so a
		// family's prune removes none (pruneBuildCache).
		return method == http.MethodPost
	case "networks", "volumes":
		return true
	}
	first, _, _ := strings.Cut(path, "/")
	switch first {
	case "containers", "exec", "images", "networks", "volumes":
		return true
	}
	return false
}

// delegatedCreateLocked holds a create through viewer's socket to what the
// owner may hand its children: volumes it sees (a new one becomes its own;
// one it sees only because it mounts it is read-only unless it mounts it
// writable) and binds inside its own (delegatedBinds, whose roots it returns
// and which it may make read-only in spec). The networks are the ones it
// sees: selectNetworkFor found no other. A child gets at most the owner's
// own CPU, memory and process limits (clampTo), and the owner's family at
// most delegatedFamilyContainers containers, so the host's limits on the
// owner bound what it creates too. Call with s.mu held.
func (s *dockerEngine) delegatedCreateLocked(viewer string, spec *dockerConfig) (map[string]string, error) {
	owner := s.containers[viewer]
	if owner == nil {
		return nil, fail(http.StatusForbidden, "the container this Docker socket belongs to is gone")
	}
	family := 0
	for _, c := range s.containers {
		if c.CreatedBy == viewer {
			family++
		}
	}
	if family >= delegatedFamilyContainers {
		return nil, fail(http.StatusConflict, fmt.Sprintf("this Docker socket has created %d containers, as many as it may hold at once; remove one first", family))
	}
	spec.HostConfig.clampTo(owner.Config.HostConfig.limits())
	roots, err := delegatedBinds(owner, spec)
	if err != nil {
		return nil, err
	}
	mounts, err := spec.mounts()
	if err != nil {
		return nil, fail(400, err.Error())
	}
	for _, m := range mounts {
		if _, _, alias := legacyCacheVolume(m.Source); m.Type != "volume" || alias {
			continue // an alias volume follows the cache rules (volumeRules)
		}
		v, err := inspectVolume(m.Source)
		switch {
		case err == nil && !s.seesVolumeLocked(viewer, v):
			return nil, fail(http.StatusForbidden, "the volume "+m.Source+" was not created on this Docker socket")
		case err == nil && !m.ReadOnly && v.createdBy != viewer && !owner.mountsVolumeWritable(v.Name):
			// The host gave the owner this volume read-only: so is its child's.
			spec.makeReadOnly(m.Target)
		case errors.Is(err, os.ErrNotExist):
			if err := ensureVolumeBy(m.Source, nil, viewer); err != nil {
				return nil, err
			}
		case err != nil:
			return nil, err
		}
	}
	return roots, nil
}

// hostJoinLocked holds a container on the host's socket (family, its own: ""
// for one being created) away from the networks and volumes a container's
// socket created (CreatedBy) for another family. They share the machine's
// name space, so a job could otherwise create the names another job's
// compose project will use (app_default, app_pgdata), and that job's
// containers would join its network, within its children's reach and past
// the gateway relay's rule, or keep their data in a volume its children may
// mount. Call with s.mu held.
func (s *dockerEngine) hostJoinLocked(family string, networks []string, spec *dockerConfig) error {
	for _, id := range networks {
		if n := s.namedNetworks[id]; n != nil && n.CreatedBy != "" && n.CreatedBy != family {
			return fail(http.StatusConflict, "the network "+n.Name+" was created through a container's Docker socket; only what that container created there may join it")
		}
	}
	if spec == nil {
		return nil
	}
	mounts, err := spec.mounts()
	if err != nil {
		return fail(400, err.Error())
	}
	for _, m := range mounts {
		if _, _, alias := legacyCacheVolume(m.Source); m.Type != "volume" || alias {
			continue
		}
		if v, err := inspectVolume(m.Source); err == nil && v.createdBy != "" && v.createdBy != family {
			return fail(http.StatusConflict, "the volume "+m.Source+" was created through a container's Docker socket; only what that container created there may mount it")
		}
	}
	return nil
}

// admitNetworkChangeLocked holds a docker network connect or disconnect of
// c through the request's socket to the rule for n, which findNetworkFor
// found among the networks that socket sees: through the host's, c does not
// join another family's network (hostJoinLocked). Call with s.mu held, both
// before the change waits for c and again where it commits.
func (s *dockerEngine) admitNetworkChangeLocked(ctx context.Context, c *dockerContainer, n *workerNetwork, connect bool) error {
	if connect && viewerOf(ctx) == "" {
		return s.hostJoinLocked(c.family(), []string{n.ID}, nil)
	}
	return nil
}

func endpointNetworks(endpoints []dockerSecondaryEndpoint) []string {
	ids := make([]string, 0, len(endpoints))
	for _, e := range endpoints {
		ids = append(ids, e.NetworkID)
	}
	return ids
}
