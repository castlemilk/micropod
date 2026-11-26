// Verify DF delivery on the private worker NIC. Reply only to its host gateway and run nonce.
package main

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"strconv"
	"syscall"
	"time"
)

func trace(device string, handshakes bool) error {
	nic, err := net.InterfaceByName(device)
	if err != nil {
		return err
	}
	fd, err := syscall.Socket(syscall.AF_PACKET, syscall.SOCK_RAW, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	var control []byte
	if handshakes {
		if err := syscall.SetsockoptInt(fd, syscall.SOL_SOCKET, syscall.SO_TIMESTAMPNS, 1); err != nil {
			return err
		}
		// This fixture builds for linux/arm64, whose timespec has two 64-bit fields.
		control = make([]byte, syscall.CmsgSpace(16))
		// Admit ARP, IPv4 TCP SYN/SYN-ACK and RST. Compute the TCP offset from
		// the IPv4 header length and discard ordinary payload in the kernel.
		filter := []syscall.SockFilter{
			*syscall.LsfStmt(syscall.BPF_LD|syscall.BPF_H|syscall.BPF_ABS, 12),
			*syscall.LsfJump(syscall.BPF_JMP|syscall.BPF_JEQ, 0x0806, 6, 0),
			*syscall.LsfJump(syscall.BPF_JMP|syscall.BPF_JEQ, 0x0800, 0, 6),
			*syscall.LsfStmt(syscall.BPF_LD|syscall.BPF_B|syscall.BPF_ABS, 23),
			*syscall.LsfJump(syscall.BPF_JMP|syscall.BPF_JEQ, 6, 0, 4),
			*syscall.LsfStmt(syscall.BPF_LDX|syscall.BPF_B|syscall.BPF_MSH, 14),
			*syscall.LsfStmt(syscall.BPF_LD|syscall.BPF_B|syscall.BPF_IND, 27),
			*syscall.LsfJump(syscall.BPF_JMP|syscall.BPF_JSET, 0x06, 0, 1),
			*syscall.LsfStmt(syscall.BPF_RET, 96),
			*syscall.LsfStmt(syscall.BPF_RET, 0),
		}
		if err := syscall.AttachLsf(fd, filter); err != nil {
			return err
		}
	}
	if err := syscall.Bind(fd, &syscall.SockaddrLinklayer{Protocol: 0x0300, Ifindex: nic.Index}); err != nil { // ETH_P_ALL
		return err
	}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &syscall.Timeval{Usec: 250000}); err != nil {
		return err
	}
	buf := make([]byte, 128)
	until := time.Now().Add(9 * time.Second)
	limit := 90
	if handshakes {
		until = time.Now().Add(12 * time.Minute)
		limit = 40000
		fmt.Println("# clock=kernel-socket-realtime-ms")
	}
	count := 0
	for time.Now().Before(until) && count < limit {
		n, nc, _, _, err := syscall.Recvmsg(fd, buf, control, 0)
		if err == syscall.EAGAIN || err == syscall.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		stamp := time.Now().UnixMilli()
		if handshakes {
			messages, err := syscall.ParseSocketControlMessage(control[:nc])
			if err != nil {
				return err
			}
			if len(messages) != 1 || messages[0].Header.Level != syscall.SOL_SOCKET ||
				messages[0].Header.Type != syscall.SCM_TIMESTAMPNS || len(messages[0].Data) != 16 {
				return fmt.Errorf("private packet socket returned no kernel timestamp")
			}
			ts := messages[0].Data
			stamp = int64(binary.NativeEndian.Uint64(ts[:8]))*1000 + int64(binary.NativeEndian.Uint64(ts[8:]))/1e6
		}
		if handshakes && n >= 42 && binary.BigEndian.Uint16(buf[12:14]) == 0x0806 {
			fmt.Printf("%s %d arp=%d %s>%s %s>%s\n", device, stamp,
				binary.BigEndian.Uint16(buf[20:22]), net.HardwareAddr(buf[6:12]), net.HardwareAddr(buf[:6]),
				net.IP(buf[28:32]), net.IP(buf[38:42]))
			count++
			continue
		}
		if n < 54 || binary.BigEndian.Uint16(buf[12:14]) != 0x0800 || buf[23] != 6 {
			continue
		}
		t := 14 + int(buf[14]&15)*4
		if t+20 > n {
			continue
		}
		fmt.Printf("%s %d %s>%s %s:%d>%s:%d flags=%02x len=%d\n", device, stamp,
			net.HardwareAddr(buf[6:12]), net.HardwareAddr(buf[:6]), net.IP(buf[26:30]), binary.BigEndian.Uint16(buf[t:]), net.IP(buf[30:34]), binary.BigEndian.Uint16(buf[t+2:]), buf[t+13], binary.BigEndian.Uint16(buf[16:18]))
		count++
	}
	return nil
}

func serve() error {
	addr := net.ParseIP(os.Args[1])
	gateway := net.ParseIP(os.Args[2])
	if addr.To4() == nil || gateway.To4() == nil {
		return fmt.Errorf("invalid private link addresses")
	}
	s, err := net.ListenUDP("udp4", &net.UDPAddr{IP: addr})
	if err != nil {
		return err
	}
	defer s.Close()
	fd, err := s.SyscallConn()
	if err != nil {
		return err
	}
	var optErr error
	const level, option, value = syscall.IPPROTO_IP, syscall.IP_MTU_DISCOVER, syscall.IP_PMTUDISC_DO
	if err := fd.Control(func(raw uintptr) {
		optErr = syscall.SetsockoptInt(int(raw), level, option, value)
		if optErr == nil {
			var got int
			got, optErr = syscall.GetsockoptInt(int(raw), level, option)
			if optErr == nil && got != value {
				optErr = fmt.Errorf("DF readback %d", got)
			}
		}
	}); err != nil {
		return err
	}
	if optErr != nil {
		return optErr
	}
	if err := s.SetDeadline(time.Now().Add(120 * time.Second)); err != nil {
		return err
	}
	temp := os.Args[3] + ".tmp"
	if err := os.WriteFile(temp, []byte(strconv.Itoa(s.LocalAddr().(*net.UDPAddr).Port)), 0600); err != nil {
		return err
	}
	if err := os.Rename(temp, os.Args[3]); err != nil {
		return err
	}
	nonce, payload := []byte(os.Args[4]), make([]byte, 9000)
	for {
		n, peer, err := s.ReadFromUDP(payload)
		if err != nil {
			return err
		}
		if !peer.IP.Equal(gateway) || !bytes.HasPrefix(payload[:n], nonce) {
			continue
		}
		fmt.Printf("received DF probe %d bytes from %s\n", n, peer)
		if _, err := s.WriteToUDP(payload[:n], peer); err != nil {
			return err
		}
		if bytes.Equal(payload[:n], append(bytes.Clone(nonce), []byte("done")...)) {
			return nil
		}
	}
}

func main() {
	if len(os.Args) == 2 && (os.Args[1] == "tcp-queue" || os.Args[1] == "cpu-set") {
		path := "/proc/sys/net/ipv4/tcp_limit_output_bytes"
		if os.Args[1] == "cpu-set" {
			path = "/sys/fs/cgroup/cpuset.cpus.effective"
		}
		value, err := os.ReadFile(path)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Print(string(value))
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "oom-check" {
		// The fault is confined to a verified 32 MiB cgroup. Wait until the
		// driver has inspected all 64 running containers before touching pages.
		limit, err := os.ReadFile("/sys/fs/cgroup/memory.max")
		if err != nil || string(bytes.TrimSpace(limit)) != "33554432" {
			fmt.Fprintln(os.Stderr, "expected a 32 MiB memory limit")
			os.Exit(2)
		}
		until := time.Now().Add(60 * time.Second)
		for {
			if _, err := os.Stat("/mpcheck/oom-now"); err == nil {
				break
			}
			if time.Now().After(until) {
				os.Exit(3)
			}
			time.Sleep(50 * time.Millisecond)
		}
		pages, err := syscall.Mmap(-1, 0, 64<<20, syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(4)
		}
		for i := 0; i < len(pages); i += os.Getpagesize() {
			pages[i] = 1
		}
		fmt.Fprintln(os.Stderr, "fault allocation survived its memory limit")
		os.Exit(5)
	}
	if len(os.Args) == 3 && os.Args[1] == "mtu" {
		nic, err := net.InterfaceByName(os.Args[2])
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Println(nic.MTU)
		return
	}
	if len(os.Args) == 2 && os.Args[1] == "neighbors" {
		neighbors, err := os.ReadFile("/proc/net/arp")
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		fmt.Print(string(neighbors))
		return
	}
	if len(os.Args) == 3 && (os.Args[1] == "trace" || os.Args[1] == "handshakes") {
		if err := trace(os.Args[2], os.Args[1] == "handshakes"); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) != 5 {
		os.Exit(2)
	}
	if err := serve(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
