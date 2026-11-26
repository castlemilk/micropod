package main

import (
	"context"
	"errors"
	"net"
	"net/netip"
	"os"
	"strings"
	"testing"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

func TestDockerBridgeSecondaryAddressesStayWithinOwnedSubnet(t *testing.T) {
	n := &workerNetwork{Subnet: netip.MustParsePrefix("10.90.42.0/29")}
	for _, tc := range []struct {
		address string
		allowed bool
	}{
		{"10.90.42.0", false},
		{"10.90.42.1", false},
		{"10.90.42.2", true},
		{"10.90.42.6", true},
		{"10.90.42.7", false},
		{"10.90.43.2", false},
		{"::ffff:10.90.42.2", false},
		{"", false},
	} {
		ip, err := secondaryBridgeAddress(n, tc.address)
		if (err == nil) != tc.allowed || tc.allowed && ip.String() != tc.address {
			t.Fatalf("secondary address %q resolved to %v, error %v", tc.address, ip, err)
		}
	}
}

func TestDockerBridgeSecondaryNamesIdentifyDistinctGenerations(t *testing.T) {
	firstPod := strings.Repeat("a", 64)
	secondPod := strings.Repeat("b", 64)
	firstNetwork := strings.Repeat("c", 64)
	secondNetwork := strings.Repeat("d", 64)
	first, firstOwner := secondaryBridgeHost(firstPod, firstNetwork)
	repeat, repeatOwner := secondaryBridgeHost(firstPod, firstNetwork)
	restarted, restartedOwner := secondaryBridgeHost(secondPod, firstNetwork)
	other, otherOwner := secondaryBridgeHost(firstPod, secondNetwork)
	if len(first) >= unix.IFNAMSIZ || !strings.HasPrefix(first, "mps") || first != repeat || firstOwner != repeatOwner {
		t.Fatalf("unstable bridge interface name %q / %q", first, repeat)
	}
	if first == restarted || first == other || firstOwner == restartedOwner || firstOwner == otherOwner {
		t.Fatal("different sandbox generations or networks share an interface identity")
	}
	if !strings.Contains(firstOwner, firstPod+":"+firstNetwork) {
		t.Fatal("link ownership has lost the complete generation and network IDs")
	}
}

func TestDockerBridgeSecondaryRejectsUnrelatedPeer(t *testing.T) {
	host := &netlink.Veth{LinkAttrs: netlink.LinkAttrs{Index: 400, ParentIndex: 10}}
	peer := &netlink.Veth{LinkAttrs: netlink.LinkAttrs{Index: 10, ParentIndex: 400}}
	if !matchingBridgePeer(host, peer) {
		t.Fatal("expected the exact veth pair to match")
	}
	if matchingBridgePeer(host, &netlink.Dummy{LinkAttrs: peer.LinkAttrs}) {
		t.Fatal("same indexes on a non-veth accepted")
	}
	peer.ParentIndex++
	if matchingBridgePeer(host, peer) {
		t.Fatal("different host interface accepted")
	}
	peer.ParentIndex--
	peer.Index++
	if matchingBridgePeer(host, peer) {
		t.Fatal("different peer interface accepted")
	}
	host.ParentIndex = 0
	if !matchingBridgePeer(host, peer) {
		t.Fatal("kernel omitted the host-side peer index despite the pinned exact peer")
	}
}

func TestDockerBridgeSecondaryPendingPairNeedsExactHostOwnership(t *testing.T) {
	chosen := net.HardwareAddr{6, 90, 12, 91, 1, 8}
	endpoint := &dockerBridgeEndpoint{pendingHostMAC: chosen}
	host := &netlink.Veth{
		LinkAttrs: netlink.LinkAttrs{Index: 400, ParentIndex: 10, HardwareAddr: chosen},
	}
	if !endpoint.matchesPendingHost(host, "") {
		t.Fatal("the created pair's exact pending host was rejected")
	}
	if endpoint.matchesPendingHost(host, "foreign") {
		t.Fatal("a different alias was accepted")
	}
	host.Alias = "foreign"
	if endpoint.matchesPendingHost(host, "") {
		t.Fatal("conflicting alias observations were accepted")
	}
	host.Alias = ""
	host.MasterIndex = 5
	if endpoint.matchesPendingHost(host, "") {
		t.Fatal("an untagged link already attached to a bridge was accepted")
	}
	host.MasterIndex = 0
	host.ParentIndex = 0
	if endpoint.matchesPendingHost(host, "") {
		t.Fatal("pending link without a peer index was accepted")
	}
	host.ParentIndex = 10
	host.HardwareAddr = net.HardwareAddr{6, 90, 12, 91, 1, 9}
	if endpoint.matchesPendingHost(host, "") {
		t.Fatal("an unrelated link using the same indexes was accepted")
	}
	host.HardwareAddr = chosen
	endpoint.pendingHostMAC = nil
	if endpoint.matchesPendingHost(host, "") {
		t.Fatal("a previously verified endpoint is allowed to lose its alias")
	}
}

func TestDockerBridgeSecondaryPeerMACFollowsTheReservedAddress(t *testing.T) {
	const first = "10.90.42.2"
	for _, tc := range []struct{ ip, mac string }{
		{first, "02:42:0a:5a:2a:02"},
		{"10.90.42.3", "02:42:0a:5a:2a:03"},
		{first, "02:42:0a:5a:2a:02"},
	} {
		if got := bridgePeerMAC(netip.MustParseAddr(tc.ip)).String(); got != tc.mac {
			t.Fatalf("peer for %s has MAC %s, want %s", tc.ip, got, tc.mac)
		}
	}
}

func TestDockerBridgePrimaryPeerMACPreservesRetainedAddressAcrossRestart(t *testing.T) {
	t.Setenv("MICROPOD_ENGINE_ROOTLESS", "")
	primary := &workerNetwork{Name: "named", Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.7.0/24")}
	for range 2 {
		mac, err := primary.primaryBridgePeerMAC("10.90.7.19")
		if err != nil || mac.String() != "02:42:0a:5a:07:13" {
			t.Fatalf("primary reserved address has MAC %s, error %v", mac, err)
		}
	}
	if _, err := primary.primaryBridgePeerMAC("10.90.8.19"); err == nil {
		t.Fatal("an address outside the primary bridge subnet was accepted")
	}
	for _, n := range []*workerNetwork{
		{Name: "bridge", Driver: "bridge", Subnet: primary.Subnet},
		{Name: "named", Driver: "ipvlan", Subnet: primary.Subnet},
	} {
		if mac, err := n.primaryBridgePeerMAC("10.90.7.19"); mac != nil || err != nil {
			t.Fatalf("network %s/%s got a primary MAC override of %s, error %v", n.Name, n.Driver, mac, err)
		}
	}
	t.Setenv("MICROPOD_ENGINE_ROOTLESS", "1")
	if mac, err := primary.primaryBridgePeerMAC("10.90.7.19"); mac != nil || err != nil {
		t.Fatalf("rootless named bridge got a primary MAC override of %s, error %v", mac, err)
	}
}

func TestDockerBridgeSecondaryDoesNotTouchUnavailableSandbox(t *testing.T) {
	network := &workerNetwork{ID: strings.Repeat("c", 64), Driver: "bridge", Subnet: netip.MustParsePrefix("10.90.42.0/29")}
	retired := &dockerBridgeSandbox{}
	if err := retired.close(); err != nil {
		t.Fatal(err)
	}
	if _, err := retired.attach(context.Background(), network, "10.90.42.2"); err == nil {
		t.Fatal("retired sandbox accepted a new endpoint")
	}
	if err := retired.detach(network); err == nil {
		t.Fatal("retired sandbox accepted an endpoint removal")
	}

	// A cancelled attach must stop before reading an unrelated namespace file.
	file, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	current := &dockerBridgeSandbox{ns: file}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := current.attach(ctx, network, "10.90.42.2"); !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled attach = %v", err)
	}
}
