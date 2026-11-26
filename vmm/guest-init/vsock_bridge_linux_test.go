package main

import (
	"io"
	"syscall"
	"testing"
)

func TestVsockPeerClosedBothPreservesHalfClose(t *testing.T) {
	pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		t.Fatal(err)
	}
	local, peer := fdRW{fd: pair[0]}, fdRW{fd: pair[1]}
	defer syscall.Close(local.fd)
	defer func() {
		if peer.fd >= 0 {
			_ = syscall.Close(peer.fd)
		}
	}()

	if err := syscall.Shutdown(peer.fd, syscall.SHUT_WR); err != nil {
		t.Fatal(err)
	}
	var reply [5]byte
	if _, err := local.Read(reply[:]); err != io.EOF {
		t.Fatalf("read after peer write shutdown: %v, want EOF", err)
	}
	if vsockPeerClosedBoth(local.fd) {
		t.Fatal("peer write shutdown was treated as full close")
	}
	if _, err := local.Write([]byte("reply")); err != nil {
		t.Fatal(err)
	}
	if _, err := io.ReadFull(peer, reply[:]); err != nil || string(reply[:]) != "reply" {
		t.Fatalf("response after write shutdown: %q, %v", reply, err)
	}

	if err := syscall.Close(peer.fd); err != nil {
		t.Fatal(err)
	}
	peer.fd = -1
	if !vsockPeerClosedBoth(local.fd) {
		t.Fatal("fully closed peer was treated as write shutdown")
	}
}
