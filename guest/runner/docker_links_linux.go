package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

func (n *workerNetwork) linkName() string { return "mpb" + n.ID[:10] }
func (n *workerNetwork) gatewayLink() string {
	if n.Driver != "bridge" {
		return "mpg" + n.ID[:10]
	}
	return n.linkName()
}
func (n *workerNetwork) gateway() netip.Addr { return n.Subnet.Addr().Next() }

func rule(ctx context.Context, table, chain string, add bool, args ...string) error {
	call := func(op string) ([]byte, error) {
		argv := append([]string{"-w", "5", "-t", table, op, chain}, args...)
		return exec.CommandContext(ctx, "iptables", argv...).CombinedOutput()
	}
	out, check := call("-C")
	if check != nil {
		var status *exec.ExitError
		if !errors.As(check, &status) || status.ExitCode() != 1 {
			return fmt.Errorf("inspect network rule %s: %w: %.512s", chain, check, out)
		}
	}
	if (check == nil) == add {
		return nil
	}
	op := "-D"
	if add {
		op = "-I"
	}
	out, err := call(op)
	if err != nil {
		return fmt.Errorf("network rule %s: %w: %.512s", chain, err, out)
	}
	return nil
}

// Isolation and masquerading belong to the network. Joining a service needs no
// firewall subprocess and no per-container NAT rule.
func (n *workerNetwork) firewall(ctx context.Context, add bool) error {
	link := n.gatewayLink()
	drop := "DROP"
	if kernelPublishedPorts() {
		drop = "MP-PUB-GATE"
	}
	if err := rule(ctx, "filter", "FORWARD", add, "!", "-i", link, "-o", link, "-m", "conntrack", "--ctstate", "NEW,INVALID", "-j", drop); err != nil {
		return err
	}
	if n.Internal {
		return rule(ctx, "filter", "FORWARD", add, "-i", link, "!", "-o", link, "-j", drop)
	}
	if err := rule(ctx, "filter", "FORWARD", add, "-i", link, "-o", "mpci0", "-j", "DROP"); err != nil {
		return err
	}
	return rule(ctx, "nat", "POSTROUTING", add, "-s", n.Subnet.String(), "-o", workerUplink(), "-j", "MASQUERADE")
}

func (n *workerNetwork) endpoint(attrs netlink.LinkAttrs) netlink.Link {
	if n.Driver == "macvlan" {
		return &netlink.Macvlan{LinkAttrs: attrs, Mode: netlink.MACVLAN_MODE_BRIDGE}
	}
	return &netlink.IPVlan{LinkAttrs: attrs, Mode: netlink.IPVLAN_MODE_L2}
}

// sysfs reports the complete IFLA_IFALIAS text on kernels that omit the
// optional trailing NUL from RTM_GETLINK replies.
func (n *workerNetwork) ownsLink(l netlink.Link) bool {
	return workerOwnsLink(l, n.ID)
}

func workerOwnsLink(l netlink.Link, owner string) bool {
	if l.Attrs().Alias == owner {
		return true
	}
	alias, err := workerLinkAlias(l)
	return err == nil && alias == owner
}

func workerLinkAlias(l netlink.Link) (string, error) {
	raw, err := os.ReadFile(filepath.Join("/sys/class/net", l.Attrs().Name, "ifalias"))
	return strings.TrimRight(string(raw), "\n\x00"), err
}

// On service recovery reuse only interfaces tagged with this durable network ID.
// An empty bridge is a private lower device on kernels built without CONFIG_DUMMY.
func (n *workerNetwork) ensureLink(request netlink.Link) (netlink.Link, error) {
	l, err := netlink.LinkByName(request.Attrs().Name)
	if err == nil {
		if !n.ownsLink(l) || l.Type() != request.Type() {
			return nil, errors.New("network link name is already in use")
		}
	} else {
		if !errors.As(err, new(netlink.LinkNotFoundError)) {
			return nil, err
		}
		request.Attrs().Alias = n.ID
		if err = netlink.LinkAdd(request); err != nil {
			return nil, fmt.Errorf("create %s link: %w", request.Type(), err)
		}
		l = request
		if e := netlink.LinkSetAlias(request, n.ID); e != nil {
			_ = netlink.LinkDel(request)
			return nil, fmt.Errorf("set network ownership: %w", e)
		}
		actual, e := netlink.LinkByName(request.Attrs().Name)
		if e != nil || !n.ownsLink(actual) {
			_ = netlink.LinkDel(request)
			if e != nil {
				return nil, e
			}
			return nil, errors.New("kernel did not retain the network ownership tag")
		}
	}
	return l, netlink.LinkSetUp(l)
}

func (n *workerNetwork) setup(ctx context.Context) error {
	link, err := n.ensureLink(&netlink.Bridge{LinkAttrs: netlink.LinkAttrs{Name: n.linkName(), MTU: n.MTU}})
	if err != nil {
		return err
	}
	ok := false
	defer func() {
		if !ok {
			n.teardown()
		}
	}()
	if n.Driver != "bridge" {
		link, err = n.ensureLink(n.endpoint(netlink.LinkAttrs{Name: n.gatewayLink(), ParentIndex: link.Attrs().Index, MTU: n.MTU}))
		if err != nil {
			return err
		}
	}
	address, err := netlink.ParseAddr(fmt.Sprintf("%s/%d", n.gateway(), n.Subnet.Bits()))
	if err != nil {
		return err
	}
	if err = netlink.AddrReplace(link, address); err != nil {
		return err
	}
	if err = n.firewall(ctx, true); err != nil {
		return err
	}
	ok = true
	return nil
}
func (n *workerNetwork) teardown() error {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	err := n.firewall(ctx, false)
	for _, name := range slices.Compact([]string{n.gatewayLink(), n.linkName()}) {
		l, e := netlink.LinkByName(name)
		if e == nil {
			if !n.ownsLink(l) {
				return errors.Join(err, errors.New("refusing to remove unowned network link"))
			}
			err = errors.Join(err, netlink.LinkDel(l))
		} else if !errors.As(e, new(netlink.LinkNotFoundError)) {
			err = errors.Join(err, e)
		}
	}
	return err
}

func (n *workerNetwork) attach(pod *netlink.Handle, fd int, podID, ip string) error {
	parent, err := netlink.LinkByName(n.linkName())
	if err != nil {
		return err
	}
	switch n.Driver {
	case "bridge":
		peer := &netlink.Veth{LinkAttrs: netlink.LinkAttrs{Name: "mpv" + podID[:10], MTU: n.MTU, MasterIndex: parent.Attrs().Index}, PeerName: "eth0", PeerNamespace: netlink.NsFd(fd)}
		if err = netlink.LinkAdd(peer); err == nil {
			err = netlink.LinkSetUp(peer)
		}
	case "ipvlan", "macvlan":
		err = netlink.LinkAdd(n.endpoint(netlink.LinkAttrs{Name: "eth0", ParentIndex: parent.Attrs().Index, Namespace: netlink.NsFd(fd), MTU: n.MTU}))
	}
	if err != nil {
		return fmt.Errorf("attach %s: %w", n.Driver, err)
	}
	link, err := pod.LinkByName("eth0")
	if err != nil {
		return err
	}
	return n.addressEndpoint(pod, link, ip)
}

// A CRI standby already owns this veth pair. Move the verified host end to
// the selected bridge before starting the workload. CRI still owns its IPAM
// lease and removes the same pair when the pod ends.
func (n *workerNetwork) moveBridgeEndpoint(pod *netlink.Handle, link netlink.Link, ip string) (string, error) {
	if link.Type() != "veth" || link.Attrs().ParentIndex <= 0 {
		return "", errors.New("CRI endpoint is not a veth pair")
	}
	source, err := netlink.LinkByName("mpci0")
	if err != nil {
		return "", err
	}
	dst, err := netlink.LinkByName(n.linkName())
	if err != nil {
		return "", err
	}
	peer, err := netlink.LinkByIndex(link.Attrs().ParentIndex)
	if err != nil {
		return "", err
	}
	if !matchingBridgePeer(peer, link) || peer.Attrs().MasterIndex != source.Attrs().Index || dst.Type() != "bridge" || !n.ownsLink(dst) {
		return "", errors.New("CRI endpoint did not match the worker bridge")
	}
	mac, err := n.primaryBridgePeerMAC(ip)
	if err != nil {
		return "", err
	}
	if err = pod.LinkSetDown(link); err != nil {
		return "", err
	}
	// Remove the previous address and default route while the link is down.
	routes, err := pod.RouteList(link, netlink.FAMILY_V4)
	if err != nil {
		return "", err
	}
	for _, route := range routes {
		if route.Protocol != unix.RTPROT_KERNEL {
			if err = pod.RouteDel(&route); err != nil {
				return "", err
			}
		}
	}
	addrs, err := pod.AddrList(link, netlink.FAMILY_V4)
	if err != nil {
		return "", err
	}
	for _, addr := range addrs {
		if err = pod.AddrDel(link, &addr); err != nil {
			return "", err
		}
	}
	if mac != nil && !slices.Equal(link.Attrs().HardwareAddr, mac) {
		if err := pod.LinkSetHardwareAddr(link, mac); err != nil {
			return "", fmt.Errorf("set the primary bridge peer MAC: %w", err)
		}
		link, err = pod.LinkByIndex(link.Attrs().Index)
		if err != nil {
			return "", err
		}
		if !matchingBridgePeer(peer, link) || !slices.Equal(link.Attrs().HardwareAddr, mac) {
			return "", errors.New("kernel did not retain the requested primary bridge peer MAC")
		}
	}
	if err = netlink.LinkSetMasterByIndex(peer, dst.Attrs().Index); err != nil {
		return "", err
	}
	if peer.Attrs().MTU != n.MTU {
		if err = netlink.LinkSetMTU(peer, n.MTU); err != nil {
			return "", err
		}
	}
	if link.Attrs().MTU != n.MTU {
		if err = pod.LinkSetMTU(link, n.MTU); err != nil {
			return "", err
		}
	}
	if err := n.addressEndpoint(pod, link, ip); err != nil {
		return "", err
	}
	return link.Attrs().HardwareAddr.String(), nil
}

func (n *workerNetwork) primaryBridgePeerMAC(address string) (net.HardwareAddr, error) {
	if n.Driver != "bridge" || builtinNetwork(networkName(n.Name)) || !n.Subnet.Addr().Is4() || privateRootless() {
		return nil, nil
	}
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() || !n.Subnet.Contains(ip) {
		return nil, errors.New("invalid primary bridge address")
	}
	// The CRI veth is new after each start, but the reserved IP and its
	// neighbours' ARP entries survive the previous pod.
	return bridgePeerMAC(ip), nil
}

func (n *workerNetwork) addressEndpoint(pod *netlink.Handle, link netlink.Link, ip string) error {
	address, err := netlink.ParseAddr(fmt.Sprintf("%s/%d", ip, n.Subnet.Bits()))
	if err != nil {
		return err
	}
	if err = pod.AddrAdd(link, address); err != nil {
		return err
	}
	if err = pod.LinkSetUp(link); err != nil {
		return err
	}
	if !n.Internal {
		return pod.RouteAdd(&netlink.Route{LinkIndex: link.Attrs().Index, Gw: net.ParseIP(n.gateway().String()).To4(), Family: unix.AF_INET})
	}
	return n.setEndpointCongestion(pod, link)
}

func (n *workerNetwork) setEndpointCongestion(pod *netlink.Handle, link netlink.Link) error {
	if n.TCPCongestion == "" {
		return nil
	}
	// Only peers in this internal subnet get the preference. Changing the TCP
	// sysctl in the pod may fail when the chosen controller is restricted.
	routes, err := pod.RouteList(link, netlink.FAMILY_V4)
	if err != nil {
		return fmt.Errorf("read sibling subnet route: %w", err)
	}
	for _, route := range routes {
		if route.Protocol != unix.RTPROT_KERNEL || route.Scope != netlink.SCOPE_LINK || routeSubnet(route) != n.Subnet {
			continue
		}
		route.Congctl = n.TCPCongestion
		if err := pod.RouteChange(&route); err != nil {
			return fmt.Errorf("set sibling TCP congestion control %s: %w", n.TCPCongestion, err)
		}
		return nil
	}
	return fmt.Errorf("missing connected route for sibling subnet %s", n.Subnet)
}

type workerRouteReader func() ([]netlink.Route, error)

var reservedWorkerNetworks = netip.MustParsePrefix("10.88.0.0/15")

func workerIPv4Routes() ([]netlink.Route, error) {
	return netlink.RouteList(nil, netlink.FAMILY_V4)
}

func routeSubnet(route netlink.Route) netip.Prefix {
	if route.Dst == nil || strings.HasSuffix(route.Dst.String(), "/0") {
		return netip.Prefix{}
	}
	prefix, _ := netip.ParsePrefix(route.Dst.String())
	return prefix
}

func routeAvailable(prefix netip.Prefix) bool {
	return subnetAvailable(prefix, workerIPv4Routes)
}

func subnetAvailable(prefix netip.Prefix, readRoutes workerRouteReader) bool {
	if prefix.Overlaps(reservedWorkerNetworks) {
		return false
	}
	routes, err := readRoutes()
	if err != nil {
		return false
	}
	for _, route := range routes {
		if routeSubnet(route).Overlaps(prefix) {
			return false
		}
	}
	return true
}
