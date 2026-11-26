package main

import (
	"log"
	"sync"
	"time"
)

// The Docker API engine's start-up, from its start to the open socket, is
// bounded: the wait for containerd's CRI (runtimeWaitBudget of it at most),
// then the recovery of what the previous boot left (interrupted jobs,
// networks, containers, probes, the shared caches' dirty marks). `job
// recover` ran the job part under a 5-minute bound before the engine took
// recovery over; since then nothing bounded it, so a recovery that hung kept
// the socket closed until the host gave up on the boot ("the Docker API did
// not answer within 2m0s", HVFSupervisorPolicy.readinessTimeout), a timeout
// that names nothing, and relaunched into the same hang.
const (
	// startupBudget is short of the host's 2-minute readiness deadline by
	// what the guest needs after the engine exits: start.sh exits with its
	// status, guest init stops what is left within its stop budget (the
	// machine's shutdown timeout, 10 s by default), syncs and resets, and
	// micropod-vmm exits with status 4 ("guest init or the container engine
	// failed") before the host's own timeout fires.
	startupBudget = 90 * time.Second
	// exitStartupTimedOut is the engine's exit status when its start-up
	// outlasts startupBudget; guest init reports "engine-exited status=4".
	exitStartupTimedOut = 4
)

// startupWatchdog exits the process when its start-up outlasts the budget,
// naming the step it was stuck in. It does not cancel the steps: one that
// hangs in a system call or on a lock would not notice, and an exit at the
// deadline is the same exit whichever step it was.
type startupWatchdog struct {
	mu    sync.Mutex
	step  string
	done  bool
	timer *time.Timer
}

// armStartupWatchdog starts the clock; exit is os.Exit outside tests.
func armStartupWatchdog(budget time.Duration, exit func(int)) *startupWatchdog {
	w := &startupWatchdog{step: "starting"}
	w.timer = time.AfterFunc(budget, func() {
		w.mu.Lock()
		if w.done {
			w.mu.Unlock()
			return
		}
		step := w.step
		w.mu.Unlock()
		log.Printf("FATAL: the engine did not open its socket within %v of starting: still %s; exiting with status %d so the machine reports a guest engine failure", budget, step, exitStartupTimedOut)
		exit(exitStartupTimedOut)
	})
	return w
}

// enter names the step start-up is in now.
func (w *startupWatchdog) enter(step string) {
	w.mu.Lock()
	w.step = step
	w.mu.Unlock()
}

// disarm ends the watch: the socket is open (or start-up failed on its own).
func (w *startupWatchdog) disarm() {
	w.mu.Lock()
	w.done = true
	w.mu.Unlock()
	w.timer.Stop()
}
