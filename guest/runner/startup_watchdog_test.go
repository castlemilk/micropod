package main

import (
	"bytes"
	"log"
	"strings"
	"sync"
	"testing"
	"time"
)

// captureLog collects what the code under test logs.
func captureLog(t *testing.T) *lockedBuffer {
	t.Helper()
	var b lockedBuffer
	out, flags := log.Writer(), log.Flags()
	log.SetOutput(&b)
	t.Cleanup(func() { log.SetOutput(out); log.SetFlags(flags) })
	return &b
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// A start-up stuck in a step past its budget ends the engine with
// exitStartupTimedOut and a fatal line that names the step, so start.sh
// exits, guest init reports the engine's failure and micropod-vmm exits 4,
// instead of the socket staying closed until the host's readiness timeout.
func TestStartupWatchdogEndsAStuckStartWithTheStep(t *testing.T) {
	logs := captureLog(t)
	exited := make(chan int, 1)
	w := armStartupWatchdog(30*time.Millisecond, func(code int) { exited <- code })
	w.enter("recovering containers")
	select {
	case code := <-exited:
		if code != 4 {
			t.Fatalf("exit status %d, want 4", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("a start-up stuck past its budget did not end the engine")
	}
	got := logs.String()
	for _, want := range []string{"FATAL", "within 30ms", "still recovering containers", "status 4"} {
		if !strings.Contains(got, want) {
			t.Fatalf("fatal log %q lacks %q", got, want)
		}
	}
}

// A start-up that opens its socket in time is never ended.
func TestStartupWatchdogDisarmedInTime(t *testing.T) {
	captureLog(t)
	exited := make(chan int, 1)
	w := armStartupWatchdog(40*time.Millisecond, func(code int) { exited <- code })
	w.enter("waiting for containerd's CRI")
	w.disarm()
	select {
	case code := <-exited:
		t.Fatalf("a disarmed watchdog exited with %d", code)
	case <-time.After(150 * time.Millisecond):
	}
}

// The budget leaves the guest time to stop and report the failure (its stop
// budget is the machine's shutdown timeout, 10 s by default) before the host's
// 2-minute readiness deadline, and covers the whole wait for containerd.
func TestStartupBudgetFitsTheHostDeadline(t *testing.T) {
	const hostReadiness, guestStop, boot = 2 * time.Minute, 10 * time.Second, 5 * time.Second
	if startupBudget+guestStop+boot >= hostReadiness {
		t.Fatalf("start-up budget %v + guest stop %v + boot %v reaches the host's %v", startupBudget, guestStop, boot, hostReadiness)
	}
	if startupBudget <= runtimeWaitBudget {
		t.Fatalf("start-up budget %v does not outlast the wait for containerd (%v)", startupBudget, runtimeWaitBudget)
	}
}
