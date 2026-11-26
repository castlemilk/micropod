package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/netip"
	"os"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/vishvananda/netlink"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const portBrokerSocket = "/var/lib/micropod/ports.sock"

func tcpPort(key string) (uint16, error) {
	s, proto, ok := strings.Cut(key, "/")
	n, err := strconv.ParseUint(s, 10, 16)
	if !ok || proto != "tcp" || err != nil || n == 0 {
		return 0, fmt.Errorf("expected a TCP container port, got %q", key)
	}
	return uint16(n), nil
}
func requestedPort(b portBinding) (uint16, error) {
	if b.HostIP != "" && b.HostIP != "127.0.0.1" {
		return 0, errors.New("published ports bind the Mac loopback address 127.0.0.1")
	}
	if b.HostPort == "" {
		return 0, nil
	}
	n, e := strconv.ParseUint(b.HostPort, 10, 16)
	return uint16(n), e
}
func (c dockerConfig) requestedPorts() (portMap, error) {
	out := portMap{}
	if c.HostConfig.NetworkMode == "none" {
		if len(c.HostConfig.PortBindings) > 0 {
			return nil, errors.New("an offline container cannot publish ports")
		}
		return out, nil
	}
	for key, bindings := range c.HostConfig.PortBindings {
		port, err := tcpPort(key)
		if err != nil {
			return nil, err
		}
		key := strconv.Itoa(int(port)) + "/tcp"
		out[key] = append(out[key], bindings...)
	}
	if c.HostConfig.PublishAllPorts {
		for key := range c.ExposedPorts {
			port, valid := parseDockerSummaryPort(key)
			if !valid || port.Type != "tcp" {
				return nil, fmt.Errorf("expected a TCP container port, got %q", key)
			}
			key := port.key()
			if _, explicit := out[key]; !explicit {
				out[key] = []portBinding{{}}
			}
		}
	}
	count := 0
	for _, bindings := range out {
		count += len(bindings)
		for _, b := range bindings {
			if _, err := requestedPort(b); err != nil {
				return nil, err
			}
		}
	}
	if count > 64 {
		return nil, errors.New("a container may publish at most 64 TCP ports")
	}
	return out, nil
}

type publishedPort struct {
	listener *net.TCPListener
	lease    io.Closer
	endpoint *directEndpoint
	mapping  *portMapping
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

func (p *publishedPort) close() error {
	if p.endpoint != nil {
		return p.endpoint.close()
	}
	if p.cancel != nil {
		p.cancel()
	}
	var err error
	if p.lease != nil {
		err = p.lease.Close()
	}
	if p.listener != nil {
		p.listener.Close()
	}
	p.wg.Wait()
	if p.mapping != nil {
		return p.mapping.close()
	}
	return err
}

// Only the guest NIC accepts a forwarded connection. The Mac owns the actual
// loopback port and releases it when the private vsock lease closes.
func reserveMacPort(ctx context.Context, host, guest uint16) (net.Conn, uint16, error) {
	var dial net.Dialer
	control, err := dial.DialContext(ctx, "unix", portBrokerSocket)
	if err != nil {
		return nil, 0, err
	}
	var req [4]byte
	binary.BigEndian.PutUint16(req[:2], host)
	binary.BigEndian.PutUint16(req[2:], guest)
	control.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = control.Write(req[:])
	if err == nil {
		_, err = io.ReadFull(control, req[:2])
	}
	if err != nil {
		control.Close()
		return nil, 0, fmt.Errorf("reserve Mac loopback port %d: %w", host, err)
	}
	control.SetDeadline(time.Time{})
	return control, binary.BigEndian.Uint16(req[:2]), nil
}

// openPublishedPort publishes target on the Mac's loopback. In the userspace
// relay mode the guest end is a listener on the guest NIC, which a container,
// a BuildKit step or a CI pod can reach too: admit (nil admits everyone)
// serves only the Mac's port broker there (macFacingAdmits).
func openPublishedPort(ctx context.Context, ip, target string, host uint16, direct *directEndpoint, admit func(netip.Addr) bool) (*publishedPort, uint16, error) {
	if kernelPublishedPorts() {
		return openKernelPort(ctx, ip, target, host, direct)
	}
	l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.ParseIP(ip)})
	if err != nil {
		return nil, 0, err
	}
	control, port, err := reserveMacPort(ctx, host, uint16(l.Addr().(*net.TCPAddr).Port))
	if err != nil {
		l.Close()
		return nil, 0, err
	}
	// The setup deadline ends when crun starts. Established listeners live
	// until the container releases its port, including across long SQL sessions.
	relayCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p := &publishedPort{listener: l, lease: control, cancel: cancel}
	guard := relayGuard{}
	if admit != nil {
		guard.admit = func(peer netip.Addr) (string, bool) { return "", admit(peer) }
		guard.pending = make(chan struct{}, relayPendingAdmissions)
	}
	p.relay(relayCtx, l, target, guard)
	return p, port, nil
}

// relayDialTimeout bounds how long an accepted connection waits for the
// published container to accept, so a target that never answers does not
// pin the relay's descriptors until the port closes.
const relayDialTimeout = 10 * time.Second

// Container-facing relays (the gateway relay) hold at most relayPortSlots
// connections each and gatewayRelaySlots between them, so no container can
// exhaust the engine's descriptors through them (each costs two), and one
// peer family (a job: a delegated socket's owner and what it created, or a
// container of the host's alone) at most relayFamilySlots of the shared
// ones, so a single job cannot hold every other job's gateway relays shut. A
// connection over a limit is closed at once. The Mac-facing relay has no
// limit: it serves only the Mac's port broker (macFacingAdmits), and closes
// any other peer, a container's included, before it dials anything.
const (
	relayPortSlots   = 128
	relayFamilySlots = 128
	// relayPendingAdmissions bounds a listener's connections waiting for
	// admit, which takes the engine's lock (a create or a remove can hold
	// it for a while): past it the accept loop waits, leaving the rest in
	// the kernel's backlog, instead of holding a descriptor for each.
	relayPendingAdmissions = 16
)

var (
	gatewayRelaySlots    = make(chan struct{}, 512)
	gatewayRelayFamilies = &familySlots{max: relayFamilySlots}
)

// relayHalfCloseIdle is how long a relayed connection whose one direction
// has ended may go without a byte in the other before the relay closes it:
// a peer that never closes its side after the target closed its own would
// otherwise hold the connection's slots until the port closes. A variable
// for tests.
var relayHalfCloseIdle = 60 * time.Second

// familySlots counts the shared gateway relay connections each peer family
// holds, at most max each.
type familySlots struct {
	mu   sync.Mutex
	held map[string]int
	max  int
}

func (f *familySlots) take(family string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.held[family] >= f.max {
		return false
	}
	if f.held == nil {
		f.held = map[string]int{}
	}
	f.held[family]++
	return true
}

func (f *familySlots) release(family string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.held[family]--; f.held[family] <= 0 {
		delete(f.held, family)
	}
}

// relayGuard is who a relay serves and how many at once: admit, when set,
// decides each peer by its address and names the family it counts against
// (a refused one is closed before anything is dialed or reserved), with at
// most pending connections waiting for it; slots and shared, when set, are
// the listener's and the engine-wide connection limits, and families what
// one family may hold of shared.
type relayGuard struct {
	admit         func(peer netip.Addr) (family string, ok bool)
	pending       chan struct{}
	slots, shared chan struct{}
	families      *familySlots
}

// take reserves a connection of family in every limit, or reports one is full.
func (g relayGuard) take(family string) (release func(), ok bool) {
	var undo []func()
	free := func() {
		for _, f := range slices.Backward(undo) {
			f()
		}
	}
	for _, ch := range []chan struct{}{g.slots, g.shared} {
		if ch == nil {
			continue
		}
		select {
		case ch <- struct{}{}:
			undo = append(undo, func() { <-ch })
		default:
			free()
			return nil, false
		}
		if ch == g.slots && g.families != nil {
			if !g.families.take(family) {
				free()
				return nil, false
			}
			undo = append(undo, func() { g.families.release(family) })
		}
	}
	return free, true
}

// tcpAcceptor is what relay accepts from (a *net.TCPListener).
type tcpAcceptor interface {
	AcceptTCP() (*net.TCPConn, error)
}

// relay copies every connection l accepts to target until relayCtx ends. An
// accept that fails while the listener is open (EMFILE, ENFILE, ECONNABORTED)
// is retried after a growing pause, as net/http does, so a burst that runs
// the engine out of descriptors does not leave the port dead once it ends.
func (p *publishedPort) relay(relayCtx context.Context, l tcpAcceptor, target string, guard relayGuard) {
	dial := net.Dialer{Timeout: relayDialTimeout}
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		var pause time.Duration
		for {
			in, err := l.AcceptTCP()
			if err != nil {
				if errors.Is(err, net.ErrClosed) || relayCtx.Err() != nil {
					return
				}
				pause = min(max(2*pause, 5*time.Millisecond), time.Second)
				select {
				case <-relayCtx.Done():
					return
				case <-time.After(pause):
				}
				continue
			}
			pause = 0
			if guard.pending != nil {
				select {
				case guard.pending <- struct{}{}:
				case <-relayCtx.Done():
					in.Close()
					return
				}
			}
			p.wg.Add(1)
			go func() {
				defer p.wg.Done()
				defer in.Close()
				family, ok := "", true
				if guard.admit != nil {
					peer, _ := netip.ParseAddrPort(in.RemoteAddr().String())
					family, ok = guard.admit(peer.Addr().Unmap())
				}
				if guard.pending != nil {
					<-guard.pending
				}
				if !ok {
					return
				}
				release, ok := guard.take(family)
				if !ok {
					return
				}
				defer release()
				out, err := dial.DialContext(relayCtx, "tcp4", target)
				if err != nil {
					return
				}
				defer out.Close()
				stop := context.AfterFunc(relayCtx, func() { in.Close(); out.Close() })
				defer stop()
				relayPipe(in, out.(*net.TCPConn))
			}()
		}
	}()
}

// relayPipe copies both directions of a relayed connection until each ends.
// Once one has ended (its sender closed), the other is closed after
// relayHalfCloseIdle without a byte, so a peer that keeps its side open and
// silent does not hold the connection for good.
func relayPipe(in, out *net.TCPConn) {
	var half atomic.Bool
	pipe := func(dst, src *net.TCPConn) {
		for {
			n, err := io.Copy(dst, src)
			var ne net.Error
			if err != nil && n > 0 && half.Load() && errors.As(err, &ne) && ne.Timeout() {
				src.SetReadDeadline(time.Now().Add(relayHalfCloseIdle))
				continue // progress since the last deadline
			}
			return
		}
	}
	// What one direction wrote to is what the other reads from.
	ended := func(c *net.TCPConn) {
		c.CloseWrite()
		half.Store(true)
		c.SetReadDeadline(time.Now().Add(relayHalfCloseIdle))
	}
	done := make(chan struct{})
	go func() {
		pipe(out, in)
		ended(out)
		close(done)
	}()
	pipe(in, out)
	ended(in)
	<-done
}

// defaultBridge is the default container network's bridge (10-micropod.conflist).
const defaultBridge = "mpci0"

// bridgeGateway is the IPv4 address of a bridge in the engine's namespace;
// "" when it has none (no container has started on it yet).
func bridgeGateway(name string) string {
	iface, err := net.InterfaceByName(name)
	if err != nil {
		return ""
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return ""
	}
	for _, addr := range addrs {
		if ip, _, err := net.ParseCIDR(addr.String()); err == nil && ip.To4() != nil {
			return ip.String()
		}
	}
	return ""
}

// defaultGateway is the default network's gateway (10.88.0.1), where an
// in-container Docker client dials a sibling's mapped port: Testcontainers
// reads it from the built-in "bridge" network. A variable for tests.
var defaultGateway = func() string { return bridgeGateway(defaultBridge) }

// relayGateways are the addresses a published port of a container on network
// (nil for the default one) is also relayed at: the default gateway, where
// Testcontainers dials whatever network the sibling is on, and the named
// network's own gateway, its members' default route.
func relayGateways(network *workerNetwork) []string {
	var out []string
	if g := defaultGateway(); g != "" {
		out = append(out, g)
	}
	if network != nil {
		if g := network.gateway().String(); !slices.Contains(out, g) {
			out = append(out, g)
		}
	}
	return out
}

// openGatewayRelay makes a published port reachable from inside the machine
// the way Docker's is: at a container network's gateway on the port the Mac
// publishes it on (gateway:hostPort), which is what a client in a container
// (Testcontainers with the engine socket, its Ryuk reaper) dials for a
// sibling's mapped port. The gateway is an address of the engine's own
// namespace, so any container with a route to it reaches the listener, past
// the FORWARD rules that keep networks apart; and the relay dials the target
// from that namespace. So admit decides each peer (relayAdmits): only one
// that could reach the target anyway or belongs to the same job is relayed.
func openGatewayRelay(ctx context.Context, gateway string, port uint16, target string, admit func(netip.Addr) (string, bool)) (*publishedPort, error) {
	l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.ParseIP(gateway), Port: int(port)})
	if err != nil {
		return nil, err
	}
	relayCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p := &publishedPort{listener: l, cancel: cancel}
	p.relay(relayCtx, l, target, relayGuard{admit: admit, pending: make(chan struct{}, relayPendingAdmissions),
		slots: make(chan struct{}, relayPortSlots), shared: gatewayRelaySlots, families: gatewayRelayFamilies})
	return p, nil
}

// relayAdmits is the rule a published port of target holds a container peer
// to at its gateway relay: the peer shares a network with target (it could
// dial target's own address anyway) or is of target's family (the delegated
// socket's owner and what it created there: a Testcontainers job and its
// siblings, on whatever networks). A peer address that is no container's is
// refused. An admitted peer counts against its own family's share of the
// relays (relayFamilySlots).
func (s *dockerEngine) relayAdmits(target *dockerContainer) func(netip.Addr) (string, bool) {
	return func(peer netip.Addr) (string, bool) {
		s.mu.Lock()
		defer s.mu.Unlock()
		from := s.containerAtLocked(peer)
		if from == nil || from.family() != target.family() && !sharesNetwork(from, target) {
			return "", false
		}
		return from.family(), true
	}
}

// macFacingAdmits is who the Mac-facing relay of the userspace relay mode
// serves: the Mac's port broker alone, which connects from the published
// link's gateway (macBroker), as the kernel mapping admits only that source.
// The relay listens on the guest NIC, which every container, BuildKit step
// and CI pod reaches (nothing filters the engine's input), and none of them
// needs it: a container dials a sibling's published port at its gateway
// relay. With no gateway known it refuses every address of the machine's
// container networks.
func (s *dockerEngine) macFacingAdmits() func(netip.Addr) bool {
	broker := macBroker()
	return func(peer netip.Addr) bool {
		if broker.IsValid() {
			return peer == broker
		}
		s.mu.Lock()
		defer s.mu.Unlock()
		if !peer.IsValid() || reservedWorkerNetworks.Contains(peer) || s.containerAtLocked(peer) != nil {
			return false
		}
		for _, n := range s.namedNetworks {
			if n.Subnet.Contains(peer) {
				return false
			}
		}
		return true
	}
}

// macBroker is the address the Mac's port broker connects from: the
// dedicated published link's gateway, else eth0's default-route gateway (as
// published-ports.sh matches it); invalid when there is none. A variable for
// tests.
var macBroker = func() netip.Addr {
	if os.Getenv("MICROPOD_CI_PUBLISH_IPV4") != "" {
		gw, _ := netip.ParseAddr(os.Getenv("MICROPOD_CI_PUBLISH_GATEWAY"))
		return gw.Unmap()
	}
	link, err := netlink.LinkByName("eth0")
	if err != nil {
		return netip.Addr{}
	}
	routes, err := netlink.RouteList(link, netlink.FAMILY_V4)
	if err != nil {
		return netip.Addr{}
	}
	for _, route := range routes {
		if ones, _ := routeDstSize(route); ones == 0 {
			if gw, ok := netip.AddrFromSlice(route.Gw.To4()); ok {
				return gw
			}
		}
	}
	return netip.Addr{}
}

// routeDstSize is a route's destination prefix length (0 for a default route).
func routeDstSize(route netlink.Route) (int, int) {
	if route.Dst == nil {
		return 0, 32
	}
	return route.Dst.Mask.Size()
}

// containerAtLocked is the running container with address ip on any of its
// networks; nil for none. Call with s.mu held.
func (s *dockerEngine) containerAtLocked(ip netip.Addr) *dockerContainer {
	if !ip.IsValid() {
		return nil
	}
	want := ip.String()
	for _, c := range s.containers {
		if !c.busy() {
			continue
		}
		if c.IP == want || slices.ContainsFunc(c.SecondaryNetworks, func(e dockerSecondaryEndpoint) bool { return e.IP == want }) {
			return c
		}
	}
	return nil
}

// sharesNetwork reports whether a and b are on a network together ("" is
// the default network).
func sharesNetwork(a, b *dockerContainer) bool {
	on := func(c *dockerContainer, id string) bool { return c.NetworkID == id || c.secondaryEndpoint(id) >= 0 }
	if on(b, a.NetworkID) {
		return true
	}
	return slices.ContainsFunc(a.SecondaryNetworks, func(e dockerSecondaryEndpoint) bool { return on(b, e.NetworkID) })
}
func guestIPv4() (string, error) {
	dev := "eth0"
	if os.Getenv("MICROPOD_CI_PUBLISH_IPV4") != "" {
		dev = "eth1"
	}
	iface, err := net.InterfaceByName(dev)
	if err != nil {
		return "", err
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return "", err
	}
	for _, addr := range addrs {
		ip, _, err := net.ParseCIDR(addr.String())
		if err == nil && ip.To4() != nil {
			return ip.String(), nil
		}
	}
	return "", errors.New("worker network has no IPv4 address")
}
func (s *dockerEngine) publish(ctx context.Context, c *dockerContainer, podID string) ([]*publishedPort, error) {
	ports, err := c.Config.requestedPorts()
	if err != nil {
		return nil, err
	}
	if c.Config.HostConfig.NetworkMode == "none" {
		_, err := configurePodNetwork(ctx, s.node, podID, nil, "")
		return nil, err
	}
	var target, primaryMAC string
	var network *workerNetwork
	if c.NetworkID != "" {
		s.mu.Lock()
		n := s.namedNetworks[c.NetworkID]
		s.mu.Unlock()
		if n == nil {
			return nil, errors.New("container network no longer exists")
		}
		start := time.Now()
		primaryMAC, err = configurePodNetwork(ctx, s.node, podID, n, c.NetworkIP)
		s.metrics.networks.attachment(n.Driver, start, err)
		if err != nil {
			return nil, err
		}
		network = n
		target = c.NetworkIP
	} else {
		pod, err := s.node.runtime.PodSandboxStatus(ctx, &cri.PodSandboxStatusRequest{PodSandboxId: podID})
		if err != nil {
			return nil, err
		}
		target = pod.GetStatus().GetNetwork().GetIp()
	}
	if net.ParseIP(target) == nil {
		return nil, errors.New("container has no network address")
	}
	s.mu.Lock()
	c.IP, c.primaryMAC = target, primaryMAC
	s.mu.Unlock()
	if len(ports) == 0 {
		return nil, nil
	}
	var ip string
	var direct *directEndpoint
	var open []*publishedPort
	if kernelPublishedPorts() {
		ip = os.Getenv("MICROPOD_PUBLISH_IPV4")
		if s.direct != nil && (network == nil || network.Driver == "bridge") {
			direct, err = s.direct.attach(ctx, s.node, podID, target)
			if direct != nil {
				open = append(open, &publishedPort{endpoint: direct})
			}
			if err != nil {
				return open, err
			}
		} else if os.Getenv("MICROPOD_CI_PORT_THROUGHPUT") == "1" && (network == nil || network.Driver == "bridge") {
			if err := s.node.preferLocalCongestionControl(ctx, podID, target, network); err != nil {
				// The published mapping and normal routing still work when an
				// installed kernel lacks the optional route metric.
				log.Printf("published TCP return route on pod %.12s: %v", podID, err)
			}
		}
	} else if !privateRootless() {
		ip, err = guestIPv4()
		if err != nil {
			return nil, err
		}
	}
	// Where a container reaches its siblings' published ports
	// (openGatewayRelay); the private rootless engine has no shared bridge
	// to serve it on.
	var gateways []string
	if !privateRootless() {
		gateways = relayGateways(network)
	}
	var macAdmit func(netip.Addr) bool
	if !kernelPublishedPorts() && !privateRootless() {
		macAdmit = s.macFacingAdmits()
	}
	actual := portMap{}
	for key, bindings := range ports {
		port, _ := tcpPort(key)
		for _, b := range bindings {
			request, _ := requestedPort(b)
			var p *publishedPort
			var n uint16
			var err error
			if privateRootless() {
				p, n, err = publishRootless(ctx, target, port, request)
			} else {
				p, n, err = openPublishedPort(ctx, ip, net.JoinHostPort(target, strconv.Itoa(int(port))), request, direct, macAdmit)
			}
			if err != nil {
				if p != nil {
					open = append(open, p)
				}
				return open, err
			}
			open = append(open, p)
			switch {
			case direct != nil:
				s.metrics.networks.directPorts.Add(1)
			case p.mapping != nil:
				s.metrics.networks.kernelPorts.Add(1)
			case p.listener != nil:
				s.metrics.networks.relayPorts.Add(1)
			default:
				s.metrics.networks.rootlessPorts.Add(1)
			}
			for _, gateway := range gateways {
				// Best effort: the Mac mapping stands without it.
				if g, err := openGatewayRelay(ctx, gateway, n, net.JoinHostPort(target, strconv.Itoa(int(port))), s.relayAdmits(c)); err != nil {
					log.Printf("published port %d of %.12s at gateway %s: %v", n, c.ID, gateway, err)
				} else {
					open = append(open, g)
				}
			}
			actual[key] = append(actual[key], portBinding{HostIP: "127.0.0.1", HostPort: strconv.Itoa(int(n))})
		}
	}
	s.mu.Lock()
	c.Ports = actual
	s.mu.Unlock()
	return open, nil
}
