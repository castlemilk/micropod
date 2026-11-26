package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"google.golang.org/grpc"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestDockerRestartTimeout(t *testing.T) {
	for _, tc := range []struct {
		query   string
		timeout int64
		status  int
	}{
		{query: "", timeout: 10},
		{query: "t=0", timeout: 0},
		{query: "t=12", timeout: 12},
		{query: "t=65535", timeout: 65535},
		{query: "t=12&signal=sigkill", timeout: 0},
		{query: "signal=9", timeout: 0},
		{query: "t=-1", status: 501},
		{query: "t=65536", status: 400},
		{query: "t=bad", status: 400},
		{query: "signal=SIGINT", status: 501},
	} {
		t.Run(tc.query, func(t *testing.T) {
			q, err := url.ParseQuery(tc.query)
			if err != nil {
				t.Fatal(err)
			}
			timeout, err := dockerRestartTimeout(q)
			if tc.status != 0 {
				var failure apiError
				if !errors.As(err, &failure) || failure.code != tc.status {
					t.Fatalf("restart options returned %v, want status %d", err, tc.status)
				}
			} else if err != nil || timeout != tc.timeout {
				t.Fatalf("restart options = %d, %v, want %d", timeout, err, tc.timeout)
			}
		})
	}
}

func TestDockerRestartRejectsUnsupportedInputsBeforeMutation(t *testing.T) {
	for _, tc := range []struct {
		name, phase, query string
		auto, removed      bool
		status             int
	}{
		{name: "invalid timeout", phase: "running", query: "t=invalid", status: 400},
		{name: "unsupported signal", phase: "running", query: "signal=SIGTERM", status: 501},
		{name: "unlimited grace", phase: "running", query: "t=-1", status: 501},
		{name: "ephemeral container", phase: "running", auto: true, status: 409},
		{name: "dead container", phase: "dead", status: 409},
		{name: "deleted container", phase: "removing", removed: true, status: 404},
	} {
		t.Run(tc.name, func(t *testing.T) {
			engine := &dockerEngine{}
			c := &dockerContainer{dockerRecord: dockerRecord{
				Phase: tc.phase, Config: dockerConfig{HostConfig: dockerHost{AutoRemove: tc.auto}},
			}, removed: tc.removed}
			r := httptest.NewRequest(http.MethodPost, "/restart?"+tc.query, nil)
			err := engine.containerLifecycle(httptest.NewRecorder(), r, c, "restart")
			var failure apiError
			if !errors.As(err, &failure) || failure.code != tc.status || c.Phase != tc.phase {
				t.Fatalf("restart returned %v, phase %q, want status %d and phase %q", err, c.Phase, tc.status, tc.phase)
			}
			if (tc.auto || tc.query != "") && c.lifecycle != nil {
				t.Fatal("rejected input allocated lifecycle state")
			}
		})
	}
}

type restartTestRuntime struct {
	cri.RuntimeServiceClient
	stop func(context.Context, *cri.StopContainerRequest) (*cri.StopContainerResponse, error)
}

func (r restartTestRuntime) StopContainer(ctx context.Context, req *cri.StopContainerRequest, _ ...grpc.CallOption) (*cri.StopContainerResponse, error) {
	return r.stop(ctx, req)
}

func TestDockerRestartFencesOtherMutationsAndSurvivesDisconnect(t *testing.T) {
	const timeout = 3
	stopFailure := errors.New("failed to stop original process")
	stopping := make(chan context.Context, 1)
	finish := make(chan struct{})
	defer close(finish)
	requested := make(chan *cri.StopContainerRequest, 1)
	runtime := restartTestRuntime{stop: func(ctx context.Context, req *cri.StopContainerRequest) (*cri.StopContainerResponse, error) {
		requested <- req
		stopping <- ctx
		<-finish
		return nil, stopFailure
	}}
	engine := &dockerEngine{node: node{runtime: runtime}}
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "running", RuntimeID: "first"}, changed: make(chan struct{})}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	r := httptest.NewRequest(http.MethodPost, "/restart?t=3", nil).WithContext(ctx)
	done := make(chan error, 1)
	go func() { done <- engine.containerLifecycle(httptest.NewRecorder(), r, c, "restart") }()
	var stopCtx context.Context
	select {
	case stopCtx = <-stopping:
	case err := <-done:
		t.Fatalf("restart returned before stopping the process: %v", err)
	case <-time.After(2 * time.Second):
		t.Fatal("restart did not request a stop")
	}
	if req := <-requested; req.ContainerId != "first" || req.Timeout != timeout {
		t.Fatalf("restart stopped %q with grace %d", req.ContainerId, req.Timeout)
	}
	cancel()
	if stopCtx.Err() != nil {
		t.Fatal("client cancellation interrupted an admitted restart")
	}
	queued, cancelQueued := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancelQueued()
	if release, err := engine.lockContainerLifecycle(queued, c); !errors.Is(err, context.DeadlineExceeded) || release != nil {
		t.Fatal("another lifecycle call entered while restart owned the container")
	}
	otherCtx, cancelOther := context.WithTimeout(context.Background(), time.Second)
	defer cancelOther()
	other, err := engine.lockContainerLifecycle(otherCtx, &dockerContainer{})
	if err != nil {
		t.Fatalf("restart blocked another container: %v", err)
	}
	other()
	// Release the stop RPC without completing a successful stop. The request
	// must return the failure while retaining the original generation.
	finish <- struct{}{}
	select {
	case err := <-done:
		if !errors.Is(err, stopFailure) || c.RuntimeID != "first" {
			t.Fatalf("restart after failed stop returned %v, runtime %q", err, c.RuntimeID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("failed restart did not release the lifecycle")
	}
	afterward, cancelAfterward := context.WithTimeout(context.Background(), time.Second)
	defer cancelAfterward()
	release, err := engine.lockContainerLifecycle(afterward, c)
	if err != nil {
		t.Fatal(err)
	}
	release()
}

type gatedWaitResponse struct {
	*httptest.ResponseRecorder
	flushed  chan struct{}
	resume   chan struct{}
	canceled <-chan struct{}
}

func (w gatedWaitResponse) Flush() {
	w.ResponseRecorder.Flush()
	close(w.flushed)
	select {
	case <-w.resume:
	case <-w.canceled:
	}
}

func TestDockerWaitReturnsTheOriginalExitAfterReplacement(t *testing.T) {
	for _, condition := range []string{"", "not-running", "next-exit"} {
		t.Run(condition, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			engine := &dockerEngine{}
			c := &dockerContainer{dockerRecord: dockerRecord{Phase: "running", RuntimeID: "original"}, changed: make(chan struct{})}
			w := gatedWaitResponse{httptest.NewRecorder(), make(chan struct{}), make(chan struct{}), ctx.Done()}
			r := httptest.NewRequest(http.MethodPost, "/wait?condition="+condition, nil).WithContext(ctx)
			done := make(chan error, 1)
			go func() { done <- engine.wait(w, r, c) }()
			select {
			case <-w.flushed:
			case <-ctx.Done():
				t.Fatal("wait did not acknowledge registration")
			}
			// Two generations complete while the handler cannot write its reply.
			engine.mu.Lock()
			for _, code := range []int32{137, 41} {
				c.Phase, c.RuntimeID, c.Exit = "exited", "", code
				c.Exits++
				c.signal()
				c.Phase, c.RuntimeID, c.Exit = "running", "replacement", 0
				c.signal()
			}
			if c.exitReceipt != nil {
				t.Error("container retained a completed wait receipt")
			}
			engine.mu.Unlock()
			close(w.resume)
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-ctx.Done():
				t.Fatal("wait followed a replacement process")
			}
			var reply struct{ StatusCode int32 }
			if err := json.Unmarshal(w.Body.Bytes(), &reply); err != nil || reply.StatusCode != 137 {
				t.Fatalf("wait returned %s (%v), want original code 137", w.Body, err)
			}
		})
	}
}
