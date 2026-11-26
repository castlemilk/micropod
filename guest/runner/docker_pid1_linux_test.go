package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	taskapi "github.com/containerd/containerd/api/types/task"
	"github.com/moby/term"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc"
)

func TestDockerPID1ConfigAndSpec(t *testing.T) {
	config, err := parseDockerConfig([]byte(`{"Image":"a","Tty":true,"OpenStdin":true,"StdinOnce":true,"AttachStdin":true,"HostConfig":{"ConsoleSize":[31,97],"ReadonlyRootfs":true}}`))
	if err != nil || !config.Tty || !config.OpenStdin || !config.StdinOnce || !config.AttachStdin ||
		!config.HostConfig.ReadonlyRootfs || !slices.Equal(config.HostConfig.ConsoleSize, []uint16{31, 97}) {
		t.Fatalf("config %+v: %v", config, err)
	}
	for _, raw := range []string{
		`{"Image":"a","HostConfig":{"ConsoleSize":[31,97]}}`,
		`{"Image":"a","Tty":true,"HostConfig":{"ConsoleSize":[31,0]}}`,
		`{"Image":"a","Tty":true,"HostConfig":{"ConsoleSize":[0,0,0]}}`,
	} {
		if _, err := parseDockerConfig([]byte(raw)); err == nil {
			t.Fatalf("accepted invalid console config %s", raw)
		}
	}
	console := dockerPID1{dir: "/runtime/pid1-351", tty: true}
	const fixture = `{"process":{"args":["probe","arg with spaces",""],"env":["PATH=/fixture","TERM=","FIXTURE=abc"],"cwd":"/fixture","user":{"uid":1234,"gid":5678},"noNewPrivileges":true},"mounts":[{"destination":"/dev","type":"tmpfs","source":"tmpfs"},{"destination":"/mnt","type":"bind","source":"/owned"}],"root":{"readonly":true}}`
	newSpec, err := console.spec([]byte(fixture))
	if err != nil {
		t.Fatal(err)
	}
	var spec struct {
		Process map[string]json.RawMessage
		Mounts  []dockerOCITmpfsMount
		Root    json.RawMessage
	}
	if err := json.Unmarshal(newSpec, &spec); err != nil {
		t.Fatal(err)
	}
	const target = "/dev/.micropod-pid1-351"
	for key, want := range map[string]string{
		"args": `["` + target + `/launch","container-stdio","` + target + `/io","tty","probe","arg with spaces",""]`,
		"env":  `["PATH=/fixture","TERM=","FIXTURE=abc"]`, "cwd": `"/fixture"`,
		"user": `{"uid":1234,"gid":5678}`, "noNewPrivileges": `true`,
	} {
		if got := string(spec.Process[key]); got != want {
			t.Errorf("process.%s %s, want %s", key, got, want)
		}
	}
	if string(spec.Root) != `{"readonly":true}` || len(spec.Mounts) != 4 || spec.Mounts[1].Source != "/owned" ||
		spec.Mounts[2].Destination != target || spec.Mounts[2].Source != console.dir ||
		spec.Mounts[3].Destination != target+"/launch" || !slices.Contains(spec.Mounts[3].Options, "ro") {
		t.Fatalf("root or mounts changed: %s", newSpec)
	}
	bare := strings.Replace(fixture, `"env":["PATH=/fixture","TERM=","FIXTURE=abc"],`, "", 1)
	bareSpec, err := console.spec([]byte(bare))
	if err != nil || !bytes.Contains(bareSpec, []byte(`"env":["TERM=xterm"]`)) {
		t.Fatalf("default terminal type missing: %s: %v", bareSpec, err)
	}
	foreignDev := strings.Replace(fixture, `"destination":"/dev","type":"tmpfs"`, `"destination":"/dev","type":"bind"`, 1)
	if _, err := console.spec([]byte(foreignDev)); err == nil {
		t.Fatal("console created a runtime path in a foreign /dev mount")
	}
}

func TestDockerPID1InputEOFAndDetach(t *testing.T) {
	for _, tc := range []struct {
		name, bytes string
		terminal    bool
		once, stop  bool
	}{
		{name: "half close", bytes: "payload"},
		{name: "stdin once", bytes: "payload", once: true},
		{name: "tty EOF", terminal: true},
		{name: "tty detach keys", bytes: "\x18\x19", terminal: true, stop: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := dockerPID1{ready: make(chan struct{}), closed: make(chan struct{}),
				input: make(chan []byte, 3), inputDone: make(chan struct{})}
			close(c.ready)
			var reader io.Reader = strings.NewReader(tc.bytes)
			if tc.terminal {
				reader = term.NewEscapeProxy(reader, []byte{24, 25})
			}
			if got := copyConsoleInput(context.Background(), &c, reader, tc.once); got != tc.stop {
				t.Fatalf("detach %v, want %v", got, tc.stop)
			}
			if tc.bytes == "payload" && (len(c.input) == 0 || string(<-c.input) != "payload") {
				t.Fatal("input payload was lost")
			}
			if tc.once && (len(c.input) == 0 || <-c.input != nil) {
				t.Fatal("single-use stdin never received EOF")
			}
			if len(c.input) != 0 {
				t.Fatal("unexpected input or EOF forwarded")
			}
		})
	}
}

type dockerPID1TaskFixture struct {
	tasks.TasksClient
	pid uint32
}

func (f dockerPID1TaskFixture) Get(_ context.Context, req *tasks.GetRequest, _ ...grpc.CallOption) (*tasks.GetResponse, error) {
	return &tasks.GetResponse{Process: &taskapi.Process{ID: req.ContainerID, Pid: f.pid, Status: taskapi.Status_RUNNING}}, nil
}

func TestDockerPID1RejectsForeignConsolePeer(t *testing.T) {
	console, err := newDockerPID1(t.TempDir(), dockerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	defer console.finish(t.Context())
	conn, err := net.DialUnix("unixpacket", nil, &net.UnixAddr{Name: filepath.Join(console.dir, "io"), Net: "unixpacket"})
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
	defer cancel()
	wrongTask := node{execTasks: dockerPID1TaskFixture{pid: uint32(os.Getpid()) + 1}}
	err = console.accept(ctx, wrongTask, "owned-task", nil, cancel)
	if !errors.Is(err, os.ErrDeadlineExceeded) || len(console.files) != 0 {
		t.Fatalf("foreign peer reached console I/O: %v", err)
	}
	var data [1]byte
	if n, err := conn.Read(data[:]); n != 0 || err == nil {
		t.Fatalf("foreign peer connection stayed open: %d %v", n, err)
	}
}

func TestDockerPID1DrainsBufferedOutputWhileSpoolProgresses(t *testing.T) {
	console, err := newDockerPID1(t.TempDir(), dockerConfig{Tty: true})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 8*time.Second)
	defer cancel()
	t.Cleanup(func() {
		select {
		case <-console.closed:
		default:
			_ = console.finish(ctx)
		}
	})

	// Queue discrete reads and close the writer before retirement, as happens
	// when a task exits with bytes still waiting in its console buffer.
	pair, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_SEQPACKET|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	console.files = []*os.File{os.NewFile(uintptr(pair[0]), "buffered stdout")}
	writer := os.NewFile(uintptr(pair[1]), "finished process stdout")
	defer writer.Close()
	var expected []byte
	for i := range 10 {
		chunk := []byte{byte(i), 0, 255}
		if _, err := writer.Write(chunk); err != nil {
			t.Fatal(err)
		}
		expected = append(expected, chunk...)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	var received []byte
	console.startCopies(func(_ string, data []byte) error {
		<-console.closed
		// Each completed write advances the spool. Combined drain duration is
		// over two seconds even though the reader never stalls.
		timer := time.NewTimer(240 * time.Millisecond)
		defer timer.Stop()
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-timer.C:
		}
		received = append(received, data...)
		return nil
	}, cancel)
	if err := console.finish(ctx); err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(received, expected) {
		t.Fatalf("drained %d of %d buffered bytes: %x", len(received), len(expected), received)
	}
}

func TestDockerPID1ExecSearch(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "physical", "cwd"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("physical/cwd", filepath.Join(root, "link")); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "physical", "probe"), nil, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "probe"), nil, 0644); err != nil {
		t.Fatal(err)
	}
	if got, err := findContainerExecutable(root+":"+root+"/link/..", "probe"); err != nil || got != root+"/link/../probe" {
		t.Fatalf("executable resolution %q: %v", got, err)
	}
	if _, err := findContainerExecutable(root, "probe"); !errors.Is(err, unix.EACCES) {
		t.Fatalf("nonexecutable PATH candidate: %v", err)
	}
	if _, err := findContainerExecutable(root, "missing"); !errors.Is(err, unix.ENOENT) {
		t.Fatalf("missing PATH candidate: %v", err)
	}
}
