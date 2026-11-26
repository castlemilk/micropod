package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fakeDialClock advances only when the dial sleeps; onSleep runs at each new
// time, so a test can make the engine listen between two attempts.
type fakeDialClock struct {
	now     time.Time
	sleeps  int
	onSleep func(now time.Time)
}

func (c *fakeDialClock) Now() time.Time { return c.now }
func (c *fakeDialClock) Sleep(d time.Duration) {
	c.sleeps++
	c.now = c.now.Add(d)
	if c.onSleep != nil {
		c.onSleep(c.now)
	}
}

func shortSocketDir(t *testing.T) string {
	t.Helper()
	// Short: a Unix socket path must stay under 104 bytes on macOS.
	dir, err := os.MkdirTemp("/tmp", "gi-dial")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}

func TestDialEngineSocketConnectsWithinOneShortIntervalOfTheEngineListening(t *testing.T) {
	// The first _ping after a switchover waits here. The engine starts
	// listening at a time no retry lines up with; the dial must connect at
	// its next attempt, and attempts must be close together: a 25 ms retry
	// cost the switchover 12 ms on average. A fake clock, so a loaded
	// machine cannot fail it and the bound is not an average.
	path := filepath.Join(shortSocketDir(t), "docker.sock")
	for _, listenAfter := range []time.Duration{0, 3 * time.Millisecond, 27 * time.Millisecond, 141 * time.Millisecond} {
		clock := &fakeDialClock{now: time.Unix(1000, 0)}
		start := clock.now
		var ln net.Listener
		var listening time.Time
		listen := func(now time.Time) {
			if ln != nil || now.Sub(start) < listenAfter {
				return
			}
			var err error
			if ln, err = net.Listen("unix", path); err != nil {
				t.Fatal(err)
			}
			listening = now
		}
		listen(clock.now)
		clock.onSleep = listen
		c := dialEngineSocket(path, 2*time.Second, engineDialInterval, clock)
		if c == nil {
			t.Fatalf("listening after %v: gave up", listenAfter)
		}
		_ = c.Close()
		if !clock.now.Equal(listening) {
			t.Fatalf("listening after %v: dialled again only %v after it listened", listenAfter, clock.now.Sub(listening))
		}
		// The socket appeared at some point of the sleep that ended at
		// `listening`, so the lag is under one interval.
		if lag := clock.now.Sub(start) - listenAfter; lag < 0 || lag >= 5*time.Millisecond {
			t.Fatalf("listening after %v: connected %v later (%d sleeps)", listenAfter, lag, clock.sleeps)
		}
		_ = ln.Close()
		_ = os.Remove(path)
	}
}

func TestDialEngineSocketGivesUpAfterItsBudget(t *testing.T) {
	clock := &fakeDialClock{now: time.Unix(1000, 0)}
	start := clock.now
	absent := filepath.Join(shortSocketDir(t), "absent.sock")
	if c := dialEngineSocket(absent, 60*time.Millisecond, engineDialInterval, clock); c != nil {
		t.Fatal("connected to a socket nobody listens on")
	}
	if spent := clock.now.Sub(start); spent != 60*time.Millisecond {
		t.Fatalf("gave up after %v, want 60ms", spent)
	}
	if clock.sleeps != 12 {
		t.Fatalf("slept %d times between attempts, want 12 (every 5 ms for 60 ms)", clock.sleeps)
	}
}
