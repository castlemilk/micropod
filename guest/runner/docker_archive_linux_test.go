package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	mounttypes "github.com/containerd/containerd/api/types"
	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestDockerArchiveRouteRequiresPath(t *testing.T) {
	const id = "0123456789012345678901234567890123456789012345678901234567890123"
	s := &dockerEngine{containers: map[string]*dockerContainer{id: {}}}
	for _, method := range []string{http.MethodHead, http.MethodGet, http.MethodPut} {
		res := httptest.NewRecorder()
		s.ServeHTTP(res, httptest.NewRequest(method, "/v"+dockerAPI+"/containers/"+id+"/archive", nil))
		if res.Code != http.StatusBadRequest {
			t.Errorf("%s archive without path: %d", method, res.Code)
		}
	}
}

func TestDockerArchiveTarRoundTrip(t *testing.T) {
	path := t.TempDir()
	root, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	if err := os.Mkdir(filepath.Join(path, "bundle"), 0700); err != nil {
		t.Fatal(err)
	}
	mount := dockerMount{Target: "/artifacts"}
	view := dockerArchiveView{root: root, mount: mount.Target, configured: []dockerMount{mount}}
	stamp := time.Date(2024, time.March, 1, 4, 3, 2, 0, time.UTC)

	var archive bytes.Buffer
	out := tar.NewWriter(&archive)
	for _, h := range []tar.Header{
		{Name: "./", Typeflag: tar.TypeDir, Mode: 0777},
		{Name: "./bundle/", Typeflag: tar.TypeDir, Mode: 0751},
		{Name: "./bundle/task", Typeflag: tar.TypeReg, Mode: 0750, Size: 3},
		{Name: "./bundle/task-copy", Typeflag: tar.TypeLink, Linkname: "./bundle/task"},
		{Name: "./alias", Typeflag: tar.TypeSymlink, Linkname: "bundle"},
	} {
		h.Uid, h.Gid, h.ModTime = os.Geteuid(), os.Getegid(), stamp
		if err := out.WriteHeader(&h); err != nil {
			t.Fatal(err)
		}
		if h.Typeflag == tar.TypeReg {
			if _, err := io.WriteString(out, "CI\n"); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := out.Close(); err != nil {
		t.Fatal(err)
	}
	req := func(method, raw string, source io.Reader) *httptest.ResponseRecorder {
		t.Helper()
		p, err := parseArchivePath(raw)
		if err != nil {
			t.Fatal(err)
		}
		res := httptest.NewRecorder()
		err = serveArchiveView(res, httptest.NewRequest(method, "/", source), view, p, true)
		if err != nil {
			t.Fatal(err)
		}
		if res.Code != http.StatusOK {
			t.Fatalf("%s %s: got %d", method, raw, res.Code)
		}
		return res
	}
	req(http.MethodPut, "/artifacts", &archive)

	bundle, err := os.Stat(filepath.Join(path, "bundle"))
	if err != nil || bundle.Mode().Perm() != 0751 || !bundle.ModTime().Equal(stamp) {
		t.Fatalf("merged directory metadata: %v %v", bundle, err)
	}
	task, err := os.Stat(filepath.Join(path, "bundle", "task"))
	if err != nil {
		t.Fatal(err)
	}
	copy, err := os.Stat(filepath.Join(path, "bundle", "task-copy"))
	if err != nil || !os.SameFile(task, copy) {
		t.Fatalf("uploaded hardlink identity: %v %v", copy, err)
	}

	head := req(http.MethodHead, "/artifacts/alias/task", nil)
	data, err := base64.StdEncoding.DecodeString(head.Header().Get(archiveStatHeader))
	var stat dockerArchiveStat
	if err != nil || json.Unmarshal(data, &stat) != nil || stat.Name != "task" || stat.Mode.Perm() != 0750 || stat.Size != 3 || !stat.Mtime.Equal(stamp) {
		t.Fatalf("HEAD path stat: %s (%v)", data, err)
	}
	if head.Body.Len() != 0 {
		t.Fatal("HEAD returned a response body")
	}
	get := req(http.MethodGet, "/artifacts/.", nil)
	if get.Header().Get("Content-Type") != "application/x-tar" {
		t.Fatalf("GET Content-Type: %s", get.Header().Get("Content-Type"))
	}
	in := tar.NewReader(get.Body)
	found := map[string]tar.Header{}
	var content string
	for h, err := in.Next(); err != io.EOF; h, err = in.Next() {
		if err != nil {
			t.Fatal(err)
		}
		found[h.Name] = *h
		if h.Typeflag == tar.TypeReg {
			body, err := io.ReadAll(in)
			if err != nil {
				t.Fatal(err)
			}
			content = string(body)
		}
	}
	first, second := found["./bundle/task"], found["./bundle/task-copy"]
	if first.Typeflag == tar.TypeLink {
		first, second = second, first
	}
	if content != "CI\n" || first.Typeflag != tar.TypeReg || second.Typeflag != tar.TypeLink || second.Linkname != first.Name ||
		first.Uid != os.Geteuid() || first.Gid != os.Getegid() || first.Mode != 0750 || !first.ModTime.Equal(stamp) ||
		found["./alias"].Linkname != "bundle" || found["./bundle/"].Mode != 0751 {
		t.Fatalf("GET archive content %q and headers: %+v", content, found)
	}
}

func TestDockerArchivePinsRunningMount(t *testing.T) {
	workspace := t.TempDir()
	source := filepath.Join(workspace, "source")
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "job"), []byte("original"), 0600); err != nil {
		t.Fatal(err)
	}
	pin, err := openMount(workspace, source)
	if err != nil {
		t.Fatal(err)
	}
	defer pin.Close()
	if err := os.Rename(source, filepath.Join(workspace, "old")); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(source, 0700); err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: workspace}
	c := &dockerContainer{}
	c.Phase = "running"
	c.Config.HostConfig.Mounts = []dockerMount{{Type: "bind", Source: source, Target: "/work"}}
	c.archive = newDockerLiveArchive([]*os.File{pin}, []*cri.Mount{
		{HostPath: dockerMountFDPath(pin), ContainerPath: "/work"},
	})
	defer s.retireDockerArchive(c)
	view, release, err := s.openArchive(t.Context(), c, "/work/job", false)
	if err != nil {
		t.Fatal(err)
	}
	defer release()
	f, _, _, err := view.stat(dockerArchivePath{absolute: "/work/job", name: "job"})
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	read, err := archiveReadFD(f)
	if err != nil {
		t.Fatal(err)
	}
	defer read.Close()
	data, err := io.ReadAll(read)
	if err != nil || string(data) != "original" {
		t.Fatalf("pinned mount payload: %s (%v)", data, err)
	}
}

func TestDockerArchiveStopUnblocksSlowUpload(t *testing.T) {
	workspace := t.TempDir()
	root, err := openMount(workspace, workspace)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	const runtimeID = "archive-test-task"
	s := &dockerEngine{workspace: workspace}
	c := &dockerContainer{
		dockerRecord: dockerRecord{Phase: "running", RuntimeID: runtimeID},
		changed:      make(chan struct{}),
		archive: newDockerLiveArchive([]*os.File{root}, []*cri.Mount{
			{HostPath: dockerMountFDPath(root), ContainerPath: "/artifacts"},
		}),
	}
	c.Config.HostConfig.Mounts = []dockerMount{{Type: "bind", Source: workspace, Target: "/artifacts"}}
	s.node.runtime = restartTestRuntime{stop: func(_ context.Context, req *cri.StopContainerRequest) (*cri.StopContainerResponse, error) {
		if req.ContainerId != runtimeID {
			return nil, errors.New("stop targeted a different task")
		}
		go func() {
			s.retireDockerArchive(c)
			s.mu.Lock()
			c.Phase = "exited"
			c.RuntimeID = ""
			c.Exits++
			c.signal()
			s.mu.Unlock()
		}()
		return &cri.StopContainerResponse{}, nil
	}}
	admitted := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := dockerArchivePath{absolute: "/artifacts", name: "artifacts"}
		view, closeView, err := s.openArchive(r.Context(), c, p.absolute, true)
		if err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
			return
		}
		defer closeView()
		r.Body = &archiveObservedBody{ReadCloser: r.Body, reading: admitted}
		if err := serveArchiveView(w, r, view, p, false); err != nil {
			http.Error(w, err.Error(), http.StatusConflict)
		}
	}))
	defer server.Close()
	read, write := io.Pipe()
	defer read.Close()
	defer write.Close()
	req, err := http.NewRequestWithContext(t.Context(), http.MethodPut, server.URL, read)
	if err != nil {
		t.Fatal(err)
	}
	var prefix bytes.Buffer
	if err := tar.NewWriter(&prefix).WriteHeader(&tar.Header{Name: "artifact", Typeflag: tar.TypeReg, Size: 1024, Mode: 0600}); err != nil {
		t.Fatal(err)
	}
	prefix.WriteString("partial contents")
	go func() { _, _ = write.Write(prefix.Bytes()) }()
	workerDone := make(chan struct{})
	go func() {
		defer close(workerDone)
		res, err := server.Client().Do(req)
		if err == nil {
			res.Body.Close()
		}
	}()
	select {
	case <-admitted:
	case <-time.After(3 * time.Second):
		t.Fatal("upload never entered the archive reader")
	}
	stopCtx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	stop := httptest.NewRequestWithContext(stopCtx, http.MethodPost, "/stop?t=0", nil)
	response := httptest.NewRecorder()
	if err := s.containerLifecycle(response, stop, c, "stop"); err != nil || response.Code != http.StatusNoContent {
		t.Fatalf("slow upload blocked container stop: HTTP %d, %v", response.Code, err)
	}
	if _, err := os.Stat(filepath.Join(workspace, "artifact")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stopped upload published an incomplete artifact: %v", err)
	}
	_ = write.Close()
	<-workerDone
}

func TestDockerArchiveOfflineViewHoldsLifecycle(t *testing.T) {
	workspace := t.TempDir()
	s := &dockerEngine{workspace: workspace}
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "created"}}
	c.Config.HostConfig.Mounts = []dockerMount{{Type: "bind", Source: workspace, Target: "/artifacts"}}
	_, closeView, err := s.openArchive(t.Context(), c, "/artifacts", true)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Millisecond)
	defer cancel()
	unlock, err := s.lockContainerLifecycle(ctx, c)
	closeView()
	if unlock != nil {
		unlock()
	}
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("lifecycle entered before the offline archive closed: %v", err)
	}
	unlock, err = s.lockContainerLifecycle(t.Context(), c)
	if err != nil {
		t.Fatal(err)
	}
	unlock()
}

type archiveObservedBody struct {
	io.ReadCloser
	reading chan struct{}
}

func (b *archiveObservedBody) Read(p []byte) (int, error) {
	if b.reading != nil {
		close(b.reading)
		b.reading = nil
	}
	return b.ReadCloser.Read(p)
}

func TestDockerArchiveDetachedOverlay(t *testing.T) {
	dir := t.TempDir()
	for _, folder := range []string{"lower", "upper", "work"} {
		if err := os.Mkdir(filepath.Join(dir, folder), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(dir, "lower", "seed"), []byte("image"), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := mountArchiveSnapshot([]*mounttypes.Mount{{Type: "overlay", Source: "overlay", Options: []string{
		"lowerdir=" + filepath.Join(dir, "lower"),
		"upperdir=" + filepath.Join(dir, "upper"),
		"workdir=" + filepath.Join(dir, "work"),
		"index=off",
	}}}, false)
	if errors.Is(err, unix.EPERM) || errors.Is(err, unix.EACCES) {
		t.Skip("mount namespace lacks permission for an isolated overlay")
	}
	if err != nil {
		t.Fatal(err)
	}
	view := dockerArchiveView{root: root}
	f, _, _, err := view.stat(dockerArchivePath{absolute: "/seed", name: "seed"})
	if err != nil {
		root.Close()
		t.Fatal(err)
	}
	f.Close()
	fd, err := unix.Openat(int(root.Fd()), "owned", unix.O_CREAT|unix.O_WRONLY|unix.O_CLOEXEC, 0600)
	if err != nil {
		root.Close()
		t.Fatal(err)
	}
	_, err = unix.Write(fd, []byte("persisted"))
	unix.Close(fd)
	root.Close()
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join(dir, "upper", "owned"))
	if err != nil || strings.TrimSpace(string(b)) != "persisted" {
		t.Fatalf("detached snapshot did not commit the writable layer: %q %v", b, err)
	}
}
