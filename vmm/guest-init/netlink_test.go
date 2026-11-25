package main

import (
	"encoding/binary"
	"net/netip"
	"strings"
	"testing"
)

func singleMessage(t *testing.T, b []byte) nlMsg {
	t.Helper()
	if len(b)%4 != 0 || int(binary.NativeEndian.Uint32(b[0:4])) != len(b) {
		t.Fatalf("bad framing: len field %d, %d bytes", binary.NativeEndian.Uint32(b[0:4]), len(b))
	}
	msgs, err := parseNlMessages(b)
	if err != nil || len(msgs) != 1 {
		t.Fatalf("parse: %v (%d messages)", err, len(msgs))
	}
	return msgs[0]
}

func TestLinkUpAndMTUAreSeparateRequests(t *testing.T) {
	m := singleMessage(t, linkUpMsg(7, 3))
	if m.typ != rtmNewLink || m.seq != 7 || m.flags != nlmFRequest|nlmFAck {
		t.Fatalf("header %+v", m)
	}
	if idx := binary.NativeEndian.Uint32(m.body[4:8]); idx != 3 {
		t.Fatalf("index %d", idx)
	}
	if flags, change := binary.NativeEndian.Uint32(m.body[8:12]), binary.NativeEndian.Uint32(m.body[12:16]); flags != iffUp || change != iffUp {
		t.Fatalf("flags %#x change %#x", flags, change)
	}
	if _, ok := parseAttrs(m.body[16:])[iflaMTU]; ok {
		t.Fatal("link up must not carry an MTU: a rejected MTU would keep the link down")
	}

	mtu := singleMessage(t, linkMTUMsg(8, 3, 9000))
	if mtu.typ != rtmNewLink || mtu.seq != 8 || binary.NativeEndian.Uint32(mtu.body[4:8]) != 3 {
		t.Fatalf("mtu header %+v", mtu)
	}
	if change := binary.NativeEndian.Uint32(mtu.body[12:16]); change != 0 {
		t.Fatalf("mtu request changes flags %#x", change)
	}
	if v := parseAttrs(mtu.body[16:])[iflaMTU]; len(v) != 4 || binary.NativeEndian.Uint32(v) != 9000 {
		t.Fatalf("mtu attr %v", v)
	}
}

func TestAddressRouteAndNeighbourMessagesRoundTrip(t *testing.T) {
	prefix := netip.MustParsePrefix("10.43.0.2/24")
	m := singleMessage(t, addrReplaceMsg(1, 4, prefix, rtScopeUniverse))
	if m.typ != rtmNewAddr || m.flags != nlmFRequest|nlmFAck|nlmFCreate|nlmFReplace {
		t.Fatalf("addr header %+v", m)
	}
	a, ok := parseAddrMsg(m.body)
	if !ok || a.index != 4 || a.prefix != prefix {
		t.Fatalf("addr round trip %+v %v", a, ok)
	}
	if bc, _ := attrIP4(parseAttrs(m.body[8:]), ifaBroadcast); bc != netip.MustParseAddr("10.43.0.255") {
		t.Fatalf("broadcast %v", bc)
	}
	lo := singleMessage(t, addrReplaceMsg(2, 1, netip.MustParsePrefix("127.0.0.1/8"), rtScopeHost))
	if lo.body[3] != rtScopeHost {
		t.Fatalf("loopback scope %d", lo.body[3])
	}

	gw := netip.MustParseAddr("10.42.0.1")
	r := singleMessage(t, defaultRouteReplaceMsg(3, 2, gw))
	if r.typ != rtmNewRoute || r.body[4] != rtTableMain || r.body[7] != rtnUnicast {
		t.Fatalf("route %+v", r)
	}
	route, ok := parseDefaultRoute(r.body)
	if !ok || route.index != 2 || route.gateway != gw {
		t.Fatalf("route round trip %+v %v", route, ok)
	}

	ip := netip.MustParseAddr("10.43.0.1")
	n := singleMessage(t, neighReplaceMsg(4, 4, ip, publishedGatewayMAC))
	if n.typ != rtmNewNeigh {
		t.Fatalf("neigh type %d", n.typ)
	}
	neigh, ok := parseNeighMsg(n.body)
	if !ok || neigh.index != 4 || neigh.ip != ip || neigh.mac != publishedGatewayMAC || neigh.state != nudPermanent {
		t.Fatalf("neigh round trip %+v %v", neigh, ok)
	}
}

func TestParseRepliesAndErrors(t *testing.T) {
	// Two replies in one datagram: a kernel error for seq 9, then NLMSG_DONE.
	eexist := int32(-17)
	errBody := binary.NativeEndian.AppendUint32(nil, uint32(eexist))
	errBody = append(errBody, make([]byte, nlmsgHdrLen)...)
	buf := append(nlMessage(nlmsgError, 0, 9, errBody), nlMessage(nlmsgDone, 0, 9, []byte{0, 0, 0, 0})...)
	msgs, err := parseNlMessages(buf)
	if err != nil || len(msgs) != 2 {
		t.Fatalf("parse %v %d", err, len(msgs))
	}
	if nlErrno(msgs[0]) != 17 || nlErrno(msgs[1]) != 0 {
		t.Fatalf("errno %d %d", nlErrno(msgs[0]), nlErrno(msgs[1]))
	}
	ack := nlMessage(nlmsgError, 0, 9, make([]byte, 4+nlmsgHdrLen))
	if m, _ := parseNlMessages(ack); nlErrno(m[0]) != 0 {
		t.Fatal("an error code of 0 is an ACK")
	}
	if _, err := parseNlMessages(buf[:20]); err == nil {
		t.Fatal("a truncated message must be reported")
	}
	// Routes outside the main table or with a destination are not "default via".
	other := defaultRouteReplaceMsg(1, 2, netip.MustParseAddr("10.42.0.1"))
	other[nlmsgHdrLen+4] = 255 // RT_TABLE_LOCAL
	if _, ok := parseDefaultRoute(singleMessage(t, other).body); ok {
		t.Fatal("local-table route accepted")
	}
}

func TestCollectRepliesSurvivesReceiveBufferReuse(t *testing.T) {
	// A dump arrives as records in one datagram and NLMSG_DONE in the next, both
	// received into the same buffer. Records kept from the first must survive.
	route := defaultRouteReplaceMsg(5, 2, netip.MustParseAddr("10.42.0.1"))
	stale := nlMessage(rtmNewRoute, 0, 4, make([]byte, 12))
	buf := make([]byte, 4096)
	n := copy(buf, append(stale, route...))
	out, done, errno, err := collectReplies(buf[:n], 5, true, nil)
	if err != nil || done || errno != 0 || len(out) != 1 {
		t.Fatalf("first datagram: %v %v %d %d", err, done, errno, len(out))
	}
	n = copy(buf, nlMessage(nlmsgDone, 0, 5, []byte{0, 0, 0, 0}))
	out, done, _, err = collectReplies(buf[:n], 5, true, out)
	if err != nil || !done {
		t.Fatalf("second datagram: %v %v", err, done)
	}
	if r, ok := parseDefaultRoute(out[0].body); !ok || r.gateway != netip.MustParseAddr("10.42.0.1") {
		t.Fatalf("dump record was clobbered by the next receive: %+v %v", r, ok)
	}

	// A request ends at its ACK or error; records are not collected.
	n = copy(buf, nlMessage(nlmsgError, 0, 6, make([]byte, 4+nlmsgHdrLen)))
	out, done, errno, _ = collectReplies(buf[:n], 6, false, nil)
	if !done || errno != 0 || len(out) != 0 {
		t.Fatalf("ack: %v %d %d", done, errno, len(out))
	}
}

func TestPublishedPathEnv(t *testing.T) {
	for in, want := range map[string]string{"": "macvlan", "macvlan": "macvlan", "bridge": "bridge", "default": ""} {
		if got, err := publishedPathEnv(in); err != nil || got != want {
			t.Fatalf("%q -> %q, %v", in, got, err)
		}
	}
	if _, err := publishedPathEnv("nat"); err == nil {
		t.Fatal("unknown published path accepted")
	}
}

func goodObservation(plan []ifacePlan) netObservation {
	obs := netObservation{links: map[string]ifaceState{}}
	for i, p := range plan {
		mtu := 1500
		if p.mtu != 0 {
			mtu = int(p.mtu)
		}
		obs.links[p.name] = ifaceState{index: i + 1, up: true, mtu: mtu}
		obs.addrs = append(obs.addrs, observedAddr{i + 1, p.addr})
		if p.gateway.IsValid() {
			obs.routes = append(obs.routes, observedRoute{i + 1, p.gateway})
		}
		if p.neighIP.IsValid() {
			obs.neighs = append(obs.neighs, observedNeigh{i + 1, p.neighIP, p.neighMAC, nudPermanent})
		}
	}
	return obs
}

func TestVerifyNetPlan(t *testing.T) {
	plan := guestNetPlan(true, 9000)
	if len(plan) != 3 || plan[2].name != "eth1" || plan[2].neighMAC != publishedGatewayMAC {
		t.Fatalf("plan %+v", plan)
	}
	if got := len(guestNetPlan(false, 0)); got != 2 {
		t.Fatalf("plan without the published link has %d interfaces", got)
	}
	obs := goodObservation(plan)
	if problems := verifyNetPlan(plan, obs); len(problems) != 0 {
		t.Fatalf("unexpected problems %v", problems)
	}
	if d := describeIface(plan[2], obs); d != "eth1 up mtu=9000 10.43.0.2/24 neigh 10.43.0.1 52:54:00:ab:cd:02 permanent" {
		t.Fatalf("describe %q", d)
	}
	if d := describeIface(plan[1], obs); d != "eth0 up mtu=1500 10.42.0.2/24 default via 10.42.0.1" {
		t.Fatalf("describe %q", d)
	}

	bad := goodObservation(plan)
	bad.links["eth0"] = ifaceState{index: 2, up: false, mtu: 1500}
	bad.links["eth1"] = ifaceState{index: 3, up: true, mtu: 1500}
	bad.addrs = bad.addrs[:1]
	bad.routes = nil
	bad.neighs[0].state = 0x02 // NUD_REACHABLE, learned rather than pinned
	problems := strings.Join(verifyNetPlan(plan, bad), "; ")
	for _, want := range []string{
		"eth0: link is down", "eth0: address 10.42.0.2/24 missing", "default route via 10.42.0.1 missing",
		"eth1: mtu 1500, want 9000", "eth1: permanent neighbour 10.43.0.1 missing",
	} {
		if !strings.Contains(problems, want) {
			t.Fatalf("missing %q in %q", want, problems)
		}
	}
	delete(bad.links, "eth1")
	if !strings.Contains(strings.Join(verifyNetPlan(plan, bad), ";"), "eth1: interface missing") {
		t.Fatal("a missing interface must be reported")
	}
}
