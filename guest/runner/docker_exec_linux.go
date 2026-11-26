package main

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

type dockerExec struct {
	container *dockerContainer
	target    string
	cmd       []string
	env       []string
	workdir   string
	size      []uint16
	stdin     bool
	stdout    bool
	stderr    bool
	tty       bool

	// The engine mutex protects the mutable state below.
	started  bool
	running  bool
	ready    chan struct{}
	pid      uint32
	exit     int32
	failure  error
	finished time.Time
}

type dockerExecStart struct {
	Detach      bool
	Tty         *bool
	ConsoleSize []uint16
}

func (s *dockerEngine) createExec(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	b, err := readBody(w, r)
	if err != nil {
		return err
	}
	var v struct {
		Cmd                                     []string
		Env                                     []string
		WorkingDir                              string
		AttachStdin, AttachStdout, AttachStderr bool
		Tty                                     bool
		ConsoleSize                             []uint16
	}
	var options map[string]any
	if json.Unmarshal(b, &v) != nil || json.Unmarshal(b, &options) != nil || len(v.Cmd) == 0 || v.Cmd[0] == "" {
		return fail(400, "a valid exec command is required")
	}
	if err := supportedOptions(options, "Cmd Env WorkingDir AttachStdin AttachStdout AttachStderr Tty ConsoleSize"); err != nil {
		return fail(400, err.Error())
	}
	if err := validateDockerExecOverrides(v.Env, v.WorkingDir); err != nil {
		return err
	}
	if err := validateExecConsoleSize(v.Tty, v.ConsoleSize); err != nil {
		return err
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
	s.execs[id] = &dockerExec{
		container: c, target: c.RuntimeID, cmd: v.Cmd, env: v.Env, workdir: v.WorkingDir, size: v.ConsoleSize,
		stdin: v.AttachStdin, stdout: v.AttachStdout, stderr: v.AttachStderr, tty: v.Tty,
	}
	s.containerEvent(c, dockerExecEventAction("exec_create", v.Cmd), map[string]string{"execID": id})
	s.mu.Unlock()
	writeJSON(w, 201, map[string]string{"Id": id})
	return nil
}

func validateExecConsoleSize(tty bool, size []uint16) error {
	if size != nil && (!tty || len(size) != 2) {
		return fail(400, "exec console size requires a TTY and two dimensions")
	}
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
		v := map[string]any{
			"ID": id, "ContainerID": e.container.ID, "Running": e.running, "ExitCode": e.exit, "Pid": e.pid,
			"OpenStdin": e.stdin, "OpenStdout": e.stdout, "OpenStderr": e.stderr,
			"ProcessConfig": map[string]any{"entrypoint": e.cmd[0], "arguments": e.cmd[1:], "tty": e.tty},
		}
		s.mu.Unlock()
		writeJSON(w, 200, v)
		return nil
	}
	s.mu.Unlock()
	switch op + " " + r.Method {
	case "start POST":
		return s.startExec(w, r, id, e)
	case "resize POST":
		return s.resizeExec(r, id, e)
	default:
		return fail(501, "unsupported exec operation")
	}
}

func (s *dockerEngine) startExec(w http.ResponseWriter, r *http.Request, id string, e *dockerExec) error {
	b, err := readBody(w, r)
	if err != nil {
		return err
	}
	var opts dockerExecStart
	var raw map[string]any
	if json.Unmarshal(b, &opts) != nil || json.Unmarshal(b, &raw) != nil || raw == nil {
		return fail(400, "invalid exec start request")
	}
	if err := supportedOptions(raw, "Tty ConsoleSize Detach"); err != nil {
		return fail(400, err.Error())
	}
	if opts.Tty != nil && *opts.Tty != e.tty {
		return fail(400, "exec start TTY does not match exec create")
	}
	if err := validateExecConsoleSize(e.tty, opts.ConsoleSize); err != nil {
		return err
	}
	s.mu.Lock()
	if !s.execTargetRunning(id, e) || e.started {
		s.mu.Unlock()
		return fail(409, "exec is no longer startable")
	}
	e.started = true
	e.running = true
	if e.tty {
		e.ready = make(chan struct{})
	}
	s.mu.Unlock()

	if opts.Detach {
		return s.startNativeExec(r.Context(), id, e, opts, nil)
	}
	conn, rw, err := http.NewResponseController(w).Hijack()
	if err != nil {
		s.finishExec(id, e, 0, err, false)
		return err
	}
	defer conn.Close()
	_ = conn.SetReadDeadline(time.Time{})
	_ = conn.SetWriteDeadline(time.Now().Add(dockerExecWriteTimeout))
	contentType := "application/vnd.docker.multiplexed-stream"
	if e.tty || !strings.EqualFold(r.Header.Get("Upgrade"), "tcp") {
		contentType = "application/vnd.docker.raw-stream"
	}
	if strings.EqualFold(r.Header.Get("Upgrade"), "tcp") {
		_, err = io.WriteString(rw, "HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n")
	} else {
		_, err = io.WriteString(rw, "HTTP/1.1 200 OK\r\n")
	}
	if err == nil {
		_, err = io.WriteString(rw, "Content-Type: "+contentType+"\r\n\r\n")
	}
	if err == nil {
		err = rw.Flush()
	}
	if err == nil {
		if peer, ok := conn.(*net.UnixConn); ok && disconnected(peer) {
			err = io.ErrClosedPipe
		}
	}
	if err == nil {
		err = r.Context().Err()
	}
	if err != nil {
		s.finishExec(id, e, 0, err, false)
		return nil
	}

	stream := &dockerExecStream{conn: conn, input: rw.Reader, tty: e.tty, lost: make(chan struct{})}
	_ = s.startNativeExec(r.Context(), id, e, opts, stream)
	return nil
}

// Call with the engine mutex held. A restart assigns a new runtime ID.
func (s *dockerEngine) execTargetRunning(id string, e *dockerExec) bool {
	return s.execs[id] == e && e.container.Phase == "running" && e.container.RuntimeID == e.target
}

func (s *dockerEngine) noteExecStart(id string, e *dockerExec) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.execTargetRunning(id, e) {
		return fail(409, "exec is no longer startable")
	}
	s.containerEvent(e.container, dockerExecEventAction("exec_start", e.cmd), map[string]string{"execID": id})
	return nil
}

func (s *dockerEngine) resizeExec(r *http.Request, id string, e *dockerExec) error {
	q := r.URL.Query()
	h, hErr := strconv.ParseUint(q.Get("h"), 10, 16)
	w, wErr := strconv.ParseUint(q.Get("w"), 10, 16)
	if hErr != nil || wErr != nil {
		return fail(400, "invalid exec resize dimensions")
	}
	if !e.tty {
		return fail(400, "exec has no TTY")
	}
	ctx, cancel := context.WithTimeout(dockerExecContext(r.Context()), 10*time.Second)
	defer cancel()
	s.mu.Lock()
	ready := e.ready
	s.mu.Unlock()
	if ready != nil {
		select {
		case <-ready:
		case <-ctx.Done():
			return fail(409, "exec TTY is not ready")
		}
	}
	s.mu.Lock()
	running := e.running && e.pid != 0 && s.execTargetRunning(id, e)
	s.mu.Unlock()
	if !running {
		return fail(409, "exec is not running")
	}
	_, err := s.node.execTasks.ResizePty(ctx, &tasks.ResizePtyRequest{
		ContainerID: e.target, ExecID: id, Height: uint32(h), Width: uint32(w),
	})
	if status.Code(err) == codes.NotFound {
		return fail(409, "exec is not running")
	}
	return err
}

func dockerExecContext(ctx context.Context) context.Context {
	return metadata.AppendToOutgoingContext(ctx, "containerd-namespace", dockerRuntimeNamespace)
}

func (s *dockerEngine) recordExecStartFailure(id string, e *dockerExec, stream *dockerExecStream, err error) {
	var cwdErr dockerExecWorkdirError
	if errors.As(err, &cwdErr) {
		s.finishExec(id, e, cwdErr.exit, nil, false)
		if stream != nil {
			stream.write(1, []byte(cwdErr.message+"\n"))
		}
		return
	}
	// An execve rejection carries a CLI exit code but no runtime process exit.
	if code, text := dockerExecRejected(err); code != 0 {
		s.finishExec(id, e, code, nil, false)
		if stream != nil && (e.stderr || e.tty && e.stdout) {
			stream.write(2, []byte(text+"\n"))
		}
		return
	}
	s.finishExec(id, e, 0, err, false)
}

func dockerExecRejected(err error) (int32, string) {
	_, detail, ok := strings.Cut(status.Convert(err).Message(), dockerExecRuntimeErrorPrefix)
	if !ok {
		return 0, ""
	}
	if strings.HasPrefix(detail, "executable file ") {
		switch {
		case strings.Contains(detail, "not found: No such file or directory"),
			strings.Contains(detail, "not found in $PATH: No such file or directory"):
			return 127, detail
		case strings.Contains(detail, "Permission denied"):
			return 126, detail
		}
	}
	if strings.HasPrefix(detail, "the path ") &&
		(strings.Contains(detail, "exists but it is not executable: Operation not permitted") ||
			strings.Contains(detail, "is not a regular file: Operation not permitted")) {
		return 126, detail
	}
	return 0, ""
}

func (s *dockerEngine) finishExec(id string, e *dockerExec, code int32, err error, exitObserved bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	e.running = false
	e.failure = err
	e.finished = time.Now()
	if e.ready != nil {
		close(e.ready)
		e.ready = nil
	}
	if err == nil {
		e.exit = code
	}
	if exitObserved && s.execs[id] == e {
		s.containerEvent(e.container, "exec_die", map[string]string{
			"execID": id, "exitCode": strconv.Itoa(int(e.exit)),
		})
	}
}
