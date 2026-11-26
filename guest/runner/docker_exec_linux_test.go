package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func testDockerExecCreate(t *testing.T, s *dockerEngine) string {
	t.Helper()
	return testDockerExecCreateBody(t, s, `{"Cmd":["sh","-c","exit 23"],"AttachStdout":true,"AttachStderr":true}`)
}

func testDockerExecCreateBody(t *testing.T, s *dockerEngine, body string) string {
	t.Helper()
	c := &dockerContainer{dockerRecord: dockerRecord{
		ID: "docker-container", Name: "fixture-app-1", RuntimeID: "cri-container", Phase: "running",
		Config: dockerConfig{Image: "alpine:3.23", Env: []string{"MP_TEST_ENV=never-in-events"},
			Labels: map[string]string{"com.docker.compose.service": "app"}},
	}}
	r := httptest.NewRequest(http.MethodPost, "/containers/docker-container/exec",
		strings.NewReader(body))
	w := httptest.NewRecorder()
	if err := s.createExec(w, r, c); err != nil || w.Code != http.StatusCreated {
		t.Fatalf("exec create returned %d: %v", w.Code, err)
	}
	var created struct {
		ID string `json:"Id"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &created); err != nil || !fullContainerID.MatchString(created.ID) {
		t.Fatalf("invalid exec creation response %q: %v", w.Body.String(), err)
	}
	return created.ID
}

func assertDockerExecEvents(t *testing.T, s *dockerEngine, id string, started bool, exit string) {
	t.Helper()
	cursor, err := s.events.subscribe(true, false)
	if err != nil {
		t.Fatal(err)
	}
	defer s.events.unsubscribe()
	want := []string{"exec_create: sh -c exit 23"}
	if started {
		want = append(want, "exec_start: sh -c exit 23")
	}
	if exit != "" {
		want = append(want, "exec_die")
	}
	for _, action := range want {
		e, ok, _ := s.events.read(&cursor)
		if !ok || e.Action != action || e.Status != action || e.Type != "container" || e.Actor.ID != "docker-container" ||
			e.Actor.Attributes["execID"] != id || e.Actor.Attributes["com.docker.compose.service"] != "app" {
			t.Fatalf("event = %+v, want %q for exec %s", e, action, id)
		}
		code, hasCode := e.Actor.Attributes["exitCode"]
		if action == "exec_die" && (!hasCode || code != exit) || action != "exec_die" && hasCode {
			t.Fatalf("unexpected exit attribute for %q: %q", action, code)
		}
		b, err := json.Marshal(e)
		if err != nil || strings.Contains(string(b), "never-in-events") {
			t.Fatalf("exec event includes environment or invalid JSON: %v", err)
		}
	}
	if additional, ok, _ := s.events.read(&cursor); ok {
		t.Fatalf("unexpected event %q", additional.Action)
	}
}

func TestDockerExecEventBeforeUpgradeFailure(t *testing.T) {
	s := &dockerEngine{execs: make(map[string]*dockerExec)}
	id := testDockerExecCreate(t, s)
	r := httptest.NewRequest(http.MethodPost, "/exec/"+id+"/start", strings.NewReader("{}"))
	if err := s.exec(httptest.NewRecorder(), r, id+"/start"); !errors.Is(err, http.ErrNotSupported) {
		t.Fatalf("non-upgradable exec returned %v", err)
	}
	assertDockerExecEvents(t, s, id, false, "")
}
