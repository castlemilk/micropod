package main

// Route netlink (rtnetlink) message encoding and decoding for guest network
// setup. The worker image ships BusyBox `ip`, which lacks `addr replace`, so
// stage 2 configures links, addresses, routes and neighbours directly. This file
// is pure byte handling so it is testable on any host; the socket lives in
// netconf_linux.go.

import (
	"encoding/binary"
	"fmt"
	"net"
	"net/netip"
	"strings"
)

const (
	nlmsgHdrLen = 16

	nlmsgError = 2
	nlmsgDone  = 3

	rtmNewLink  = 16
	rtmNewAddr  = 20
	rtmGetAddr  = 22
	rtmNewRoute = 24
	rtmGetRoute = 26
	rtmNewNeigh = 28
	rtmGetNeigh = 30

	nlmFRequest = 0x1
	nlmFAck     = 0x4
	nlmFReplace = 0x100
	nlmFCreate  = 0x400
	nlmFDump    = 0x300

	afUnspec = 0
	afInet   = 2

	iffUp = 0x1

	iflaMTU = 4

	ifaAddress   = 1
	ifaLocal     = 2
	ifaBroadcast = 4

	rtaOIF     = 4
	rtaGateway = 5
	rtaTable   = 15

	ndaDst    = 1
	ndaLLAddr = 2

	rtTableMain     = 254
	rtprotBoot      = 3
	rtScopeUniverse = 0
	rtScopeHost     = 254
	rtnUnicast      = 1

	nudPermanent = 0x80
)

type nlAttr struct {
	typ  uint16
	data []byte
}

func nlAlign(n int) int { return (n + 3) &^ 3 }

func appendAttrs(b []byte, attrs []nlAttr) []byte {
	for _, a := range attrs {
		n := 4 + len(a.data)
		b = binary.NativeEndian.AppendUint16(b, uint16(n))
		b = binary.NativeEndian.AppendUint16(b, a.typ)
		b = append(b, a.data...)
		for len(b)%4 != 0 {
			b = append(b, 0)
		}
	}
	return b
}

// nlMessage frames `body` (the fixed family header) plus attributes.
func nlMessage(typ, flags uint16, seq uint32, body []byte, attrs ...nlAttr) []byte {
	b := make([]byte, nlmsgHdrLen, 128)
	b = append(b, body...)
	for len(b)%4 != 0 {
		b = append(b, 0)
	}
	b = appendAttrs(b, attrs)
	binary.NativeEndian.PutUint32(b[0:4], uint32(len(b)))
	binary.NativeEndian.PutUint16(b[4:6], typ)
	binary.NativeEndian.PutUint16(b[6:8], flags)
	binary.NativeEndian.PutUint32(b[8:12], seq)
	return b
}

func u32Attr(typ uint16, v uint32) nlAttr {
	return nlAttr{typ, binary.NativeEndian.AppendUint32(nil, v)}
}

func ip4Attr(typ uint16, ip netip.Addr) nlAttr {
	a := ip.As4()
	return nlAttr{typ, a[:]}
}

// linkUpMsg is `ip link set dev <index> up`. It carries no MTU: the kernel
// applies IFLA_MTU before the flags and stops at the first error, so a
// rejected MTU in the same message would leave the link down.
func linkUpMsg(seq uint32, index int) []byte {
	body := make([]byte, 16) // ifinfomsg
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	binary.NativeEndian.PutUint32(body[8:12], iffUp)
	binary.NativeEndian.PutUint32(body[12:16], iffUp)
	return nlMessage(rtmNewLink, nlmFRequest|nlmFAck, seq, body)
}

// linkMTUMsg is `ip link set dev <index> mtu N`; the flags are left alone.
func linkMTUMsg(seq uint32, index int, mtu uint32) []byte {
	body := make([]byte, 16) // ifinfomsg, ifi_change 0
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	return nlMessage(rtmNewLink, nlmFRequest|nlmFAck, seq, body, u32Attr(iflaMTU, mtu))
}

// addrReplaceMsg is `ip addr replace <prefix> dev <index>`.
func addrReplaceMsg(seq uint32, index int, prefix netip.Prefix, scope uint8) []byte {
	body := make([]byte, 8) // ifaddrmsg
	body[0] = afInet
	body[1] = uint8(prefix.Bits())
	body[3] = scope
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	attrs := []nlAttr{ip4Attr(ifaLocal, prefix.Addr()), ip4Attr(ifaAddress, prefix.Addr())}
	if prefix.Bits() < 31 {
		attrs = append(attrs, ip4Attr(ifaBroadcast, broadcast4(prefix)))
	}
	return nlMessage(rtmNewAddr, nlmFRequest|nlmFAck|nlmFCreate|nlmFReplace, seq, body, attrs...)
}

func broadcast4(p netip.Prefix) netip.Addr {
	a := p.Masked().Addr().As4()
	host := uint32(1)<<(32-p.Bits()) - 1
	v := binary.BigEndian.Uint32(a[:]) | host
	binary.BigEndian.PutUint32(a[:], v)
	return netip.AddrFrom4(a)
}

// defaultRouteReplaceMsg is `ip route replace default via <gw> dev <index>`.
func defaultRouteReplaceMsg(seq uint32, index int, gw netip.Addr) []byte {
	body := []byte{afInet, 0, 0, 0, rtTableMain, rtprotBoot, rtScopeUniverse, rtnUnicast, 0, 0, 0, 0}
	return nlMessage(rtmNewRoute, nlmFRequest|nlmFAck|nlmFCreate|nlmFReplace, seq, body,
		ip4Attr(rtaGateway, gw), u32Attr(rtaOIF, uint32(index)))
}

// neighReplaceMsg is `ip neigh replace <ip> lladdr <mac> nud permanent dev <index>`.
func neighReplaceMsg(seq uint32, index int, ip netip.Addr, mac [6]byte) []byte {
	body := make([]byte, 12) // ndmsg
	body[0] = afInet
	binary.NativeEndian.PutUint32(body[4:8], uint32(index))
	binary.NativeEndian.PutUint16(body[8:10], nudPermanent)
	return nlMessage(rtmNewNeigh, nlmFRequest|nlmFAck|nlmFCreate|nlmFReplace, seq, body,
		ip4Attr(ndaDst, ip), nlAttr{ndaLLAddr, mac[:]})
}

// dumpMsg requests every object of one kind for an address family.
func dumpMsg(typ uint16, seq uint32, family uint8) []byte {
	var body []byte
	switch typ {
	case rtmGetAddr:
		body = []byte{family, 0, 0, 0, 0, 0, 0, 0}
	case rtmGetRoute:
		body = []byte{family, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	default: // rtmGetNeigh
		body = []byte{family, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	}
	return nlMessage(typ, nlmFRequest|nlmFDump, seq, body)
}

type nlMsg struct {
	typ   uint16
	flags uint16
	seq   uint32
	body  []byte
}

func parseNlMessages(b []byte) ([]nlMsg, error) {
	var out []nlMsg
	for len(b) >= nlmsgHdrLen {
		n := int(binary.NativeEndian.Uint32(b[0:4]))
		if n < nlmsgHdrLen || n > len(b) {
			return out, fmt.Errorf("truncated netlink message (%d of %d bytes)", len(b), n)
		}
		out = append(out, nlMsg{
			typ:   binary.NativeEndian.Uint16(b[4:6]),
			flags: binary.NativeEndian.Uint16(b[6:8]),
			seq:   binary.NativeEndian.Uint32(b[8:12]),
			body:  b[nlmsgHdrLen:n],
		})
		b = b[min(nlAlign(n), len(b)):]
	}
	return out, nil
}

// collectReplies folds one received datagram into `out`: the replies to `seq`
// (dump records are copied, since the caller reuses its receive buffer). It
// reports completion at the ACK/error or NLMSG_DONE, with the kernel's errno.
func collectReplies(datagram []byte, seq uint32, dump bool, out []nlMsg) ([]nlMsg, bool, int, error) {
	msgs, err := parseNlMessages(datagram)
	if err != nil {
		return out, false, 0, err
	}
	for _, m := range msgs {
		if m.seq != seq {
			continue // a reply to an earlier, abandoned request
		}
		switch {
		case m.typ == nlmsgError:
			return out, true, nlErrno(m), nil
		case m.typ == nlmsgDone:
			return out, true, 0, nil
		case dump:
			m.body = append([]byte(nil), m.body...)
			out = append(out, m)
		}
	}
	return out, false, 0, nil
}

// nlErrno is the errno carried by an NLMSG_ERROR reply (0 is a plain ACK).
func nlErrno(m nlMsg) int {
	if m.typ != nlmsgError || len(m.body) < 4 {
		return 0
	}
	return -int(int32(binary.NativeEndian.Uint32(m.body[0:4])))
}

func parseAttrs(b []byte) map[uint16][]byte {
	out := map[uint16][]byte{}
	for len(b) >= 4 {
		n := int(binary.NativeEndian.Uint16(b[0:2]))
		if n < 4 || n > len(b) {
			break
		}
		out[binary.NativeEndian.Uint16(b[2:4])&0x3fff] = b[4:n]
		b = b[min(nlAlign(n), len(b)):]
	}
	return out
}

func attrIP4(attrs map[uint16][]byte, typ uint16) (netip.Addr, bool) {
	v, ok := attrs[typ]
	if !ok || len(v) != 4 {
		return netip.Addr{}, false
	}
	return netip.AddrFrom4([4]byte(v)), true
}

type observedAddr struct {
	index  int
	prefix netip.Prefix
}

type observedRoute struct {
	index   int
	gateway netip.Addr
}

type observedNeigh struct {
	index int
	ip    netip.Addr
	mac   [6]byte
	state uint16
}

func parseAddrMsg(body []byte) (observedAddr, bool) {
	if len(body) < 8 || body[0] != afInet {
		return observedAddr{}, false
	}
	attrs := parseAttrs(body[8:])
	ip, ok := attrIP4(attrs, ifaLocal)
	if !ok {
		ip, ok = attrIP4(attrs, ifaAddress)
	}
	if !ok {
		return observedAddr{}, false
	}
	return observedAddr{int(binary.NativeEndian.Uint32(body[4:8])), netip.PrefixFrom(ip, int(body[1]))}, true
}

// parseDefaultRoute reports an IPv4 main-table default route with a gateway.
func parseDefaultRoute(body []byte) (observedRoute, bool) {
	if len(body) < 12 || body[0] != afInet || body[1] != 0 {
		return observedRoute{}, false
	}
	attrs := parseAttrs(body[12:])
	table := uint32(body[4])
	if v, ok := attrs[rtaTable]; ok && len(v) == 4 {
		table = binary.NativeEndian.Uint32(v)
	}
	gw, ok := attrIP4(attrs, rtaGateway)
	oif, hasOIF := attrs[rtaOIF]
	if table != rtTableMain || !ok || !hasOIF || len(oif) != 4 {
		return observedRoute{}, false
	}
	return observedRoute{int(binary.NativeEndian.Uint32(oif)), gw}, true
}

func parseNeighMsg(body []byte) (observedNeigh, bool) {
	if len(body) < 12 || body[0] != afInet {
		return observedNeigh{}, false
	}
	attrs := parseAttrs(body[12:])
	ip, ok := attrIP4(attrs, ndaDst)
	mac, hasMAC := attrs[ndaLLAddr]
	if !ok || !hasMAC || len(mac) != 6 {
		return observedNeigh{}, false
	}
	return observedNeigh{
		index: int(binary.NativeEndian.Uint32(body[4:8])),
		ip:    ip,
		mac:   [6]byte(mac),
		state: binary.NativeEndian.Uint16(body[8:10]),
	}, true
}

// ifacePlan is the configuration stage 2 applies to one guest interface.
type ifacePlan struct {
	name     string
	mtu      uint32 // 0 keeps the device default
	addr     netip.Prefix
	scope    uint8
	gateway  netip.Addr // default route via this interface when valid
	neighIP  netip.Addr // permanent neighbour entry when valid
	neighMAC [6]byte
}

// Host side of the published link (micropod-vmm NetConfig::published_link).
var publishedGatewayMAC = [6]byte{0x52, 0x54, 0x00, 0xab, 0xcd, 0x02}

func guestNetPlan(withPublished bool, publishedMTU uint32) []ifacePlan {
	plan := []ifacePlan{
		{name: "lo", addr: netip.MustParsePrefix("127.0.0.1/8"), scope: rtScopeHost},
		{name: "eth0", addr: netip.MustParsePrefix("10.42.0.2/24"), gateway: netip.MustParseAddr("10.42.0.1")},
	}
	if withPublished {
		plan = append(plan, ifacePlan{
			name:     "eth1",
			mtu:      publishedMTU,
			addr:     netip.MustParsePrefix("10.43.0.2/24"),
			neighIP:  netip.MustParseAddr("10.43.0.1"),
			neighMAC: publishedGatewayMAC,
		})
	}
	return plan
}

// publishedPathEnv maps `mp.published_path=` to MICROPOD_CI_PUBLISHED_PATH:
// unset keeps the historical macvlan default, `bridge` or `macvlan` select one,
// and `default` leaves the variable unset so the engine picks (kernel NAT or
// its relay), as the Virtualization.framework host does unless configured.
func publishedPathEnv(v string) (string, error) {
	switch v {
	case "":
		return "macvlan", nil
	case "macvlan", "bridge":
		return v, nil
	case "default":
		return "", nil
	}
	return "", fmt.Errorf("invalid mp.published_path=%q (want macvlan, bridge or default)", v)
}

type ifaceState struct {
	index int
	up    bool
	mtu   int
}

type netObservation struct {
	links  map[string]ifaceState
	addrs  []observedAddr
	routes []observedRoute
	neighs []observedNeigh
}

// verifyNetPlan lists every way the observed state differs from the plan.
func verifyNetPlan(plan []ifacePlan, obs netObservation) []string {
	var problems []string
	for _, p := range plan {
		link, ok := obs.links[p.name]
		if !ok {
			problems = append(problems, p.name+": interface missing")
			continue
		}
		if !link.up {
			problems = append(problems, p.name+": link is down")
		}
		if p.mtu != 0 && link.mtu != int(p.mtu) {
			problems = append(problems, fmt.Sprintf("%s: mtu %d, want %d", p.name, link.mtu, p.mtu))
		}
		if !containsAddr(obs.addrs, link.index, p.addr) {
			problems = append(problems, fmt.Sprintf("%s: address %s missing", p.name, p.addr))
		}
		if p.gateway.IsValid() && !containsRoute(obs.routes, link.index, p.gateway) {
			problems = append(problems, fmt.Sprintf("%s: default route via %s missing", p.name, p.gateway))
		}
		if p.neighIP.IsValid() && !containsNeigh(obs.neighs, link.index, p.neighIP, p.neighMAC) {
			problems = append(problems, fmt.Sprintf("%s: permanent neighbour %s missing", p.name, p.neighIP))
		}
	}
	return problems
}

func containsAddr(addrs []observedAddr, index int, want netip.Prefix) bool {
	for _, a := range addrs {
		if a.index == index && a.prefix == want {
			return true
		}
	}
	return false
}

func containsRoute(routes []observedRoute, index int, gw netip.Addr) bool {
	for _, r := range routes {
		if r.index == index && r.gateway == gw {
			return true
		}
	}
	return false
}

func containsNeigh(neighs []observedNeigh, index int, ip netip.Addr, mac [6]byte) bool {
	for _, n := range neighs {
		if n.index == index && n.ip == ip && n.mac == mac && n.state&nudPermanent != 0 {
			return true
		}
	}
	return false
}

// describeIface renders one interface's observed configuration for the console.
func describeIface(p ifacePlan, obs netObservation) string {
	link, ok := obs.links[p.name]
	if !ok {
		return p.name + " missing"
	}
	state := "down"
	if link.up {
		state = "up"
	}
	parts := []string{fmt.Sprintf("%s %s mtu=%d", p.name, state, link.mtu)}
	for _, a := range obs.addrs {
		if a.index == link.index {
			parts = append(parts, a.prefix.String())
		}
	}
	for _, r := range obs.routes {
		if r.index == link.index {
			parts = append(parts, "default via "+r.gateway.String())
		}
	}
	for _, n := range obs.neighs {
		if n.index == link.index && n.state&nudPermanent != 0 {
			parts = append(parts, fmt.Sprintf("neigh %s %s permanent", n.ip, net.HardwareAddr(n.mac[:])))
		}
	}
	return strings.Join(parts, " ")
}
