package main

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"strconv"
	"testing"

	"github.com/vishvananda/netlink"
	"golang.org/x/net/dns/dnsmessage"
)

func testWorkerRoute(prefix netip.Prefix) netlink.Route {
	return netlink.Route{Dst: &net.IPNet{IP: prefix.Addr().AsSlice(), Mask: net.CIDRMask(prefix.Bits(), prefix.Addr().BitLen())}}
}

func TestDockerAutoIPAMReadsRoutesOnce(t *testing.T) {
	routes := []netlink.Route{{}, testWorkerRoute(netip.MustParsePrefix("0.0.0.0/0"))}
	for index := range 31 {
		routes = append(routes, testWorkerRoute(automaticSubnet(index)))
	}
	reads := 0
	readRoutes := func() ([]netlink.Route, error) {
		reads++
		return routes, nil
	}
	if got := firstAutomaticSubnet(readRoutes); got != netip.MustParsePrefix("10.90.31.0/24") || reads != 1 {
		t.Fatalf("first allocation selected %s with %d route dumps", got, reads)
	}
	routes = append(routes, testWorkerRoute(netip.MustParsePrefix("10.90.31.0/24")))
	if got := firstAutomaticSubnet(readRoutes); got != netip.MustParsePrefix("10.90.32.0/24") || reads != 2 {
		t.Fatalf("next allocation selected %s with %d total route dumps", got, reads)
	}
}

func TestDockerAutoIPAMRouteOverlap(t *testing.T) {
	for _, tc := range []struct {
		name, route, want string
	}{
		{name: "default route", route: "0.0.0.0/0", want: "10.90.0.0/24"},
		{name: "outside pool", route: "10.89.0.0/16", want: "10.90.0.0/24"},
		{name: "host route", route: "10.90.0.27/32", want: "10.90.1.0/24"},
		{name: "nested route", route: "10.90.0.252/30", want: "10.90.1.0/24"},
		{name: "covering route", route: "10.90.0.0/19", want: "10.90.32.0/24"},
		{name: "occupied hole", route: "10.90.1.0/24", want: "10.90.0.0/24"},
		{name: "entire pool", route: "10.90.0.0/16"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			routes := []netlink.Route{testWorkerRoute(netip.MustParsePrefix(tc.route))}
			got := firstAutomaticSubnet(func() ([]netlink.Route, error) { return routes, nil })
			if tc.want == "" && !got.IsValid() {
				return
			}
			if got.String() != tc.want {
				t.Fatalf("got %s, want %q", got, tc.want)
			}
		})
	}
}

func TestDockerAutoIPAMRouteReadFailure(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want netip.Prefix
	}{
		{name: "interrupted dump recovered", want: netip.MustParsePrefix("10.90.1.0/24")},
		{name: "persistent read failure", err: errors.New("route read failed")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reads := 0
			readRoutes := func() ([]netlink.Route, error) {
				reads++
				if reads == 1 {
					return nil, netlink.ErrDumpInterrupted
				}
				return []netlink.Route{testWorkerRoute(automaticSubnet(0))}, tc.err
			}
			if got := firstAutomaticSubnet(readRoutes); got != tc.want || reads != 2 {
				t.Fatalf("got %s after %d route dumps, want %s after two", got, reads, tc.want)
			}
		})
	}
}

func TestDockerAutoIPAMExplicitSubnet(t *testing.T) {
	for _, tc := range []struct {
		prefix string
		allow  bool
		reads  int
	}{
		{prefix: "10.88.0.0/16"},
		{prefix: "10.89.255.0/24"},
		{prefix: "10.88.0.0/14"},
		{prefix: "10.90.0.32/29", reads: 1},
		{prefix: "10.90.0.40/29", allow: true, reads: 1},
		{prefix: "10.90.0.0/16", reads: 1},
	} {
		t.Run(tc.prefix, func(t *testing.T) {
			reads := 0
			readRoutes := func() ([]netlink.Route, error) {
				reads++
				return []netlink.Route{{}, testWorkerRoute(netip.MustParsePrefix("0.0.0.0/0")),
					testWorkerRoute(netip.MustParsePrefix("10.90.0.33/32"))}, nil
			}
			if got := subnetAvailable(netip.MustParsePrefix(tc.prefix), readRoutes); got != tc.allow || reads != tc.reads {
				t.Fatalf("allowed %t after %d route dumps, want %t after %d", got, reads, tc.allow, tc.reads)
			}
		})
	}
	reads := 0
	readRoutes := func() ([]netlink.Route, error) {
		reads++
		return nil, netlink.ErrDumpInterrupted
	}
	if subnetAvailable(netip.MustParsePrefix("10.90.0.0/24"), readRoutes) || reads != 1 {
		t.Fatalf("explicit subnet accepted an interrupted dump or retried (%d reads)", reads)
	}
}

func BenchmarkDockerAutoIPAM(b *testing.B) {
	if os.Getenv("MICROPOD_BENCH_DOCKER_IPAM") != "1" {
		b.Skip("enable on the disposable worker with the first 32 job networks present")
	}
	old := func(readRoutes workerRouteReader) netip.Prefix {
		for index := range 256 {
			subnet := automaticSubnet(index)
			if subnetAvailable(subnet, readRoutes) {
				return subnet
			}
		}
		return netip.Prefix{}
	}
	variants := []struct {
		name   string
		choose func(workerRouteReader) netip.Prefix
	}{{"per-candidate", old}, {"snapshot", firstAutomaticSubnet}}
	switch order := os.Getenv("MICROPOD_BENCH_DOCKER_IPAM_ORDER"); order {
	case "", "old-first":
	case "new-first":
		variants[0], variants[1] = variants[1], variants[0]
	default:
		b.Fatalf("invalid benchmark order %q", order)
	}
	want := netip.MustParsePrefix("10.90.32.0/24")
	for _, variant := range variants {
		b.Run(variant.name, func(b *testing.B) {
			reads := 0
			readRoutes := func() ([]netlink.Route, error) {
				reads++
				return workerIPv4Routes()
			}
			b.ReportAllocs()
			for b.Loop() {
				if got := variant.choose(readRoutes); got != want {
					b.Fatalf("selected %s, want %s with the first 32 job networks present", got, want)
				}
			}
			b.ReportMetric(float64(reads)/float64(b.N), "route-dumps/op")
		})
	}
}

func TestServiceDirectoryIsScopedAndDropsOnlyExitedAddress(t *testing.T) {
	s := new(dockerEngine)
	n := &workerNetwork{Internal: true}
	other := &workerNetwork{Internal: true}
	c := &dockerContainer{IP: "10.90.0.3", dockerRecord: dockerRecord{Name: "svc", Config: dockerConfig{Aliases: []string{"BACKEND", "backend"}}}}
	peer := &dockerContainer{IP: "10.90.0.4", dockerRecord: dockerRecord{Name: "peer", Config: dockerConfig{Aliases: []string{"backend"}}}}
	n.services.publish(c, true)
	n.services.publish(peer, true)
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 123}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("backend."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	wire, err := q.Pack()
	if err != nil {
		t.Fatal(err)
	}
	ask := func(n *workerNetwork) dnsmessage.Message {
		t.Helper()
		var ans dnsmessage.Message
		if err := ans.Unpack(s.dnsReply(context.Background(), n, nil, wire, "udp")); err != nil {
			t.Fatal(err)
		}
		return ans
	}
	if len(ask(n).Answers) != 2 || ask(other).RCode != dnsmessage.RCodeNameError {
		t.Fatal("DNS membership crossed networks or duplicated an alias")
	}
	n.services.publish(c, false)
	if a := ask(n).Answers; len(a) != 1 || a[0].Body.(*dnsmessage.AResource).A != netip.MustParseAddr(peer.IP).As4() {
		t.Fatal(a)
	}
	n.services.publish(peer, false)
	if ask(n).RCode != dnsmessage.RCodeNameError {
		t.Fatal("stale DNS record")
	}
	if s.metrics.networks.dnsMissing.Load() != 2 || s.metrics.networks.dnsLocal.Load() != 2 {
		t.Fatal("incorrect DNS metrics")
	}
	b, err := json.Marshal(n)
	if err != nil {
		t.Fatal(err)
	}
	var restored workerNetwork
	if err = json.Unmarshal(b, &restored); err != nil || restored.services.contains("backend") {
		t.Fatal("persisted transient endpoints", err)
	}
}

func TestServiceAliasesRespectDNSPayloadSize(t *testing.T) {
	s := new(dockerEngine)
	n := &workerNetwork{Internal: true}
	for i := range 64 {
		n.services.publish(&dockerContainer{IP: netip.AddrFrom4([4]byte{10, 90, 0, byte(i + 2)}).String(), dockerRecord: dockerRecord{Name: "replica", Config: dockerConfig{Aliases: []string{"backend"}}}}, true)
	}
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 7}, Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName("backend."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	ask := func(transport string) dnsmessage.Message {
		t.Helper()
		wire, err := q.Pack()
		if err != nil {
			t.Fatal(err)
		}
		var a dnsmessage.Message
		if err := a.Unpack(s.dnsReply(context.Background(), n, nil, wire, transport)); err != nil {
			t.Fatal(err)
		}
		return a
	}
	if a := ask("udp"); !a.Truncated {
		t.Fatal("oversized legacy UDP response")
	}
	if a := ask("tcp"); a.Truncated || len(a.Answers) != 64 {
		t.Fatal("missing answers over TCP")
	}
	q.Additionals = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName("."), Type: dnsmessage.TypeOPT, Class: 4096}, Body: &dnsmessage.OPTResource{}}}
	if a := ask("udp"); a.Truncated || len(a.Answers) != 64 {
		t.Fatal("incorrect EDNS response")
	}
}

func TestServiceDNSNonAddressQuestionsKeepLocalAuthority(t *testing.T) {
	// A replica alias must answer AAAA/TXT locally even when the service only
	// publishes IPv4 addresses. The same name outside its directory is a miss.
	for _, typ := range []dnsmessage.Type{dnsmessage.TypeAAAA, dnsmessage.TypeTXT} {
		for _, tc := range []struct {
			records                   []netip.Addr
			internal                  bool
			code                      dnsmessage.RCode
			local, missing, forwarded uint64
		}{
			{[]netip.Addr{netip.MustParseAddr("10.9.0.2"), netip.MustParseAddr("10.9.0.3")}, false, dnsmessage.RCodeSuccess, 1, 0, 0},
			{nil, true, dnsmessage.RCodeNameError, 0, 1, 0},
			{nil, false, dnsmessage.RCodeServerFailure, 0, 0, 1},
		} {
			s := new(dockerEngine)
			n := &workerNetwork{Internal: tc.internal}
			n.services.records = map[string][]netip.Addr{"db.svc": tc.records}
			q := dnsmessage.Question{Name: dnsmessage.MustNewName("Db.SvC."), Type: typ, Class: dnsmessage.ClassINET}
			m := dnsmessage.Message{Header: dnsmessage.Header{ID: 21, RecursionDesired: true}, Questions: []dnsmessage.Question{q}}
			wire, err := m.Pack()
			if err != nil {
				t.Fatal(err)
			}
			var got dnsmessage.Message
			if err := got.Unpack(s.dnsReply(context.Background(), n, nil, wire, "udp")); err != nil {
				t.Fatal(err)
			}
			if got.RCode != tc.code || len(got.Answers) != 0 || got.Authoritative != (tc.forwarded == 0) || len(got.Questions) != 1 || got.Questions[0] != q {
				t.Fatalf("bad %s answer: %+v", typ, got)
			}
			metrics := &s.metrics.networks
			if metrics.dnsLocal.Load() != tc.local || metrics.dnsMissing.Load() != tc.missing || metrics.dnsForwarded.Load() != tc.forwarded {
				t.Fatalf("incorrect %s DNS counters", typ)
			}
		}
	}
}

// A membership change between the count check and the bounded copy must
// yield a complete answer for one state, including forwarding a vanished name.
func TestServiceDNSMembershipChangesDuringReply(t *testing.T) {
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("web.svc."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
	request := dnsmessage.Message{Questions: []dnsmessage.Question{q}, Additionals: []dnsmessage.Resource{{
		Header: dnsmessage.ResourceHeader{Name: dnsmessage.MustNewName("."), Type: dnsmessage.TypeOPT, Class: 1232},
		Body:   &dnsmessage.OPTResource{},
	}}}
	wire, err := request.Pack()
	if err != nil {
		t.Fatal(err)
	}
	n := &workerNetwork{}
	n.services.records = make(map[string][]netip.Addr)
	states := make([][]netip.Addr, 0, 5)
	for _, count := range []int{0, 1, 9, 60, 80} {
		var ips []netip.Addr
		for i := range count {
			ips = append(ips, netip.AddrFrom4([4]byte{10, 42, byte(count), byte(i + 1)}))
		}
		states = append(states, ips)
	}
	stop, done := make(chan struct{}), make(chan struct{})
	go func() {
		defer close(done)
		for {
			for _, ips := range states {
				select {
				case <-stop:
					return
				default:
				}
				n.services.mu.Lock()
				n.services.records["web.svc"] = ips
				n.services.mu.Unlock()
			}
		}
	}()
	defer func() { close(stop); <-done }()
	s := new(dockerEngine)
	for range 3000 {
		var reply dnsmessage.Message
		if err := reply.Unpack(s.dnsReply(context.Background(), n, nil, wire, "udp")); err != nil {
			t.Fatal(err)
		}
		count := len(reply.Answers)
		switch {
		case reply.RCode == dnsmessage.RCodeServerFailure:
			if count != 0 || reply.Authoritative || reply.Truncated {
				t.Fatal("bad forwarded miss", reply.Header, count)
			}
		case reply.RCode != dnsmessage.RCodeSuccess || !reply.Authoritative:
			t.Fatal("bad local answer", reply.Header)
		case reply.Truncated:
			if count != 0 {
				t.Fatal("partially encoded truncated answer", count)
			}
		default:
			if count != 1 && count != 9 && count != 60 {
				t.Fatal("inconsistent answer count", count)
			}
			for i, a := range reply.Answers {
				if a.Body.(*dnsmessage.AResource).A != [4]byte{10, 42, byte(count), byte(i + 1)} {
					t.Fatal("mixed addresses from different directory states", count, i)
				}
			}
		}
	}
}

func TestServiceDNSRejectsExtraQuestions(t *testing.T) {
	n := &workerNetwork{Internal: true}
	s := new(dockerEngine)
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("unused."), Type: dnsmessage.TypeAAAA, Class: dnsmessage.ClassINET}
	m := dnsmessage.Message{Questions: []dnsmessage.Question{q, q}}
	wire, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	for _, input := range [][]byte{wire, wire[:len(wire)-1]} {
		if reply := s.dnsReply(context.Background(), n, nil, input, "udp"); reply != nil {
			t.Fatalf("unexpected reply to extra question: %x", reply)
		}
	}
	if s.metrics.networks.dnsMissing.Load() != 0 {
		t.Fatal("invalid question counted as a miss")
	}
}

func BenchmarkServiceDNSQuestions(b *testing.B) {
	for _, count := range []int{0, 1, 8, 256} {
		n := &workerNetwork{Internal: true}
		n.services.records = make(map[string][]netip.Addr)
		for i := range count {
			ip := netip.AddrFrom4([4]byte{10, 0, byte(i >> 8), byte(i)})
			n.services.records["alias.svc"] = append(n.services.records["alias.svc"], ip)
		}
		for _, pattern := range []struct {
			name  string
			types []dnsmessage.Type
		}{
			{"A", []dnsmessage.Type{dnsmessage.TypeA}},
			{"AAAA", []dnsmessage.Type{dnsmessage.TypeAAAA}},
			{"alternating", []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA}},
		} {
			b.Run(strconv.Itoa(count)+"/"+pattern.name, func(b *testing.B) {
				s := new(dockerEngine)
				var requests [][]byte
				for _, typ := range pattern.types {
					q := dnsmessage.Question{Name: dnsmessage.MustNewName("alias.svc."), Type: typ, Class: dnsmessage.ClassINET}
					m := dnsmessage.Message{Header: dnsmessage.Header{ID: 42, RecursionDesired: true}, Questions: []dnsmessage.Question{q}}
					wire, err := m.Pack()
					if err != nil {
						b.Fatal(err)
					}
					requests = append(requests, wire)
				}
				b.ReportAllocs()
				i := 0
				for b.Loop() {
					if s.dnsReply(context.Background(), n, nil, requests[i], "udp") == nil {
						b.Fatal("missing DNS response")
					}
					i++
					if i == len(requests) {
						i = 0
					}
				}
			})
		}
	}
}
