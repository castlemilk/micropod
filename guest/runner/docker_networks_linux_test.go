package main

import (
	"context"
	"encoding/json"
	"net/netip"
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
	if err = json.Unmarshal(b, &restored); err != nil || len(restored.services.lookup("backend")) != 0 {
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
