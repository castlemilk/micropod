package main

import (
	"bufio"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func (s *dockerEngine) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if err := s.dispatch(w, r); err != nil {
		code := 500
		var problem apiError
		if errors.As(err, &problem) {
			code = problem.code
		}
		writeJSON(w, code, map[string]string{"message": err.Error()})
	}
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
	case path == "_ping" && (method == "HEAD" || method == "GET"):
		w.Header().Set("API-Version", dockerAPI)
		w.Header().Set("Ostype", "linux")
		w.WriteHeader(200)
		if method == "GET" {
			_, _ = io.WriteString(w, "OK")
		}
		return nil
	case path == "version" && method == "GET":
		writeJSON(w, 200, map[string]any{"Version": "micropod", "ApiVersion": dockerAPI, "MinAPIVersion": "1.44", "Os": "linux", "Arch": "arm64", "Platform": map[string]string{"Name": "Micropod"}})
		return nil
	case path == "micropod/buildkit" && method == "GET":
		if _, err := os.Stat(buildkitBinary); err != nil {
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
		metrics["start_parallelism_limit"] = cap(s.startSlots)
		metrics["setup_slots_in_use"] = len(s.startSlots)
		metrics["setup_wait_usec_total"] = s.metrics.setupWaitUS.Load()
		writeJSON(w, 200, metrics)
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
	case path == "info" && method == "GET":
		writeJSON(w, 200, s.info())
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
		c, err := s.lookup(key)
		if err != nil {
			return err
		}
		switch method + " " + op {
		case "GET stats":
			return s.stats(w, r, c)
		case "GET json":
			s.mu.Lock()
			v := c.inspect()
			s.mu.Unlock()
			writeJSON(w, 200, v)
		case "POST start":
			if err := s.start(c); err != nil {
				return err
			}
			w.WriteHeader(204)
		case "POST wait":
			return s.wait(w, r, c)
		case "POST attach", "GET logs":
			return s.stream(w, r, c, op == "attach")
		case "POST exec":
			return s.createExec(w, r, c)
		case "POST stop", "POST kill":
			timeout := int64(10)
			if op == "kill" {
				signal := r.URL.Query().Get("signal")
				switch strings.TrimPrefix(strings.ToUpper(signal), "SIG") {
				case "", "KILL", "9":
					timeout = 0
				default:
					return fail(400, "only SIGKILL is supported by the CRI kill operation")
				}
			}
			if v := r.URL.Query().Get("t"); v != "" {
				t, e := strconv.ParseUint(v, 10, 16)
				if e != nil {
					return fail(400, "invalid stop timeout")
				}
				timeout = int64(t)
			}
			if err := s.stop(r.Context(), c, timeout); err != nil {
				return err
			}
			w.WriteHeader(204)
		case "DELETE ":
			if err := s.remove(r.Context(), c, truth(r.URL.Query().Get("force"))); err != nil {
				return err
			}
			w.WriteHeader(204)
		default:
			return fail(501, "unsupported container operation: "+op)
		}
		return nil
	default:
		return fail(501, "operation is unavailable on the Micropod native engine")
	}
}
func truth(s string) bool { return s == "1" || s == "true" }

// Clients use either arrays (current SDK) or sets (the stock Docker CLI) in filters.
func dockerFilters(raw string, allowed ...string) (map[string][]string, error) {
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
				if enabled {
					items = append(items, k)
				}
			}
		}
		out[key] = items
	}
	return out, nil
}
func (s *dockerEngine) list(w http.ResponseWriter, r *http.Request) error {
	filters, err := dockerFilters(r.URL.Query().Get("filters"), "label", "name", "id", "status")
	if err != nil {
		return err
	}
	list := []map[string]any{}
	s.mu.Lock()
	for _, c := range s.containers {
		if !truth(r.URL.Query().Get("all")) && !c.busy() {
			continue
		}
		match := matchesLabels(c.Config.Labels, filters["label"])
		for k, values := range filters {
			if k == "label" || len(values) == 0 {
				continue
			}
			anyMatch := false
			for _, v := range values {
				anyMatch = anyMatch || (k == "id" && strings.HasPrefix(c.ID, v)) || (k == "name" && strings.Contains(c.Name, strings.TrimPrefix(v, "/"))) || (k == "status" && c.Phase == v)
			}
			match = match && anyMatch
		}
		if match {
			list = append(list, map[string]any{"Id": c.ID, "Names": []string{"/" + c.Name}, "Image": c.Config.Image, "ImageID": c.ImageID, "Command": strings.Join(append(append([]string{}, c.Config.Entrypoint...), c.Config.Cmd...), " "), "Created": c.Created.Unix(), "State": c.Phase, "Status": c.Phase, "Labels": c.Config.Labels, "Ports": []any{}, "Mounts": []any{}})
		}
	}
	s.mu.Unlock()
	writeJSON(w, 200, list)
	return nil
}
func (s *dockerEngine) wait(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	condition := r.URL.Query().Get("condition")
	if condition != "" && condition != "not-running" && condition != "next-exit" && condition != "removed" {
		return fail(400, "invalid wait condition")
	}
	s.mu.Lock()
	epoch := c.Exits
	s.mu.Unlock()
	// Docker waits for this acknowledgement before it sends the start request.
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(200)
	w.(http.Flusher).Flush()
	s.mu.Lock()
	for {
		ready := !c.busy()
		switch condition {
		case "next-exit":
			ready = c.Exits != epoch
		case "removed":
			ready = c.removed
		}
		if ready || c.removed || c.Phase == "dead" {
			result := map[string]any{"StatusCode": c.Exit}
			readersDone := c.readersDone
			if c.Failure != "" {
				result["Error"] = map[string]string{"Message": c.Failure}
			}
			s.mu.Unlock()
			// The CLI can close its attached stream when a wait finishes. Deliver
			// the final frames before acknowledging exit to foreground clients.
			if readersDone != nil && (condition == "removed" || condition == "next-exit") {
				select {
				case <-readersDone:
				case <-r.Context().Done():
					return nil
				case <-time.After(2 * time.Second):
				}
			}
			_ = json.NewEncoder(w).Encode(result)
			return nil
		}
		ch := c.changed
		s.mu.Unlock()
		select {
		case <-r.Context().Done():
			return nil
		case <-ch:
		}
		s.mu.Lock()
	}
}

func (s *dockerEngine) stream(w http.ResponseWriter, r *http.Request, c *dockerContainer, attach bool) error {
	q := r.URL.Query()
	if truth(q.Get("stdin")) {
		return fail(400, "interactive stdin is unavailable")
	}
	if !attach && ((q.Get("tail") != "" && q.Get("tail") != "all") || q.Get("since") != "" || q.Get("until") != "" || truth(q.Get("timestamps"))) {
		return fail(400, "time and tail log selection are unavailable")
	}
	s.mu.Lock()
	if c.removed {
		s.mu.Unlock()
		return fail(404, "container removed")
	}
	f, err := os.Open(filepath.Join(c.dir(), "output"))
	prestart := c.Phase == "created"
	if err == nil && attach && prestart && truth(q.Get("stream")) {
		if c.foregroundReaders == 0 {
			c.readersDone = make(chan struct{})
		}
		c.foregroundReaders++
		defer func() {
			s.mu.Lock()
			c.foregroundReaders--
			if c.foregroundReaders == 0 {
				close(c.readersDone)
				c.readersDone = nil
			}
			s.mu.Unlock()
		}()
	}
	var offset int64
	if attach && !truth(q.Get("logs")) {
		offset = c.outputBytes
	}
	s.mu.Unlock()
	if err != nil {
		if f != nil {
			f.Close()
		}
		return err
	}
	defer f.Close()
	var writer io.Writer
	var flush func() error
	var peer *net.UnixConn
	var pulse <-chan time.Time
	cancelled := r.Context().Done()
	if attach {
		conn, rw, err := w.(http.Hijacker).Hijack()
		if err != nil {
			return err
		}
		defer conn.Close()
		cancelled = nil // A hijacked transport owns its EOF and half-close lifecycle.
		peer, _ = conn.(*net.UnixConn)
		timer := time.NewTicker(2 * time.Second)
		defer timer.Stop()
		pulse = timer.C
		upgrade := strings.EqualFold(r.Header.Get("Upgrade"), "tcp")
		if upgrade {
			_, err = io.WriteString(rw, "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n\r\n")
		} else {
			_, err = io.WriteString(rw, "HTTP/1.1 200 OK\r\nContent-Type: application/vnd.docker.raw-stream\r\n\r\n")
		}
		if err != nil || rw.Flush() != nil {
			return nil
		}
		// A read half-close is normal for Docker attach without stdin.
		writer, flush = rw, rw.Flush
	} else {
		w.Header().Set("Content-Type", "application/vnd.docker.multiplexed-stream")
		w.WriteHeader(200)
		w.(http.Flusher).Flush()
		writer = w
		flush = http.NewResponseController(w).Flush
	}
	follow := truth(q.Get("follow")) || attach && truth(q.Get("stream"))
	read := bufio.NewReader(nil)
	for {
		s.mu.Lock()
		ch := c.changed
		end := c.outputBytes
		done := !follow || c.removed || (!c.busy() && !(prestart && c.Phase == "created"))
		s.mu.Unlock()
		read.Reset(io.NewSectionReader(f, offset, end-offset))
		offset = end
		if peer != nil {
			_ = peer.SetWriteDeadline(time.Now().Add(30 * time.Second))
		}
		if err := copyFrames(read, writer, truth(q.Get("stdout")), truth(q.Get("stderr"))); err != nil {
			return nil
		}
		if err := flush(); err != nil || done {
			return nil
		}
		select {
		case <-ch:
		case <-cancelled:
			return nil
		case <-pulse:
			if peer != nil && disconnected(peer) {
				return nil
			}
		}
	}
}

// POLLHUP detects a fully closed peer. Docker may legitimately half-close its
// write side immediately after attaching a read-only stdout/stderr client.
func disconnected(peer *net.UnixConn) bool {
	raw, err := peer.SyscallConn()
	if err != nil {
		return true
	}
	closed := false
	err = raw.Control(func(fd uintptr) {
		p := []unix.PollFd{{Fd: int32(fd)}}
		_, err := unix.Poll(p, 0)
		closed = err != nil || p[0].Revents&(unix.POLLHUP|unix.POLLERR|unix.POLLNVAL) != 0
	})
	return err != nil || closed
}

func copyFrames(r *bufio.Reader, w io.Writer, stdout, stderr bool) error {
	for {
		h, err := r.Peek(8)
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		n := int64(binary.BigEndian.Uint32(h[4:]))
		dst := io.Writer(io.Discard)
		if (h[0] == 1 && stdout) || (h[0] == 2 && stderr) {
			dst = w
		}
		if _, err = dst.Write(h); err != nil {
			return err
		}
		r.Discard(8)
		if _, err = io.CopyN(dst, r, n); err != nil {
			return err
		}
	}
}
func (s *dockerEngine) images(w http.ResponseWriter, r *http.Request, path string) error {
	q := r.URL.Query()
	imgMap := func(i *cri.Image) map[string]any {
		return map[string]any{"Id": i.Id, "RepoTags": i.RepoTags, "RepoDigests": i.RepoDigests, "Size": i.Size, "Os": "linux", "Architecture": "arm64"}
	}
	switch {
	case path == "load" && r.Method == "POST":
		return importImages(w, r)
	case path == "get" && r.Method == "GET":
		return exportImages(w, r, q["names"])
	case strings.HasSuffix(path, "/get") && r.Method == "GET":
		return exportImages(w, r, []string{strings.TrimSuffix(path, "/get")})
	case path == "json" && r.Method == "GET":
		res, err := s.node.images.ListImages(r.Context(), &cri.ListImagesRequest{})
		if err != nil {
			return err
		}
		list := []map[string]any{}
		for _, i := range res.Images {
			list = append(list, imgMap(i))
		}
		writeJSON(w, 200, list)
		return nil
	case strings.HasSuffix(path, "/json") && r.Method == "GET":
		i, err := s.node.images.ImageStatus(r.Context(), &cri.ImageStatusRequest{Image: &cri.ImageSpec{Image: strings.TrimSuffix(path, "/json")}, Verbose: true})
		if err != nil {
			return err
		}
		if i.Image == nil {
			return fail(404, "No such image")
		}
		v := imgMap(i.Image)
		var details struct {
			ImageSpec struct {
				Config  json.RawMessage
				Created string
			}
		}
		if json.Unmarshal([]byte(i.Info["info"]), &details) == nil {
			v["Config"] = details.ImageSpec.Config
			v["Created"] = details.ImageSpec.Created
		}
		writeJSON(w, 200, v)
		return nil
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
		var auth *cri.AuthConfig
		if header := r.Header.Get("X-Registry-Auth"); header != "" {
			b, err := base64.URLEncoding.DecodeString(header)
			if err != nil {
				b, err = base64.RawURLEncoding.DecodeString(header)
			}
			if err != nil || json.Unmarshal(b, &auth) != nil {
				return fail(400, "invalid registry authentication")
			}
		}
		// An explicit Docker pull refreshes a tag. Credentials are scoped to this call.
		_, err := s.node.images.PullImage(r.Context(), &cri.PullImageRequest{Image: &cri.ImageSpec{Image: ref}, Auth: auth})
		if err != nil {
			return err
		}
		writeJSON(w, 200, map[string]string{"status": "Downloaded " + ref})
		return nil
	default:
		return fail(501, "unsupported image operation")
	}
}
