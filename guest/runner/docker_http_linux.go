package main

import (
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// extraRoutes lets feature files add Docker API routes from their own init()
// without editing dispatch. They are consulted, in registration order, only
// for requests no built-in route matched, just before the 501 fallback; the
// first handler that returns handled=true wins. path has the leading slash and
// any /v1.NN prefix removed. POST and DELETE requests already hold an
// engineLease for the handler's lifetime (a hijacked connection included).
var extraRoutes []func(s *dockerEngine, w http.ResponseWriter, r *http.Request, method, path string) (handled bool, err error)

// engineCommit is set at link time by ci/build-runner-tools.sh to the commit
// recorded in the bundle's runner/manifest.json, and reported as GitCommit.
var engineCommit = "unknown"

func (s *dockerEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	rec := &statusRecorder{ResponseWriter: w}
	var errMsg string
	if err := s.dispatch(rec, r); err != nil {
		code := 500
		var problem apiError
		if errors.As(err, &problem) {
			code = problem.code
		}
		errMsg = err.Error()
		writeJSON(rec, code, map[string]string{"message": errMsg})
	}
	s.metrics.api.recordHTTP("docker_api", r.Method, r.URL.Path, rec.status, start, time.Since(start), errMsg)
}
func (s *dockerEngine) dispatch(w http.ResponseWriter, r *http.Request) error {
	path := strings.TrimPrefix(r.URL.Path, "/")
	if strings.HasPrefix(path, "v1.") {
		v, rest, _ := strings.Cut(path, "/")
		minor, e := strconv.Atoi(strings.TrimPrefix(v, "v1."))
		if e != nil || minor < 44 || minor > 47 {
			return fail(400, "supported Docker API versions are 1.44 through "+dockerAPI)
		}
		path = rest
	}
	method := r.Method
	switch {
	case path == "auth" && method == http.MethodPost:
		return registryLogin(w, r)
	case (path == "grpc" || path == "session") && method == http.MethodPost:
		return s.dockerBuildkitUpgrade(w, r, path)
	case path == "_ping" && (method == "HEAD" || method == "GET"):
		w.Header().Set("API-Version", dockerAPI)
		w.Header().Set("Ostype", "linux")
		if s.buildkitSocket != "" {
			w.Header().Set("Builder-Version", "2")
		}
		w.WriteHeader(200)
		if method == "GET" {
			_, _ = io.WriteString(w, "OK")
		}
		return nil
	case path == "version" && method == "GET":
		writeJSON(w, 200, map[string]any{"Version": "micropod", "ApiVersion": dockerAPI, "MinAPIVersion": "1.44", "Os": "linux", "Arch": "arm64", "Platform": map[string]string{"Name": "Micropod"}, "GitCommit": engineCommit, "MicropodCapabilities": engineCapabilities(s.buildkitSocket != "")})
		return nil
	case path == "events" && method == "GET":
		return s.serveEvents(w, r)
	case path == "micropod/buildkit" && method == "GET":
		if s.buildkitSocket == "" {
			return fail(503, "BuildKit is unavailable")
		}
		writeJSON(w, 200, map[string]string{"worker": "containerd", "runtime": "crun"})
		return nil
	case path == "micropod/metrics" && method == "GET":
		metrics := s.metrics.snapshot()
		network := s.metrics.networks.snapshot()
		if s.direct != nil {
			network["macvlan_quarantined_ports"] = s.direct.quarantined()
			if counts := s.direct.linkCounters(); counts != nil {
				network["published_link"] = counts
			}
		}
		metrics["network"] = network
		apiSnap, recentIssues := s.metrics.api.snapshot()
		metrics["api"] = apiSnap
		metrics["reaper"] = s.metrics.reaper.snapshot()
		metrics["recent_issues"] = recentIssues
		metrics["start_parallelism_limit"] = cap(s.startSlots)
		metrics["setup_slots_in_use"] = len(s.startSlots)
		metrics["setup_wait_usec_total"] = s.metrics.setupWaitUS.Load()
		writeJSON(w, 200, metrics)
		return nil
	case path == "micropod/traces" && (method == "GET" || method == "POST"):
		s.serveObservabilityTraces(w, r)
		return nil
	case path == "micropod/traces/clear" && method == "POST":
		s.serveObservabilityTraces(w, r)
		return nil
	case path == "micropod/storage" && method == "GET":
		// All snapshots, writable layers and caches live on this ext4 disk.
		// statfs stays constant-cost even when many jobs share a package cache.
		var st unix.Statfs_t
		if err := unix.Statfs(engineRoot, &st); err != nil {
			return err
		}
		block := uint64(st.Bsize)
		writeJSON(w, 200, map[string]uint64{"total_bytes": st.Blocks * block, "used_bytes": (st.Blocks - st.Bfree) * block, "available_bytes": st.Bavail * block})
		return nil
	case path == "micropod/containers/summary" && method == "GET":
		return s.containersSummary(w, r)
	case path == "info" && method == "GET":
		info := s.info()
		info["MicropodCapabilities"] = []string{"restart"}
		info["NEventsListener"] = s.events.subscribers()
		writeJSON(w, 200, info)
		return nil
	}
	// Hold the cross-process admission lock for all mutating requests. Start
	// additionally transfers its own lease to the job until its pod is gone.
	if method == "POST" || method == "DELETE" {
		lease, err := engineLease()
		if err != nil {
			return err
		}
		defer lease.Close()
	}
	switch {
	case path == "networks" || strings.HasPrefix(path, "networks/"):
		return s.networks(w, r, strings.TrimPrefix(path, "networks"))
	case strings.HasPrefix(path, "images/"):
		return s.images(w, r, strings.TrimPrefix(path, "images/"))
	case path == "volumes" || strings.HasPrefix(path, "volumes/"):
		return s.volumes(w, r, strings.TrimPrefix(path, "volumes"))
	case path == "containers/create" && method == "POST":
		if p := r.URL.Query().Get("platform"); p != "" && p != "linux/arm64" && p != "linux/arm64/v8" {
			return fail(400, "only linux/arm64 images are supported")
		}
		b, err := readBody(w, r)
		if err != nil {
			return err
		}
		spec, err := parseDockerConfig(b)
		if err != nil {
			return fail(400, err.Error())
		}
		c, err := s.create(r.Context(), spec, r.URL.Query().Get("name"))
		if err != nil {
			return err
		}
		writeJSON(w, 201, map[string]any{"Id": c.ID, "Warnings": []string{}})
		return nil
	case path == "containers/json" && method == "GET":
		return s.list(w, r)
	case strings.HasPrefix(path, "exec/"):
		return s.exec(w, r, strings.TrimPrefix(path, "exec/"))
	case strings.HasPrefix(path, "containers/"):
		key, op, _ := strings.Cut(strings.TrimPrefix(path, "containers/"), "/")
		c, err := s.lookupFor(r.Context(), key)
		if err != nil {
			return err
		}
		switch method + " " + op {
		case "GET stats":
			return s.stats(w, r, c)
		case "GET archive", "HEAD archive", "PUT archive":
			return s.serveArchive(w, r, c)
		case "GET json":
			s.mu.Lock()
			v := s.inspectDockerContainer(c)
			s.mu.Unlock()
			writeJSON(w, 200, v)
			return nil
		case "POST start", "POST stop", "POST kill", "POST restart", "DELETE ":
			return s.containerLifecycle(w, r, c, op)
		case "POST wait":
			return s.wait(w, r, c)
		case "POST attach", "GET logs":
			return s.stream(w, r, c, op == "attach")
		case "POST resize":
			return s.resizeContainer(w, r, c)
		case "POST exec":
			return s.createExec(w, r, c)
		default:
			return fail(501, "unsupported container operation: "+op)
		}
	default:
		for _, route := range extraRoutes {
			// An error counts as handled: the route recognised the request.
			if handled, err := route(s, w, r, method, path); handled || err != nil {
				return err
			}
		}
		return fail(501, "operation is unavailable on the Micropod native engine")
	}
}
func truth(s string) bool { return s == "1" || s == "true" }

// Clients use either arrays (current SDK) or sets (the stock Docker CLI) in filters.
func dockerFilters(raw string, allowed ...string) (map[string][]string, error) {
	return dockerFilterValues(raw, nil, allowed)
}

func dockerFilterValues(raw string, setKeys, allowed []string) (map[string][]string, error) {
	if raw == "" {
		return nil, nil
	}
	var wire map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &wire); err != nil {
		return nil, fail(400, "invalid filters")
	}
	out := make(map[string][]string, len(wire))
	for key, value := range wire {
		if !slices.Contains(allowed, key) {
			return nil, fail(400, "unsupported filter: "+key)
		}
		var items []string
		if err := json.Unmarshal(value, &items); err != nil {
			var set map[string]bool
			if err := json.Unmarshal(value, &set); err != nil {
				return nil, fail(400, "invalid filter values")
			}
			for k, enabled := range set {
				if enabled || slices.Contains(setKeys, key) {
					items = append(items, k)
				}
			}
		}
		out[key] = items
	}
	return out, nil
}

type dockerContainerListRow struct {
	ID              string `json:"Id"`
	Names           []string
	Image           string
	ImageID         string
	Command         string
	Created         int64
	State           string
	Status          string
	Labels          map[string]string
	Ports           []dockerSummaryPort
	Mounts          []any
	NetworkSettings dockerNetworkSettings
	created         time.Time
}

func (s *dockerEngine) list(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	filters, err := dockerFilterValues(q.Get("filters"), []string{"name", "ancestor", "network"},
		[]string{"label", "name", "id", "status", "ancestor", "network"})
	if err != nil {
		return err
	}
	ancestors, filterAncestor := filters["ancestor"]
	delete(filters, "ancestor")
	names := filters["name"]
	delete(filters, "name")
	networks, filterNetwork := filters["network"]
	delete(filters, "network")
	patterns := make([]*regexp.Regexp, 0, len(names))
	for _, value := range names {
		if pattern, err := regexp.Compile(value); err == nil {
			patterns = append(patterns, pattern)
		}
	}
	all := truth(q.Get("all")) || len(filters["status"]) != 0
	list := []dockerContainerListRow{}
	viewer := viewerOf(r.Context())
	s.mu.Lock()
	for _, c := range s.containers {
		if !all && !c.busy() || !seesContainer(viewer, c) {
			continue
		}
		if len(names) != 0 && !slices.ContainsFunc(patterns, func(pattern *regexp.Regexp) bool {
			return pattern.MatchString(c.Name) || pattern.MatchString("/"+c.Name)
		}) {
			continue
		}
		if filterNetwork && !s.matchesDockerNetwork(c, networks) {
			continue
		}
		match := matchesLabels(c.Config.Labels, filters["label"])
		for k, values := range filters {
			if k == "label" || len(values) == 0 {
				continue
			}
			anyMatch := false
			for _, v := range values {
				anyMatch = anyMatch || (k == "id" && strings.HasPrefix(c.ID, v)) || (k == "status" && c.dockerStatus() == v)
			}
			match = match && anyMatch
		}
		if match {
			status := c.dockerStatus()
			list = append(list, dockerContainerListRow{
				ID: c.ID, Names: []string{"/" + c.Name}, Image: c.Config.Image, ImageID: c.ImageID,
				Command: strings.Join(append(append([]string{}, c.Config.Entrypoint...), c.Config.Cmd...), " "),
				Created: c.Created.Unix(), State: status, Status: status, Labels: c.Config.Labels,
				Ports: c.effectivePorts().summary(), Mounts: []any{}, created: c.Created,
				NetworkSettings: dockerNetworkSettings{Networks: s.dockerContainerNetworks(c)},
			})
		}
	}
	s.mu.Unlock()
	if filterAncestor {
		ids := make(map[string]bool)
		for _, row := range list {
			ids[row.ImageID] = true
		}
		matching, err := s.matchContainerAncestorImages(r.Context(), ancestors, ids)
		if err != nil {
			return err
		}
		list = slices.DeleteFunc(list, func(row dockerContainerListRow) bool { return !matching[row.ImageID] })
	}
	slices.SortFunc(list, func(a, b dockerContainerListRow) int {
		if order := b.created.Compare(a.created); order != 0 {
			return order
		}
		return cmp.Compare(a.ID, b.ID)
	})
	writeJSON(w, 200, list)
	return nil
}

// containersSummary returns every container with published ports and cache
// metadata in a single vsock RTT, avoiding N+1 docker inspect calls on list.
func (s *dockerEngine) containersSummary(w http.ResponseWriter, r *http.Request) error {
	type summaryPort struct {
		HostIP        string `json:"hostIp,omitempty"`
		HostPort      uint32 `json:"hostPort"`
		ContainerPort uint32 `json:"containerPort"`
		Protocol      string `json:"protocol"`
	}
	type summaryRow struct {
		ID            string            `json:"id"`
		Name          string            `json:"name"`
		Image         string            `json:"image"`
		State         string            `json:"state"`
		ExitCode      int32             `json:"exitCode"`
		Created       int64             `json:"created"`
		Labels        map[string]string `json:"labels,omitempty"`
		Ports         []summaryPort     `json:"ports,omitempty"`
		MicropodCache map[string]any    `json:"micropodCache,omitempty"`
		created       time.Time
	}
	s.mu.Lock()
	rows := make([]summaryRow, 0, len(s.containers))
	for _, c := range s.containers {
		if c.removed {
			continue
		}
		var ports []summaryPort
		for key, bindings := range c.effectivePorts() {
			pStr, proto, _ := strings.Cut(key, "/")
			if proto == "" {
				proto = "tcp"
			}
			cp, _ := strconv.ParseUint(pStr, 10, 32)
			for _, b := range bindings {
				hp, _ := strconv.ParseUint(b.HostPort, 10, 32)
				if cp > 0 && hp > 0 {
					ports = append(ports, summaryPort{
						HostIP: b.HostIP, HostPort: uint32(hp), ContainerPort: uint32(cp), Protocol: proto,
					})
				}
			}
		}
		row := summaryRow{
			ID:       c.ID,
			Name:     c.Name,
			Image:    c.Config.Image,
			State:    c.dockerStatus(),
			ExitCode: c.Exit,
			Created:  c.Created.Unix(),
			Labels:   c.Config.Labels,
			Ports:    ports,
			created:  c.Created,
		}
		if c.Cache != nil {
			row.MicropodCache = map[string]any{
				"scope":    c.Cache.Scope,
				"trust":    c.Cache.Trust,
				"readOnly": c.Cache.ReadOnly,
				"tools":    c.cacheToolStates(),
			}
		}
		rows = append(rows, row)
	}
	s.mu.Unlock()
	slices.SortFunc(rows, func(a, b summaryRow) int {
		if order := b.created.Compare(a.created); order != 0 {
			return order
		}
		return cmp.Compare(a.ID, b.ID)
	})
	writeJSON(w, 200, map[string]any{"containers": rows})
	return nil
}
func (s *dockerEngine) wait(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	condition := r.URL.Query().Get("condition")
	if condition != "" && condition != "not-running" && condition != "next-exit" && condition != "removed" {
		return fail(400, "invalid wait condition")
	}
	s.mu.Lock()
	ready := c.removed || c.Phase == "dead" || (condition != "removed" && condition != "next-exit" && !c.busy())
	result := c.waitStatus()
	var pending *dockerExitReceipt
	if !ready && condition != "removed" {
		pending = c.pendingExitReceipt()
	}
	s.mu.Unlock()
	// Docker waits for this acknowledgement before it sends the start request.
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	w.(http.Flusher).Flush()
	if pending != nil {
		select {
		case <-r.Context().Done():
			return nil
		case <-pending.done:
			result = pending.result
		}
	} else if !ready {
		var completed bool
		result, completed = s.waitRemoved(r.Context(), c)
		if !completed {
			return nil
		}
	}
	// Removed means the names its delegated socket's family held are free
	// too: `docker run --rm` of a job's container answers once they are.
	if condition == "removed" && !s.awaitFamily(r.Context(), c) {
		return nil
	}
	// The CLI can close its attached stream when a wait finishes. Deliver
	// the final frames before acknowledging exit to foreground clients.
	if result.readersDone != nil && (condition == "removed" || condition == "next-exit") {
		select {
		case <-result.readersDone:
		case <-r.Context().Done():
			return nil
		case <-time.After(2 * time.Second):
		}
	}
	payload := map[string]any{"StatusCode": result.exit}
	if result.failure != "" {
		payload["Error"] = map[string]string{"Message": result.failure}
	}
	_ = json.NewEncoder(w).Encode(payload)
	return nil
}

func (s *dockerEngine) waitRemoved(ctx context.Context, c *dockerContainer) (dockerWaitStatus, bool) {
	for {
		s.mu.Lock()
		if c.removed || c.Phase == "dead" {
			result := c.waitStatus()
			s.mu.Unlock()
			return result, true
		}
		ch := c.changed
		s.mu.Unlock()
		select {
		case <-ctx.Done():
			return dockerWaitStatus{}, false
		case <-ch:
		}
	}
}

// POLLHUP detects a fully closed peer. Docker may legitimately half-close its
// write side immediately after attaching a read-only stdout/stderr client.
func disconnected(peer *net.UnixConn) bool {
	return peerDisconnectError(peer) != nil
}

func peerDisconnectError(peer *net.UnixConn) error {
	raw, err := peer.SyscallConn()
	if err != nil {
		return err
	}
	var cause error
	err = raw.Control(func(fd uintptr) {
		p := []unix.PollFd{{Fd: int32(fd)}}
		_, err := unix.Poll(p, 0)
		if pollReportsDisconnection(p[0].Revents, err) {
			if err != nil {
				cause = fmt.Errorf("poll peer: %w", err)
			} else {
				cause = fmt.Errorf("poll peer revents=%#x", p[0].Revents)
			}
		}
	})
	if err != nil {
		return err
	}
	return cause
}

func pollReportsDisconnection(events int16, err error) bool {
	// Local interruption or temporary allocation failure says nothing about
	// whether this client disconnected. The next observation can retry.
	if errors.Is(err, unix.EINTR) || errors.Is(err, unix.EAGAIN) || errors.Is(err, unix.ENOMEM) {
		return false
	}
	return err != nil || events&(unix.POLLHUP|unix.POLLERR|unix.POLLNVAL) != 0
}

func (s *dockerEngine) images(w http.ResponseWriter, r *http.Request, path string) error {
	q := r.URL.Query()
	imgMap := func(i *cri.Image) map[string]any {
		return map[string]any{"Id": i.Id, "RepoTags": i.RepoTags, "RepoDigests": i.RepoDigests, "Size": i.Size, "Os": "linux", "Architecture": "arm64"}
	}
	switch {
	case path == "load" && r.Method == "POST":
		s.imageMu.RLock()
		defer s.imageMu.RUnlock()
		return importImages(w, r)
	case path == "get" && r.Method == "GET":
		return s.exportImages(w, r, q["names"])
	case strings.HasSuffix(path, "/get") && r.Method == "GET":
		return s.exportImages(w, r, []string{strings.TrimSuffix(path, "/get")})
	case path == "json" && r.Method == "GET":
		return s.listDockerImages(w, r, imgMap)
	case strings.HasSuffix(path, "/json") && r.Method == "GET":
		s.imageMu.RLock()
		defer s.imageMu.RUnlock()
		i, err := s.node.dockerImageStatus(r.Context(), strings.TrimSuffix(path, "/json"), true)
		if err != nil {
			return err
		}
		if i.Image == nil {
			return fail(404, "No such image")
		}
		digests, err := s.node.inspectDockerRepoDigests(r.Context(), i.Image)
		if err != nil {
			return err
		}
		v := imgMap(i.Image)
		v["RepoDigests"] = digests
		var details struct {
			ImageSpec struct {
				Config  json.RawMessage
				Created string
				RootFS  json.RawMessage `json:"rootfs"`
			}
		}
		if json.Unmarshal([]byte(i.Info["info"]), &details) == nil {
			v["Config"] = details.ImageSpec.Config
			if len(details.ImageSpec.Config) > 0 {
				config, err := s.inspectDockerImageConfig(r.Context(), i.GetImage().GetId(), details.ImageSpec.Config)
				if err != nil {
					return err
				}
				v["Config"] = config
			}
			v["Created"] = details.ImageSpec.Created
			var rootFS struct {
				Type    string   `json:"type"`
				DiffIDs []string `json:"diff_ids"`
			}
			if json.Unmarshal(details.ImageSpec.RootFS, &rootFS) == nil && rootFS.Type != "" {
				v["RootFS"] = struct {
					Type   string
					Layers []string `json:",omitempty"`
				}{Type: rootFS.Type, Layers: rootFS.DiffIDs}
			}
		}
		writeJSON(w, 200, v)
		return nil
	case strings.HasSuffix(path, "/history") && r.Method == "GET":
		return s.imageHistory(w, r, strings.TrimSuffix(path, "/history"))
	case strings.HasSuffix(path, "/tag") && r.Method == "POST":
		return s.tagImage(w, r, strings.TrimSuffix(path, "/tag"))
	case strings.HasSuffix(path, "/push") && r.Method == "POST":
		return s.pushImage(w, r, strings.TrimSuffix(path, "/push"))
	case path == "create" && r.Method == "POST":
		ref := q.Get("fromImage")
		tag := q.Get("tag")
		if ref == "" {
			return fail(400, "fromImage is required")
		}
		if p := q.Get("platform"); p != "" && p != "linux/arm64" && p != "linux/arm64/v8" {
			return fail(400, "unsupported platform")
		}
		if tag != "" {
			if strings.HasPrefix(tag, "sha256:") {
				ref += "@" + tag
			} else {
				ref += ":" + tag
			}
		}
		auth, err := registryPullCredentials(w, r, ref)
		if err != nil {
			return err
		}
		// An explicit Docker pull refreshes a tag. Credentials are scoped to this call.
		s.imageMu.RLock()
		defer s.imageMu.RUnlock()
		_, err = s.node.images.PullImage(r.Context(), &cri.PullImageRequest{Image: &cri.ImageSpec{Image: ref}, Auth: auth})
		if err != nil {
			return err
		}
		// The unpacked files are on the disk before the pull answers
		// (image_durability_linux.go).
		if err := imageSync.Sync(); err != nil {
			return err
		}
		writeJSON(w, 200, map[string]string{"status": "Downloaded " + ref})
		return nil
	case r.Method == "DELETE":
		return s.deleteImage(w, r, path)
	default:
		return fail(501, "unsupported image operation")
	}
}
