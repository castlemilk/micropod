// Command porttrace times small TCP packets at two interfaces in a private
// benchmark guest. The socket filters return only the selected service's headers.
package main

import (
	"bufio"
	"context"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net"
	"net/netip"
	"os"
	"os/signal"
	"sync"
	"time"

	"golang.org/x/net/bpf"
	"golang.org/x/sys/unix"
)

// The two interfaces see different addresses before and after guest DNAT.
type tap struct {
	fd      int
	name    string
	address uint32
	in, out string
}

func headerFilter(address uint32, port uint16) []bpf.Instruction {
	// A failed predicate returns immediately. Both branches of the address
	// match converge before calculating how many header bytes to return.
	require := func(load bpf.Instruction, condition bpf.JumpTest, value uint32) []bpf.Instruction {
		return []bpf.Instruction{load, bpf.JumpIf{Cond: condition, Val: value, SkipTrue: 1}, bpf.RetConstant{Val: 0}}
	}
	p := require(bpf.LoadAbsolute{Off: 12, Size: 2}, bpf.JumpEqual, unix.ETH_P_IP)
	p = append(p, require(bpf.LoadAbsolute{Off: 23, Size: 1}, bpf.JumpEqual, unix.IPPROTO_TCP)...)
	p = append(p, require(bpf.LoadAbsolute{Off: 20, Size: 2}, bpf.JumpBitsNotSet, 0x3fff)...)
	p = append(p, require(bpf.LoadAbsolute{Off: 16, Size: 2}, bpf.JumpLessOrEqual, 512)...)
	p = append(p, bpf.LoadMemShift{Off: 14}) // X = length of the IPv4 header
	destination := require(bpf.LoadAbsolute{Off: 30, Size: 4}, bpf.JumpEqual, address)
	destination = append(destination, require(bpf.LoadIndirect{Off: 16, Size: 2}, bpf.JumpEqual, uint32(port))...)
	p = append(p, bpf.LoadAbsolute{Off: 26, Size: 4},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: address, SkipFalse: 2},
		bpf.LoadIndirect{Off: 14, Size: 2},
		bpf.JumpIf{Cond: bpf.JumpEqual, Val: uint32(port), SkipTrue: uint8(len(destination))})
	p = append(p, destination...)
	return append(p,
		bpf.LoadIndirect{Off: 26, Size: 1}, // TCP data offset
		bpf.ALUOpConstant{Op: bpf.ALUOpAnd, Val: 0xf0},
		bpf.ALUOpConstant{Op: bpf.ALUOpShiftRight, Val: 2},
		bpf.ALUOpX{Op: bpf.ALUOpAdd},
		bpf.StoreScratch{Src: bpf.RegA, N: 0}, // IPv4 + TCP header lengths
		bpf.LoadIndirect{Off: 27, Size: 1},
		bpf.JumpIf{Cond: bpf.JumpBitsSet, Val: 2, SkipTrue: 4}, // retain SYNs
		bpf.LoadScratch{Dst: bpf.RegX, N: 0},
		bpf.LoadAbsolute{Off: 16, Size: 2},
		bpf.JumpIfX{Cond: bpf.JumpGreaterThan, SkipTrue: 1}, // retain data, exclude pure ACKs
		bpf.RetConstant{Val: 0},
		bpf.LoadScratch{Dst: bpf.RegA, N: 0},
		bpf.ALUOpConstant{Op: bpf.ALUOpAdd, Val: 14},
		bpf.RetA{}) // Ethernet + IPv4 + TCP headers, independent of payload size
}

func socketFilter(address uint32, port uint16) ([]unix.SockFilter, error) {
	raw, err := bpf.Assemble(headerFilter(address, port))
	if err != nil {
		return nil, err
	}
	filters := make([]unix.SockFilter, len(raw))
	for i, ins := range raw {
		filters[i] = unix.SockFilter{Code: ins.Op, Jt: ins.Jt, Jf: ins.Jf, K: ins.K}
	}
	return filters, nil
}

func openTap(name, ip string, port int, incoming, outgoing string) (tap, error) {
	a, err := netip.ParseAddr(ip)
	if err != nil || !a.Is4() || port < 1 || port > 65535 {
		return tap{}, fmt.Errorf("invalid IPv4 service %s port %d", ip, port)
	}
	link, err := net.InterfaceByName(name)
	if err != nil {
		return tap{}, err
	}
	octets := a.As4()
	address := binary.BigEndian.Uint32(octets[:])
	filter, err := socketFilter(address, uint16(port))
	if err != nil {
		return tap{}, err
	}
	// Protocol zero keeps the socket inactive until the filter is installed.
	fd, err := unix.Socket(unix.AF_PACKET, unix.SOCK_RAW|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return tap{}, err
	}
	fail := func(err error) (tap, error) { unix.Close(fd); return tap{}, err }
	program := &unix.SockFprog{Len: uint16(len(filter)), Filter: &filter[0]}
	if err := unix.SetsockoptSockFprog(fd, unix.SOL_SOCKET, unix.SO_ATTACH_FILTER, program); err != nil {
		return fail(err)
	}
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_TIMESTAMPNS, 1); err != nil {
		return fail(err)
	}
	if err := unix.SetsockoptInt(fd, unix.SOL_SOCKET, unix.SO_RCVBUF, 4<<20); err != nil {
		return fail(err)
	}
	if err := unix.SetsockoptTimeval(fd, unix.SOL_SOCKET, unix.SO_RCVTIMEO, &unix.Timeval{Usec: 100000}); err != nil {
		return fail(err)
	}
	packetProtocol := binary.NativeEndian.Uint16([]byte{0, unix.ETH_P_ALL})
	if err := unix.Bind(fd, &unix.SockaddrLinklayer{Protocol: packetProtocol, Ifindex: link.Index}); err != nil {
		return fail(err)
	}
	return tap{fd: fd, name: name, address: address, in: incoming, out: outgoing}, nil
}

type packet struct {
	Stage    string `json:"stage"`
	TimeNS   int64  `json:"ns"`
	Sequence uint32 `json:"seq"`
	Ack      uint32 `json:"ack"`
	Bytes    int    `json:"bytes"`
	Flags    byte   `json:"flags"`
}

func (t tap) capture(ctx context.Context, events chan<- any) error {
	var hdr [160]byte
	oob := make([]byte, unix.CmsgSpace(32))
	for ctx.Err() == nil {
		n, nc, _, _, err := unix.Recvmsg(t.fd, hdr[:], oob, 0)
		if err == unix.EAGAIN || err == unix.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		if n < 54 {
			continue
		}
		tcp := 14 + int(hdr[14]&15)*4
		if tcp < 34 || tcp+20 > n {
			continue
		}
		size := int(binary.BigEndian.Uint16(hdr[16:18])) - (tcp - 14) - int(hdr[tcp+12]>>4)*4
		if size < 0 {
			continue
		}
		stage := t.in
		if binary.BigEndian.Uint32(hdr[26:30]) == t.address {
			stage = t.out
		}
		messages, err := unix.ParseSocketControlMessage(oob[:nc])
		if err != nil {
			return err
		}
		var timestamp unix.Timespec
		for _, c := range messages {
			if c.Header.Level == unix.SOL_SOCKET && c.Header.Type == unix.SCM_TIMESTAMPNS {
				if _, err := binary.Decode(c.Data, binary.NativeEndian, &timestamp); err != nil {
					return err
				}
			}
		}
		if timestamp.Sec == 0 {
			return fmt.Errorf("missing kernel timestamp on %s", t.name)
		}
		events <- packet{Stage: stage, TimeNS: timestamp.Nano(), Sequence: binary.BigEndian.Uint32(hdr[tcp+4 : tcp+8]), Ack: binary.BigEndian.Uint32(hdr[tcp+8 : tcp+12]), Bytes: size, Flags: hdr[tcp+13]}
	}
	stats, err := unix.GetsockoptTpacketStats(t.fd, unix.SOL_PACKET, unix.PACKET_STATISTICS)
	if err != nil {
		return err
	}
	events <- map[string]any{"interface": t.name, "packets": stats.Packets, "drops": stats.Drops}
	return nil
}

func main() {
	guest := flag.String("guest", "", "guest NIC IPv4 address")
	guestPort := flag.Int("guest-port", 0, "guest port leased to the fresh client")
	pod := flag.String("pod", "", "container IPv4 address")
	podPort := flag.Int("pod-port", 8080, "container service port")
	nic := flag.String("nic", "eth0", "guest NIC")
	bridge := flag.String("bridge", "mpci0", "container bridge")
	duration := flag.Duration("duration", 6*time.Second, "capture interval")
	flag.Parse()
	if *duration <= 0 {
		log.Fatal("duration must be positive")
	}
	outer, err := openTap(*nic, *guest, *guestPort, "guest-in", "guest-out")
	if err != nil {
		log.Fatal(err)
	}
	defer unix.Close(outer.fd)
	inner, err := openTap(*bridge, *pod, *podPort, "to-container", "from-container")
	if err != nil {
		log.Fatal(err)
	}
	defer unix.Close(inner.fd)
	stopping, stop := signal.NotifyContext(context.Background(), os.Interrupt, unix.SIGTERM)
	defer stop()
	ctx, cancel := context.WithTimeout(stopping, *duration)
	defer cancel()
	writer := bufio.NewWriterSize(os.Stdout, 128<<10)
	enc := json.NewEncoder(writer)
	if err := enc.Encode(map[string]bool{"ready": true}); err != nil {
		log.Fatal(err)
	}
	if err := writer.Flush(); err != nil {
		log.Fatal(err)
	}
	events := make(chan any, 2048)
	var wg sync.WaitGroup
	for _, t := range []tap{outer, inner} {
		wg.Go(func() {
			if err := t.capture(ctx, events); err != nil {
				log.Fatal(err)
			}
		})
	}
	go func() { wg.Wait(); close(events) }()
	for event := range events {
		if err := enc.Encode(event); err != nil {
			log.Fatal(err)
		}
	}
	if err := writer.Flush(); err != nil {
		log.Fatal(err)
	}
}
