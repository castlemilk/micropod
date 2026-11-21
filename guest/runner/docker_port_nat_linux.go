package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"

	"github.com/vishvananda/netlink"
	"github.com/vishvananda/netns"
	"golang.org/x/sys/unix"
)

func kernelPublishedPorts() bool {
	return !privateRootless() && os.Getenv("MICROPOD_PUBLISH_IPV4") != ""
}

// Pace flows before the single virtio transmit queue. This interface only
// carries Mac published ports. An explicitly configured discipline takes precedence.
func pacePublishedLink() error {
	handle, err := netlink.NewHandle(unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer handle.Close()
	link, err := handle.LinkByName("eth1")
	if err != nil {
		return err
	}
	return paceDefaultQueue(handle, link, "pfifo_fast")
}

func paceDefaultQueue(handle *netlink.Handle, link netlink.Link, initial string) error {
	queues, err := handle.QdiscList(link)
	if err != nil {
		return err
	}
	for _, q := range queues {
		if q.Attrs().Parent != netlink.HANDLE_ROOT {
			continue
		}
		if q.Attrs().Handle == 0 && q.Type() == initial {
			return handle.QdiscReplace(netlink.NewFq(netlink.QdiscAttrs{LinkIndex: link.Attrs().Index, Parent: netlink.HANDLE_ROOT}))
		}
	}
	return nil
}

// A bound, non-listening socket reserves the guest port while netfilter routes
// packets. No userspace process accepts connections or copies application data.
type portMapping struct {
	mu      sync.Mutex
	fd      int
	port    uint16
	guestIP net.IP
	target  netip.AddrPort
}

func reserveGuestPort(address string) (int, uint16, error) {
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() {
		return -1, 0, fmt.Errorf("invalid worker IPv4 address %q", address)
	}
	fd, err := unix.Socket(unix.AF_INET, unix.SOCK_STREAM|unix.SOCK_CLOEXEC, unix.IPPROTO_TCP)
	if err != nil {
		return -1, 0, err
	}
	if err = unix.Bind(fd, &unix.SockaddrInet4{Addr: ip.As4()}); err != nil {
		unix.Close(fd)
		return -1, 0, err
	}
	bound, err := unix.Getsockname(fd)
	if err != nil {
		unix.Close(fd)
		return -1, 0, err
	}
	return fd, uint16(bound.(*unix.SockaddrInet4).Port), nil
}

func (m *portMapping) args() []string {
	return []string{"-p", "tcp", "--dport", strconv.Itoa(int(m.port)), "-j", "DNAT", "--to-destination", m.target.String()}
}

// Netfilter remembers translations for established streams after rule removal.
// Match both ends of this lease before either endpoint can be recycled.
func (m *portMapping) MatchConntrackFlow(f *netlink.ConntrackFlow) bool {
	return f.Forward.Protocol == unix.IPPROTO_TCP && f.Forward.DstPort == m.port &&
		f.Forward.DstIP.Equal(m.guestIP) && f.Reverse.SrcPort == m.target.Port() &&
		f.Reverse.SrcIP.Equal(net.IP(m.target.Addr().AsSlice()))
}

func (m *portMapping) close() error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.fd < 0 {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	// Also reconciles an interrupted iptables add that committed in the kernel.
	if err := rule(ctx, "nat", "MP-PUB-IN", false, m.args()...); err != nil {
		return err
	}
	for {
		_, err := netlink.ConntrackDeleteFilters(netlink.ConntrackTable, netlink.FAMILY_V4, m)
		if !errors.Is(err, netlink.ErrDumpInterrupted) {
			if err != nil {
				return fmt.Errorf("retire published flows: %w", err)
			}
			break
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
	}
	err := unix.Close(m.fd)
	m.fd = -1
	return err
}

func openKernelPort(ctx context.Context, ip, target string, host uint16) (*publishedPort, uint16, error) {
	endpoint, err := netip.ParseAddrPort(target)
	if err != nil || !endpoint.Addr().Is4() || endpoint.Port() == 0 {
		return nil, 0, fmt.Errorf("invalid published container endpoint %q", target)
	}
	fd, guest, err := reserveGuestPort(ip)
	if err != nil {
		return nil, 0, err
	}
	m := &portMapping{fd: fd, port: guest, guestIP: net.ParseIP(ip), target: endpoint}
	p := &publishedPort{mapping: m}
	args := append([]string{"-w", "5", "-t", "nat", "-A", "MP-PUB-IN"}, m.args()...)
	if out, err := exec.CommandContext(ctx, "iptables", args...).CombinedOutput(); err != nil {
		return p, 0, fmt.Errorf("add published port: %w: %.512s", err, out)
	}
	owner, port, err := reserveMacPort(ctx, host, guest)
	if err != nil {
		return p, 0, err
	}
	p.lease = owner
	p.wg.Go(func() {
		// Revocation also works if the Mac broker loses this lease while the
		// container is still running. The broker sends no data after its reply.
		var b [1]byte
		_, _ = owner.Read(b[:])
		if err := m.close(); err != nil {
			log.Printf("release published port %d: %v", guest, err)
		}
	})
	return p, port, nil
}

// Guest SNAT presents a host-published connection to the service as its local
// bridge gateway. Give just that directly connected /32 a congestion-control
// preference. Applications may override it and other destinations keep their
// normal policy. The route belongs to this single-use pod network namespace.
func (n node) preferLocalCongestionControl(ctx context.Context, podID, address string, network *workerNetwork) error {
	ns, err := n.podNetwork(ctx, podID)
	if err != nil {
		return err
	}
	defer ns.Close()
	pod, err := netlink.NewHandleAt(netns.NsHandle(ns.Fd()), unix.NETLINK_ROUTE)
	if err != nil {
		return err
	}
	defer pod.Close()
	link, err := pod.LinkByName("eth0")
	if err != nil {
		return err
	}
	if link.Type() != "veth" {
		return nil
	}

	source := net.ParseIP(address).To4()
	addrs, err := pod.AddrList(link, netlink.FAMILY_V4)
	if err != nil {
		return err
	}
	var gateway net.IP
	if network != nil {
		gateway = net.IP(network.gateway().AsSlice())
	} else {
		routes, err := pod.RouteList(link, netlink.FAMILY_V4)
		if err != nil {
			return err
		}
		for _, route := range routes {
			defaultRoute := route.Dst == nil
			if route.Dst != nil {
				prefix, bits := route.Dst.Mask.Size()
				defaultRoute = prefix == 0 && bits == 32
			}
			if defaultRoute && route.Gw.To4() != nil {
				gateway = route.Gw.To4()
				break
			}
		}
	}
	for _, address := range addrs {
		if source != nil && gateway != nil && address.IP.Equal(source) && address.IPNet.Contains(gateway) {
			// At the service veth, fq can still pace individual sending sockets.
			// Only change the implicit noqueue discipline on this new published pod.
			if os.Getenv("MICROPOD_CI_PUBLISH_IPV4") != "" {
				if err := paceDefaultQueue(pod, link, "noqueue"); err != nil {
					log.Printf("published service fair queuing on %.12s: %v", podID, err)
				}
			}
			// Do not replace an explicit application route or a prior successful installation.
			dst := &net.IPNet{IP: gateway, Mask: net.CIDRMask(32, 32)}
			// Shorten the minimum loss-recovery delay on this private
			// hop. The congestion controller remains application-selectable.
			err := pod.RouteAdd(&netlink.Route{
				LinkIndex:  link.Attrs().Index,
				Dst:        dst,
				Src:        source,
				Scope:      netlink.SCOPE_LINK,
				Congctl:    "reno",
				RtoMin:     20, // Linux route metric in milliseconds.
				RtoMinLock: true,
			})
			if errors.Is(err, unix.EEXIST) {
				return nil
			}
			return err
		}
	}
	return fmt.Errorf("cannot verify on-link gateway for %s", source)
}
