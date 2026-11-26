package main

import (
	"context"
	"errors"
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
// container, exec, network and volume handlers scope themselves to the viewer
// (lookupFor, seesNetworkLocked, seesVolumeLocked); images and BuildKit are
// the machine's. dispatch still validates the API version.
func delegatedRoute(method, raw string) bool {
	path := strings.TrimPrefix(raw, "/")
	if strings.HasPrefix(path, "v1.") {
		_, path, _ = strings.Cut(path, "/")
	}
	read := method == http.MethodGet || method == http.MethodHead
	switch path {
	case "_ping", "version", "info", "events":
		return read
	case "auth", "grpc", "session":
		return method == http.MethodPost
	case "micropod/buildkit":
		return method == http.MethodGet
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
// owner may hand its children: networks it sees, volumes it sees (a new one
// becomes its own) and binds inside its own (delegatedBinds, whose roots it
// returns and which it may make read-only in spec). Call with s.mu held,
// after selectNetwork resolved the networks.
func (s *dockerEngine) delegatedCreateLocked(viewer string, spec *dockerConfig, network string, endpoints []dockerSecondaryEndpoint) (map[string]string, error) {
	owner := s.containers[viewer]
	if owner == nil {
		return nil, fail(http.StatusForbidden, "the container this Docker socket belongs to is gone")
	}
	for _, id := range append([]string{network}, endpointNetworks(endpoints)...) {
		if n := s.namedNetworks[id]; id != "" && (n == nil || !s.seesNetworkLocked(viewer, n)) {
			return nil, fail(http.StatusNotFound, "no such network")
		}
	}
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

func endpointNetworks(endpoints []dockerSecondaryEndpoint) []string {
	ids := make([]string, 0, len(endpoints))
	for _, e := range endpoints {
		ids = append(ids, e.NetworkID)
	}
	return ids
}
