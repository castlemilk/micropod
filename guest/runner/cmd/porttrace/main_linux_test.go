package main

import (
	"encoding/binary"
	"testing"

	"golang.org/x/net/bpf"
)

func TestFilterReturnsOnlyHeadersForTheSelectedService(t *testing.T) {
	const service = 0xc0000201
	const other = 0xc0000202
	const port = 8080
	vm, err := bpf.NewVM(headerFilter(service, port))
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		name                string
		source, destination uint32
		sport, dport        uint16
		ihl, thl, body      int
		flags               byte
		accept              bool
	}{
		{"request", other, service, 50000, port, 20, 20, 50, 0x18, true},
		{"response with options", service, other, port, 50000, 24, 32, 70, 0x10, true},
		{"SYN", other, service, 50000, port, 20, 40, 0, 2, true},
		{"pure ACK", other, service, 50000, port, 20, 32, 0, 0x10, false},
		{"large transfer", service, other, port, 50000, 20, 20, 1000, 0x18, false},
		{"another address", other, other, 50000, port, 20, 20, 50, 0x18, false},
		{"another service", other, service, 50000, port + 1, 20, 20, 50, 0x18, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			p := make([]byte, 14+c.ihl+c.thl+c.body)
			binary.BigEndian.PutUint16(p[12:], 0x0800)
			p[14] = 0x40 | byte(c.ihl/4)
			p[23] = 6
			binary.BigEndian.PutUint16(p[16:], uint16(len(p)-14))
			binary.BigEndian.PutUint32(p[26:], c.source)
			binary.BigEndian.PutUint32(p[30:], c.destination)
			tcp := 14 + c.ihl
			binary.BigEndian.PutUint16(p[tcp:], c.sport)
			binary.BigEndian.PutUint16(p[tcp+2:], c.dport)
			p[tcp+12] = byte(c.thl/4) << 4
			p[tcp+13] = c.flags
			n, err := vm.Run(p)
			if err != nil {
				t.Fatal(err)
			}
			want := 0
			if c.accept {
				want = tcp + c.thl
			}
			if n != want {
				t.Fatalf("captured %d bytes, want %d", n, want)
			}
			binary.BigEndian.PutUint16(p[20:], 0x2000)
			n, err = vm.Run(p)
			if err != nil || n != 0 {
				t.Fatalf("fragmented packet returned %d bytes, err %v", n, err)
			}
		})
	}
}
