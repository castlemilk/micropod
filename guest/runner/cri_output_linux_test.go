package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestCRIOutputRecordBoundaries(t *testing.T) {
	long := bytes.Repeat([]byte{0, 0xff, ' '}, 13000)
	var source, seen bytes.Buffer
	output := criOutput{reader: bufio.NewReaderSize(&source, 64)}
	write := func(stream string, data []byte) error {
		seen.WriteString(stream + "|")
		seen.Write(data)
		seen.WriteByte('|')
		return nil
	}
	source.WriteString("t stderr P ")
	source.Write(long[:100])
	if err := output.drain(write); err != nil || seen.Len() != 0 {
		t.Fatalf("partial physical record: bytes=%d, err=%v", seen.Len(), err)
	}
	source.Write(long[100:])
	source.WriteString("\nt stdout F \nt stderr P \nt stdout F  a  b\r\n")
	if err := output.drain(write); err != nil {
		t.Fatal(err)
	}
	want := append([]byte("stderr|"), long...)
	want = append(want, []byte("|stdout|\n|stderr||stdout| a  b\r\n|")...)
	if !bytes.Equal(seen.Bytes(), want) || len(output.partial) != 0 {
		t.Fatal("records changed across EOF or buffer boundaries")
	}
}

func TestCRIOutputErrorsAndLimit(t *testing.T) {
	sinkErr := errors.New("sink failed")
	for _, tc := range []struct {
		raw, want string
		initial   int64
	}{
		{"t stdout F\n", "invalid CRI log record", 0},
		{"t other F payload\n", "invalid CRI log stream", 0},
		{"t stdout X payload\n", "invalid CRI log fragment", 0},
		{"t stdout F x\n", sinkErr.Error(), 0},
		{"t stdout F x\n", "job log exceeded the 8 MiB limit", (8 << 20) - 4096 - int64(len("t stdout F x\n"))},
	} {
		out := criOutput{reader: bufio.NewReader(bytes.NewBufferString(tc.raw)), bytes: tc.initial}
		err := out.drain(func(string, []byte) error { return sinkErr })
		if err == nil || err.Error() != tc.want || out.bytes != tc.initial+int64(len(tc.raw)) {
			t.Fatalf("raw=%q: err=%v bytes=%d", tc.raw, err, out.bytes)
		}
	}
}

type followRuntime struct {
	cri.RuntimeServiceClient
	checks   atomic.Int32
	response func(check int32) *cri.ContainerStatus
}

func (r *followRuntime) ContainerStatus(_ context.Context, _ *cri.ContainerStatusRequest, _ ...grpc.CallOption) (*cri.ContainerStatusResponse, error) {
	return &cri.ContainerStatusResponse{Status: r.response(r.checks.Add(1))}, nil
}

type fakeTaskWait func(context.Context, *tasks.WaitRequest) (*tasks.WaitResponse, error)

func (f fakeTaskWait) Wait(ctx context.Context, req *tasks.WaitRequest, _ ...grpc.CallOption) (*tasks.WaitResponse, error) {
	return f(ctx, req)
}

func receiveFollow[T any](t *testing.T, ctx context.Context, out <-chan T) T {
	t.Helper()
	select {
	case value := <-out:
		return value
	case <-ctx.Done():
		t.Fatal("timed out waiting for container follow progress")
		var zero T
		return zero
	}
}

func TestCRIFollowStreamsWhileWaitingForTask(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	log, err := os.CreateTemp(t.TempDir(), "job.log")
	if err != nil {
		t.Fatal(err)
	}
	defer log.Close()
	var exited atomic.Bool
	runtime := &followRuntime{response: func(int32) *cri.ContainerStatus {
		if exited.Load() {
			return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_EXITED, FinishedAt: 1, ExitCode: 137, Reason: "OOMKilled"}
		}
		// The completion RPC is independent of how CRI classifies a live task.
		return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_UNKNOWN}
	}}
	registration := make(chan error, 1)
	exitEvent := make(chan struct{})
	watch := fakeTaskWait(func(ctx context.Context, req *tasks.WaitRequest) (*tasks.WaitResponse, error) {
		md, _ := metadata.FromOutgoingContext(ctx)
		want := md.Get("containerd-namespace")
		if req.ContainerID != "native-runtime-id" || req.ExecID != "" || len(want) != 1 || want[0] != "k8s.io" {
			registration <- fmt.Errorf("unexpected wait request %v in namespace %v", req, want)
			return nil, status.Error(codes.NotFound, "test waiter identity mismatch")
		}
		registration <- nil
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-exitEvent:
			// The CRI record supplies the authoritative code and reason.
			return &tasks.WaitResponse{ExitStatus: 1}, nil
		}
	})
	type outcome struct {
		code   int32
		reason string
		err    error
	}
	frames := make(chan string, 3)
	done := make(chan outcome, 1)
	n := node{runtime: runtime, tasks: watch}
	go func() {
		code, reason, err := n.follow(ctx, "native-runtime-id", criLogSource{path: log.Name()}, func(stream string, b []byte) error {
			frames <- stream + ":" + string(b)
			return nil
		}, true)
		done <- outcome{code, reason, err}
	}()
	if err := receiveFollow(t, ctx, registration); err != nil {
		t.Fatal(err)
	}
	for _, line := range []struct{ raw, want string }{
		{"t stdout F while waiting\n", "stdout:while waiting\n"},
		{"t stderr P second read\n", "stderr:second read"},
	} {
		if _, err := log.WriteString(line.raw); err != nil {
			t.Fatal(err)
		}
		if got := receiveFollow(t, ctx, frames); got != line.want {
			t.Fatalf("streamed frame = %q, want %q", got, line.want)
		}
	}
	if checks := runtime.checks.Load(); checks != 1 {
		t.Fatalf("running task with a healthy waiter received %d CRI status calls", checks)
	}
	if _, err := log.WriteString("t stdout F final frame\n"); err != nil {
		t.Fatal(err)
	}
	exited.Store(true)
	close(exitEvent)
	if last := receiveFollow(t, ctx, frames); last != "stdout:final frame\n" {
		t.Fatalf("final frame = %q", last)
	}
	if got := receiveFollow(t, ctx, done); got != (outcome{code: 137, reason: "OOMKilled"}) {
		t.Fatalf("completion = %+v", got)
	}
	if checks := runtime.checks.Load(); checks != 2 {
		t.Fatalf("CRI status calls = %d, want initial and final", checks)
	}
}

func TestCRIFollowWaitRechecksUncommittedExit(t *testing.T) {
	for _, result := range []error{
		nil, status.Error(codes.NotFound, "CRI removed the runtime task"), status.Error(codes.Unavailable, "transport closed"),
	} {
		t.Run(status.Code(result).String(), func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
			defer cancel()
			runtime := &followRuntime{response: func(check int32) *cri.ContainerStatus {
				if check < 3 {
					return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_RUNNING}
				}
				return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_EXITED, FinishedAt: 1, ExitCode: 17, Reason: "Error"}
			}}
			watch := fakeTaskWait(func(context.Context, *tasks.WaitRequest) (*tasks.WaitResponse, error) {
				return nil, result
			})
			n := node{runtime: runtime, tasks: watch}
			code, reason, err := n.follow(ctx, "runtime-id", criLogSource{path: filepath.Join(t.TempDir(), "missing.log")}, func(string, []byte) error {
				return errors.New("received output from missing log")
			}, true)
			if code != 17 || reason != "Error" || err != nil || runtime.checks.Load() != 3 {
				t.Fatalf("uncommitted exit: code=%d, reason=%q, err=%v, status calls=%d", code, reason, err, runtime.checks.Load())
			}
		})
	}
}

func TestCRIFollowCancelsTaskWait(t *testing.T) {
	ctx, timeout := context.WithTimeout(context.Background(), 2*time.Second)
	defer timeout()
	follow, cancel := context.WithCancel(ctx)
	defer cancel()
	registration, stopped := make(chan struct{}), make(chan struct{})
	runtime := &followRuntime{response: func(int32) *cri.ContainerStatus {
		return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_RUNNING}
	}}
	watch := fakeTaskWait(func(ctx context.Context, _ *tasks.WaitRequest) (*tasks.WaitResponse, error) {
		close(registration)
		<-ctx.Done()
		close(stopped)
		return nil, ctx.Err()
	})
	done := make(chan error, 1)
	path := filepath.Join(t.TempDir(), "job.log")
	go func() {
		n := node{runtime: runtime, tasks: watch}
		_, _, err := n.follow(follow, "id", criLogSource{path: path}, func(string, []byte) error { return nil }, true)
		done <- err
	}()
	receiveFollow(t, ctx, registration)
	cancel()
	if err := receiveFollow(t, ctx, done); !errors.Is(err, context.Canceled) {
		t.Fatalf("follow cancel = %v", err)
	}
	receiveFollow(t, ctx, stopped)
}

func BenchmarkCRIDrain(b *testing.B) {
	for _, tc := range []struct {
		name        string
		count, size int
	}{
		{"one", 1, 96}, {"ci", 1024, 96}, {"oversized", 8, 65536},
	} {
		var wire, stdout, stderr, jsonWire bytes.Buffer
		for i := 0; i < tc.count; i++ {
			stream, target := "stdout", &stdout
			if i%4 == 1 {
				stream, target = "stderr", &stderr
			}
			tag := "F"
			if i%7 == 0 {
				tag = "P"
			}
			body := bytes.Repeat([]byte{byte('A' + i%26)}, tc.size)
			fmt.Fprintf(&wire, "2026-11-23T00:00:00.000000000Z %s %s ", stream, tag)
			wire.Write(body)
			wire.WriteByte('\n')
			if tag == "F" {
				body = append(body, '\n')
			}
			target.Write(body)
			rec, err := json.Marshal(struct {
				Type string `json:"type"`
				Data []byte `json:"data"`
			}{stream, body})
			if err != nil {
				b.Fatal(err)
			}
			jsonWire.Write(rec)
			jsonWire.WriteByte('\n')
		}
		f, err := os.CreateTemp(b.TempDir(), "job.log")
		if err != nil {
			b.Fatal(err)
		}
		if _, err := f.Write(wire.Bytes()); err != nil {
			b.Fatal(err)
		}
		for _, transport := range []string{"streams", "json"} {
			b.Run(tc.name+"/"+transport, func(b *testing.B) {
				reader := bufio.NewReaderSize(nil, 32<<10)
				var out, errout bytes.Buffer
				var sink outputSink
				if transport == "json" {
					out.Grow(jsonWire.Len())
					sink = jsonOutput(json.NewEncoder(&out))
				} else {
					out.Grow(stdout.Len())
					errout.Grow(stderr.Len())
					sink = func(stream string, data []byte) error {
						if stream == "stdout" {
							_, err := out.Write(data)
							return err
						}
						_, err := errout.Write(data)
						return err
					}
				}
				b.SetBytes(int64(wire.Len()))
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					reader.Reset(io.NewSectionReader(f, 0, int64(wire.Len())))
					state := criOutput{reader: reader}
					out.Reset()
					errout.Reset()
					if err := state.drain(sink); err != nil {
						b.Fatal(err)
					}
					expected := stdout.Bytes()
					if transport == "json" {
						expected = jsonWire.Bytes()
					}
					if state.bytes != int64(wire.Len()) || len(state.partial) != 0 || !bytes.Equal(out.Bytes(), expected) || (transport == "streams" && !bytes.Equal(errout.Bytes(), stderr.Bytes())) {
						b.Fatal("decoded output differs")
					}
				}
			})
		}
		if err := f.Close(); err != nil {
			b.Fatal(err)
		}
	}
}
