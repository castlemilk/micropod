package main

import (
	"net/netip"
	"slices"
	"strings"
	"testing"

	"golang.org/x/net/dns/dnsmessage"
)

func sandboxDNSQuestion(t *testing.T, name string, kind dnsmessage.Type) []byte {
	t.Helper()
	query := dnsmessage.Message{
		Header:    dnsmessage.Header{ID: 42, RecursionDesired: true},
		Questions: []dnsmessage.Question{{Name: dnsmessage.MustNewName(name + "."), Type: kind, Class: dnsmessage.ClassINET}},
	}
	packet, err := query.Pack()
	if err != nil {
		t.Fatal(err)
	}
	return packet
}

func assertSandboxDNS(t *testing.T, d *dockerSandboxDNS, transport, name string, kind dnsmessage.Type, code dnsmessage.RCode, addresses ...string) {
	t.Helper()
	raw, forward, _, _, _ := d.answer(sandboxDNSQuestion(t, name, kind), transport, nil)
	var reply dnsmessage.Message
	if err := reply.Unpack(raw); forward || err != nil {
		t.Fatalf("%s lookup %q returned forward=%v, decode=%v", transport, name, forward, err)
	}
	if !reply.Response || reply.ID != 42 || reply.RCode != code {
		t.Fatalf("%s lookup %q header = %+v", transport, name, reply.Header)
	}
	var got []string
	for _, rr := range reply.Answers {
		address, ok := rr.Body.(*dnsmessage.AResource)
		if !ok {
			t.Fatalf("%s lookup %q unexpected answer %v", transport, name, rr)
		}
		got = append(got, netip.AddrFrom4(address.A).String())
	}
	if !slices.Equal(got, addresses) {
		t.Fatalf("%s lookup %q addresses = %v, want %v", transport, name, got, addresses)
	}
}

func TestDockerSandboxDNSAttachmentScopeAndAliases(t *testing.T) {
	first, second := &workerNetwork{Internal: true}, &workerNetwork{Internal: true}
	first.services.publishEndpoint("app", "", []string{"Alias-A", "shared"}, "10.90.1.3", true)
	second.services.publishEndpoint("app", "", []string{"Alias-B", "shared"}, "10.90.2.3", true)
	second.services.publishEndpoint("sidecar", "sidecar-b", nil, "10.90.2.4", true)
	another := &workerNetwork{Internal: true}
	another.services.publishEndpoint("elsewhere", "", nil, "10.90.3.3", true)
	engine := new(dockerEngine)
	primary := &dockerSandboxDNS{engine: engine, internal: true}
	secondary := &dockerSandboxDNS{engine: engine, internal: true}
	primary.setNetworks([]*workerNetwork{first})
	secondary.setNetworks([]*workerNetwork{second})

	for _, transport := range []string{"udp", "tcp"} {
		joined := &dockerSandboxDNS{engine: engine, internal: true}
		scope := []*workerNetwork{first}
		joined.setNetworks(scope)
		assertSandboxDNS(t, joined, transport, "sidecar-b", dnsmessage.TypeA, dnsmessage.RCodeNameError)
		scope = append(scope, second)
		joined.setNetworks(scope)
		// The control-plane's input slice can be reused after publication.
		scope[1] = another
		assertSandboxDNS(t, joined, transport, "SideCar-B", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.2.4")
		assertSandboxDNS(t, joined, transport, "sidecar-b", dnsmessage.TypeAAAA, dnsmessage.RCodeSuccess)
		assertSandboxDNS(t, joined, transport, "elsewhere", dnsmessage.TypeA, dnsmessage.RCodeNameError)
		assertSandboxDNS(t, joined, transport, "shared", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.1.3")
		assertSandboxDNS(t, primary, transport, "Alias-A", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.1.3")
		assertSandboxDNS(t, primary, transport, "Alias-B", dnsmessage.TypeA, dnsmessage.RCodeNameError)
		assertSandboxDNS(t, secondary, transport, "Alias-B", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.2.3")
		assertSandboxDNS(t, secondary, transport, "Alias-A", dnsmessage.TypeA, dnsmessage.RCodeNameError)
		joined.setNetworks([]*workerNetwork{first})
		assertSandboxDNS(t, joined, transport, "sidecar-b", dnsmessage.TypeA, dnsmessage.RCodeNameError)
	}

	second.services.publishEndpoint("replica", "", []string{"Alias-B"}, "10.90.2.5", true)
	second.services.publishEndpoint("app", "", []string{"Alias-B", "shared"}, "10.90.2.3", false)
	assertSandboxDNS(t, secondary, "udp", "Alias-B", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.2.5")
	assertSandboxDNS(t, primary, "udp", "shared", dnsmessage.TypeA, dnsmessage.RCodeSuccess, "10.90.1.3")
}

func TestDockerSandboxDNSPreservesPrimaryForwardingPolicy(t *testing.T) {
	first := &workerNetwork{Internal: true}
	external := &workerNetwork{}
	local := &dockerSandboxDNS{engine: new(dockerEngine), internal: first.Internal}
	local.setNetworks([]*workerNetwork{first, external})
	assertSandboxDNS(t, local, "udp", "external.example", dnsmessage.TypeA, dnsmessage.RCodeNameError)

	policy := &dockerSandboxDNS{engine: new(dockerEngine), internal: external.Internal}
	policy.setNetworks([]*workerNetwork{external, first})
	out, forward, id, header, _ := policy.answer(sandboxDNSQuestion(t, "external.example", dnsmessage.TypeA), "tcp", nil)
	if out != nil || !forward || id != 42 || !header.RecursionAvailable {
		t.Fatalf("public DNS forwarding = %x, %v, %d, %+v", out, forward, id, header)
	}
}

func TestDockerSandboxDNSRedirectUsesOwnedLoopbackPorts(t *testing.T) {
	rules := strings.Split(strings.TrimSpace(sandboxDNSRules(41019, 42020)), "\n")
	if len(rules) != 6 || rules[0] != "*nat" || rules[5] != "COMMIT" {
		t.Fatalf("expected one transaction with four redirects, got %v", rules)
	}
	want := []string{
		"-A OUTPUT -o lo -d 127.0.0.11/32 -p udp --dport 53 -j DNAT --to-destination 127.0.0.11:41019",
		"-A POSTROUTING -o lo -s 127.0.0.11/32 -p udp --sport 41019 -j SNAT --to-source :53",
		"-A OUTPUT -o lo -d 127.0.0.11/32 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.11:42020",
		"-A POSTROUTING -o lo -s 127.0.0.11/32 -p tcp --sport 42020 -j SNAT --to-source :53",
	}
	if !slices.Equal(rules[1:5], want) {
		t.Fatalf("unexpected DNS redirect rules: %v", rules)
	}
}
