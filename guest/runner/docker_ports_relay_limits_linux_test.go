package main

import (
	"context"
	"errors"
	"io"
	"net"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// A relay a container can reach holds a bounded number of connections and
// keeps serving through a descriptor shortage.

// A relay holds at most its listener's and the shared limit of connections;
// one over either is closed at once, and a slot comes back when it closes.
func TestRelayLimitsConnections(t *testing.T) {
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			// Hold each connection open until its client closes.
			go func() { io.Copy(io.Discard, c); c.Close() }()
		}
	}()
	front, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	p := &publishedPort{listener: front, cancel: cancel}
	slots, shared := make(chan struct{}, 2), make(chan struct{}, 3)
	p.relay(ctx, front, l.Addr().String(), relayGuard{slots: slots, shared: shared})
	defer p.close()
	open := func() net.Conn {
		c, err := net.Dial("tcp4", front.Addr().String())
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { c.Close() })
		return c
	}
	closedAtOnce := func(c net.Conn) bool {
		c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		_, err := c.Read(make([]byte, 1))
		var ne net.Error
		return err != nil && !(errors.As(err, &ne) && ne.Timeout())
	}
	waitFor := func(what string, cond func() bool) {
		t.Helper()
		for deadline := time.Now().Add(3 * time.Second); !cond(); time.Sleep(10 * time.Millisecond) {
			if time.Now().After(deadline) {
				t.Fatal(what)
			}
		}
	}
	a, b := open(), open()
	if closedAtOnce(a) || closedAtOnce(b) {
		t.Fatal("a connection within the limits was closed")
	}
	if !closedAtOnce(open()) {
		t.Fatal("a connection over the listener's limit was relayed")
	}
	if len(slots) != 2 || len(shared) != 2 {
		t.Fatalf("slots in use %d/%d, want 2/2", len(slots), len(shared))
	}
	a.Close()
	waitFor("a closed connection's slot never came back", func() bool { return len(slots) == 1 && len(shared) == 1 })
	shared <- struct{}{} // other relays hold the rest of the engine-wide limit
	shared <- struct{}{}
	if !closedAtOnce(open()) {
		t.Fatal("a connection over the engine-wide limit was relayed")
	}
	waitFor("a refused connection kept its listener slot", func() bool { return len(slots) == 1 })
	<-shared
	if closedAtOnce(open()) {
		t.Fatal("a connection within the limits again was closed")
	}
	_ = b
}

// flakyAcceptor fails its first accepts as a process out of descriptors does.
type flakyAcceptor struct {
	*net.TCPListener
	failures atomic.Int32
}

func (f *flakyAcceptor) AcceptTCP() (*net.TCPConn, error) {
	if f.failures.Add(-1) >= 0 {
		return nil, &net.OpError{Op: "accept", Net: "tcp", Err: syscall.EMFILE}
	}
	return f.TCPListener.AcceptTCP()
}

// An accept that fails while the listener is open does not end the relay.
func TestRelaySurvivesAcceptErrors(t *testing.T) {
	target, _ := echoTarget(t)
	front, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	flaky := &flakyAcceptor{TCPListener: front}
	flaky.failures.Store(5)
	ctx, cancel := context.WithCancel(context.Background())
	p := &publishedPort{listener: front, cancel: cancel}
	p.relay(ctx, flaky, target, relayGuard{})
	defer p.close()
	if got := roundTrip(t, front.Addr().String()); got != "echo:hello" {
		t.Fatalf("after accept errors the relay gave %q", got)
	}
}
