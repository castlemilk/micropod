package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sync"
)

// A job's family by label, for callers on the machine's own socket.
//
// A container that owns a delegated socket has a family the engine keeps
// for it (docker_family_linux.go). A job that runs as a process on the Mac
// (a GitHub Actions runner, a developer's script) has no such owner: what it
// creates on the machine's socket is the host's, and nothing says which job
// made it. The family label does: every container, network and volume
// carrying io.micropod.family=<name> is that job's, counted under its name
// (GET /micropod/capacity) and removed together
// (POST /micropod/families/prune?family=<name>).
//
// The caller sets the label itself, or sends the X-Micropod-Family request
// header and the engine stamps what the request creates (the docker CLI,
// compose and buildx send the "HttpHeaders" of the client's config.json on
// every request, so a job's DOCKER_CONFIG is enough to attribute everything
// its docker commands make). The header is read on the machine's own socket
// only: on a delegated socket the family is the socket's owner, whatever a
// request says.
//
// The label attributes and cleans up. It grants nothing: trust, cache scope
// and what a socket may see never depend on it.

const familyHeader = "X-Micropod-Family"

var familyName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$`)

func validFamilyName(name string) bool { return familyName.MatchString(name) }

type requestFamilyKey struct{}

func withRequestFamily(ctx context.Context, name string) context.Context {
	return context.WithValue(ctx, requestFamilyKey{}, name)
}

// stampFamily adds the request's family (familyHeader) to labels that name
// none; labels come back unchanged for a request without one.
func stampFamily(ctx context.Context, labels map[string]string) map[string]string {
	name, _ := ctx.Value(requestFamilyKey{}).(string)
	if name == "" || labels[familyLabel] != "" {
		return labels
	}
	out := make(map[string]string, len(labels)+1)
	for k, v := range labels {
		out[k] = v
	}
	out[familyLabel] = name
	return out
}

// familyPruneLimit bounds one prune: the containers it stops and removes at
// once, and how many of each kind it takes on in a call. What is left is
// reported, and the next call takes it.
const (
	familyPruneParallel = 32
	familyPruneLimit    = 1024
)

type familyPruneReport struct {
	Family     string   `json:"family"`
	DryRun     bool     `json:"dry_run"`
	Containers []string `json:"containers"`
	Networks   []string `json:"networks"`
	Volumes    []string `json:"volumes"`
	Errors     []string `json:"errors"`
	// Remaining is true when something carrying the label is still there:
	// an error above, or more than one call takes on.
	Remaining bool `json:"remaining"`
}

// pruneFamilyRoute serves POST /micropod/families/prune?family=NAME
// [&dry-run=1]: host only (engineOwnRoute).
func (s *dockerEngine) pruneFamilyRoute(w http.ResponseWriter, r *http.Request) error {
	name := r.URL.Query().Get("family")
	if !validFamilyName(name) {
		return fail(400, "family: expected 1 to 128 of [A-Za-z0-9_.-], starting with a letter or digit")
	}
	dry := r.URL.Query().Get("dry-run")
	report := s.pruneFamily(r.Context(), name, dry == "1" || dry == "true")
	writeJSON(w, 200, report)
	return nil
}

// pruneFamily removes what the host created with familyLabel=name:
// containers (stopped at once, with what their own delegated sockets
// created), then the networks nothing uses any more, then the volumes
// nothing mounts. Only an exact label match is taken, never a container made
// through a delegated socket (its owner's removal takes it) and never
// anything unlabelled.
func (s *dockerEngine) pruneFamily(ctx context.Context, name string, dryRun bool) familyPruneReport {
	report := familyPruneReport{Family: name, DryRun: dryRun, Containers: []string{}, Networks: []string{}, Volumes: []string{}, Errors: []string{}}
	s.mu.Lock()
	var containers []*dockerContainer
	for _, c := range s.containers {
		if c.CreatedBy == "" && c.Config.Labels[familyLabel] == name {
			if len(containers) == familyPruneLimit {
				report.Remaining = true
				break
			}
			containers = append(containers, c)
		}
	}
	var networks []string
	for id, n := range s.namedNetworks {
		if n.CreatedBy == "" && n.Labels[familyLabel] == name && len(networks) < familyPruneLimit {
			networks = append(networks, id)
		}
	}
	volumes, err := labelledVolumes(name)
	s.mu.Unlock()
	if err != nil {
		report.Errors = append(report.Errors, "volumes: "+err.Error())
	}
	if dryRun {
		for _, c := range containers {
			report.Containers = append(report.Containers, c.ID)
		}
		report.Networks, report.Volumes = append(report.Networks, networks...), append(report.Volumes, volumes...)
		return report
	}
	var mu sync.Mutex
	var reaping sync.WaitGroup
	slots := make(chan struct{}, familyPruneParallel)
	for _, c := range containers {
		reaping.Go(func() {
			slots <- struct{}{}
			defer func() { <-slots }()
			child, cancel := context.WithTimeout(ctx, reapChildTimeout)
			defer cancel()
			err := s.reapChild(child, c)
			mu.Lock()
			defer mu.Unlock()
			if err != nil {
				report.Errors = append(report.Errors, fmt.Sprintf("container %.12s: %v", c.ID, err))
				return
			}
			report.Containers = append(report.Containers, c.ID)
		})
	}
	reaping.Wait()
	for _, id := range networks {
		err := s.removeNetwork(id, func(n *workerNetwork) bool {
			return n.ID == id && n.CreatedBy == "" && n.Labels[familyLabel] == name
		})
		var api apiError
		switch {
		case err == nil:
			report.Networks = append(report.Networks, id)
		case errors.As(err, &api) && api.code == 404:
		default:
			report.Errors = append(report.Errors, fmt.Sprintf("network %.12s: %v", id, err))
		}
	}
	s.mu.Lock()
	data := map[string]string{}
	for _, volume := range volumes {
		d, err := s.removeVolumeLocked(volume)
		if err != nil {
			report.Errors = append(report.Errors, fmt.Sprintf("volume %s: %v", volume, err))
			continue
		}
		data[volume] = d
	}
	s.mu.Unlock()
	for volume, d := range data {
		if err := discardVolumeData(d); err != nil {
			report.Errors = append(report.Errors, fmt.Sprintf("volume %s: %v", volume, err))
			continue
		}
		report.Volumes = append(report.Volumes, volume)
	}
	report.Remaining = report.Remaining || len(report.Errors) > 0
	return report
}

// labelledVolumes are the named volumes the host created with
// familyLabel=name.
func labelledVolumes(name string) ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(volumeStore, "volumes"))
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var names []string
	for _, e := range entries {
		if _, shared := sharedCachePath(e.Name()); !e.IsDir() || shared || !dockerName.MatchString(e.Name()) {
			continue
		}
		if v, err := inspectVolume(e.Name()); err == nil && v.createdBy == "" && v.Labels[familyLabel] == name && len(names) < familyPruneLimit {
			names = append(names, e.Name())
		}
	}
	return names, nil
}
