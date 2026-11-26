package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type volumeInfo struct {
	Name, Driver, Scope, Mountpoint, CreatedAt string
	Labels                                     map[string]string
}

func volumePath(name string) string { return filepath.Join(engineRoot, "volumes", name) }
func volumeMeta(name string) string { return filepath.Join(engineRoot, "volume-meta", name+".json") }
func inspectVolume(name string) (volumeInfo, error) {
	v := volumeInfo{Name: name, Driver: "local", Scope: "local", Mountpoint: volumePath(name), Labels: map[string]string{}}
	i, err := os.Stat(volumePath(name))
	if err != nil {
		return v, err
	}
	if !i.IsDir() {
		return v, errors.New("invalid volume directory")
	}
	if path, shared := sharedCachePath(name); shared {
		v.Mountpoint = path
	}
	b, err := os.ReadFile(volumeMeta(name))
	if errors.Is(err, os.ErrNotExist) {
		v.CreatedAt = formatTime(i.ModTime())
		return v, nil
	}
	if err != nil {
		return v, err
	}
	var metadata struct {
		CreatedAt string
		Labels    map[string]string
	}
	if err := json.Unmarshal(b, &metadata); err != nil {
		return v, err
	}
	v.CreatedAt = metadata.CreatedAt
	v.Labels = metadata.Labels
	return v, nil
}

// Called under the engine lock. Existing named volumes keep their original labels.
func ensureVolume(name string, labels map[string]string) error {
	if err := os.Mkdir(volumePath(name), 0755); err != nil {
		if errors.Is(err, os.ErrExist) {
			return nil
		}
		return err
	}
	// Explicit: the engine inherited umask 077 before it set 022, and a 0700
	// volume is unusable by a non-root container user.
	if err := os.Chmod(volumePath(name), 0755); err != nil {
		os.Remove(volumePath(name))
		return err
	}
	metadata := struct {
		CreatedAt string
		Labels    map[string]string
	}{formatTime(time.Now()), labels}
	b, err := json.Marshal(metadata)
	if err == nil {
		err = os.WriteFile(volumeMeta(name)+".tmp", b, 0600)
	}
	if err == nil {
		err = os.Rename(volumeMeta(name)+".tmp", volumeMeta(name))
	}
	if err != nil {
		os.Remove(volumePath(name))
	}
	return err
}

// volumeInUse also counts auto-attached stores: the legacy alias
// micropod-ci-scoped-<scope>-<kind> is in use while any container's plan binds
// that scope (the /micropod/cache bind exposes every kind) or that kind.
func (s *dockerEngine) volumeInUse(name string) bool {
	scope, kind, alias := legacyCacheVolume(name)
	for _, c := range s.containers {
		mounts, _ := c.Config.mounts()
		for _, m := range mounts {
			if m.Type == "volume" && m.Source == name {
				return true
			}
		}
		if p := c.Cache; alias && p.attached() && p.Scope == scope {
			for _, m := range p.Mounts {
				if !m.Shim && (m.Kind == "" || m.Kind == kind) {
					return true
				}
			}
		}
	}
	return false
}
func matchesLabels(labels map[string]string, filters []string) bool {
	for _, q := range filters {
		k, v, has := strings.Cut(q, "=")
		got, ok := labels[k]
		if !ok || (has && got != v) {
			return false
		}
	}
	return true
}
func (s *dockerEngine) volumes(w http.ResponseWriter, r *http.Request, path string) error {
	root := filepath.Join(engineRoot, "volumes")
	if path == "/create" && r.Method == "POST" {
		b, err := readBody(w, r)
		if err != nil {
			return err
		}
		var opts struct {
			Name, Driver string
			Labels       map[string]string
		}
		var raw map[string]any
		if json.Unmarshal(b, &opts) != nil || json.Unmarshal(b, &raw) != nil {
			return fail(400, "invalid volume request")
		}
		if err := supportedOptions(raw, "Name Driver Labels"); err != nil {
			return fail(400, err.Error())
		}
		if opts.Name == "" {
			opts.Name = engineID()
		}
		if !dockerName.MatchString(opts.Name) || (opts.Driver != "" && opts.Driver != "local") {
			return fail(400, "expected a local named volume")
		}
		s.mu.Lock()
		err = ensureVolume(opts.Name, opts.Labels)
		var v volumeInfo
		if err == nil {
			v, err = inspectVolume(opts.Name)
		}
		s.mu.Unlock()
		if err != nil {
			return err
		}
		writeJSON(w, 201, v)
		return nil
	}
	if path == "" && r.Method == "GET" {
		filters, err := dockerFilters(r.URL.Query().Get("filters"), "label", "name", "driver", "dangling")
		if err != nil {
			return err
		}
		s.mu.Lock()
		entries, err := os.ReadDir(root)
		var list = []volumeInfo{}
		if err == nil {
			for _, e := range entries {
				if !e.IsDir() {
					continue
				}
				var v volumeInfo
				v, err = inspectVolume(e.Name())
				if err != nil {
					break
				}
				match := matchesLabels(v.Labels, filters["label"])
				for k, values := range filters {
					if k == "label" || len(values) == 0 {
						continue
					}
					ok := false
					for _, value := range values {
						ok = ok || k == "name" && strings.Contains(v.Name, value) || k == "driver" && v.Driver == value || k == "dangling" && truth(value) != s.volumeInUse(v.Name)
					}
					match = match && ok
				}
				if match {
					list = append(list, v)
				}
			}
		}
		s.mu.Unlock()
		if err != nil {
			return err
		}
		writeJSON(w, 200, map[string]any{"Volumes": list, "Warnings": []string{}})
		return nil
	}
	name := strings.TrimPrefix(path, "/")
	if !dockerName.MatchString(name) {
		return fail(404, "no such volume")
	}
	s.mu.Lock()
	v, err := inspectVolume(name)
	if err != nil {
		s.mu.Unlock()
		if os.IsNotExist(err) {
			if r.Method == "DELETE" && truth(r.URL.Query().Get("force")) {
				w.WriteHeader(204)
				return nil
			}
			return fail(404, "no such volume")
		}
		return err
	}
	if r.Method == "GET" {
		s.mu.Unlock()
		writeJSON(w, 200, v)
		return nil
	}
	if r.Method != "DELETE" {
		s.mu.Unlock()
		return fail(501, "unsupported volume operation")
	}
	err = s.removeVolumeLocked(name)
	s.mu.Unlock()
	if err != nil {
		return err
	}
	w.WriteHeader(204)
	return nil
}

func (s *dockerEngine) removeVolumeLocked(name string) error {
	if s.volumeInUse(name) {
		return fail(409, "volume is in use")
	}
	err := os.RemoveAll(volumePath(name))
	if err == nil {
		e := os.Remove(volumeMeta(name))
		if !os.IsNotExist(e) {
			err = e
		}
	}
	return err
}
