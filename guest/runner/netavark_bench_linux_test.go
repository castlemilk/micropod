package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

// Opt-in operator benchmark in a disposable Linux VM. Both implementations join
// the same warm, isolated bridge. CRI, DNS, IP allocation and namespace creation
// are outside the timed interval; the production attach code runs unmodified.
func TestNetavarkBridgeFanout(t *testing.T) {
	tool, probe := os.Getenv("MICROPOD_BENCH_NETAVARK"), os.Getenv("MICROPOD_BENCH_NETWORK_PROBE")
	if tool == "" || probe == "" {
		t.Skip("requires standalone Netavark and netbench in a disposable VM")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Minute)
	defer cancel()
	prefix := netip.MustParsePrefix("10.97.201.0/24")
	if !routeAvailable(prefix) {
		t.Fatal("benchmark subnet in use")
	}
	nw := &workerNetwork{ID: engineID(), Name: "bench", Driver: "bridge", Subnet: prefix, MTU: 1500, Internal: true}
	if err := nw.setup(ctx); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := nw.teardown(); err != nil {
			t.Error(err)
		}
	})
	for round := 1; round <= 5; round++ {
		order := []string{"native", "netavark"}
		if round%2 == 0 {
			slices.Reverse(order)
		}
		for _, count := range []int{16, 32} {
			for _, backend := range order {
				t.Run(fmt.Sprintf("%d/%d/%s", round, count, backend), func(t *testing.T) {
					oneNetworkWave(t, ctx, nw, tool, probe, backend, count, round)
				})
				if t.Failed() {
					return
				}
			}
		}
	}
}

type benchEndpoint struct {
	ns      *os.File
	handle  *netlink.Handle
	id, ip  string
	request []byte
}

func makeBenchEndpoint(n *workerNetwork, ip netip.Addr) (*benchEndpoint, error) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	orig, err := netns.Get()
	if err != nil {
		return nil, err
	}
	defer orig.Close()
	inner, err := netns.New()
	if err != nil {
		return nil, err
	}
	if err = netns.Set(orig); err != nil {
		panic(err)
	}
	f := os.NewFile(uintptr(inner), "bench-net")
	h, err := netlink.NewHandleAt(inner, unix.NETLINK_ROUTE)
	if err != nil {
		f.Close()
		return nil, err
	}
	e := &benchEndpoint{ns: f, handle: h, id: engineID(), ip: ip.String()}
	cfg := map[string]any{"container_id": e.id, "container_name": e.id, "networks": map[string]any{n.Name: map[string]any{"interface_name": "eth0", "static_ips": []string{e.ip}}},
		"network_info": map[string]any{n.Name: map[string]any{"name": n.Name, "id": n.ID, "driver": "bridge", "network_interface": n.linkName(), "internal": true, "dns_enabled": false, "ipv6_enabled": false, "options": map[string]string{"mode": "unmanaged", "mtu": strconv.Itoa(n.MTU)}, "subnets": []map[string]string{{"subnet": n.Subnet.String(), "gateway": n.gateway().String()}}}}}
	e.request, err = json.Marshal(cfg)
	return e, err
}
func (e *benchEndpoint) check() error {
	l, err := e.handle.LinkByName("eth0")
	if err != nil {
		return err
	}
	addrs, err := e.handle.AddrList(l, netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	if len(addrs) != 1 || !addrs[0].IP.Equal(net.ParseIP(e.ip)) {
		return fmt.Errorf("incorrect endpoint address for %s", e.ip)
	}
	routes, err := e.handle.RouteList(l, netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	for _, r := range routes {
		if r.Dst == nil || r.Dst.String() == "0.0.0.0/0" {
			return errors.New("unexpected external route")
		}
	}
	return nil
}
func (e *benchEndpoint) apply(ctx context.Context, n *workerNetwork, tool, backend, op, state string) error {
	if backend == "native" {
		if op == "setup" {
			return n.attach(e.handle, int(e.ns.Fd()), e.id, e.ip)
		}
		l, err := e.handle.LinkByName("eth0")
		if err != nil {
			return err
		}
		return e.handle.LinkDel(l)
	}
	c := exec.CommandContext(ctx, tool, "--config", state, "--firewall-driver", "none", op, "/proc/self/fd/3")
	c.Stdin = bytes.NewReader(e.request)
	c.ExtraFiles = []*os.File{e.ns}
	if out, err := c.CombinedOutput(); err != nil {
		return fmt.Errorf("netavark %s: %w: %.1000s", op, err, out)
	}
	return nil
}
func (e *benchEndpoint) run(ctx context.Context, probe string, args ...string) *exec.Cmd {
	c := exec.CommandContext(ctx, "nsenter", append([]string{"--net=/proc/self/fd/3", "--", probe}, args...)...)
	c.ExtraFiles = []*os.File{e.ns}
	return c
}
func oneNetworkWave(t *testing.T, ctx context.Context, n *workerNetwork, tool, probe, backend string, count, round int) {
	t.Helper()
	endpoints := make([]*benchEndpoint, 0, count)
	for i := range count {
		ep, err := makeBenchEndpoint(n, netip.AddrFrom4([4]byte{10, 97, 201, byte(2 + i)}))
		if err != nil {
			t.Fatal(err)
		}
		defer ep.ns.Close()
		defer ep.handle.Close()
		endpoints = append(endpoints, ep)
	}
	state := t.TempDir()
	receipt := map[string]any{"round": round, "clients": count, "backend": backend}
	for _, op := range []string{"setup", "teardown"} {
		var group sync.WaitGroup
		gate := make(chan struct{})
		errs := make([]error, count)
		elapsed := make([]int64, count)
		for i, e := range endpoints {
			group.Go(func() {
				<-gate
				start := time.Now()
				errs[i] = e.apply(ctx, n, tool, backend, op, state)
				elapsed[i] = time.Since(start).Microseconds()
			})
		}
		start := time.Now()
		close(gate)
		group.Wait()
		receipt[op+"_wall_us"] = time.Since(start).Microseconds()
		for _, err := range errs {
			if err != nil {
				t.Fatal(err)
			}
		}
		slices.Sort(elapsed)
		receipt[op+"_p95_us"] = elapsed[(count*95-1)/100]
		if op == "setup" {
			for _, e := range endpoints {
				if err := e.check(); err != nil {
					t.Fatal(err)
				}
			}
			srv := endpoints[0].run(ctx, probe, "-listen", endpoints[0].ip+":8080")
			if err := srv.Start(); err != nil {
				t.Fatal(err)
			}
			func() {
				defer func() { _ = srv.Process.Kill(); _ = srv.Wait() }()
				addr := "http://" + endpoints[0].ip + ":8080"
				var out []byte
				var err error
				for i := 0; i < 20; i++ {
					out, err = endpoints[1].run(ctx, probe, "-url", addr, "-streams", strconv.Itoa(count)).CombinedOutput()
					if err == nil {
						break
					}
					time.Sleep(10 * time.Millisecond)
				}
				if err != nil {
					t.Fatalf("probe: %v: %s", err, out)
				}
				var traffic map[string]any
				if err := json.Unmarshal(out, &traffic); err != nil {
					t.Fatal(err)
				}
				receipt["traffic"] = traffic
			}()
		} else {
			for _, e := range endpoints {
				if _, err := e.handle.LinkByName("eth0"); !errors.As(err, new(netlink.LinkNotFoundError)) {
					t.Fatalf("endpoint persisted after %s teardown", backend)
				}
			}
		}
	}
	line, _ := json.Marshal(receipt)
	t.Log("NETWORK_RECEIPT " + string(line))
}
