package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	tasks "github.com/containerd/containerd/api/services/tasks/v1"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

func TestCRIFollowLogNotificationsAndFinalDrain(t *testing.T) {
	path := filepath.Join(t.TempDir(), "job.log")
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		wake, taskExit := make(chan struct{}, 1), make(chan struct{})
		var exited atomic.Bool
		runtime := &followRuntime{response: func(int32) *cri.ContainerStatus {
			if exited.Load() {
				return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_EXITED, FinishedAt: 1, ExitCode: 23}
			}
			return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_RUNNING}
		}}
		var watched string
		var unsubscribed bool
		n := node{
			runtime: runtime,
			tasks: fakeTaskWait(func(ctx context.Context, _ *tasks.WaitRequest) (*tasks.WaitResponse, error) {
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-taskExit:
					return &tasks.WaitResponse{}, nil
				}
			}),
			watchLog: func(path string) (<-chan struct{}, func()) {
				watched = path
				return wake, func() { unsubscribed = true }
			},
		}
		var output string
		var exit int32
		var followErr error
		go func() {
			exit, _, followErr = n.follow(ctx, "runtime", criLogSource{path: path}, func(stream string, b []byte) error {
				output += stream + ":" + string(b)
				return nil
			}, true)
		}()
		synctest.Wait()
		if watched != path || runtime.checks.Load() != 1 {
			t.Fatalf("initial watch=%q, status calls=%d", watched, runtime.checks.Load())
		}
		file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if _, err := file.WriteString("t stdout F live\nt stderr P split"); err != nil {
			t.Fatal(err)
		}
		time.Sleep(time.Second)
		synctest.Wait()
		if output != "" || runtime.checks.Load() != 1 {
			t.Fatalf("unexpected idle reads: output=%q status=%d", output, runtime.checks.Load())
		}
		wake <- struct{}{}
		synctest.Wait()
		if output != "stdout:live\n" {
			t.Fatalf("notification did not stream the complete record: %q", output)
		}
		if _, err := file.WriteString(" record\nt stdout F final\n"); err != nil {
			t.Fatal(err)
		}
		// Deliberately send no log notification for the final bytes.
		exited.Store(true)
		close(taskExit)
		synctest.Wait()
		if output != "stdout:live\nstderr:split recordstdout:final\n" ||
			exit != 23 || followErr != nil || !unsubscribed || runtime.checks.Load() != 2 {
			t.Fatalf("final drain: output=%q exit=%d err=%v unsubscribed=%t calls=%d",
				output, exit, followErr, unsubscribed, runtime.checks.Load())
		}
	})
}

func TestCRIFollowLogNotificationsFallBackToPolling(t *testing.T) {
	path := filepath.Join(t.TempDir(), "job.log")
	if err := os.WriteFile(path, []byte("t stdout F before watch\n"), 0600); err != nil {
		t.Fatal(err)
	}
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		wake := make(chan struct{}, 1)
		runtime := &followRuntime{response: func(int32) *cri.ContainerStatus {
			return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_RUNNING}
		}}
		n := node{
			runtime: runtime,
			tasks: fakeTaskWait(func(ctx context.Context, _ *tasks.WaitRequest) (*tasks.WaitResponse, error) {
				<-ctx.Done()
				return nil, ctx.Err()
			}),
			watchLog: func(string) (<-chan struct{}, func()) { return wake, nil },
		}
		var output string
		var followErr error
		go func() {
			_, _, followErr = n.follow(ctx, "runtime", criLogSource{path: path}, func(_ string, b []byte) error {
				output += string(b)
				return nil
			}, true)
		}()
		synctest.Wait()
		if output != "before watch\n" {
			t.Fatalf("initial drain = %q", output)
		}
		close(wake)
		synctest.Wait()
		file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0600)
		if err != nil {
			t.Fatal(err)
		}
		defer file.Close()
		if _, err := file.WriteString("t stderr F after failure\n"); err != nil {
			t.Fatal(err)
		}
		time.Sleep(250 * time.Millisecond)
		synctest.Wait()
		if output != "before watch\nafter failure\n" || runtime.checks.Load() != 1 {
			t.Fatalf("fallback: output=%q status=%d", output, runtime.checks.Load())
		}
		cancel()
		synctest.Wait()
		if !errors.Is(followErr, context.Canceled) {
			t.Fatalf("fallback cancellation: %v", followErr)
		}
	})
}

func TestCRIFollowLogNotificationsDoNotPostponeStatusPolling(t *testing.T) {
	path := filepath.Join(t.TempDir(), "job.log")
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		wake, taskExit := make(chan struct{}, 1), make(chan struct{})
		runtime := &followRuntime{response: func(check int32) *cri.ContainerStatus {
			if check == 3 {
				return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_EXITED, FinishedAt: 1}
			}
			return &cri.ContainerStatus{State: cri.ContainerState_CONTAINER_RUNNING}
		}}
		n := node{
			runtime: runtime,
			tasks: fakeTaskWait(func(ctx context.Context, _ *tasks.WaitRequest) (*tasks.WaitResponse, error) {
				select {
				case <-ctx.Done():
					return nil, ctx.Err()
				case <-taskExit:
					return &tasks.WaitResponse{}, nil
				}
			}),
			watchLog: func(string) (<-chan struct{}, func()) { return wake, nil },
		}
		finished := false
		var followErr error
		go func() {
			_, _, followErr = n.follow(ctx, "runtime", criLogSource{path: path}, func(string, []byte) error { return nil }, true)
			finished = true
		}()
		synctest.Wait()
		close(taskExit)
		synctest.Wait()
		if runtime.checks.Load() != 2 {
			t.Fatal("task exit did not immediately recheck CRI")
		}
		for range 5 {
			wake <- struct{}{}
			synctest.Wait()
			time.Sleep(time.Millisecond)
		}
		synctest.Wait()
		if !finished || followErr != nil || runtime.checks.Load() != 3 {
			t.Fatalf("status polling delayed by log signals: finished=%t err=%v checks=%d",
				finished, followErr, runtime.checks.Load())
		}
	})
}
