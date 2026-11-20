package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDockerOptionsAndMounts(t *testing.T) {
	for _, raw := range []string{`{"label":{"cuttle.test=x":true}}`, `{"label":["cuttle.test=x"]}`} {
		filters, err := dockerFilters(raw, "label")
		if err != nil || len(filters["label"]) != 1 || filters["label"][0] != "cuttle.test=x" {
			t.Fatalf("failed to decode %s: %v %v", raw, filters, err)
		}
	}
	const ordinary = `{"Image":"alpine","HostConfig":{"RestartPolicy":{"Name":"no","MaximumRetryCount":0},"ConsoleSize":[0,0],"PidsLimit":0,"MemorySwappiness":-1,"Mounts":[{"Type":"volume","Source":"cache","Target":"/cache","VolumeOptions":{"NoCopy":true}}]},"NetworkingConfig":{"EndpointsConfig":{"default":{"Aliases":null}}}}`
	spec, err := parseDockerConfig([]byte(ordinary))
	if err != nil {
		t.Fatal(err)
	}
	mounts, err := spec.mounts()
	if err != nil || len(mounts) != 1 || mounts[0].Source != "cache" {
		t.Fatalf("mounts %v %v", mounts, err)
	}
	for _, v := range []string{`{"Image":"a","HostConfig":{"Privileged":true}}`, `{"Image":"a","HostConfig":{"RestartPolicy":{"Name":"always"}}}`, `{"Image":"a","NetworkingConfig":{"EndpointsConfig":{"other":{}}}}`, `{"Image":"a","OpenStdin":true}`, `{"Image":"a","HostConfig":{"NetworkMode":"none","PortBindings":{"80/tcp":[{}]}}}`} {
		if _, err := parseDockerConfig([]byte(v)); err == nil {
			t.Fatalf("accepted unsupported configuration %s", v)
		}
	}
	for _, kind := range []string{"gomod", "gobuild", "npm"} {
		p, ok := sharedCachePath("micropod-ci-scoped-go-1-26-" + kind)
		if !ok || p != filepath.Join(dataRoot, "scopes", "go-1-26", kind) {
			t.Fatal(p, ok)
		}
	}
	if _, ok := sharedCachePath("ordinary-gobuild"); ok {
		t.Fatal("adopted a non-scoped volume")
	}
}
func TestBoundWorkspaceUsesOpenedInode(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "marker")
	os.WriteFile(p, []byte("first"), 0600)
	f, err := openMount(dir, p)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	before, err := f.Stat()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(p, p+"-old"); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(p, []byte("second"), 0600)
	now, err := os.Stat(p)
	if err != nil || os.SameFile(before, now) {
		t.Fatal("fixture did not replace inode")
	}
	st, err := f.Stat()
	if err != nil || !os.SameFile(before, st) {
		t.Fatal("opened mount changed")
	}
	if _, err := openMount(dir, filepath.Dir(dir)); err == nil {
		t.Fatal("accepted parent directory")
	}
}
func TestCRILogSplitAcrossReads(t *testing.T) {
	var source bytes.Buffer
	s := criOutput{reader: bufio.NewReader(&source)}
	var out, stderr bytes.Buffer
	write := func(stream string, b []byte) error {
		if stream == "stdout" {
			_, _ = out.Write(b)
		} else {
			_, _ = stderr.Write(b)
		}
		return nil
	}
	source.WriteString("time stdout P ab")
	if err := s.drain(write); err != nil || out.Len() != 0 {
		t.Fatal(err, out.String())
	}
	source.WriteString("c\ntime stderr F complete\ntime stdout P z\n")
	if err := s.drain(write); err != nil {
		t.Fatal(err)
	}
	if out.String() != "abcz" || stderr.String() != "complete\n" {
		t.Fatal(out.String(), stderr.String())
	}
}
func TestFramesAndMetrics(t *testing.T) {
	frame := []byte{1, 0, 0, 0, 0, 0, 0, 2, 'o', 'k', 2, 0, 0, 0, 0, 0, 0, 1, 'e'}
	var b bytes.Buffer
	if err := copyFrames(bufio.NewReader(bytes.NewReader(frame)), &b, false, true); err != nil || !bytes.Equal(b.Bytes(), frame[10:]) {
		t.Fatal(err, b.Bytes())
	}
	if err := copyFrames(bufio.NewReader(strings.NewReader("")), io.Discard, true, true); err != nil {
		t.Fatal(err)
	}
	m := dockerMetrics{}
	m.record(result{Prepared: true, Hit: true, StartMS: 7}, nil)
	got, _ := json.Marshal(m.snapshot())
	if !strings.Contains(string(got), `"start_ms_total":7`) {
		t.Fatal(string(got))
	}
}

func TestSessionCleanupOwnership(t *testing.T) {
	const session = "qualification-session-001"
	self := strings.Repeat("1", 64)
	other := strings.Repeat("2", 64)
	own := strings.Repeat("3", 64)
	makeContainer := func(id, scope string) *dockerContainer {
		return &dockerContainer{dockerRecord: dockerRecord{ID: id, Name: "job-" + id[:4], Phase: "running", Config: dockerConfig{Labels: map[string]string{tcSession: scope, tcReap: "true"}}}}
	}
	s := &dockerEngine{containers: map[string]*dockerContainer{other: makeContainer(other, "another-session"), own: makeContainer(own, session)}}
	api := cleanupAPI{s, session, self}
	for _, tc := range []struct {
		method, path string
		code         int
	}{
		{"GET", "/v1.47/containers/json", 200}, {"DELETE", "/containers/" + other, 404}, {"POST", "/containers/create", 403}, {"GET", "/v1.47/containers/" + other + "/json", 403},
	} {
		w := httptest.NewRecorder()
		api.ServeHTTP(w, httptest.NewRequest(tc.method, tc.path, nil))
		if w.Code != tc.code || strings.Contains(w.Body.String(), other) {
			t.Fatalf("unexpected %s %s status %d: %s", tc.method, tc.path, w.Code, w.Body.String())
		}
		if tc.code == 200 && !strings.Contains(w.Body.String(), own) {
			t.Fatal("missing owned container")
		}
	}
}
