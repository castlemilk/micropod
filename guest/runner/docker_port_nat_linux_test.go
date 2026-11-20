package main

import (
	"errors"
	"net"
	"net/netip"
	"testing"

	"github.com/vishvananda/netlink"
	"golang.org/x/sys/unix"
)

func TestPublishedGuestReservation(t *testing.T) {
	fd, port, err := reserveGuestPort("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(fd)
	if port < 1024 {
		t.Fatalf("unexpected reserved port %d", port)
	}
	listening, err := unix.GetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_ACCEPTCONN)
	if err != nil || listening != 0 {
		t.Fatalf("reserved socket listening=%d err=%v", listening, err)
	}
	l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)})
	if l != nil {
		l.Close()
	}
	if !errors.Is(err, unix.EADDRINUSE) {
		t.Fatalf("reserved port was not exclusive: %v", err)
	}
}

func TestPublishedFlowOwnership(t *testing.T) {
	mapping := portMapping{port: 40001, guestIP: net.IPv4(192, 168, 1, 2), target: netip.MustParseAddrPort("10.88.0.2:8080")}
	owned := netlink.ConntrackFlow{
		Forward: netlink.IPTuple{Protocol: unix.IPPROTO_TCP, DstIP: mapping.guestIP, DstPort: mapping.port},
		Reverse: netlink.IPTuple{SrcIP: net.IPv4(10, 88, 0, 2), SrcPort: 8080},
	}
	if !mapping.MatchConntrackFlow(&owned) {
		t.Fatal("published flow did not match")
	}
	for name, change := range map[string]func(*netlink.ConntrackFlow){
		"protocol": func(f *netlink.ConntrackFlow) { f.Forward.Protocol = unix.IPPROTO_UDP },
		"guest":    func(f *netlink.ConntrackFlow) { f.Forward.DstIP = net.IPv4(192, 168, 1, 3) },
		"lease":    func(f *netlink.ConntrackFlow) { f.Forward.DstPort++ },
		"pod":      func(f *netlink.ConntrackFlow) { f.Reverse.SrcIP = net.IPv4(10, 88, 0, 3) },
		"service":  func(f *netlink.ConntrackFlow) { f.Reverse.SrcPort++ },
	} {
		other := owned
		change(&other)
		if mapping.MatchConntrackFlow(&other) {
			t.Errorf("matched a different %s", name)
		}
	}
}
