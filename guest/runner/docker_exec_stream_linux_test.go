package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	containers "github.com/containerd/containerd/api/services/containers/v1"
	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/anypb"
	"google.golang.org/protobuf/types/known/emptypb"
)

type execSpecFixture struct {
	containers.ContainersClient
}

func (execSpecFixture) Get(_ context.Context, req *containers.GetContainerRequest, _ ...grpc.CallOption) (*containers.GetContainerResponse, error) {
	return &containers.GetContainerResponse{Container: &containers.Container{ID: req.GetID(), Spec: &anypb.Any{
		TypeUrl: dockerExecSpecType,
		Value:   []byte(`{"process":{"args":["old"],"env":["PERSIST=1"],"user":{"uid":1000,"gid":4},"cwd":"/fixture","noNewPrivileges":true,"commandLine":"old"}}`),
	}}}, nil
}

type nativeExecFixture struct {
	tasks.TasksClient
	t           *testing.T
	request     *tasks.ExecProcessRequest
	execErr     error
	waitErr     error
	killErr     error
	deleteErr   error
	start       func(*tasks.ExecProcessRequest) error
	omitExit    bool
	runtimeIn   *os.File
	exited      chan struct{}
	exitCode    uint32
	exitOnce    sync.Once
	resized     chan *tasks.ResizePtyRequest
	stdinClosed chan struct{}
	deleted     chan struct{}
	killed      chan uint32
}

func testNativeExecEngine(t *testing.T) (*dockerEngine, *nativeExecFixture) {
	t.Helper()
	f := &nativeExecFixture{
		t: t, exited: make(chan struct{}), resized: make(chan *tasks.ResizePtyRequest, 1),
		stdinClosed: make(chan struct{}, 1), deleted: make(chan struct{}, 1), killed: make(chan uint32, 1),
	}
	s := &dockerEngine{
		node: node{containers: execSpecFixture{}, execTasks: f}, execPipeDir: t.TempDir(),
		execs: make(map[string]*dockerExec),
	}
	return s, f
}

func (f *nativeExecFixture) Exec(ctx context.Context, req *tasks.ExecProcessRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	md, _ := metadata.FromOutgoingContext(ctx)
	if !slices.Equal(md.Get("containerd-namespace"), []string{dockerRuntimeNamespace}) || req.GetContainerID() != "cri-container" ||
		!fullContainerID.MatchString(req.GetExecID()) || req.GetSpec().GetTypeUrl() != dockerExecProcessType {
		f.t.Errorf("unexpected namespaced Exec request %v", req)
	}
	f.request = req
	return &emptypb.Empty{}, f.execErr
}

func (f *nativeExecFixture) Start(_ context.Context, req *tasks.StartRequest, _ ...grpc.CallOption) (*tasks.StartResponse, error) {
	if f.request.GetExecID() != req.GetExecID() {
		f.t.Errorf("Start ID %q does not match Exec %q", req.GetExecID(), f.request.GetExecID())
	}
	if f.start != nil {
		if err := f.start(f.request); err != nil {
			return nil, err
		}
	}
	return &tasks.StartResponse{Pid: 123}, nil
}

func (f *nativeExecFixture) Wait(ctx context.Context, req *tasks.WaitRequest, _ ...grpc.CallOption) (*tasks.WaitResponse, error) {
	if f.request.GetExecID() != req.GetExecID() {
		f.t.Errorf("Wait ID %q does not match Exec %q", req.GetExecID(), f.request.GetExecID())
	}
	select {
	case <-f.exited:
		if f.omitExit {
			return nil, nil
		}
		if f.waitErr != nil {
			return nil, f.waitErr
		}
		return &tasks.WaitResponse{ExitStatus: f.exitCode}, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (f *nativeExecFixture) ResizePty(_ context.Context, req *tasks.ResizePtyRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.resized <- req
	return &emptypb.Empty{}, nil
}

func (f *nativeExecFixture) CloseIO(_ context.Context, req *tasks.CloseIORequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	if !req.GetStdin() || req.GetExecID() != f.request.GetExecID() {
		f.t.Errorf("unexpected input close %v", req)
	}
	if f.runtimeIn != nil {
		_ = f.runtimeIn.Close()
	}
	f.stdinClosed <- struct{}{}
	return &emptypb.Empty{}, nil
}

func (f *nativeExecFixture) Kill(_ context.Context, req *tasks.KillRequest, _ ...grpc.CallOption) (*emptypb.Empty, error) {
	f.killed <- req.GetSignal()
	if f.killErr != nil {
		return nil, f.killErr
	}
	f.exit(137)
	return &emptypb.Empty{}, nil
}

func (f *nativeExecFixture) DeleteProcess(_ context.Context, req *tasks.DeleteProcessRequest, _ ...grpc.CallOption) (*tasks.DeleteResponse, error) {
	if req.GetExecID() != f.request.GetExecID() {
		f.t.Errorf("unexpected exec deletion %v", req)
	}
	f.deleted <- struct{}{}
	return &tasks.DeleteResponse{}, f.deleteErr
}

func (f *nativeExecFixture) exit(code uint32) {
	f.exitOnce.Do(func() {
		f.exitCode = code
		close(f.exited)
	})
}

func (f *nativeExecFixture) openPipe(path string, flags int) (*os.File, error) {
	file, err := os.OpenFile(path, flags|unix.O_NONBLOCK, 0)
	if err == nil {
		f.t.Cleanup(func() { _ = file.Close() })
	}
	return file, err
}

func (f *nativeExecFixture) openInput(path string) (*os.File, error) {
	reader, err := f.openPipe(path, os.O_RDONLY)
	if err != nil {
		return nil, err
	}
	// The real containerd shim keeps this extra writer open until CloseIO.
	f.runtimeIn, err = f.openPipe(path, os.O_WRONLY)
	return reader, err
}

func testNativeExecStart(t *testing.T, s *dockerEngine, id, body, bufferedInput string) (*net.UnixConn, *bufio.Reader, *http.Response, <-chan error) {
	t.Helper()
	done := make(chan error, 1)
	server := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		done <- s.exec(w, r, id+"/start")
	}))
	server.Listener.Close()
	name := &net.UnixAddr{Name: "@micropod-exec-" + id[:16], Net: "unix"}
	listener, err := net.ListenUnix("unix", name)
	if err != nil {
		t.Fatal(err)
	}
	server.Listener = listener
	server.Start()
	t.Cleanup(server.Close)
	client, err := net.DialUnix("unix", nil, name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = client.Close() })
	if err := client.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		t.Fatal(err)
	}
	if _, err := fmt.Fprintf(client, "POST /exec/%s/start HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n%s%s",
		id, len(body), body, bufferedInput); err != nil {
		t.Fatal(err)
	}
	reader := bufio.NewReader(client)
	response, err := http.ReadResponse(reader, nil)
	if err != nil || response.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("exec upgrade response = %v, %v", response, err)
	}
	return client, reader, response, done
}

func readExecTestFrame(t *testing.T, reader io.Reader) (byte, string) {
	t.Helper()
	var header [8]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		t.Fatal(err)
	}
	size := binary.BigEndian.Uint32(header[4:])
	if size > 1024 {
		t.Fatalf("invalid exec output frame of %d bytes", size)
	}
	payload := make([]byte, size)
	if _, err := io.ReadFull(reader, payload); err != nil {
		t.Fatal(err)
	}
	return header[0], string(payload)
}

func testExecInspect(t *testing.T, s *dockerEngine, id string) (running bool, code int32, tty bool) {
	t.Helper()
	w := httptest.NewRecorder()
	r := httptest.NewRequest(http.MethodGet, "/exec/"+id+"/json", nil)
	var result struct {
		Running       bool
		ExitCode      int32
		ProcessConfig struct{ Tty bool }
	}
	if err := s.exec(w, r, id+"/json"); err != nil || json.Unmarshal(w.Body.Bytes(), &result) != nil {
		t.Fatalf("inspect returned %s, %v", w.Body, err)
	}
	return result.Running, result.ExitCode, result.ProcessConfig.Tty
}

func testExecHandlerDone(t *testing.T, done <-chan error) {
	t.Helper()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("exec handler did not complete")
	}
}

func TestDockerNativeExecPlainStreamsBeforeExit(t *testing.T) {
	for _, code := range []uint32{0, 23} {
		t.Run(strconv.Itoa(int(code)), func(t *testing.T) {
			s, f := testNativeExecEngine(t)
			release := make(chan struct{})
			unblock := sync.OnceFunc(func() { close(release) })
			t.Cleanup(unblock)
			f.start = func(req *tasks.ExecProcessRequest) error {
				if req.GetStdin() != "" || req.GetTerminal() {
					return errors.New("plain exec unexpectedly opened stdin or a terminal")
				}
				out, err := f.openPipe(req.GetStdout(), os.O_WRONLY)
				if err != nil {
					return err
				}
				stderr, err := f.openPipe(req.GetStderr(), os.O_WRONLY)
				if err != nil {
					return err
				}
				go func() {
					defer out.Close()
					defer stderr.Close()
					defer f.exit(code)
					if _, err := io.WriteString(out, "stdout ready"); err != nil {
						t.Error(err)
						return
					}
					if _, err := io.WriteString(stderr, "stderr ready"); err != nil {
						t.Error(err)
						return
					}
					<-release
					if _, err := io.WriteString(out, "tail"); err != nil {
						t.Error(err)
					}
				}()
				return nil
			}
			id := testDockerExecCreate(t, s)
			client, reader, response, done := testNativeExecStart(t, s, id, "{}", "")
			if got := response.Header.Get("Content-Type"); got != "application/vnd.docker.multiplexed-stream" {
				t.Fatalf("plain exec Content-Type = %s", got)
			}
			// Like the stock read-only CLI, close only the upload side before
			// waiting for output and let the guest keep running.
			if err := client.CloseWrite(); err != nil {
				t.Fatal(err)
			}
			streams := make(map[byte]string, 2)
			for range 2 {
				channel, body := readExecTestFrame(t, reader)
				streams[channel] += body
			}
			if streams[1] != "stdout ready" || streams[2] != "stderr ready" {
				t.Fatalf("live exec streams = %v", streams)
			}
			if running, _, tty := testExecInspect(t, s, id); !running || tty {
				t.Fatalf("plain exec before release Running=%v Tty=%v", running, tty)
			}
			assertDockerExecEvents(t, s, id, true, "")
			if code != 0 {
				// Keep the half-closed stream active beyond a peer poll.
				select {
				case <-f.killed:
					t.Fatal("plain exec treated the client half-close as a disconnect")
				case <-time.After(400 * time.Millisecond):
				}
			}
			unblock()
			if channel, body := readExecTestFrame(t, reader); channel != 1 || body != "tail" {
				t.Fatalf("final plain exec frame = %d, %q", channel, body)
			}
			if _, err := reader.ReadByte(); err != io.EOF {
				t.Fatalf("plain exec output termination = %v", err)
			}
			testExecHandlerDone(t, done)
			if running, got, _ := testExecInspect(t, s, id); running || got != int32(code) {
				t.Fatalf("completed plain exec Running=%v ExitCode=%d", running, got)
			}
			assertDockerExecEvents(t, s, id, true, strconv.Itoa(int(code)))
		})
	}
}

func TestDockerNativeExecStdinHalfClose(t *testing.T) {
	s, f := testNativeExecEngine(t)
	const input = "bytes\x00after\n"
	f.start = func(req *tasks.ExecProcessRequest) error {
		stdin, err := f.openInput(req.GetStdin())
		if err != nil {
			return err
		}
		stdout, err := f.openPipe(req.GetStdout(), os.O_WRONLY)
		if err != nil {
			return err
		}
		stderr, err := f.openPipe(req.GetStderr(), os.O_WRONLY)
		if err != nil {
			return err
		}
		go func() {
			defer stdout.Close()
			defer stderr.Close()
			defer f.exit(23)
			if _, err := io.WriteString(stderr, "stderr"); err != nil {
				t.Error(err)
				return
			}
			if _, err := io.Copy(stdout, stdin); err != nil {
				t.Error(err)
				return
			}
			if _, err := io.WriteString(stdout, "EOF"); err != nil {
				t.Error(err)
			}
		}()
		return nil
	}
	id := testDockerExecCreateBody(t, s, `{"Cmd":["sh","-c","exit 23"],"AttachStdin":true,"AttachStdout":true,"AttachStderr":true}`)
	client, reader, response, done := testNativeExecStart(t, s, id, "{}", input[:6])
	if got := response.Header.Get("Content-Type"); got != "application/vnd.docker.multiplexed-stream" {
		t.Fatalf("pipe Content-Type = %s", got)
	}
	var stdout, stderr strings.Builder
	read := func() {
		switch channel, body := readExecTestFrame(t, reader); channel {
		case 1:
			stdout.WriteString(body)
		case 2:
			stderr.WriteString(body)
		default:
			t.Fatalf("unexpected frame channel %d", channel)
		}
	}
	for stdout.Len() < 6 || stderr.Len() == 0 {
		read()
	}
	if stdout.String() != input[:6] || stderr.String() != "stderr" {
		t.Fatalf("exec streams before close = %q, %q", stdout.String(), stderr.String())
	}
	if running, _, _ := testExecInspect(t, s, id); !running {
		t.Fatal("exec is not reported running while waiting for more input")
	}
	if _, err := io.WriteString(client, input[6:]); err != nil {
		t.Fatal(err)
	}
	if err := client.CloseWrite(); err != nil {
		t.Fatal(err)
	}
	for stdout.Len() < len(input)+3 {
		read()
	}
	if got := stdout.String(); got != input+"EOF" {
		t.Fatalf("stdout after half-close = %q", got)
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		t.Fatalf("exec output termination = %v", err)
	}
	testExecHandlerDone(t, done)
	if running, code, _ := testExecInspect(t, s, id); running || code != 23 {
		t.Fatalf("completed exec Running=%v ExitCode=%d", running, code)
	}
	assertDockerExecEvents(t, s, id, true, "23")
	if entries, err := os.ReadDir(s.execPipeDir); err != nil || len(entries) != 0 {
		t.Fatalf("leftover exec FIFOs = %v, %v", entries, err)
	}
}

func TestDockerNativeExecTTYResizeAndExit(t *testing.T) {
	s, f := testNativeExecEngine(t)
	f.start = func(req *tasks.ExecProcessRequest) error {
		var spec struct {
			Args, Env       []string
			Cwd             string
			CommandLine     string
			Terminal        bool
			NoNewPrivileges bool
			User            struct{ UID, GID uint32 }
			ConsoleSize     struct{ Height, Width uint16 }
		}
		if err := json.Unmarshal(req.GetSpec().GetValue(), &spec); err != nil {
			return err
		}
		if !req.GetTerminal() || req.GetStderr() != "" || !spec.Terminal || spec.ConsoleSize.Height != 31 ||
			spec.ConsoleSize.Width != 97 || spec.Cwd != "/fixture" || spec.User.UID != 1000 || spec.User.GID != 4 ||
			!spec.NoNewPrivileges || spec.CommandLine != "" || !slices.Equal(spec.Args, []string{"sh", "-c", "exit 23"}) ||
			!slices.Equal(spec.Env, []string{"PERSIST=1", "TERM=xterm"}) {
			return fmt.Errorf("invalid terminal process spec %s", req.GetSpec().GetValue())
		}
		in, err := f.openInput(req.GetStdin())
		if err != nil {
			return err
		}
		out, err := f.openPipe(req.GetStdout(), os.O_WRONLY)
		if err != nil {
			return err
		}
		go func() {
			defer out.Close()
			defer f.exit(23)
			if _, err := io.WriteString(out, "prompt\r\n"); err != nil {
				t.Error(err)
				return
			}
			select {
			case size := <-f.resized:
				if size.GetHeight() != 42 || size.GetWidth() != 113 || size.GetExecID() != req.GetExecID() {
					t.Errorf("unexpected resize %v", size)
				}
			case <-time.After(3 * time.Second):
				t.Error("did not receive resize")
				return
			}
			var input [1]byte
			if _, err := io.ReadFull(in, input[:]); err != nil || input[0] != 4 {
				t.Errorf("PTY input = %v, %v", input, err)
				return
			}
			select {
			case <-f.stdinClosed:
				t.Error("PTY stdin was closed before final output")
			default:
			}
			if _, err := io.WriteString(out, "done\r\n"); err != nil {
				t.Error(err)
			}
		}()
		return nil
	}
	id := testDockerExecCreateBody(t, s, `{"Cmd":["sh","-c","exit 23"],"AttachStdin":true,"AttachStdout":true,"AttachStderr":true,"Tty":true,"ConsoleSize":[31,97]}`)
	client, reader, response, done := testNativeExecStart(t, s, id, `{"Tty":true}`, "")
	if got := response.Header.Get("Content-Type"); got != "application/vnd.docker.raw-stream" {
		t.Fatalf("TTY Content-Type = %s", got)
	}
	if prompt, err := reader.ReadString('\n'); err != nil || prompt != "prompt\r\n" {
		t.Fatalf("TTY prompt = %q, %v", prompt, err)
	}
	if running, _, tty := testExecInspect(t, s, id); !running || !tty {
		t.Fatalf("live exec Running=%v Tty=%v", running, tty)
	}
	r := httptest.NewRequest(http.MethodPost, "/exec/"+id+"/resize?h=42&w=113", nil)
	if err := s.exec(httptest.NewRecorder(), r, id+"/resize"); err != nil {
		t.Fatal(err)
	}
	if _, err := client.Write([]byte{4}); err != nil {
		t.Fatal(err)
	}
	if remaining, err := io.ReadAll(reader); err != nil || string(remaining) != "done\r\n" {
		t.Fatalf("TTY final output = %q, %v", remaining, err)
	}
	testExecHandlerDone(t, done)
	if running, code, tty := testExecInspect(t, s, id); running || code != 23 || !tty {
		t.Fatalf("completed exec Running=%v ExitCode=%d Tty=%v", running, code, tty)
	}
	assertDockerExecEvents(t, s, id, true, "23")
	select {
	case <-f.stdinClosed:
	default:
		t.Fatal("PTY input was not retired after exit")
	}
}

func TestDockerNativeExecDoesNotDeleteRejectedID(t *testing.T) {
	s, f := testNativeExecEngine(t)
	f.execErr = status.Error(codes.AlreadyExists, "existing process")
	id := testDockerExecCreateBody(t, s, `{"Cmd":["sh","-c","exit 23"],"Tty":true}`)
	r := httptest.NewRequest(http.MethodPost, "/exec/"+id+"/start", strings.NewReader(`{"Detach":true,"Tty":true}`))
	if err := s.exec(httptest.NewRecorder(), r, id+"/start"); status.Code(err) != codes.AlreadyExists {
		t.Fatalf("start returned %v", err)
	}
	if len(f.killed) != 0 || len(f.deleted) != 0 {
		t.Fatal("rejected exec attempted to retire an unowned runtime process")
	}
	if entries, err := os.ReadDir(s.execPipeDir); err != nil || len(entries) != 0 {
		t.Fatalf("leftover exec FIFOs = %v, %v", entries, err)
	}
	assertDockerExecEvents(t, s, id, true, "")
}

func TestDockerNativeExecRetiresFailedStart(t *testing.T) {
	for _, tc := range []struct {
		name, diagnostic string
		code             int32
	}{
		{"absolute command missing", "executable file `/missing` not found: No such file or directory", 127},
		{"PATH command missing", "executable file `missing` not found in $PATH: No such file or directory", 127},
		{"command has no execute bit", "the path `/missing` exists but it is not executable: Operation not permitted", 126},
		{"command permission denied", `executable file "/missing": Permission denied`, 126},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, f := testNativeExecEngine(t)
			f.start = func(*tasks.ExecProcessRequest) error {
				return status.Error(codes.Unknown, "failed to start exec: OCI runtime exec failed: "+tc.diagnostic)
			}
			f.killErr = status.Error(codes.FailedPrecondition, "process not created")
			id := testDockerExecCreate(t, s)
			_, reader, _, done := testNativeExecStart(t, s, id, "{}", "")
			if channel, body := readExecTestFrame(t, reader); channel != 2 || !strings.Contains(body, tc.diagnostic) {
				t.Fatalf("rejected exec frame = %d, %q", channel, body)
			}
			if _, err := reader.ReadByte(); err != io.EOF {
				t.Fatalf("rejected exec output termination = %v", err)
			}
			testExecHandlerDone(t, done)
			if len(f.deleted) != 1 {
				t.Fatal("owned exec was not deleted after failing to start")
			}
			if running, code, _ := testExecInspect(t, s, id); running || code != tc.code {
				t.Fatalf("rejected exec Running=%v ExitCode=%d", running, code)
			}
			if entries, err := os.ReadDir(s.execPipeDir); err != nil || len(entries) != 0 {
				t.Fatalf("leftover exec FIFOs = %v, %v", entries, err)
			}
			assertDockerExecEvents(t, s, id, true, "")
		})
	}
}

func TestDockerNativeExecFullDisconnectRecordsExit(t *testing.T) {
	s, f := testNativeExecEngine(t)
	f.start = func(req *tasks.ExecProcessRequest) error {
		out, err := f.openPipe(req.GetStdout(), os.O_WRONLY)
		if err != nil {
			return err
		}
		stderr, err := f.openPipe(req.GetStderr(), os.O_WRONLY)
		if err != nil {
			return err
		}
		if _, err := io.WriteString(out, "ready\n"); err != nil {
			return err
		}
		go func() {
			<-f.exited
			_ = out.Close()
			_ = stderr.Close()
		}()
		return nil
	}
	id := testDockerExecCreate(t, s)
	client, reader, _, done := testNativeExecStart(t, s, id, "{}", "")
	if channel, line := readExecTestFrame(t, reader); channel != 1 || line != "ready\n" {
		t.Fatalf("exec readiness frame = %d, %q", channel, line)
	}
	if err := client.Close(); err != nil {
		t.Fatal(err)
	}
	testExecHandlerDone(t, done)
	select {
	case signal := <-f.killed:
		if signal != uint32(unix.SIGKILL) {
			t.Fatalf("disconnected exec got signal %d", signal)
		}
	default:
		t.Fatal("disconnected exec was not stopped")
	}
	if running, code, _ := testExecInspect(t, s, id); running || code != 137 {
		t.Fatalf("disconnected exec Running=%v ExitCode=%d", running, code)
	}
	if len(f.deleted) != 1 {
		t.Fatal("disconnected exec was not deleted")
	}
	assertDockerExecEvents(t, s, id, true, "137")
}

func TestDockerNativeExecLostWithContainerIsNotReportedAsSuccess(t *testing.T) {
	for _, tc := range []struct {
		name, message string
		waitErr       error
	}{
		{"container disappears", "container task disappeared", status.Error(codes.NotFound, "container task disappeared")},
		{"missing runtime result", "containerd returned no exec result", nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, f := testNativeExecEngine(t)
			f.waitErr = tc.waitErr
			f.omitExit = tc.waitErr == nil
			f.killErr = status.Error(codes.NotFound, "container task disappeared")
			f.deleteErr = f.killErr
			id := testDockerExecCreate(t, s)
			r := httptest.NewRequest(http.MethodPost, "/exec/"+id+"/start", strings.NewReader(`{"Detach":true}`))
			if err := s.exec(httptest.NewRecorder(), r, id+"/start"); err != nil {
				t.Fatal(err)
			}
			f.exit(0)
			select {
			case <-f.deleted:
			case <-time.After(3 * time.Second):
				t.Fatal("exec cleanup waited after the container task disappeared")
			}
			r = httptest.NewRequest(http.MethodGet, "/exec/"+id+"/json", nil)
			if err := s.exec(httptest.NewRecorder(), r, id+"/json"); err == nil || !strings.Contains(err.Error(), tc.message) {
				t.Fatalf("inspect with unknown exit returned %v", err)
			}
			assertDockerExecEvents(t, s, id, true, "")
		})
	}
}

func TestDockerNativeExecDetachesAndRecordsExit(t *testing.T) {
	s, f := testNativeExecEngine(t)
	f.start = func(req *tasks.ExecProcessRequest) error {
		if req.GetStdin() != "" || req.GetStdout() != "" || req.GetStderr() != "" {
			return errors.New("detached pipe exec unexpectedly opened I/O")
		}
		return nil
	}
	id := testDockerExecCreate(t, s)
	r := httptest.NewRequest(http.MethodPost, "/exec/"+id+"/start", strings.NewReader(`{"Detach":true}`))
	if err := s.exec(httptest.NewRecorder(), r, id+"/start"); err != nil {
		t.Fatal(err)
	}
	if running, _, _ := testExecInspect(t, s, id); !running {
		t.Fatal("detached exec is not running")
	}
	f.exit(23)
	select {
	case <-f.deleted:
	case <-time.After(3 * time.Second):
		t.Fatal("completed detached exec was not deleted")
	}
	if running, code, _ := testExecInspect(t, s, id); running || code != 23 {
		t.Fatalf("completed exec Running=%v ExitCode=%d", running, code)
	}
	assertDockerExecEvents(t, s, id, true, "23")
}

func TestDockerExecOutputDrainFollowsProgress(t *testing.T) {
	t.Run("active", func(t *testing.T) {
		const idle = 120 * time.Millisecond
		pump := newDockerOutputDrain()
		result := make(chan error, 1)
		go func() { result <- pump.waitForEOF(idle, nil) }()
		ticker := time.NewTicker(idle / 5)
		defer ticker.Stop()
		for range 10 {
			select {
			case <-ticker.C:
			case <-result:
				t.Fatal("active output was abandoned before EOF")
			}
			select {
			case pump.progress <- struct{}{}:
			default:
			}
		}
		close(pump.done)
		if err := <-result; err != nil {
			t.Fatalf("active output was abandoned: %v", err)
		}
	})
	t.Run("inactive", func(t *testing.T) {
		pump := newDockerOutputDrain()
		if pump.waitForEOF(time.Millisecond, nil) == nil {
			t.Fatal("inactive output was mistaken for EOF")
		}
	})
	t.Run("client disconnects", func(t *testing.T) {
		pump := newDockerOutputDrain()
		lost := make(chan struct{})
		pump.progress <- struct{}{}
		close(lost)
		if err := pump.waitForEOF(time.Second, lost); !errors.Is(err, io.ErrClosedPipe) {
			t.Fatalf("drain after disconnect returned %v", err)
		}
	})
}
