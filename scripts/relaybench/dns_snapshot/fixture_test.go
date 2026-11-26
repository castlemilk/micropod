// Local DNS fixture. The driver compiles both revisions with the same inputs.
package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"net/netip"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

type workerNetwork struct {
	Internal bool
	services serviceDirectory
}

type dockerContainer struct {
	IP, Name string
	Config   struct {
		Hostname string
		Aliases  []string
	}
}

type dockerEngine struct {
	metrics struct{ networks networkMetrics }
}

func setup(count int) (*workerNetwork, []dockerContainer) {
	n := &workerNetwork{Internal: true}
	members := make([]dockerContainer, count)
	for i := range members {
		c := &members[i]
		c.Name = fmt.Sprintf("worker-%d", i)
		c.IP = netip.AddrFrom4([4]byte{10, 23, byte(i >> 8), byte(i)}).String()
		c.Config.Aliases = []string{"web.svc"}
		n.services.publish(c, true)
	}
	return n, members
}

func query(t testing.TB, qtype dnsmessage.Type) []byte {
	t.Helper()
	q := dnsmessage.Question{Name: dnsmessage.MustNewName("WeB.sVc."), Type: qtype, Class: dnsmessage.ClassINET}
	m := dnsmessage.Message{Header: dnsmessage.Header{ID: 882, RecursionDesired: true}, Questions: []dnsmessage.Question{q}}
	wire, err := m.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return wire
}

func TestReplies(t *testing.T) {
	digest := sha256.New()
	queries := 0
	for _, count := range []int{0, 1, 8, 256} {
		n, members := setup(count)
		engine := new(dockerEngine)
		lookup := func(expected []dockerContainer) {
			for _, transport := range []string{"udp", "tcp"} {
				for _, qtype := range []dnsmessage.Type{dnsmessage.TypeA, dnsmessage.TypeAAAA, dnsmessage.TypeALL} {
					wire := engine.dnsReply(context.Background(), n, nil, query(t, qtype), transport)
					var reply dnsmessage.Message
					if err := reply.Unpack(wire); err != nil {
						t.Fatal(err)
					}
					addresses := qtype != dnsmessage.TypeAAAA
					truncated := addresses && transport == "udp" && len(expected) > 30
					want := 0
					if addresses && !truncated {
						want = len(expected)
					}
					if !reply.Response || !reply.Authoritative || (reply.RCode == dnsmessage.RCodeNameError) != (len(expected) == 0) ||
						reply.Truncated != truncated || len(reply.Answers) != want {
						t.Fatalf("%d records %s/%v flags %v with %d answers", count, transport, qtype, reply.Header, len(reply.Answers))
					}
					for k, answer := range reply.Answers {
						got := netip.AddrFrom4(answer.Body.(*dnsmessage.AResource).A)
						if got.String() != expected[k].IP {
							t.Fatalf("address %d: got %s, want %s", k, got, expected[k].IP)
						}
					}
					fmt.Fprintf(digest, "%d:", len(wire))
					digest.Write(wire)
					queries++
				}
			}
		}
		lookup(members)
		if count > 0 {
			index := count / 2
			c := members[index]
			n.services.publish(&c, false)
			next := append([]dockerContainer(nil), members[:index]...)
			next = append(next, members[index+1:]...)
			lookup(next)
			n.services.publish(&c, true)
			lookup(append(next, c))
		}
		m := &engine.metrics.networks
		wantLocal, wantMissing := uint64(18), uint64(0)
		switch count {
		case 0:
			wantLocal, wantMissing = 0, 6
		case 1:
			wantLocal, wantMissing = 12, 6
		}
		if m.dnsLocal.Load() != wantLocal || m.dnsMissing.Load() != wantMissing || m.dnsFailures.Load() != 0 || m.dnsForwarded.Load() != 0 {
			t.Fatal("DNS metrics", m.snapshot())
		}
	}
	t.Logf("verified %d responses %x", queries, digest.Sum(nil))
}

func BenchmarkSnapshot(b *testing.B) {
	for _, count := range []int{0, 1, 8, 256} {
		n, _ := setup(count)
		for _, mix := range []string{"A", "AAAA", "alternating"} {
			b.Run(fmt.Sprintf("lookup/%d/%s", count, mix), func(b *testing.B) {
				engine := new(dockerEngine)
				a := query(b, dnsmessage.TypeA)
				aaaa := query(b, dnsmessage.TypeAAAA)
				requests := [2][]byte{a, a}
				if mix == "AAAA" {
					requests = [2][]byte{aaaa, aaaa}
				} else if mix == "alternating" {
					requests[1] = aaaa
				}
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					if engine.dnsReply(context.Background(), n, nil, requests[i%2], "udp") == nil {
						b.Fatal("missing response")
					}
				}
			})
		}
		if count > 0 {
			b.Run(fmt.Sprintf("publish/%d", count), func(b *testing.B) {
				// Each removal is at the middle. Re-insertion moves it to the tail.
				start := count / 2
				own, ordered := setup(count)
				b.ReportAllocs()
				b.ResetTimer()
				for i := 0; i < b.N; i++ {
					member := &ordered[start+i%(len(ordered)-start)]
					own.services.publish(member, false)
					own.services.publish(member, true)
				}
			})
		}
	}
}
