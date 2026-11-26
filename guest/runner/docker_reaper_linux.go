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
	"sync"
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
		s.metrics.reaper.sessionsStarted.Add(1)
		s.metrics.reaper.activeSessions.Add(1)
		var closeOnce sync.Once
		go func() { _ = server.Serve(l) }()
		return name, func() {
			closeOnce.Do(func() {
				s.metrics.reaper.activeSessions.Add(-1)
				s.metrics.reaper.sessionsClosed.Add(1)
			})
			server.Close()
			l.Close()
			os.Remove(dir)
		}, nil
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
	start := time.Now()
	p.engine.metrics.reaper.requestsTotal.Add(1)
	rec := &statusRecorder{ResponseWriter: w}
	var errMsg string
	// A request on this socket comes from inside the Ryuk container: the
	// engine never treats it as the host's (cacheOrigin), and nothing it
	// could create would be more trusted than that container.
	r = r.WithContext(withCacheOrigin(r.Context(), cacheOrigin{creator: p.owner}))
	err := p.handle(rec, r)
	dur := time.Since(start)
	if err != nil {
		code := 500
		var api apiError
		if errors.As(err, &api) {
			code = api.code
		}
		if code == 403 {
			p.engine.metrics.reaper.reapDenied.Add(1)
		}
		errMsg = err.Error()
		writeJSON(rec, code, map[string]string{"message": errMsg})
	}
	if r.Method == http.MethodDelete {
		path := strings.TrimPrefix(r.URL.Path, "/")
		if strings.HasPrefix(path, "v1.") {
			_, path, _ = strings.Cut(path, "/")
		}
		kind, _, _ := strings.Cut(path, "/")
		p.engine.metrics.reaper.recordDelete(kind, dur, err)
	}
	p.engine.metrics.api.recordHTTP("ryuk_reaper", r.Method, r.URL.Path, rec.status, start, dur, errMsg)
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
			switch path {
			case "volumes":
				return p.engine.volumes(w, r, "")
			case "networks":
				return p.engine.networks(w, r, "")
			default:
				return p.engine.list(w, r)
			}
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
			return p.engine.containerLifecycle(w, r, c, "")
		case "networks":
			return p.engine.deleteNetwork(w, key, func(n *workerNetwork) bool {
				return n.ID == key && p.owns(n.Labels)
			})
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
