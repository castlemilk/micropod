package main

import (
	"context"
	"encoding/json"
	"net/netip"
	"strconv"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

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
