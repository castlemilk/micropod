package main

import (
	"errors"
	"path/filepath"
	"runtime"
	"sync"
	"syscall"
	"testing"
	"time"
)

// launchWorker makes the unshare, every mount after it and the exec on one
// thread, even when its goroutine is pushed toward another thread between the
// calls. Namespaces belong to a thread: an exec (or a mount) from one that
// never unshared ran start.sh in guest init's namespaces, at the real cgroup
// root, whose kernel threads its cgroup step could not move.
func TestLaunchWorkerKeepsItsNamespaceCallsOnOneThread(t *testing.T) {
	var mu sync.Mutex
	var calls []string
	var tids []int
	record := func(name string) {
		mu.Lock()
		defer mu.Unlock()
		calls = append(calls, name)
		tids = append(tids, syscall.Gettid())
	}
	errExec := errors.New("recorded instead of exec")
	sys := workerSyscalls{
		unshare: func(int) error { record("unshare"); return nil },
		mount:   func(_, target, _ string, _ uintptr, _ string) error { record("mount " + target); return nil },
		unmount: func(target string, _ int) error { record("unmount " + target); return nil },
		exec:    func(string, []string, []string) error { record("exec"); return errExec },
	}
	moved := 0
	between := func() {
		tid := syscall.Gettid()
		pushToAnotherThread()
		if syscall.Gettid() != tid {
			moved++
		}
	}
	done := make(chan error, 1)
	// Its own goroutine: launchWorker locks the thread it runs on for good.
	go func() {
		done <- launchWorker(filepath.Join(t.TempDir(), "cgroup.procs"), []string{"/bin/sh", "start.sh"}, sys, between)
	}()
	if err := <-done; !errors.Is(err, errExec) {
		t.Fatalf("launchWorker: %v", err)
	}
	want := []string{"unshare", "mount /", "unmount /sys/fs/cgroup", "mount /sys/fs/cgroup", "exec"}
	if len(calls) != len(want) {
		t.Fatalf("calls %v, want %v", calls, want)
	}
	for i := range want {
		if calls[i] != want[i] {
			t.Fatalf("calls %v, want %v", calls, want)
		}
		if tids[i] != tids[0] {
			t.Fatalf("%s ran on thread %d, the unshare on %d (calls %v on %v; the goroutine moved %d times)", calls[i], tids[i], tids[0], calls, tids, moved)
		}
	}
}

// pushToAnotherThread makes the calling goroutine resume on another thread
// unless it is locked to its own: every P is busy while it sits in a blocking
// system call long enough for the scheduler to hand its P to another thread,
// so on return it waits for any thread to pick it up again.
func pushToAnotherThread() {
	stop := make(chan struct{})
	var wg sync.WaitGroup
	for range runtime.GOMAXPROCS(0) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
				}
			}
		}()
	}
	ts := syscall.NsecToTimespec(int64(30 * time.Millisecond))
	_ = syscall.Nanosleep(&ts, nil)
	close(stop)
	wg.Wait()
}
