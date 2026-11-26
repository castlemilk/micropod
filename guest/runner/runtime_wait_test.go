package main

import (
	"context"
	"errors"
	"testing"
	"time"
)

// fakeWaitClock advances only when the code under test sleeps.
type fakeWaitClock struct {
	now    time.Time
	sleeps []time.Duration
}

func (c *fakeWaitClock) Now() time.Time { return c.now }
func (c *fakeWaitClock) Sleep(d time.Duration) {
	c.sleeps = append(c.sleeps, d)
	c.now = c.now.Add(d)
}

func TestAwaitRuntimeNoticesReadinessWithinOneShortInterval(t *testing.T) {
	// containerd becomes ready at a time no poll lines up with; the wait
	// must notice it within one interval, and that interval must be short:
	// start.sh's 50 ms poll cost every boot 25 ms on average.
	for _, readyAfter := range []time.Duration{0, 3 * time.Millisecond, 77 * time.Millisecond, 126 * time.Millisecond} {
		clock := &fakeWaitClock{now: time.Unix(1000, 0)}
		start := clock.now
		polls := 0
		err := awaitRuntime(context.Background(), clock, runtimeWaitInterval, runtimeWaitBudget, func(context.Context) error {
			polls++
			if clock.now.Sub(start) < readyAfter {
				return errors.New("containerd is not listening")
			}
			return nil
		})
		if err != nil {
			t.Fatalf("ready after %v: %v", readyAfter, err)
		}
		if lag := clock.now.Sub(start) - readyAfter; lag < 0 || lag >= 5*time.Millisecond {
			t.Fatalf("ready after %v: noticed %v later (%d polls, sleeps %v)", readyAfter, lag, polls, clock.sleeps)
		}
		// One poll at once, then one per interval until the first at or
		// after readyAfter.
		if want := int((readyAfter+runtimeWaitInterval-1)/runtimeWaitInterval) + 1; polls != want {
			t.Fatalf("ready after %v: %d polls, want %d", readyAfter, polls, want)
		}
	}
}

func TestAwaitRuntimeGivesUpAfterItsBudgetWithTheLastError(t *testing.T) {
	clock := &fakeWaitClock{now: time.Unix(1000, 0)}
	start := clock.now
	last := errors.New("CRI runtime or network is not ready")
	err := awaitRuntime(context.Background(), clock, runtimeWaitInterval, 60*time.Millisecond, func(context.Context) error { return last })
	if !errors.Is(err, last) {
		t.Fatalf("got %v, want the last readiness error", err)
	}
	if spent := clock.now.Sub(start); spent < 60*time.Millisecond || spent > 65*time.Millisecond {
		t.Fatalf("gave up after %v of waiting, want 60ms", spent)
	}
	for _, d := range clock.sleeps {
		if d != runtimeWaitInterval {
			t.Fatalf("slept %v between polls", clock.sleeps)
		}
	}
}

func TestAwaitRuntimeStopsWhenItsContextEnds(t *testing.T) {
	clock := &fakeWaitClock{now: time.Unix(1000, 0)}
	ctx, cancel := context.WithCancel(context.Background())
	polls := 0
	err := awaitRuntime(ctx, clock, runtimeWaitInterval, runtimeWaitBudget, func(context.Context) error {
		if polls++; polls == 3 {
			cancel()
		}
		return errors.New("not ready")
	})
	if !errors.Is(err, context.Canceled) || polls != 3 {
		t.Fatalf("got %v after %d polls", err, polls)
	}
}
