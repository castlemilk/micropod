package main

import (
	"archive/tar"
	"bytes"
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// docker cp through a bind that covers the machine's own directory never
// reaches it: the container sees an empty read-only directory there
// (docker_private_linux.go), and its archive view, running or stopped, sees
// nothing at all, whatever path or link leads in.
func TestArchiveNeverReachesTheMachineDirectory(t *testing.T) {
	ws := t.TempDir()
	machine := filepath.Join(ws, ".micropod", "hvf")
	policy := filepath.Join(machine, "run", "guest-config", "cache-policy.json")
	if err := os.MkdirAll(filepath.Dir(policy), 0755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{policy: `{"defaultTrust":"untrusted"}`, filepath.Join(machine, "machine.json"): `{"secret":1}`} {
		if err := os.WriteFile(name, []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(ws, "src"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "src", "keep.txt"), []byte("ok"), 0644); err != nil {
		t.Fatal(err)
	}
	// Relative, so it stays beneath the bind: the archive view follows it.
	if err := os.Symlink("../.micropod/hvf", filepath.Join(ws, "src", "up")); err != nil {
		t.Fatal(err)
	}
	r, err := loadPrivateRoot(machine, filepath.Join(t.TempDir(), "private-mask"))
	if err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: ws, machineDir: r}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Phase: "created",
		Config: dockerConfig{Image: "alpine", HostConfig: dockerHost{Binds: []string{ws + ":/h", ws + "/.micropod:/m:ro"}}}}, changed: make(chan struct{})}

	tarOf := func(name, body string) *bytes.Buffer {
		var b bytes.Buffer
		w := tar.NewWriter(&b)
		if err := w.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeReg, Mode: 0644, Size: int64(len(body))}); err != nil {
			t.Fatal(err)
		}
		io.WriteString(w, body)
		w.Close()
		return &b
	}
	do := func(method, raw string, body io.Reader) (*httptest.ResponseRecorder, error) {
		t.Helper()
		p, err := parseArchivePath(raw)
		if err != nil {
			t.Fatal(err)
		}
		view, closeView, err := s.pinArchive(context.Background(), c, p.absolute, method == http.MethodPut)
		if err != nil {
			return nil, err
		}
		defer closeView()
		rec := httptest.NewRecorder()
		return rec, serveArchiveView(rec, httptest.NewRequest(method, "/", body), view, p, false)
	}
	refused := func(method, raw string, body io.Reader) {
		t.Helper()
		_, err := do(method, raw, body)
		var api apiError
		if !errors.As(err, &api) || api.code != http.StatusForbidden && api.code != http.StatusBadRequest {
			t.Errorf("%s %s reached the machine directory (%v)", method, raw, err)
		}
	}
	names := func(raw string) []string {
		t.Helper()
		rec, err := do(http.MethodGet, raw, nil)
		if err != nil {
			t.Fatalf("GET %s: %v", raw, err)
		}
		var out []string
		in := tar.NewReader(rec.Body)
		for h, err := in.Next(); err != io.EOF; h, err = in.Next() {
			if err != nil {
				t.Fatal(err)
			}
			out = append(out, h.Name)
		}
		return out
	}
	unchanged := func() {
		t.Helper()
		if b, err := os.ReadFile(policy); err != nil || string(b) != `{"defaultTrust":"untrusted"}` {
			t.Fatalf("the machine's cache policy was rewritten: %q %v", b, err)
		}
	}
	check := func(phase string) {
		for _, raw := range []string{"/h/.micropod/hvf/machine.json", "/h/.micropod/hvf", "/h/.micropod/hvf/run/", "/h/src/up/machine.json", "/m/hvf/machine.json"} {
			refused(http.MethodGet, raw, nil)
			refused(http.MethodHead, raw, nil)
		}
		refused(http.MethodPut, "/h/.micropod/hvf/run/guest-config", tarOf("cache-policy.json", `{}`))
		refused(http.MethodPut, "/h/src/up/run/guest-config", tarOf("cache-policy.json", `{}`))
		refused(http.MethodPut, "/h", tarOf(".micropod/hvf/run/guest-config/cache-policy.json", `{}`))
		unchanged()
		for _, raw := range []string{"/h/.micropod", "/m"} {
			for _, name := range names(raw) {
				if strings.Contains(name, "hvf") {
					t.Errorf("%s (%s): the archive of %s holds %s", phase, raw, raw, name)
				}
			}
		}
		if got := names("/h/src/keep.txt"); len(got) != 1 {
			t.Errorf("%s: the rest of the bind is unreadable: %v", phase, got)
		}
		if _, err := do(http.MethodPut, "/h/src", tarOf("new.txt", "x")); err != nil {
			t.Errorf("%s: the rest of the bind is unwritable: %v", phase, err)
		}
	}
	check("stopped")

	// Running: the view is the descriptors the start opened.
	files, mounts, _, err := s.openMounts(c.Config, cacheVolumeRules{}, false, "", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer closeMounts(files)
	c.Phase, c.archive = "running", newDockerLiveArchive(files, mounts)
	check("running")

	// The view decides by identity, not by the mask's spelling: one that has
	// no mask entry (a case-folded or renamed path matches none) still never
	// opens or walks into the directory.
	root, err := os.Open(ws)
	if err != nil {
		t.Fatal(err)
	}
	defer root.Close()
	view := dockerArchiveView{root: root, mount: "/h", configured: []dockerMount{{Target: "/h"}}, machine: r}
	serve := func(method, raw string, body io.Reader) (*httptest.ResponseRecorder, error) {
		p, _ := parseArchivePath(raw)
		rec := httptest.NewRecorder()
		return rec, serveArchiveView(rec, httptest.NewRequest(method, "/", body), view, p, false)
	}
	for _, raw := range []string{"/h/.micropod/hvf/machine.json", "/h/.micropod/hvf", "/h/src/up/machine.json"} {
		if _, err := serve(http.MethodGet, raw, nil); err == nil {
			t.Errorf("GET %s by identity: read the machine directory", raw)
		}
	}
	if _, err := serve(http.MethodPut, "/h", tarOf(".micropod/hvf/run/guest-config/cache-policy.json", `{}`)); err == nil {
		t.Error("PUT through the machine directory by identity was written")
	}
	unchanged()
	rec, err := serve(http.MethodGet, "/h/.micropod", nil)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(rec.Body.String(), "machine.json") || strings.Contains(rec.Body.String(), "guest-config") {
		t.Error("the archive of the directory above held the machine directory's files")
	}
}

// docker cp out of a running container's file bind copies the file the
// container sees, the one its start opened, after the host replaced the
// file at that path (an editor's save, sed -i, git checkout) or unlinked it;
// a bind of a file inside the machine's directory is still refused, at its
// start, with the error that says so.
func TestArchiveOfAReplacedFileBindIsTheContainersFile(t *testing.T) {
	ws := t.TempDir()
	machine := filepath.Join(ws, ".micropod", "hvf")
	if err := os.MkdirAll(machine, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(machine, "machine.json"), []byte(`{"secret":1}`), 0644); err != nil {
		t.Fatal(err)
	}
	conf := filepath.Join(ws, "app.conf")
	if err := os.WriteFile(conf, []byte("as started"), 0644); err != nil {
		t.Fatal(err)
	}
	r, err := loadPrivateRoot(machine, filepath.Join(t.TempDir(), "private-mask"))
	if err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: ws, machineDir: r}
	c := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("a", 64), Phase: "created",
		Config: dockerConfig{Image: "nginx", HostConfig: dockerHost{Binds: []string{conf + ":/etc/app.conf"}}}}, changed: make(chan struct{})}
	files, mounts, _, err := s.openMounts(c.Config, cacheVolumeRules{}, false, "", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	defer closeMounts(files)
	c.Phase, c.archive = "running", newDockerLiveArchive(files, mounts)
	read := func() (string, error) {
		t.Helper()
		p, _ := parseArchivePath("/etc/app.conf")
		view, closeView, err := s.pinArchive(context.Background(), c, p.absolute, false)
		if err != nil {
			return "", err
		}
		defer closeView()
		rec := httptest.NewRecorder()
		if err := serveArchiveView(rec, httptest.NewRequest(http.MethodGet, "/", nil), view, p, false); err != nil {
			return "", err
		}
		in := tar.NewReader(rec.Body)
		if _, err := in.Next(); err != nil {
			return "", err
		}
		b, err := io.ReadAll(in)
		return string(b), err
	}
	// Saved the way editors do: a new file renamed over the old one.
	if err := os.WriteFile(conf+".new", []byte("saved later"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(conf+".new", conf); err != nil {
		t.Fatal(err)
	}
	if got, err := read(); err != nil || got != "as started" {
		t.Fatalf("docker cp of the replaced file bind: %q, %v; want the container's file", got, err)
	}
	if err := os.Remove(conf); err != nil {
		t.Fatal(err)
	}
	if got, err := read(); err != nil || got != "as started" {
		t.Fatalf("docker cp of the unlinked file bind: %q, %v; want the container's file", got, err)
	}

	// A file inside the machine's directory is refused at the start.
	inside := dockerConfig{Image: "nginx", HostConfig: dockerHost{Binds: []string{filepath.Join(machine, "machine.json") + ":/m.json:ro"}}}
	if files, _, _, err := s.openMounts(inside, cacheVolumeRules{}, false, "", t.TempDir()); err == nil {
		closeMounts(files)
		t.Fatal("a start bound a file inside the machine's directory")
	} else if !strings.Contains(err.Error(), "machine's own directory") {
		t.Fatalf("a start bound a file inside the machine's directory: %v", err)
	}
	// And a stopped container's copy of one names why.
	stopped := &dockerContainer{dockerRecord: dockerRecord{ID: strings.Repeat("b", 64), Phase: "created", Config: inside}, changed: make(chan struct{})}
	_, _, err = s.pinArchive(context.Background(), stopped, "/m.json", false)
	var api apiError
	if !errors.As(err, &api) || api.code != http.StatusForbidden || !strings.Contains(api.message, "machine's own directory") {
		t.Fatalf("docker cp of a file inside the machine's directory: %v, want 403", err)
	}
}
