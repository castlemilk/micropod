package main

import (
	"bytes"
	"fmt"
	"net/netip"
	"strings"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

// The former general answer path built the whole packet before comparing its
// actual byte count to the transport limit.
func generalServiceAddresses(h dnsmessage.Header, q dnsmessage.Question, ips []netip.Addr, limit int) ([]byte, error) {
	reply := dnsmessage.Message{Header: h, Questions: []dnsmessage.Question{q}}
	for _, ip := range ips {
		reply.Answers = append(reply.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.AResource{A: ip.As4()}})
	}
	raw, err := reply.Pack()
	if err == nil && limit > 0 && len(raw) > limit {
		reply.Truncated = true
		reply.Answers = nil
		return reply.Pack()
	}
	return raw, err
}

func preparedQuestion(t testing.TB, q dnsmessage.Question, edns int) dnsmessage.Parser {
	t.Helper()
	request := dnsmessage.Message{Questions: []dnsmessage.Question{q}}
	if edns >= 0 {
		// An OPT can follow another additional record.
		root := dnsmessage.MustNewName(".")
		request.Additionals = []dnsmessage.Resource{
			{Header: dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET}, Body: &dnsmessage.AResource{A: [4]byte{192, 0, 2, 9}}},
			{Header: dnsmessage.ResourceHeader{Name: root, Class: dnsmessage.Class(edns)}, Body: &dnsmessage.OPTResource{}},
		}
	}
	wire, err := request.Pack()
	if err != nil {
		t.Fatal(err)
	}
	var p dnsmessage.Parser
	if _, err = p.Start(wire); err != nil {
		t.Fatal(err)
	}
	if _, err = p.Question(); err != nil {
		t.Fatal(err)
	}
	if _, err = p.Question(); err != dnsmessage.ErrSectionDone {
		t.Fatal("unexpected question boundary", err)
	}
	return p
}

func serviceAliasAddresses(count int) []netip.Addr {
	ips := make([]netip.Addr, count)
	for i := range ips {
		ips[i] = netip.AddrFrom4([4]byte{10, 80, byte(i / 256), byte(i)})
	}
	return ips
}

func packForTransport(h dnsmessage.Header, q dnsmessage.Question, ips []netip.Addr, network string, parser *dnsmessage.Parser, hasAdditional bool) ([]byte, error) {
	count := len(ips)
	if count > serviceAnswerLimit(&q, network, parser, hasAdditional, count) {
		ips = nil
	}
	return packServiceAddresses(h, q, ips, count)
}

func TestMultiServiceAWireAndTruncation(t *testing.T) {
	maxName := strings.Repeat(strings.Repeat("x", 63)+".", 3) + strings.Repeat("y", 61) + "."
	for _, name := range []string{"Db.Svc.", ".", maxName, strings.Repeat("x", 14) + ".", strings.Repeat("x", 15) + "."} {
		for _, n := range []int{2, 8, 30, 31, 64, 254, 255, 300} {
			ips := serviceAliasAddresses(n)
			for _, typ := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeALL} {
				q := dnsmessage.Question{Name: dnsmessage.MustNewName(name), Type: typ, Class: dnsmessage.ClassCHAOS}
				h := dnsmessage.Header{ID: 23, Response: true, Authoritative: true, RecursionDesired: true, RecursionAvailable: true}
				for _, edns := range []int{-1, 128, 512, 1232, 65535} {
					p := preparedQuestion(t, q, edns)
					for _, proto := range []string{"udp", "tcp"} {
						limit := 0
						if proto == "udp" {
							limit = min(4096, max(512, edns))
						}
						want, err := generalServiceAddresses(h, q, ips, limit)
						if err != nil {
							t.Fatal(err)
						}
						parser := p
						got, err := packForTransport(h, q, ips, proto, &parser, edns >= 0)
						if err != nil || !bytes.Equal(got, want) {
							t.Fatalf("name=%s answers=%d type=%v EDNS=%d proto=%s: wire mismatch, err=%v", name, n, typ, edns, proto, err)
						}
					}
				}
			}
		}
	}
}

func TestMultiServiceARejectsUnrepresentableCountBeforeTruncation(t *testing.T) {
	if _, err := packServiceAddresses(dnsmessage.Header{}, dnsmessage.Question{}, nil, 1<<16); err == nil {
		t.Fatal("unrepresentable count accepted")
	}
}

func BenchmarkPackMultiServiceA(b *testing.B) {
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("replicas.svc."), Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}
	h := dnsmessage.Header{ID: 123, Response: true, Authoritative: true}
	for _, c := range []struct {
		count   int
		network string
		edns    int
	}{{2, "udp", -1}, {8, "udp", -1}, {32, "udp", -1}, {64, "udp", 1232}, {256, "udp", 1232}, {256, "tcp", -1}} {
		ips := serviceAliasAddresses(c.count)
		parser := preparedQuestion(b, q, c.edns)
		limit := 0
		if c.network == "udp" {
			limit = max(512, c.edns)
		}
		for _, lane := range []string{"baseline", "candidate"} {
			b.Run(fmt.Sprintf("%d_%s_%d/%s", c.count, c.network, c.edns, lane), func(b *testing.B) {
				b.ReportAllocs()
				for b.Loop() {
					var err error
					if lane == "baseline" {
						dnsAnswerBytes, err = generalServiceAddresses(h, q, ips, limit)
					} else {
						p := parser
						dnsAnswerBytes, err = packForTransport(h, q, ips, c.network, &p, c.edns >= 0)
					}
					if err != nil {
						b.Fatal(err)
					}
				}
			})
		}
	}
}
