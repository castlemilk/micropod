package main

import (
	"net"
	"time"
)

// A host connection bridged to an engine socket waits this long for the
// engine to listen (it may arrive while the guest is still booting), retrying
// every engineDialInterval. The interval bounds how long after the engine's
// socket appears the first such connection, typically the first _ping after a
// boot or a payload switchover, is served: it was 25 ms, which cost the
// switchover 12 ms on average.
const (
	engineDialBudget   = 2500 * time.Millisecond
	engineDialInterval = 5 * time.Millisecond
)

// dialClock is the time a dial retry sees; tests replace it.
type dialClock interface {
	Now() time.Time
	Sleep(time.Duration)
}

type systemDialClock struct{}

func (systemDialClock) Now() time.Time        { return time.Now() }
func (systemDialClock) Sleep(d time.Duration) { time.Sleep(d) }

// dialEngineSocket connects to the engine's Unix socket at path, retrying
// within budget while it does not accept. Nil once the budget is spent.
func dialEngineSocket(path string, budget, interval time.Duration, clock dialClock) *net.UnixConn {
	deadline := clock.Now().Add(budget)
	for {
		c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
		if err == nil {
			return c
		}
		if !clock.Now().Before(deadline) {
			return nil
		}
		clock.Sleep(interval)
	}
}
