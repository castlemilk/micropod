package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

var errDockerBridgeCleanup = errors.New("secondary bridge endpoint cleanup is unverified")

// Lifetime follows one owned CRI pod, including rollback and natural exit.
// The namespace descriptor pins that identity even if its pause PID exits.
type dockerBridgeSandbox struct {
	mu        sync.Mutex
	podID     string
	primaryID string
	ns        *os.File
	dns       *dockerSandboxDNS
	endpoints map[string]*dockerBridgeEndpoint
	closeErr  error
}

type dockerBridgeEndpoint struct {
	network *workerNetwork
	address netip.Addr
	host    string
	peer    string
	owner   string
	master  int
	mac     string
	// Exists only before a full kernel alias has been verified. The address
	// is chosen by this attempt and supplied in the create request itself.
	pendingHostMAC net.HardwareAddr
}

func (s *dockerEngine) openDockerBridgeSandbox(ctx context.Context, podID string, primary *workerNetwork) (*dockerBridgeSandbox, error) {
	if primary == nil || primary.Driver != "bridge" || !fullContainerID.MatchString(primary.ID) || !fullContainerID.MatchString(podID) {
		return nil, errors.New("secondary networks require an owned IPv4 bridge sandbox")
	}
	ns, err := s.node.podNetwork(ctx, podID)
	if err != nil {
		return nil, err
	}
	dns, err := s.listenDockerSandboxDNS(ctx, ns, primary)
	if err != nil {
		ns.Close()
		return nil, err
	}
	return &dockerBridgeSandbox{podID: podID, primaryID: primary.ID, ns: ns, dns: dns}, nil
}

func (b *dockerBridgeSandbox) setDNSNetworks(networks []*workerNetwork) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ns != nil {
		b.dns.setNetworks(networks)
	}
}

type bridgeRouteHandles struct {
	host *netlink.Handle
	pod  *netlink.Handle
}

func openBridgeRouteHandles(ns *os.File) (bridgeRouteHandles, error) {
	host, err := netlink.NewHandle(unix.NETLINK_ROUTE)
	if err != nil {
		return bridgeRouteHandles{}, err
	}
	var pod *netlink.Handle
	if err := inDockerNetworkNamespace(ns, func() error {
		var err error
		pod, err = netlink.NewHandle(unix.NETLINK_ROUTE)
		return err
	}); err != nil {
		host.Close()
		if pod != nil {
			pod.Close()
		}
		return bridgeRouteHandles{}, err
	}
	links := bridgeRouteHandles{host: host, pod: pod}
	if err := errors.Join(host.SetSocketTimeout(time.Second), pod.SetSocketTimeout(time.Second)); err != nil {
		links.close()
		return bridgeRouteHandles{}, err
	}
	return links, nil
}

func (r bridgeRouteHandles) close() {
	r.pod.Close()
	r.host.Close()
}

func (r bridgeRouteHandles) bridge(n *workerNetwork) (netlink.Link, error) {
	link, err := r.host.LinkByName(n.linkName())
	if err != nil {
		return nil, err
	}
	if link.Type() != "bridge" || !n.ownsLink(link) {
		return nil, errors.New("secondary network bridge ownership differs")
	}
	return link, nil
}

func secondaryBridgeAddress(n *workerNetwork, address string) (netip.Addr, error) {
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() || !n.Subnet.Contains(ip.Next()) || ip.Compare(n.gateway()) <= 0 {
		return netip.Addr{}, errors.New("invalid secondary bridge address")
	}
	return ip, nil
}

func secondaryBridgePeer(pod *netlink.Handle) (string, error) {
	for index := 1; index <= 64; index++ {
		peer := "eth" + strconv.Itoa(index)
		if _, err := pod.LinkByName(peer); errors.As(err, new(netlink.LinkNotFoundError)) {
			return peer, nil
		} else if err != nil {
			return "", err
		}
	}
	return "", errors.New("no free name for secondary bridge interface")
}

func secondaryBridgeHost(podID, networkID string) (name, owner string) {
	owner = "micropod-secondary:" + podID + ":" + networkID
	hash := sha256.Sum256([]byte(owner))
	return fmt.Sprintf("mps%x", hash[:6]), owner
}

func bridgePeerMAC(ip netip.Addr) net.HardwareAddr {
	b := ip.As4()
	// Keep IPv4 neighbours' ARP entries valid across fast reconnection.
	return net.HardwareAddr{0x02, 0x42, b[0], b[1], b[2], b[3]}
}

// Attach is idempotent for this generation and address. An ordinary failure
// leaves no new endpoint. An unverified rollback retains the reservation.
func (b *dockerBridgeSandbox) attach(ctx context.Context, n *workerNetwork, address string) (string, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ns == nil {
		return "", errors.New("bridge sandbox has retired")
	}
	if n == nil || n.ID == b.primaryID || n.Driver != "bridge" || !fullContainerID.MatchString(n.ID) {
		return "", errors.New("secondary endpoint requires a different owned bridge")
	}
	ip, err := secondaryBridgeAddress(n, address)
	if err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	links, err := openBridgeRouteHandles(b.ns)
	if err != nil {
		return "", err
	}
	defer links.close()
	if existing := b.endpoints[n.ID]; existing != nil {
		if existing.address != ip {
			return "", errors.New("secondary endpoint has a different address reservation")
		}
		if existing.mac != "" {
			current, _, err := links.endpoint(existing)
			if err != nil {
				return "", errors.Join(errDockerBridgeCleanup, err)
			}
			if current != nil {
				return existing.mac, nil
			}
		}
		if err := links.removeEndpoint(existing); err != nil {
			return "", err
		}
		delete(b.endpoints, n.ID)
	}
	master, err := links.bridge(n)
	if err != nil {
		return "", err
	}
	peer, err := secondaryBridgePeer(links.pod)
	if err != nil {
		return "", err
	}
	host, owner := secondaryBridgeHost(b.podID, n.ID)
	hostMAC := make(net.HardwareAddr, 6)
	rand.Read(hostMAC)
	hostMAC[0] = hostMAC[0]&0xfc | 0x02
	endpoint := &dockerBridgeEndpoint{
		network: n, address: ip, host: host, peer: peer, owner: owner, master: master.Attrs().Index,
		pendingHostMAC: hostMAC,
	}
	req := netlink.NewVeth(netlink.LinkAttrs{Name: host, HardwareAddr: hostMAC, MTU: n.MTU, TxQLen: -1})
	req.PeerName = peer
	req.PeerNamespace = netlink.NsFd(b.ns.Fd())
	req.PeerMTU = uint32(n.MTU)
	req.PeerHardwareAddr = bridgePeerMAC(ip)
	if b.endpoints == nil {
		b.endpoints = make(map[string]*dockerBridgeEndpoint)
	}
	if err := links.host.LinkAdd(req); errors.Is(err, unix.EEXIST) {
		return "", fmt.Errorf("secondary bridge interface already exists: %w", err)
	} else if err != nil {
		return "", b.rollbackEndpoint(links, endpoint, err)
	}
	mac, err := b.configureEndpoint(ctx, links, endpoint)
	if err != nil {
		return "", b.rollbackEndpoint(links, endpoint, err)
	}
	endpoint.mac = mac
	b.endpoints[n.ID] = endpoint
	return mac, nil
}

func (b *dockerBridgeSandbox) rollbackEndpoint(links bridgeRouteHandles, endpoint *dockerBridgeEndpoint, cause error) error {
	err := links.removeEndpoint(endpoint)
	if err != nil {
		b.endpoints[endpoint.network.ID] = endpoint
	}
	return errors.Join(cause, err)
}

func (b *dockerBridgeSandbox) configureEndpoint(ctx context.Context, links bridgeRouteHandles, e *dockerBridgeEndpoint) (string, error) {
	host, peer, err := links.endpoint(e)
	if err != nil {
		return "", err
	}
	if host == nil || len(peer.Attrs().HardwareAddr) != 6 {
		return "", errors.New("created secondary bridge interface is missing")
	}
	// RTM_NEWLINK does not retain IFLA_IFALIAS on this kernel. Tag the proven
	// pair explicitly while neither side has joined the network.
	if err := links.host.LinkSetAlias(host, e.owner); err != nil {
		return "", err
	}
	tagged, err := links.host.LinkByIndex(host.Attrs().Index)
	if err != nil {
		return "", err
	}
	if tagged.Type() != "veth" || tagged.Attrs().Name != e.host || !bytes.Equal(tagged.Attrs().HardwareAddr, e.pendingHostMAC) || !workerOwnsLink(tagged, e.owner) {
		return "", errors.New("kernel did not retain secondary bridge link ownership")
	}
	e.pendingHostMAC = nil
	// Only the secondary receives this IPv4 address and connected route.
	// Prevent IPv6 router advertisements from installing another default.
	if err := inDockerNetworkNamespace(b.ns, func() error {
		return disableBridgePeerIPv6(e.peer)
	}); err != nil {
		return "", err
	}
	address, err := netlink.ParseAddr(netip.PrefixFrom(e.address, e.network.Subnet.Bits()).String())
	if err != nil {
		return "", err
	}
	if err := links.pod.AddrAdd(peer, address); err != nil {
		return "", err
	}
	if err := links.host.LinkSetMasterByIndex(host, e.master); err != nil {
		return "", err
	}
	if err := links.host.LinkSetUp(host); err != nil {
		return "", err
	}
	if err := links.pod.LinkSetUp(peer); err != nil {
		return "", err
	}
	if err := e.network.setEndpointCongestion(links.pod, peer); err != nil {
		return "", err
	}
	if err := ctx.Err(); err != nil {
		return "", err
	}
	return peer.Attrs().HardwareAddr.String(), nil
}

func disableBridgePeerIPv6(peer string) error {
	f, err := os.OpenFile("/proc/sys/net/ipv6/conf/"+peer+"/disable_ipv6", os.O_WRONLY, 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	_, err = f.WriteString("1\n")
	return errors.Join(err, f.Close())
}

func matchingBridgePeer(host, peer netlink.Link) bool {
	return host.Type() == "veth" && peer.Type() == "veth" && host.Attrs().Index > 0 &&
		peer.Attrs().Index > 0 && peer.Attrs().ParentIndex == host.Attrs().Index &&
		(host.Attrs().ParentIndex == 0 || host.Attrs().ParentIndex == peer.Attrs().Index)
}

func (e *dockerBridgeEndpoint) matchesPendingHost(host netlink.Link, alias string) bool {
	return alias == "" && host.Attrs().Alias == "" && len(e.pendingHostMAC) != 0 &&
		host.Attrs().MasterIndex == 0 && host.Attrs().ParentIndex > 0 &&
		bytes.Equal(host.Attrs().HardwareAddr, e.pendingHostMAC)
}

func (r bridgeRouteHandles) endpoint(e *dockerBridgeEndpoint) (host, peer netlink.Link, err error) {
	host, err = r.host.LinkByName(e.host)
	if errors.As(err, new(netlink.LinkNotFoundError)) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	if host.Type() != "veth" {
		return nil, nil, errors.New("secondary bridge link ownership differs")
	}
	tagged := host.Attrs().Alias == e.owner
	if !tagged {
		alias, err := workerLinkAlias(host)
		if err != nil {
			return nil, nil, err
		}
		tagged = alias == e.owner
		if !tagged && !e.matchesPendingHost(host, alias) {
			return nil, nil, errors.New("secondary bridge link ownership differs")
		}
	}
	if index := host.Attrs().MasterIndex; index != 0 {
		master, err := r.bridge(e.network)
		if err != nil {
			return nil, nil, err
		}
		if index != e.master || index != master.Attrs().Index {
			return nil, nil, errors.New("secondary bridge link master differs")
		}
	} else if e.mac != "" {
		return nil, nil, errors.New("secondary bridge link is no longer attached to its master")
	}
	if index := host.Attrs().ParentIndex; index > 0 {
		peer, err = r.pod.LinkByIndex(index)
	} else {
		peer, err = r.pod.LinkByName(e.peer)
	}
	if err != nil {
		return nil, nil, err
	}
	if !matchingBridgePeer(host, peer) || !bytes.Equal(peer.Attrs().HardwareAddr, bridgePeerMAC(e.address)) || !tagged && peer.Attrs().Name != e.peer {
		return nil, nil, errors.New("secondary bridge peer does not match the owned sandbox")
	}
	return host, peer, nil
}

func (r bridgeRouteHandles) removeEndpoint(e *dockerBridgeEndpoint) error {
	host, _, err := r.endpoint(e)
	if err != nil {
		return errors.Join(errDockerBridgeCleanup, err)
	}
	if host == nil {
		return nil
	}
	deleteErr := r.host.LinkDel(host)
	_, inspectErr := r.host.LinkByName(e.host)
	if errors.As(inspectErr, new(netlink.LinkNotFoundError)) {
		return nil
	}
	return errors.Join(errDockerBridgeCleanup, deleteErr, inspectErr)
}

func (b *dockerBridgeSandbox) detach(n *workerNetwork) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ns == nil {
		return errors.New("bridge sandbox has retired")
	}
	endpoint := b.endpoints[n.ID]
	if endpoint == nil {
		return nil
	}
	links, err := openBridgeRouteHandles(b.ns)
	if err != nil {
		return errors.Join(errDockerBridgeCleanup, err)
	}
	defer links.close()
	if err := links.removeEndpoint(endpoint); err != nil {
		return err
	}
	delete(b.endpoints, n.ID)
	return nil
}

func (b *dockerBridgeSandbox) close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ns == nil {
		return b.closeErr
	}
	b.dns.setNetworks(nil)
	b.dns.server.close()
	if len(b.endpoints) != 0 {
		links, err := openBridgeRouteHandles(b.ns)
		if err != nil {
			b.closeErr = errors.Join(errDockerBridgeCleanup, err)
		} else {
			for _, endpoint := range b.endpoints {
				b.closeErr = errors.Join(b.closeErr, links.removeEndpoint(endpoint))
			}
			links.close()
		}
	}
	b.closeErr = errors.Join(b.closeErr, b.ns.Close())
	b.ns = nil
	b.endpoints = nil
	return b.closeErr
}
