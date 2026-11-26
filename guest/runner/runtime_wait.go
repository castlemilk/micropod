package main

import (
	"context"
	"fmt"
	"time"
)

// The Docker API engine starts beside containerd (ci/runner/start.sh) and
// waits for its CRI here, before it recovers anything or opens its socket.
// start.sh used to poll `job status` every 50 ms and start the engine only
// then: the first _ping after a boot or a payload switchover waited 25 ms
// for the poll on average, and the engine's own start-up (a cold exec of
// this binary from the tools share) followed instead of overlapping
// containerd's.
const (
	runtimeWaitInterval = 5 * time.Millisecond
	// What start.sh's poll allowed: 1200 attempts 50 ms apart.
	runtimeWaitBudget = 60 * time.Second
)

// waitClock is the time a wait sees; tests replace it.
type waitClock interface {
	Now() time.Time
	Sleep(time.Duration)
}

type systemClock struct{}

func (systemClock) Now() time.Time        { return time.Now() }
func (systemClock) Sleep(d time.Duration) { time.Sleep(d) }

// awaitRuntime calls ready until it succeeds, every interval, for at most
// budget. Once the budget is spent it returns ready's last error; when ctx
// ends, ctx's.
func awaitRuntime(ctx context.Context, clock waitClock, interval, budget time.Duration, ready func(context.Context) error) error {
	deadline := clock.Now().Add(budget)
	for {
		err := ready(ctx)
		if err == nil {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if !clock.Now().Before(deadline) {
			return fmt.Errorf("containerd was not ready after %v: %w", budget, err)
		}
		clock.Sleep(interval)
	}
}
