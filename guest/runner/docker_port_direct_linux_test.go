package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Run inside a fresh test container only. Real workload containers never
// receive the worker's broker socket. The fixture refuses an occupied path.
func TestDirectPortRevocationRecovery(t *testing.T) {
	if os.Getenv("MICROPOD_TEST_PORT_FENCE") != "1" {
		t.Skip("requires an isolated local test container")
	}
	if _, e := os.Lstat(portBrokerSocket); !errors.Is(e, os.ErrNotExist) {
		t.Fatal("test broker path occupied")
	}
	if err := os.MkdirAll(filepath.Dir(portBrokerSocket), 0700); err != nil {
		t.Fatal(err)
	}
	broker, err := net.Listen("unix", portBrokerSocket)
	if err != nil {
		t.Fatal(err)
	}
	defer broker.Close()
	// An abandoned preparation cannot create a listener. A lost reply after
	// the commit may have created one and must fence reuse.
	for _, commit := range []bool{false, true} {
		done := make(chan bool, 1)
		go func() {
			_, _, uncertain, err := reserveDirectMacPort(context.Background(), 30000, 34000)
			done <- err != nil && uncertain == commit
		}()
		broker.(*net.UnixListener).SetDeadline(time.Now().Add(4 * time.Second))
		c, err := broker.Accept()
		if err != nil {
			t.Fatal(err)
		}
		c.SetDeadline(time.Now().Add(2 * time.Second))
		var frame [4]byte
		if _, err = io.ReadFull(c, frame[:]); err != nil || binary.BigEndian.Uint16(frame[:2]) != 34000 || binary.BigEndian.Uint16(frame[2:]) != 1 {
			t.Fatalf("unexpected prepare %x: %v", frame, err)
		}
		if commit {
			if _, err = c.Write([]byte{0x50}); err != nil {
				t.Fatal(err)
			}
			if _, err = io.ReadFull(c, frame[:2]); err != nil || binary.BigEndian.Uint16(frame[:2]) != 30000 {
				t.Fatalf("unexpected commit %x: %v", frame[:2], err)
			}
		}
		c.Close()
		if !<-done {
			t.Fatalf("incorrect lost-bind outcome for commit=%t", commit)
		}
	}

	fd, port, err := reserveGuestPort("127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	netw := &directNetwork{}
	netw.quarantine(port, fd)
	target := &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(port)}
	check := func(answer byte) {
		t.Helper()
		broker.(*net.UnixListener).SetDeadline(time.Now().Add(4 * time.Second))
		c, e := broker.Accept()
		if e != nil {
			t.Fatal(e)
		}
		defer c.Close()
		var frame [4]byte
		if _, e = io.ReadFull(c, frame[:]); e != nil {
			t.Fatal(e)
		}
		if binary.BigEndian.Uint16(frame[:2]) != port || binary.BigEndian.Uint16(frame[2:]) != 0 {
			t.Fatalf("wrong fence request %x", frame)
		}
		if _, e = c.Write([]byte{answer}); e != nil {
			t.Fatal(e)
		}
	}
	check(0)
	l, e := net.ListenTCP("tcp4", target)
	if e == nil {
		l.Close()
		t.Fatal("uncertain host lease was reused")
	}
	if netw.quarantined() != 1 {
		t.Fatal("missing reserved port")
	}
	check(revokePort)
	deadline := time.Now().Add(2 * time.Second)
	for netw.quarantined() != 0 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if netw.quarantined() != 0 {
		t.Fatal("host-confirmed port was not released")
	}
	l, e = net.ListenTCP("tcp4", target)
	if e != nil {
		t.Fatal(e)
	}
	l.Close()
}
