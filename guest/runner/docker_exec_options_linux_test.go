package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"testing"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

func TestDockerExecEnvOverlay(t *testing.T) {
	inherited := []string{"KEEP=base", "REPLACE=base", "UNSET=base", "RESTORE=base", "EMPTY=base"}
	overrides := []string{"REPLACE=first", "REPLACE=last", "UNSET=changed", "UNSET", "RESTORE", "RESTORE=back",
		"EMPTY=", "UNKNOWN", "NEW=first", "NEW=last=with-equals", "NEW", "FROM_CLI=local value"}
	want := []string{"KEEP=base", "REPLACE=last", "RESTORE=back", "EMPTY=", "NEW=last=with-equals", "FROM_CLI=local value"}
	if got := overlayDockerExecEnv(inherited, overrides); !slices.Equal(got, want) {
		t.Fatalf("environment = %q, want %q", got, want)
	}
	if !slices.Equal(inherited, []string{"KEEP=base", "REPLACE=base", "UNSET=base", "RESTORE=base", "EMPTY=base"}) {
		t.Fatalf("container environment was modified: %q", inherited)
	}
}

func TestDockerExecProcessOverrides(t *testing.T) {
	for _, tc := range []struct {
		name, body, cwd string
		env             []string
	}{
		{"no override", `{"Cmd":["pwd"]}`, "/fixture", []string{"PERSIST=1"}},
		{"workdir and env", `{"Cmd":["pwd"],"WorkingDir":"/tmp/work dir","Env":["PERSIST=private"]}`, "/tmp/work dir", []string{"PERSIST=private"}},
		{"all unset", `{"Cmd":["pwd"],"Env":["PERSIST"]}`, "/fixture", []string{"PERSIST"}},
		{"tty TERM unset", `{"Cmd":["pwd"],"Tty":true,"Env":["TERM"]}`, "/fixture", []string{"PERSIST=1"}},
		{"tty TERM empty", `{"Cmd":["pwd"],"Tty":true,"Env":["TERM="]}`, "/fixture", []string{"PERSIST=1", "TERM="}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, _ := testNativeExecEngine(t)
			id := testDockerExecCreateBody(t, s, tc.body)
			spec, err := s.dockerExecProcessSpec(t.Context(), s.execs[id], nil)
			if err != nil {
				t.Fatal(err)
			}
			var process struct {
				Cwd             string
				Env             []string
				User            struct{ UID, GID int }
				NoNewPrivileges bool
			}
			if err := json.Unmarshal(spec.Value, &process); err != nil {
				t.Fatal(err)
			}
			if process.Cwd != tc.cwd || !slices.Equal(process.Env, tc.env) || process.User.UID != 1000 || process.User.GID != 4 || !process.NoNewPrivileges {
				t.Fatalf("unexpected OCI process spec %s", spec.Value)
			}
			inspect := httptest.NewRecorder()
			if err := s.exec(inspect, httptest.NewRequest(http.MethodGet, "/exec/"+id+"/json", nil), id+"/json"); err != nil {
				t.Fatal(err)
			}
			if strings.Contains(inspect.Body.String(), "private") || strings.Contains(inspect.Body.String(), "/tmp/work dir") {
				t.Fatalf("exec inspect contains process overrides: %s", inspect.Body)
			}
		})
	}
}

func TestDockerExecRejectsMalformedOverrides(t *testing.T) {
	for _, body := range []string{
		`{"Cmd":["pwd"],"Env":["=secret"]}`,
		`{"Cmd":["pwd"],"Env":["NAME=\u0000"]}`,
		`{"Cmd":["pwd"],"Env":[null]}`,
		`{"Cmd":["pwd"],"WorkingDir":"/dir\u0000"}`,
	} {
		s := &dockerEngine{execs: make(map[string]*dockerExec)}
		r := httptest.NewRequest(http.MethodPost, "/containers/container/exec", strings.NewReader(body))
		var apiErr apiError
		err := s.createExec(httptest.NewRecorder(), r, &dockerContainer{})
		if !errors.As(err, &apiErr) || apiErr.code != http.StatusBadRequest || strings.Contains(err.Error(), "secret") {
			t.Fatalf("exec validation for malformed metadata returned %v", err)
		}
		if len(s.execs) != 0 {
			t.Fatal("malformed metadata created an exec record")
		}
	}
}

func TestDockerExecWorkdirRejection(t *testing.T) {
	for _, tc := range []struct {
		name, dir, detail string
		runtimeErr        error
		code              int32
	}{
		{name: "relative", dir: "relative", detail: "Cwd must be an absolute path", code: 128},
		{name: "missing", dir: "/missing", detail: "No such file or directory", code: 127,
			runtimeErr: status.Error(codes.Unknown, "OCI runtime exec failed: chdir to `/missing`: No such file or directory: unknown")},
		{name: "file", dir: "/file", detail: "not a directory", code: 127,
			runtimeErr: status.Error(codes.Unknown, `OCI runtime exec failed: exec failed: unable to start container process: chdir to cwd ("/file") set in config.json failed: not a directory`)},
		{name: "denied", dir: "/denied", detail: "Permission denied", code: 126,
			runtimeErr: status.Error(codes.Unknown, "OCI runtime exec failed: chdir to `/denied`: Permission denied: unknown")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, runtime := testNativeExecEngine(t)
			runtime.start = func(*tasks.ExecProcessRequest) error { return tc.runtimeErr }
			body, err := json.Marshal(map[string]any{"Cmd": []string{"pwd"}, "WorkingDir": tc.dir, "AttachStdout": true, "AttachStderr": true})
			if err != nil {
				t.Fatal(err)
			}
			id := testDockerExecCreateBody(t, s, string(body))
			_, reader, _, done := testNativeExecStart(t, s, id, "{}", "")
			channel, text := readExecTestFrame(t, reader)
			if channel != 1 || !strings.Contains(text, tc.detail) {
				t.Fatalf("workdir rejection frame = %d %q", channel, text)
			}
			testExecHandlerDone(t, done)
			running, code, _ := testExecInspect(t, s, id)
			if running || code != tc.code || (runtime.request != nil) != (tc.runtimeErr != nil) {
				t.Fatalf("workdir rejection running=%t, exit=%d, runtime called=%t", running, code, runtime.request != nil)
			}
		})
	}
}
