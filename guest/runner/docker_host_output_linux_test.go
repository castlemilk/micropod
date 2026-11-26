package main

import (
	"context"
	"errors"
	"net"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

// hostOutputNet is a throwaway machine namespace with one container
// network: its bridge (named as a named network's is) holds the gateway
// address, and a container namespace on it listens at its own address. The
// calling goroutine stays locked in the machine namespace until cleanup.
type hostOutputNet struct {
	target string
}

func newHostOutputNet(t *testing.T) hostOutputNet {
	t.Helper()
	needRoot(t)
	for _, tool := range []string{"iptables", "iptables-restore"} {
		if _, err := exec.LookPath(tool); err != nil {
			t.Skipf("needs %s: %v", tool, err)
		}
	}
	runtime.LockOSThread()
	orig, err := os.Open("/proc/thread-self/ns/net")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := unix.Setns(int(orig.Fd()), unix.CLONE_NEWNET); err != nil {
			t.Errorf("back to the test's namespace: %v", err) // leave the thread locked: it is not reusable
			return
		}
		orig.Close()
		runtime.UnlockOSThread()
	})
	nsOf := func() *os.File {
		if err := unix.Unshare(unix.CLONE_NEWNET); err != nil {
			t.Fatal(err)
		}
		f, err := os.Open("/proc/thread-self/ns/net")
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { f.Close() })
		lo, err := netlink.LinkByName("lo")
		if err == nil {
			err = netlink.LinkSetUp(lo)
		}
		if err != nil {
			t.Fatal(err)
		}
		return f
	}
	container := nsOf()
	machine := nsOf()
	bridge := &netlink.Bridge{LinkAttrs: netlink.LinkAttrs{Name: "mpb0123456789"}}
	if err := netlink.LinkAdd(bridge); err != nil {
		t.Fatal(err)
	}
	gw, _ := netlink.ParseAddr("10.250.0.1/24")
	if err := netlink.AddrAdd(bridge, gw); err != nil {
		t.Fatal(err)
	}
	veth := &netlink.Veth{LinkAttrs: netlink.LinkAttrs{Name: "mpvtest", MasterIndex: bridge.Index}, PeerName: "eth0", PeerNamespace: netlink.NsFd(int(container.Fd()))}
	if err := netlink.LinkAdd(veth); err != nil {
		t.Fatal(err)
	}
	for _, l := range []netlink.Link{bridge, veth} {
		if err := netlink.LinkSetUp(l); err != nil {
			t.Fatal(err)
		}
	}
	pod, err := netlink.NewHandleAt(netns.NsHandle(container.Fd()), unix.NETLINK_ROUTE)
	if err != nil {
		t.Fatal(err)
	}
	defer pod.Close()
	eth0, err := pod.LinkByName("eth0")
	if err != nil {
		t.Fatal(err)
	}
	addr, _ := netlink.ParseAddr("10.250.0.2/24")
	if err := pod.AddrAdd(eth0, addr); err == nil {
		err = pod.LinkSetUp(eth0)
	}
	if err != nil {
		t.Fatal(err)
	}
	// The container's service: a listener made in its namespace.
	if err := unix.Setns(int(container.Fd()), unix.CLONE_NEWNET); err != nil {
		t.Fatal(err)
	}
	l, lerr := net.Listen("tcp4", "10.250.0.2:0")
	if err := unix.Setns(int(machine.Fd()), unix.CLONE_NEWNET); err != nil {
		t.Fatal(err)
	}
	if lerr != nil {
		t.Fatal(lerr)
	}
	t.Cleanup(func() { l.Close() })
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Write([]byte("data of another job"))
			c.Close()
		}
	}()
	return hostOutputNet{target: l.Addr().String()}
}

// The machine's own connection into a container network (a build's ADD URL,
// a pull, a registry probe) is refused at once; the engine's relays, whose
// rule decided the peer, still reach the container.
func TestTheMachineDoesNotConnectIntoContainerNetworks(t *testing.T) {
	n := newHostOutputNet(t)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	if err := guardHostOutput(ctx); err != nil {
		t.Fatal(err)
	}
	// Installing again (an engine restart) adds nothing.
	if err := guardHostOutput(ctx); err != nil {
		t.Fatal(err)
	}
	read := func(d net.Dialer) (string, error) {
		c, err := d.DialContext(ctx, "tcp4", n.target)
		if err != nil {
			return "", err
		}
		defer c.Close()
		c.SetReadDeadline(time.Now().Add(5 * time.Second))
		b := make([]byte, 64)
		k, err := c.Read(b)
		return string(b[:k]), err
	}
	start := time.Now()
	if got, err := read(net.Dialer{Timeout: 5 * time.Second}); err == nil || !errors.Is(err, unix.EHOSTUNREACH) {
		t.Fatalf("the machine's own connection read %q, %v: want it refused (no route to host)", got, err)
	}
	if took := time.Since(start); took > 2*time.Second {
		t.Errorf("the refusal took %v, want it at once", took)
	}
	if got, err := read(net.Dialer{Timeout: 5 * time.Second, Control: markHostOutput}); err != nil || got != "data of another job" {
		t.Fatalf("a relay's connection: %q, %v", got, err)
	}
	out, err := exec.Command("iptables", "-S", "OUTPUT").CombinedOutput()
	if err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if got := strings.Count(string(out), "-j "+hostOutputChain); got != len(hostOutputLinks) {
		t.Fatalf("OUTPUT jumps after two installs: %d, want %d:\n%s", got, len(hostOutputLinks), out)
	}
}
