package main

import (
	"context"
	"errors"
	"io"
	"net"
	"net/netip"
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

// holdTarget accepts connections and keeps each until its client closes.
func holdTarget(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			go func() { io.Copy(io.Discard, c); c.Close() }()
		}
	}()
	return l.Addr().String()
}

func relayFront(t *testing.T, target string, guard relayGuard) (*publishedPort, string) {
	t.Helper()
	front, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	p := &publishedPort{listener: front, cancel: cancel}
	p.relay(ctx, front, target, guard)
	return p, front.Addr().String()
}

func dialHeld(t *testing.T, addr string) net.Conn {
	t.Helper()
	c, err := net.Dial("tcp4", addr)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	return c
}

func closedSoon(c net.Conn) bool {
	c.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	_, err := c.Read(make([]byte, 1))
	var ne net.Error
	return err != nil && !(errors.As(err, &ne) && ne.Timeout())
}

func eventually(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for deadline := time.Now().Add(3 * time.Second); !cond(); time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal(what)
		}
	}
}

// One peer family holds at most its share of the engine-wide gateway relay
// connections, so a single job cannot hold every other job's relays shut.
func TestRelayLimitsEachFamilysShare(t *testing.T) {
	var family atomic.Value
	family.Store("job-a")
	shared := make(chan struct{}, 10)
	families := &familySlots{max: 2}
	p, addr := relayFront(t, holdTarget(t), relayGuard{
		admit:   func(netip.Addr) (string, bool) { return family.Load().(string), true },
		pending: make(chan struct{}, relayPendingAdmissions),
		slots:   make(chan struct{}, 10), shared: shared, families: families,
	})
	defer p.close()
	a1, a2 := dialHeld(t, addr), dialHeld(t, addr)
	if closedSoon(a1) || closedSoon(a2) {
		t.Fatal("a family's connections within its share were closed")
	}
	if !closedSoon(dialHeld(t, addr)) {
		t.Fatal("a family was relayed past its share of the shared limit")
	}
	family.Store("job-b")
	if closedSoon(dialHeld(t, addr)) {
		t.Fatal("another family was refused while the first held its share")
	}
	eventually(t, "the refused connection kept a shared slot", func() bool { return len(shared) == 3 })
	a1.Close()
	eventually(t, "a closed connection's family slot never came back", func() bool { return len(shared) == 2 })
	family.Store("job-a")
	if closedSoon(dialHeld(t, addr)) {
		t.Fatal("a family within its share again was refused")
	}
}

// A peer is admitted before it takes any slot, and at most
// relayPendingAdmissions of a listener's connections wait for the rule (which
// takes the engine's lock) at once: a flood while the lock is held neither
// fills the shared limit nor holds a descriptor for each connection.
func TestRelayAdmitsBeforeTakingSlots(t *testing.T) {
	gate := make(chan struct{})
	var waiting atomic.Int32
	shared := make(chan struct{}, 64)
	p, addr := relayFront(t, holdTarget(t), relayGuard{
		admit: func(netip.Addr) (string, bool) {
			waiting.Add(1)
			defer waiting.Add(-1)
			<-gate
			return "", false
		},
		pending: make(chan struct{}, relayPendingAdmissions),
		slots:   make(chan struct{}, 64), shared: shared, families: &familySlots{max: 64},
	})
	var conns []net.Conn
	for range relayPendingAdmissions + 14 {
		conns = append(conns, dialHeld(t, addr))
	}
	eventually(t, "the rule was never asked", func() bool { return waiting.Load() >= relayPendingAdmissions })
	time.Sleep(200 * time.Millisecond)
	if n := waiting.Load(); n != relayPendingAdmissions || len(shared) != 0 {
		t.Fatalf("%d connections waiting for the rule, %d shared slots held; want %d and none", n, len(shared), relayPendingAdmissions)
	}
	close(gate)
	for _, c := range conns {
		if !closedSoon(c) {
			t.Fatal("a refused peer was relayed")
		}
	}
	p.close()
	if len(shared) != 0 {
		t.Fatalf("refused peers hold %d shared slots", len(shared))
	}
}

// Once one direction of a relayed connection has ended, the other is closed
// after relayHalfCloseIdle without a byte, releasing its slots, while one
// that keeps sending stays open.
func TestRelayClosesAHalfClosedSilentPeer(t *testing.T) {
	old := relayHalfCloseIdle
	relayHalfCloseIdle = 200 * time.Millisecond
	t.Cleanup(func() { relayHalfCloseIdle = old })
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	got := make(chan int, 4)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			// The target ends its side at once and reads what comes.
			go func() {
				c.(*net.TCPConn).CloseWrite()
				n, _ := io.Copy(io.Discard, c)
				c.Close()
				got <- int(n)
			}()
		}
	}()
	slots := make(chan struct{}, 4)
	p, addr := relayFront(t, l.Addr().String(), relayGuard{slots: slots, halfCloseIdle: true})
	defer p.close()

	silent := dialHeld(t, addr)
	eventually(t, "a silent peer held its slot after the target ended its side", func() bool { return len(slots) == 0 })
	if !closedSoon(silent) {
		t.Fatal("the silent peer's connection is still open")
	}
	<-got

	busy := dialHeld(t, addr)
	for range 8 {
		if _, err := busy.Write([]byte("12345678")); err != nil {
			t.Fatalf("a peer that keeps sending was cut: %v", err)
		}
		time.Sleep(100 * time.Millisecond)
	}
	busy.(*net.TCPConn).CloseWrite()
	if n := <-got; n != 64 {
		t.Fatalf("the target got %d of 64 bytes from a peer that kept sending", n)
	}
}

// The Mac-facing relay leaves a half-closed connection open however long the
// service takes to answer: a Mac client that sends its request and ends its
// side (nc -N) gets the reply that comes after relayHalfCloseIdle.
func TestMacFacingRelayWaitsForALateReplyToAHalfClosedRequest(t *testing.T) {
	old := relayHalfCloseIdle
	relayHalfCloseIdle = 100 * time.Millisecond
	t.Cleanup(func() { relayHalfCloseIdle = old })
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
			go func() {
				defer c.Close()
				io.Copy(io.Discard, c) // the whole request, to its end
				time.Sleep(5 * relayHalfCloseIdle)
				c.Write([]byte("late reply"))
			}()
		}
	}()
	p, addr := relayFront(t, l.Addr().String(), macFacingGuard(func(netip.Addr) bool { return true }))
	defer p.close()
	c := dialHeld(t, addr)
	if _, err := c.Write([]byte("job")); err != nil {
		t.Fatal(err)
	}
	c.(*net.TCPConn).CloseWrite()
	c.SetReadDeadline(time.Now().Add(5 * time.Second))
	if got, err := io.ReadAll(c); err != nil || string(got) != "late reply" {
		t.Fatalf("the Mac client got %q, %v: want the reply that came after the idle limit", got, err)
	}
}
