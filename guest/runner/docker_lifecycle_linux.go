package main

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	"golang.org/x/sys/unix"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

const defaultDockerStopTimeout = 10

type dockerWaitStatus struct {
	exit        int32
	failure     string
	readersDone <-chan struct{}
	log         dockerLogWatermark
}

type dockerExitReceipt struct {
	epoch  uint64
	done   chan struct{}
	result dockerWaitStatus
}

// These helpers run under the engine's state lock. Existing waiters share a
// receipt for their generation. Completing it releases the container's reference.
func (c *dockerContainer) pendingExitReceipt() *dockerExitReceipt {
	if c.exitReceipt == nil {
		c.exitReceipt = &dockerExitReceipt{epoch: c.Exits, done: make(chan struct{})}
	}
	return c.exitReceipt
}

func (c *dockerContainer) waitStatus() dockerWaitStatus {
	return dockerWaitStatus{exit: c.Exit, failure: c.Failure, readersDone: c.readersDone, log: c.logWatermark()}
}

func (c *dockerContainer) completeExitReceipt() {
	if pending := c.exitReceipt; pending != nil && (c.Exits != pending.epoch || c.removed || c.Phase == "dead") {
		pending.result = c.waitStatus()
		close(pending.done)
		c.exitReceipt = nil
	}
}

func dockerRestartTimeout(q url.Values) (int64, error) {
	timeout := int64(defaultDockerStopTimeout)
	if raw := q.Get("t"); raw != "" {
		var err error
		timeout, err = strconv.ParseInt(raw, 10, 64)
		if err != nil || timeout > 65535 {
			return 0, fail(400, "restart timeout must be an integer of at most 65535 seconds")
		}
		if timeout < 0 {
			return 0, fail(501, "unlimited restart grace is unavailable")
		}
	}
	switch strings.ToUpper(q.Get("signal")) {
	case "":
		return timeout, nil
	case "SIGKILL", "KILL", "9":
		return 0, nil
	default:
		return 0, fail(501, "restart signal overrides support SIGKILL only")
	}
}

func dockerStopTimeout(op string, q url.Values) (int64, error) {
	timeout := int64(defaultDockerStopTimeout)
	if op == "kill" {
		switch strings.TrimPrefix(strings.ToUpper(q.Get("signal")), "SIG") {
		case "", "KILL", "9":
			timeout = 0
		default:
			return 0, fail(400, "only SIGKILL is supported by the CRI kill operation")
		}
	}
	if raw := q.Get("t"); raw != "" {
		t, err := strconv.ParseUint(raw, 10, 16)
		if err != nil {
			return 0, fail(400, "invalid stop timeout")
		}
		timeout = int64(t)
	}
	return timeout, nil
}

func dockerPID1Signal(raw string) (unix.Signal, error) {
	if raw == "" {
		return unix.SIGKILL, nil
	}
	if value, err := strconv.ParseUint(raw, 10, 8); err == nil && value > 0 && value <= 64 {
		return unix.Signal(value), nil
	}
	if sig := unix.SignalNum("SIG" + strings.TrimPrefix(strings.ToUpper(raw), "SIG")); sig != 0 {
		return sig, nil
	}
	return 0, fail(400, "invalid container signal")
}

func (s *dockerEngine) signalPID1(ctx context.Context, c *dockerContainer, signal unix.Signal) error {
	if s.node.execTasks == nil {
		return fail(503, "containerd task service is unavailable")
	}
	ctx, cancel := context.WithTimeout(dockerExecContext(ctx), 10*time.Second)
	defer cancel()
	s.mu.Lock()
	if c.Phase != "running" || c.RuntimeID == "" {
		s.mu.Unlock()
		return fail(409, "container is not running")
	}
	// Hold exit publication until the runtime acknowledges this generation's
	// signal, just as the synchronous SIGKILL path does.
	if c.killEventDone != nil {
		s.mu.Unlock()
		return fail(409, "container signal delivery is already in progress")
	}
	id := c.RuntimeID
	done := make(chan struct{})
	c.killEventDone = done
	s.mu.Unlock()
	_, err := s.node.execTasks.Kill(ctx, &tasks.KillRequest{ContainerID: id, Signal: uint32(signal)})
	s.mu.Lock()
	if err == nil {
		s.containerEvent(c, "kill", map[string]string{"signal": strconv.Itoa(int(signal))})
	}
	c.killEventDone = nil
	close(done)
	s.mu.Unlock()
	if status.Code(err) == codes.NotFound || status.Code(err) == codes.FailedPrecondition {
		return fail(409, "container is not running")
	}
	return err
}

// Acquire between lookup and mutation. The exit observer uses s.mu alone so it
// can signal stop completion while this request owns the lifecycle.
func (s *dockerEngine) lockContainerLifecycle(ctx context.Context, c *dockerContainer) (func(), error) {
	s.mu.Lock()
	if c.Config.HostConfig.AutoRemove && !s.namedNetworks[c.NetworkID].secondaryBridge() {
		s.mu.Unlock()
		return nil, nil // Disposable containers keep their existing fast path.
	}
	if c.lifecycle == nil {
		c.lifecycle = make(chan struct{}, 1)
	}
	lifecycle := c.lifecycle
	s.mu.Unlock()

	select {
	case lifecycle <- struct{}{}:
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	release := func() { <-lifecycle }
	if err := ctx.Err(); err != nil {
		release()
		return nil, err
	}
	s.mu.Lock()
	removed := c.removed
	s.mu.Unlock()
	if removed {
		release()
		return nil, fail(404, "container removed")
	}
	return release, nil
}

func (s *dockerEngine) containerLifecycle(w http.ResponseWriter, r *http.Request, c *dockerContainer, op string) error {
	ctx := r.Context()
	q := r.URL.Query()
	var mutate func() error
	switch op {
	case "start":
		mutate = func() error { return s.start(c, false, viewerOf(ctx)) }
	case "kill":
		signal, err := dockerPID1Signal(q.Get("signal"))
		if err != nil {
			return err
		}
		if signal != unix.SIGKILL {
			if q.Has("t") {
				return fail(400, "timeout applies only to container stop")
			}
			mutate = func() error { return s.signalPID1(ctx, c, signal) }
			break
		}
		fallthrough
	case "stop":
		timeout, err := dockerStopTimeout(op, q)
		if err != nil {
			return err
		}
		mutate = func() error { return s.stop(ctx, c, timeout, op) }
	case "restart":
		timeout, err := dockerRestartTimeout(q)
		if err != nil {
			return err
		}
		mutate = func() error { return s.restart(ctx, c, timeout) }
	case "":
		mutate = func() error { return s.remove(ctx, c, truth(q.Get("force"))) }
	default:
		return fail(501, "unsupported container operation: "+op)
	}
	release, err := s.lockContainerLifecycle(ctx, c)
	if err != nil {
		return err
	}
	if release != nil {
		defer release()
	}
	if err := mutate(); err != nil {
		return err
	}
	w.WriteHeader(http.StatusNoContent)
	return nil
}

func (s *dockerEngine) restartable(c *dockerContainer) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	switch {
	case c.removed || c.Phase == "removing":
		return fail(404, "container removed")
	case c.Config.HostConfig.AutoRemove:
		return fail(409, "restart requires a retained container")
	case c.Phase == "dead":
		return fail(409, "container cannot restart from its failed runtime state: "+c.Failure)
	}
	return nil
}

func (s *dockerEngine) restart(ctx context.Context, c *dockerContainer, timeout int64) error {
	if err := s.restartable(c); err != nil {
		return err
	}
	// Complete an accepted restart after client disconnect. Allow the requested
	// grace and a separate minute for CRI teardown (worker cleanup allows 45s).
	stopCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), time.Duration(timeout)*time.Second+time.Minute)
	err := s.stop(stopCtx, c, timeout, "stop")
	cancel()
	if err != nil {
		return fmt.Errorf("stop container before restart: %w", err)
	}
	if err := s.restartable(c); err != nil {
		return err
	}
	return s.start(c, true, viewerOf(ctx))
}
