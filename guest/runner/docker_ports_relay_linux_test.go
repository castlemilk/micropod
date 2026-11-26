package main

import (
	"context"
	"io"
	"net"
	"net/netip"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// The gateway relay serves a published port only to the containers that
// could reach it anyway or belong to the same job.

func echoTarget(t *testing.T) (addr string, accepted *atomic.Int32) {
	t.Helper()
	l, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	accepted = new(atomic.Int32)
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			accepted.Add(1)
			go func() {
				defer c.Close()
				buf := make([]byte, 5)
				n, _ := io.ReadFull(c, buf)
				c.Write(append([]byte("echo:"), buf[:n]...))
			}()
		}
	}()
	return l.Addr().String(), accepted
}

func freePort(t *testing.T) uint16 {
	t.Helper()
	probe, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	return uint16(probe.Addr().(*net.TCPAddr).Port)
}

// roundTrip sends hello and returns what comes back before EOF or 2 s.
func roundTrip(t *testing.T, addr string) string {
	t.Helper()
	c, err := net.DialTimeout("tcp4", addr, 2*time.Second)
	if err != nil {
		return "dial: " + err.Error()
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	c.Write([]byte("hello"))
	got, _ := io.ReadAll(c)
	return string(got)
}

// A peer the rule refuses is closed before anything is dialed.
func TestGatewayRelayAdmitsOnlyWhatTheRuleAdmits(t *testing.T) {
	target, accepted := echoTarget(t)
	port := freePort(t)
	var admit atomic.Bool
	var asked atomic.Value
	p, err := openGatewayRelay(context.Background(), "127.0.0.1", port, target, func(peer netip.Addr) bool {
		asked.Store(peer)
		return admit.Load()
	})
	if err != nil {
		t.Fatal(err)
	}
	defer p.close()
	addr := net.JoinHostPort("127.0.0.1", strconv.Itoa(int(port)))
	if got := roundTrip(t, addr); got != "" || accepted.Load() != 0 {
		t.Fatalf("a refused peer got %q (target accepted %d)", got, accepted.Load())
	}
	if peer, _ := asked.Load().(netip.Addr); peer != netip.MustParseAddr("127.0.0.1") {
		t.Fatalf("the rule was asked about %v, want the peer's address", peer)
	}
	admit.Store(true)
	if got := roundTrip(t, addr); got != "echo:hello" {
		t.Fatalf("an admitted peer got %q", got)
	}
}

// Who a published port's gateway relay serves: a container on one of the
// target's networks, or one of the target's job (its delegated socket's
// owner and what that created), on any network; no other container, and no
// address that is no running container's, except the Mac at the Mac-facing
// relay.
func TestRelayAdmitsTheTargetsNetworkAndJob(t *testing.T) {
	id := func(c byte) string { return strings.Repeat(string(c), 64) }
	tcNet, jobNet, otherNet := id('1'), id('2'), id('3')
	mk := func(id, createdBy, network, ip string, secondary ...dockerSecondaryEndpoint) *dockerContainer {
		return &dockerContainer{IP: ip, dockerRecord: dockerRecord{ID: id, Phase: "running", CreatedBy: createdBy, NetworkID: network, SecondaryNetworks: secondary}}
	}
	job := mk(id('a'), "", "", "10.88.0.10")            // trusted step with the socket, default network
	postgres := mk(id('b'), job.ID, tcNet, "10.90.1.2") // its sibling on a network it made
	ryuk := mk(id('c'), job.ID, "", "10.88.0.12")       // its reaper, default network
	untrusted := mk(id('d'), "", "", "10.88.0.13")      // another job, default network
	foreign := mk(id('e'), "", otherNet, "10.90.3.2")   // another job, its own network
	member := mk(id('f'), "", tcNet, "10.90.1.3")       // a host container on the sibling's network
	service := mk(id('9'), "", jobNet, "10.90.2.2")     // a host service on the job's network
	step := mk(id('8'), "", "", "10.88.0.14", dockerSecondaryEndpoint{NetworkID: jobNet, IP: "10.90.2.3"})
	stopped := mk(id('7'), job.ID, "", "10.88.0.15")
	stopped.Phase = "exited"
	s := &dockerEngine{containers: map[string]*dockerContainer{}}
	for _, c := range []*dockerContainer{job, postgres, ryuk, untrusted, foreign, member, service, step, stopped} {
		s.containers[c.ID] = c
	}
	for _, tc := range []struct {
		name   string
		target *dockerContainer
		peer   string
		mac    bool
		want   bool
	}{
		{"the job reaches its sibling on another network", postgres, "10.88.0.10", false, true},
		{"the job reaches its reaper", ryuk, "10.88.0.10", false, true},
		{"a sibling reaches the job's reaper", ryuk, "10.90.1.2", false, true},
		{"the target reaches itself", postgres, "10.90.1.2", false, true},
		{"another job on the default network: not the sibling", postgres, "10.88.0.13", false, false},
		{"another job on the default network: the reaper it could dial anyway", ryuk, "10.88.0.13", false, true},
		{"another job's network: not the sibling", postgres, "10.90.3.2", false, false},
		{"another job's network: not the reaper", ryuk, "10.90.3.2", false, false},
		{"a host container on the sibling's network", postgres, "10.90.1.3", false, true},
		{"a step reaches its job's service by its secondary network", service, "10.90.2.3", false, true},
		{"a step reaches its job's service from its default address", service, "10.88.0.14", false, true},
		{"the default network does not reach a job network's service", service, "10.88.0.13", false, false},
		{"a stopped container's address is no one's", ryuk, "10.88.0.15", false, false},
		{"an address that is no container's", ryuk, "10.88.0.99", false, false},
		{"the engine's own address", ryuk, "10.88.0.1", false, false},
		{"the Mac at the Mac-facing relay", postgres, "192.168.64.1", true, true},
		{"a foreign container at the Mac-facing relay", postgres, "10.90.3.2", true, false},
	} {
		if got := s.relayAdmits(tc.target, tc.mac)(netip.MustParseAddr(tc.peer)); got != tc.want {
			t.Errorf("%s: admitted %v, want %v", tc.name, got, tc.want)
		}
	}
}

// A published port is relayed at the default gateway, where Testcontainers
// dials, whatever network its container is on, and at a named network's own.
func TestRelayGatewaysIncludeTheDefaultGateway(t *testing.T) {
	old := defaultGateway
	t.Cleanup(func() { defaultGateway = old })
	defaultGateway = func() string { return "10.88.0.1" }
	named := &workerNetwork{Subnet: netip.MustParsePrefix("10.90.4.0/24")}
	if got := relayGateways(named); !slices.Equal(got, []string{"10.88.0.1", "10.90.4.1"}) {
		t.Fatalf("named network: %v", got)
	}
	if got := relayGateways(nil); !slices.Equal(got, []string{"10.88.0.1"}) {
		t.Fatalf("default network: %v", got)
	}
	defaultGateway = func() string { return "" }
	if got := relayGateways(named); !slices.Equal(got, []string{"10.90.4.1"}) {
		t.Fatalf("no default bridge yet: %v", got)
	}
}
