package main

import (
	"encoding/binary"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"time"

	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type dockerExec struct {
	container                        *dockerContainer
	target                           string
	cmd                              []string
	stdout, stderr, started, running bool
	exit                             int32
	failure                          error
	finished                         time.Time
}

func (s *dockerEngine) createExec(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	b, err := readBody(w, r)
	if err != nil {
		return err
	}
	var v struct {
		Cmd                        []string
		AttachStdout, AttachStderr bool
	}
	var options map[string]any
	if json.Unmarshal(b, &v) != nil || json.Unmarshal(b, &options) != nil || len(v.Cmd) == 0 {
		return fail(400, "an exec command is required")
	}
	if err := supportedOptions(options, "Cmd AttachStdout AttachStderr"); err != nil {
		return fail(400, err.Error())
	}
	s.mu.Lock()
	if c.Phase != "running" {
		s.mu.Unlock()
		return fail(409, "container is not running")
	}
	if len(s.execs) >= 4096 {
		expired := time.Now().Add(-5 * time.Minute)
		for id, old := range s.execs {
			if !old.finished.IsZero() && old.finished.Before(expired) {
				delete(s.execs, id)
			}
		}
	}
	if len(s.execs) >= 4096 {
		s.mu.Unlock()
		return fail(409, "exec record limit reached")
	}
	id := engineID()
	s.execs[id] = &dockerExec{container: c, target: c.RuntimeID, cmd: v.Cmd, stdout: v.AttachStdout, stderr: v.AttachStderr}
	s.mu.Unlock()
	writeJSON(w, 201, map[string]string{"Id": id})
	return nil
}
func (s *dockerEngine) exec(w http.ResponseWriter, r *http.Request, path string) error {
	id, op, _ := strings.Cut(path, "/")
	s.mu.Lock()
	e := s.execs[id]
	if e == nil {
		s.mu.Unlock()
		return fail(404, "no such exec")
	}
	if op == "json" && r.Method == "GET" {
		if e.failure != nil {
			err := e.failure
			s.mu.Unlock()
			return err
		}
		v := map[string]any{"ID": id, "ContainerID": e.container.ID, "Running": e.running, "ExitCode": e.exit, "ProcessConfig": map[string]any{"entrypoint": e.cmd[0], "arguments": e.cmd[1:], "tty": false}}
		s.mu.Unlock()
		writeJSON(w, 200, v)
		return nil
	}
	s.mu.Unlock()
	if op != "start" || r.Method != "POST" {
		return fail(501, "unsupported exec operation")
	}
	b, err := readBody(w, r)
	if err != nil {
		return err
	}
	var opts map[string]any
	if json.Unmarshal(b, &opts) != nil {
		return fail(400, "invalid exec start request")
	}
	if err := supportedOptions(opts, ""); err != nil {
		return fail(400, err.Error())
	}
	s.mu.Lock()
	if e.container.Phase != "running" || e.target != e.container.RuntimeID || e.started {
		s.mu.Unlock()
		return fail(409, "exec is no longer startable")
	}
	e.started = true
	e.running = true
	s.mu.Unlock()
	conn, rw, err := w.(http.Hijacker).Hijack()
	if err != nil {
		s.mu.Lock()
		e.running = false
		e.failure = err
		e.finished = time.Now()
		s.mu.Unlock()
		return err
	}
	defer conn.Close()
	_, err = io.WriteString(rw, "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\n\r\n")
	if err == nil {
		err = rw.Flush()
	}
	var result *cri.ExecSyncResponse
	if err == nil {
		result, err = s.node.runtime.ExecSync(r.Context(), &cri.ExecSyncRequest{ContainerId: e.target, Cmd: e.cmd})
		if err != nil {
			// CRI wraps an OCI execve failure as a gRPC error. Docker exposes
			// missing and non-executable programs as process exits to SDK clients.
			_, detail, ok := strings.Cut(status.Convert(err).Message(), "OCI runtime exec failed: ")
			if ok && strings.HasPrefix(detail, "executable file ") {
				var code int32
				switch {
				case strings.Contains(detail, "not found: No such file or directory"):
					code = 127
				case strings.Contains(detail, "Permission denied"):
					code = 126
				}
				if code != 0 {
					result = &cri.ExecSyncResponse{ExitCode: code, Stderr: []byte(detail + "\n")}
					err = nil
				}
			}
		}
	}
	if err == nil {
		for i, b := range [][]byte{result.Stdout, result.Stderr} {
			if len(b) == 0 || i == 0 && !e.stdout || i == 1 && !e.stderr {
				continue
			}
			var h [8]byte
			h[0] = byte(i + 1)
			binary.BigEndian.PutUint32(h[4:], uint32(len(b)))
			_, _ = rw.Write(h[:])
			_, _ = rw.Write(b)
		}
		_ = rw.Flush()
	}
	s.mu.Lock()
	e.running = false
	e.failure = err
	e.finished = time.Now()
	if err == nil {
		e.exit = result.ExitCode
	}
	s.mu.Unlock()
	return nil
}
