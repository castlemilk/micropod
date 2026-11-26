package main

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type volumeInfo struct {
	Name, Driver, Scope, Mountpoint, CreatedAt string
	Labels                                     map[string]string
	// createdBy is the container whose delegated socket created the volume
	// ("" for the host's); it is kept in the volume's metadata, not shown.
	createdBy string
}

// volumeStore holds the volumes/ and volume-meta/ directories; a variable only
// so tests can point it at a temporary directory.
var volumeStore = engineRoot

func volumePath(name string) string { return filepath.Join(volumeStore, "volumes", name) }
func volumeMeta(name string) string { return filepath.Join(volumeStore, "volume-meta", name+".json") }
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
	var metadata volumeMetadata
	if err := json.Unmarshal(b, &metadata); err != nil {
		return v, err
	}
	v.CreatedAt = metadata.CreatedAt
	v.Labels = metadata.Labels
	v.createdBy = metadata.CreatedBy
	return v, nil
}

type volumeMetadata struct {
	CreatedAt string
	Labels    map[string]string
	CreatedBy string `json:",omitempty"`
}

// Called under the engine lock. Existing named volumes keep their original labels.
func ensureVolume(name string, labels map[string]string) error {
	return ensureVolumeBy(name, labels, "")
}

// ensureVolumeBy is ensureVolume recording the delegated socket's owner that
// created the volume (volumeInfo.createdBy); an existing volume keeps its own.
func ensureVolumeBy(name string, labels map[string]string, creator string) error {
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
	metadata := volumeMetadata{formatTime(time.Now()), labels, creator}
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
		viewer := viewerOf(r.Context())
		s.mu.Lock()
		err = s.socketOwnerGoneLocked(viewer)
		if err == nil {
			err = ensureVolumeBy(opts.Name, opts.Labels, viewer)
		}
		var v volumeInfo
		if err == nil {
			v, err = inspectVolume(opts.Name)
		}
		if err == nil && (!s.seesVolumeLocked(viewer, v) || viewer == "" && v.createdBy != "") {
			// The host's socket does not adopt a volume a container's socket
			// created (hostJoinLocked).
			err = fail(http.StatusConflict, "a volume named "+opts.Name+" already exists")
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
		viewer := viewerOf(r.Context())
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
				if !s.seesVolumeLocked(viewer, v) {
					continue
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
	viewer := viewerOf(r.Context())
	s.mu.Lock()
	v, err := inspectVolume(name)
	if err == nil && (!s.seesVolumeLocked(viewer, v) || r.Method == "DELETE" && viewer != "" && v.createdBy != viewer) {
		// Another job's, or (to remove) one this delegated socket did not create.
		err = os.ErrNotExist
	}
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
	data, err := s.removeVolumeLocked(name)
	s.mu.Unlock()
	if err := errors.Join(err, discardVolumeData(data)); err != nil {
		return err
	}
	w.WriteHeader(204)
	return nil
}

// volumeTrash holds the data of removed volumes until it is deleted
// (removeVolumeLocked); beside volumes/, so a rename moves a tree there.
func volumeTrash() string { return filepath.Join(volumeStore, "volume-trash") }

// deleteVolumeData deletes a removed volume's data; a variable only so tests
// can see when it runs.
var deleteVolumeData = os.RemoveAll

// removeVolumeLocked removes the volume name. Under s.mu it only moves the
// volume's directory into volumeTrash and drops its metadata, so the name is
// free at once; the caller deletes the data it returns (discardVolumeData)
// once it has released s.mu. A volume's tree (a node_modules, a build cache)
// can take seconds to delete, and every engine request needs that lock. An
// engine start deletes what a crash left in volumeTrash (sweepVolumeTrash).
// Call with s.mu held.
func (s *dockerEngine) removeVolumeLocked(name string) (data string, err error) {
	if s.volumeInUse(name) {
		return "", fail(409, "volume is in use")
	}
	if err := os.MkdirAll(volumeTrash(), 0700); err != nil {
		return "", err
	}
	data = filepath.Join(volumeTrash(), name+"."+engineID()[:16])
	if err := os.Rename(volumePath(name), data); errors.Is(err, os.ErrNotExist) {
		data = ""
	} else if err != nil {
		return "", err
	}
	if err := os.Remove(volumeMeta(name)); err != nil && !os.IsNotExist(err) {
		return data, err
	}
	return data, nil
}

// discardVolumeData deletes data, what removeVolumeLocked moved aside ("" for
// nothing). Call without s.mu.
func discardVolumeData(data string) error {
	if data == "" {
		return nil
	}
	return deleteVolumeData(data)
}

// sweepVolumeTrash deletes, in the background, the data of volumes whose
// removal a stop or crash interrupted before it was deleted. Call before
// anything removes a volume.
func sweepVolumeTrash() {
	trash := volumeTrash()
	entries, err := os.ReadDir(trash)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Printf("read removed volumes' data: %v", err)
		}
		return
	}
	go func() {
		for _, e := range entries {
			if err := os.RemoveAll(filepath.Join(trash, e.Name())); err != nil {
				log.Printf("delete a removed volume's data: %v", err)
			}
		}
	}()
}
