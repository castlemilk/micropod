package main

import (
	"encoding/hex"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const tcSession = "org.testcontainers.sessionId"
const tcReap = "org.testcontainers.reap"

var sessionKey = regexp.MustCompile("^[a-zA-Z0-9_-]{16,128}$")

// A cleanup sidecar receives a new capability socket. The source path in the
// client bind request never opens a host or scheduler socket.
func (spec dockerConfig) cleanupMount(m dockerMount) bool {
	image := strings.TrimPrefix(spec.Image, "docker.io/")
	repo, tag, has := strings.Cut(image, ":")
	return m.Type == "bind" && m.Target == "/var/run/docker.sock" && filepath.Base(m.Source) == "docker.sock" &&
		has && tag != "" && repo == "testcontainers/ryuk" && spec.Labels["org.testcontainers.ryuk"] == "true" &&
		spec.Labels["org.testcontainers.reaper"] == "true" && sessionKey.MatchString(spec.Labels[tcSession])
}

func (s *dockerEngine) openCleanupSocket(c *dockerContainer) (string, func(), error) {
	mounts, err := c.Config.mounts()
	if err != nil {
		return "", nil, err
	}
	for _, m := range mounts {
		if !c.Config.cleanupMount(m) {
			continue
		}
		dir, err := os.MkdirTemp(filepath.Dir(engineGate), "reaper-")
		if err != nil {
			return "", nil, err
		}
		name := filepath.Join(dir, "api.sock")
		l, err := net.Listen("unix", name)
		if err != nil {
			os.Remove(dir)
			return "", nil, err
		}
		if err = os.Chmod(name, 0600); err != nil {
			l.Close()
			os.Remove(dir)
			return "", nil, err
		}
		api := &cleanupAPI{engine: s, session: c.Config.Labels[tcSession], owner: c.ID}
		server := &http.Server{Handler: api, ReadHeaderTimeout: 5 * time.Second, ReadTimeout: 15 * time.Second, WriteTimeout: 30 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16 << 10}
		go func() { _ = server.Serve(l) }()
		return name, func() { server.Close(); l.Close(); os.Remove(dir) }, nil
	}
	return "", func() {}, nil
}

type cleanupAPI struct {
	engine         *dockerEngine
	session, owner string
}

func (p *cleanupAPI) owns(labels map[string]string) bool {
	return labels[tcSession] == p.session && labels[tcReap] == "true" && labels["org.testcontainers.ryuk"] != "true"
}
func (p *cleanupAPI) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := p.handle(w, r); err != nil {
		code := 500
		var api apiError
		if errors.As(err, &api) {
			code = api.code
		}
		writeJSON(w, code, map[string]string{"message": err.Error()})
	}
}
func (p *cleanupAPI) handle(w http.ResponseWriter, r *http.Request) error {
	path := strings.TrimPrefix(r.URL.Path, "/")
	if strings.HasPrefix(path, "v1.") {
		v, rest, _ := strings.Cut(path, "/")
		minor, err := strconv.Atoi(strings.TrimPrefix(v, "v1."))
		if err != nil || minor < 44 || minor > 47 {
			return fail(400, "unsupported cleanup API version")
		}
		path = rest
	}
	if (path == "_ping" || path == "version") && (r.Method == "GET" || r.Method == "HEAD") {
		return p.engine.dispatch(w, r)
	}
	if r.Method == "GET" {
		switch path {
		case "containers/json", "volumes", "networks":
			filters, err := dockerFilters(r.URL.Query().Get("filters"), "label")
			if err != nil {
				return err
			}
			if filters == nil {
				filters = map[string][]string{}
			}
			filters["label"] = append(filters["label"], tcSession+"="+p.session, tcReap+"=true")
			b, err := json.Marshal(filters)
			if err != nil {
				return err
			}
			q := r.URL.Query()
			q.Set("filters", string(b))
			r.URL.RawQuery = q.Encode()
			if path == "volumes" {
				return p.engine.volumes(w, r, "")
			}
			return p.engine.list(w, r)
		case "images/json":
			// Both built-in networks and all image layers are owned by the worker.
			writeJSON(w, 200, []any{})
			return nil
		}
	}
	if r.Method == "DELETE" {
		kind, key, _ := strings.Cut(path, "/")
		switch kind {
		case "containers":
			if len(key) != 64 || key == p.owner {
				return fail(404, "unknown session container")
			}
			if _, err := hex.DecodeString(key); err != nil {
				return fail(404, "unknown session container")
			}
			p.engine.mu.Lock()
			c := p.engine.containers[key]
			owned := c != nil && p.owns(c.Config.Labels)
			p.engine.mu.Unlock()
			if !owned {
				return fail(404, "unknown session container")
			}
			if err := p.engine.remove(r.Context(), c, truth(r.URL.Query().Get("force"))); err != nil {
				return err
			}
		case "networks":
			p.engine.mu.Lock()
			n := p.engine.findNetwork(key)
			owned := n != nil && n.ID == key && p.owns(n.Labels)
			p.engine.mu.Unlock()
			if !owned {
				return fail(404, "unknown session network")
			}
			return p.engine.deleteNetwork(w, key)
		case "volumes":
			if !dockerName.MatchString(key) {
				return fail(404, "unknown session volume")
			}
			if _, shared := sharedCachePath(key); shared {
				return fail(404, "unknown session volume")
			}
			p.engine.mu.Lock()
			v, err := inspectVolume(key)
			if err == nil && p.owns(v.Labels) {
				err = p.engine.removeVolumeLocked(key)
			} else if err == nil || errors.Is(err, os.ErrNotExist) {
				err = fail(404, "unknown session volume")
			}
			p.engine.mu.Unlock()
			if err != nil {
				return err
			}
		default:
			return fail(403, "session cleanup operation unavailable")
		}
		w.WriteHeader(204)
		return nil
	}
	return fail(403, "session cleanup operation unavailable")
}
