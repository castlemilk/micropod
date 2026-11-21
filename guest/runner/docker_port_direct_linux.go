package main

import (
	"context"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netlink/nl"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

// The Mac continues to dial the worker IP and a kernel-reserved TCP port.
// At eth1 ingress the worker changes only the Ethernet destination of a
// leased tuple. The macvlan driver then delivers it to the correct pod.
type directNetwork struct {
	address, gateway netip.Addr
	parent           netlink.Link
	// Only touched when a previously granted broker lease loses its acknowledgement.
	mu        sync.Mutex
	uncertain map[uint16]int
}

const rootDirectRules = `destroy table netdev mp_publication
table netdev mp_publication {
	map listeners { type inet_service : ether_addr; }
	set replies { type ether_addr . inet_service; }
	set neighbors { type ether_addr . ipv4_addr; }
	chain receive {
		type filter hook ingress device "eth1" priority -500; policy drop;
		ether daddr %[1]s ip saddr %[2]s ip daddr %[3]s ip protocol tcp ether daddr set tcp dport map @listeners counter accept
		ether daddr %[1]s accept
		arp operation reply arp saddr ip %[2]s ether daddr . arp daddr ip @neighbors accept
		meta pkttype { broadcast, multicast } accept
	}
	chain send {
		type filter hook egress device "eth1" priority 500; policy drop;
		ether saddr %[1]s accept
		ip saddr %[3]s ip daddr %[2]s ip protocol tcp ether saddr . tcp sport @replies counter accept
		arp operation request arp daddr ip %[2]s ether saddr . arp saddr ip @neighbors accept
	}
}
`

// NAT takes place in the service namespace so a process bound to its usual
// Docker IP works just like a wildcard listener. The new interface has no IP
// address. Only reply traffic for an admitted connection can leave through it.
const podDirectRules = `create table inet mp_publication
table inet mp_publication {
	map ports { type inet_service : ipv4_addr . inet_service; }
	chain translate {
		type nat hook prerouting priority dstnat; policy accept;
		iifname "mppub0" ip saddr %[1]s ip daddr %[2]s ip protocol tcp dnat ip to tcp dport map @ports
	}
	chain receive {
		type filter hook input priority filter; policy accept;
		iifname "mppub0" ip saddr %[1]s ip daddr %[3]s ct direction original ct status dnat accept
		iifname "mppub0" drop
	}
	chain send {
		type filter hook output priority filter; policy accept;
		oifname "mppub0" ip saddr %[3]s ip daddr %[1]s ct direction reply ct status dnat accept
		oifname "mppub0" drop
	}
	chain forward {
		type filter hook forward priority filter; policy accept;
		iifname "mppub0" drop
		oifname "mppub0" drop
	}
}
`

// Only the control plane runs nft. An inherited descriptor pins the CRI
// namespace across process exit and PID reuse. Each input is one transaction.
func directRules(ctx context.Context, ns *os.File, rules string) error {
	cmd := exec.CommandContext(ctx, "nft", "-f", "-")
	if ns != nil {
		cmd = exec.CommandContext(ctx, "nsenter", "--net=/proc/self/fd/3", "nft", "-f", "-")
		cmd.ExtraFiles = []*os.File{ns}
	}
	cmd.Stdin = strings.NewReader(rules)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("published-port rules: %w: %.1024s", err, out)
	}
	return nil
}

func newDirectNetwork(ctx context.Context) (*directNetwork, error) {
	addr, e1 := netip.ParseAddr(os.Getenv("MICROPOD_CI_PUBLISH_IPV4"))
	gw, e2 := netip.ParseAddr(os.Getenv("MICROPOD_CI_PUBLISH_GATEWAY"))
	if !kernelPublishedPorts() || e1 != nil || e2 != nil || !addr.Is4() || !gw.Is4() ||
		addr == gw || addr.String() != os.Getenv("MICROPOD_PUBLISH_IPV4") {
		return nil, errors.New("macvlan publication needs the dedicated worker IPv4 link")
	}
	l, err := netlink.LinkByName("eth1")
	if err != nil {
		return nil, err
	}
	if len(l.Attrs().HardwareAddr) != 6 {
		return nil, errors.New("published link has no Ethernet address")
	}
	addrs, err := netlink.AddrList(l, netlink.FAMILY_V4)
	if err != nil {
		return nil, err
	}
	for _, a := range addrs {
		if a.IP.Equal(net.IP(addr.AsSlice())) && a.IPNet.Contains(net.IP(gw.AsSlice())) {
			if err := directRules(ctx, nil, fmt.Sprintf(rootDirectRules, l.Attrs().HardwareAddr, gw, addr)); err != nil {
				return nil, err
			}
			return &directNetwork{address: addr, gateway: gw, parent: l}, nil
		}
	}
	return nil, errors.New("published link does not own the configured subnet")
}

const revokePort = 0x52

// The Mac records the pending guest port before accepting the host port. If
// the final bind response is lost, a fence on a different stream can never
// run ahead of that bind and incorrectly report the guest port as reusable.
func reserveDirectMacPort(ctx context.Context, host, guest uint16) (net.Conn, uint16, bool, error) {
	var dial net.Dialer
	c, err := dial.DialContext(ctx, "unix", portBrokerSocket)
	if err != nil {
		return nil, 0, false, err
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	var frame [4]byte
	binary.BigEndian.PutUint16(frame[:2], guest)
	binary.BigEndian.PutUint16(frame[2:], 1)
	if _, err = c.Write(frame[:]); err == nil {
		_, err = io.ReadFull(c, frame[:1])
	}
	if err == nil && frame[0] != 0x50 {
		err = errors.New("Mac broker rejected direct port preparation")
	}
	if err != nil {
		c.Close()
		return nil, 0, false, err
	}
	binary.BigEndian.PutUint16(frame[:2], host)
	if _, err = c.Write(frame[:2]); err == nil {
		_, err = io.ReadFull(c, frame[:2])
	}
	if err != nil {
		c.Close()
		return nil, 0, true, fmt.Errorf("reserve Mac loopback port %d: %w", host, err)
	}
	c.SetDeadline(time.Time{})
	return c, binary.BigEndian.Uint16(frame[:2]), false, nil
}

type directControl struct {
	net.Conn
	done chan struct{}
}

func (c *directControl) Close() error {
	select {
	case <-c.done:
		return nil
	default:
	}
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := c.Write([]byte{revokePort}); err != nil {
		c.Conn.Close()
	}
	<-c.done
	return nil
}

func (d *directNetwork) quarantined() int {
	d.mu.Lock()
	defer d.mu.Unlock()
	return len(d.uncertain)
}

func (d *directNetwork) quarantine(port uint16, fd int) {
	d.mu.Lock()
	if d.uncertain == nil {
		d.uncertain = make(map[uint16]int)
	}
	d.uncertain[port] = fd
	start := len(d.uncertain) == 1
	d.mu.Unlock()
	log.Printf("waiting for Mac confirmation before reusing guest port %d", port)
	if start {
		go d.reconcile()
	}
}

// A single worker retries only ambiguous revocations. Never infer lease
// loss from a timeout. A successful fence has passed the Mac accept queue.
func (d *directNetwork) reconcile() {
	for delay := 100 * time.Millisecond; ; delay = min(delay*2, 5*time.Second) {
		time.Sleep(delay)
		d.mu.Lock()
		pending := make(map[uint16]int, len(d.uncertain))
		for p, fd := range d.uncertain {
			pending[p] = fd
		}
		d.mu.Unlock()
		for port, fd := range pending {
			free, err := macPortReleased(port)
			if err != nil {
				break
			}
			if free {
				d.mu.Lock()
				delete(d.uncertain, port)
				unix.Close(fd)
				if len(d.uncertain) == 0 {
					d.mu.Unlock()
					return
				}
				d.mu.Unlock()
			}
		}
	}
}

func macPortReleased(port uint16) (bool, error) {
	c, err := net.DialTimeout("unix", portBrokerSocket, time.Second)
	if err != nil {
		return false, err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(time.Second))
	var frame [4]byte
	binary.BigEndian.PutUint16(frame[:2], port)
	if _, err := c.Write(frame[:]); err != nil {
		return false, err
	}
	_, err = io.ReadFull(c, frame[:1])
	return frame[0] == revokePort && err == nil, err
}

type directEndpoint struct {
	network  *directNetwork
	ns       *os.File
	pod      *netlink.Handle
	link     netlink.Link
	mac      net.HardwareAddr
	target   netip.Addr
	enrolled bool
}

func (d *directNetwork) attach(ctx context.Context, node node, id, target string) (*directEndpoint, error) {
	ip, err := netip.ParseAddr(target)
	if err != nil || !ip.Is4() {
		return nil, errors.New("invalid published pod IPv4")
	}
	ns, err := node.podNetwork(ctx, id)
	if err != nil {
		return nil, err
	}
	end := &directEndpoint{network: d, ns: ns, target: ip, mac: make(net.HardwareAddr, 6)}
	end.pod, err = netlink.NewHandleAt(netns.NsHandle(ns.Fd()), unix.NETLINK_ROUTE, unix.NETLINK_NETFILTER)
	if err != nil {
		return end, err
	}
	original, err := end.pod.LinkByName("eth0")
	if err != nil {
		return end, err
	}
	addrs, err := end.pod.AddrList(original, netlink.FAMILY_V4)
	if err != nil {
		return end, err
	}
	owned := false
	for _, a := range addrs {
		if a.IP.Equal(net.IP(ip.AsSlice())) {
			owned = true
			break
		}
	}
	if !owned || original.Type() != "veth" {
		return end, errors.New("pod does not own the published bridge endpoint")
	}
	if err = directRules(ctx, ns, fmt.Sprintf(podDirectRules, d.gateway, d.address, ip)); err != nil {
		return end, err
	}
	rand.Read(end.mac)
	end.mac[0] = (end.mac[0] & 0xfc) | 2
	parent := d.parent.Attrs()
	link := &netlink.Macvlan{LinkAttrs: netlink.LinkAttrs{Name: "mppub0", ParentIndex: parent.Index, MTU: parent.MTU, Namespace: netlink.NsFd(ns.Fd()), HardwareAddr: end.mac}, Mode: netlink.MACVLAN_MODE_PRIVATE}
	if err := netlink.LinkAdd(link); err != nil {
		return end, err
	}
	end.link, err = end.pod.LinkByName("mppub0")
	if err != nil {
		return end, err
	}
	if !strings.EqualFold(end.link.Attrs().HardwareAddr.String(), end.mac.String()) {
		end.link = nil
		return end, errors.New("published interface ownership mismatch")
	}
	if err := end.pod.LinkSetIP6AddrGenMode(end.link, nl.IN6_ADDR_GEN_MODE_NONE); err != nil {
		return end, err
	}
	if err := end.pod.LinkSetUp(end.link); err != nil {
		return end, err
	}
	route := netlink.Route{LinkIndex: end.link.Attrs().Index, Dst: &net.IPNet{IP: net.IP(d.gateway.AsSlice()), Mask: net.CIDRMask(32, 32)}, Src: net.IP(ip.AsSlice()), Scope: netlink.SCOPE_LINK, Congctl: "reno", RtoMin: 20, RtoMinLock: true}
	if err := end.pod.RouteAdd(&route); err != nil {
		return end, err
	}
	if err := paceDefaultQueue(end.pod, end.link, "noqueue"); err != nil {
		return end, err
	}
	// Seed from the parent's neighbor cache when warm. Normal ARP is allowed
	// for this pod and gateway only, so neighbor changes can repair in place.
	neighbors, err := netlink.NeighList(parent.Index, netlink.FAMILY_V4)
	if err != nil {
		return end, err
	}
	for _, n := range neighbors {
		if n.IP.Equal(net.IP(d.gateway.AsSlice())) && len(n.HardwareAddr) == 6 {
			if err := end.pod.NeighSet(&netlink.Neigh{LinkIndex: end.link.Attrs().Index, IP: n.IP, HardwareAddr: n.HardwareAddr, State: netlink.NUD_STALE}); err != nil {
				return end, err
			}
			break
		}
	}
	// Cleanup also reconciles an interrupted transaction.
	end.enrolled = true
	if err := directRules(ctx, nil, fmt.Sprintf("add element netdev mp_publication neighbors { %s . %s }\n", end.mac, ip)); err != nil {
		return end, err
	}
	return end, nil
}

func (e *directEndpoint) grant(ctx context.Context, port, service uint16) error {
	if err := directRules(ctx, e.ns, fmt.Sprintf("add element inet mp_publication ports { %d : %s . %d }\n", port, e.target, service)); err != nil {
		return err
	}
	// Make ingress and return traffic visible together, only after pod setup.
	return directRules(ctx, nil, fmt.Sprintf("add element netdev mp_publication listeners { %d : %s }\nadd element netdev mp_publication replies { %s . %d }\n", port, e.mac, e.mac, port))
}

func (e *directEndpoint) revoke(ctx context.Context, port uint16) error {
	if err := directRules(ctx, nil, fmt.Sprintf("destroy element netdev mp_publication listeners { %d }\ndestroy element netdev mp_publication replies { %s . %d }\n", port, e.mac, port)); err != nil {
		return err
	}
	return directRules(ctx, e.ns, fmt.Sprintf("destroy element inet mp_publication ports { %d }\n", port))
}

func (e *directEndpoint) close() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var err error
	if e.link != nil {
		err = e.pod.LinkDel(e.link)
	}
	if e.enrolled {
		err = errors.Join(err, directRules(ctx, nil, fmt.Sprintf("destroy element netdev mp_publication neighbors { %s . %s }\n", e.mac, e.target)))
	}
	if e.pod != nil {
		e.pod.Close()
	}
	return errors.Join(err, e.ns.Close())
}
