package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net"
	"net/netip"
	"os"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
)

type networkDNS struct {
	udp      net.PacketConn
	tcp      net.Listener
	cancel   context.CancelFunc
	wg       sync.WaitGroup
	slots    chan struct{}
	upstream []string
}

func (d *networkDNS) close() { d.cancel(); d.udp.Close(); d.tcp.Close(); d.wg.Wait() }

type localDNSReply func([]byte, string, []byte) ([]byte, bool, uint16, dnsmessage.Header, dnsmessage.Question)

func (s *dockerEngine) listenDNS(n *workerNetwork) (*networkDNS, error) {
	// The same short service name can exist on many networks. Socket scope
	// also prevents another interface from querying this network's service list.
	config := net.ListenConfig{Control: func(_, _ string, c syscall.RawConn) error {
		var err error
		if e := c.Control(func(fd uintptr) {
			err = unix.SetsockoptString(int(fd), unix.SOL_SOCKET, unix.SO_BINDTODEVICE, n.gatewayLink())
		}); e != nil {
			return e
		}
		return err
	}}
	addr := net.JoinHostPort(n.gateway().String(), "53")
	udp, err := config.ListenPacket(context.Background(), "udp4", addr)
	if err != nil {
		return nil, err
	}
	tcp, err := config.Listen(context.Background(), "tcp4", addr)
	if err != nil {
		udp.Close()
		return nil, err
	}
	return s.serveNetworkDNS(udp, tcp, func(packet []byte, transport string, dst []byte) ([]byte, bool, uint16, dnsmessage.Header, dnsmessage.Question) {
		return s.dnsLocalReply(n, packet, transport, dst)
	})
}

// Takes ownership of both listeners, including when initialization fails.
func (s *dockerEngine) serveNetworkDNS(udp net.PacketConn, tcp net.Listener, local localDNSReply) (*networkDNS, error) {
	ctx, cancel := context.WithCancel(context.Background())
	d := &networkDNS{udp: udp, tcp: tcp, cancel: cancel, slots: make(chan struct{}, 64)}
	b, err := os.ReadFile("/etc/resolv.conf")
	if err != nil {
		cancel()
		udp.Close()
		tcp.Close()
		return nil, err
	}
	for _, ln := range strings.Split(string(b), "\n") {
		f := strings.Fields(ln)
		if len(f) >= 2 && f[0] == "nameserver" && net.ParseIP(f[1]) != nil {
			d.upstream = append(d.upstream, net.JoinHostPort(f[1], "53"))
		}
	}
	d.wg.Add(2)
	go func() {
		defer d.wg.Done()
		buf := make([]byte, 4096)
		replyBuf := make([]byte, 0, 512)
		udpConn, isUDPConn := udp.(*net.UDPConn)
		for {
			var size int
			var fromAddr netip.AddrPort
			var fromNet net.Addr
			var err error
			if isUDPConn {
				size, fromAddr, err = udpConn.ReadFromUDPAddrPort(buf)
			} else {
				size, fromNet, err = udp.ReadFrom(buf)
			}
			if err != nil {
				return
			}
			// Fast inline path for authoritative local service answers, local NODATA,
			// and local NXDOMAIN: zero goroutine spawns, zero packet cloning, zero heap allocs.
			out, forward, reqID, hdr, q := local(buf[:size], "udp", replyBuf[:0])
			if !forward {
				if out != nil {
					if isUDPConn {
						_, _ = udpConn.WriteToUDPAddrPort(out, fromAddr)
					} else {
						_, _ = udp.WriteTo(out, fromNet)
					}
					if cap(out) <= 4096 {
						replyBuf = out[:0]
					}
				}
				continue
			}
			select {
			case d.slots <- struct{}{}:
			default:
				s.metrics.networks.dnsDropped.Add(1)
				continue
			}
			req := slices.Clone(buf[:size])
			d.wg.Add(1)
			go func(addrPort netip.AddrPort, netAddr net.Addr) {
				defer d.wg.Done()
				defer func() { <-d.slots }()
				if fwd := s.dnsForwardReply(ctx, d.upstream, req, "udp", reqID, hdr, q); fwd != nil {
					if isUDPConn {
						_, _ = udpConn.WriteToUDPAddrPort(fwd, addrPort)
					} else {
						_, _ = udp.WriteTo(fwd, netAddr)
					}
				}
			}(fromAddr, fromNet)
		}
	}()
	go func() {
		defer d.wg.Done()
		for {
			c, err := tcp.Accept()
			if err != nil {
				return
			}
			select {
			case d.slots <- struct{}{}:
			default:
				s.metrics.networks.dnsDropped.Add(1)
				c.Close()
				continue
			}
			d.wg.Add(1)
			go func() {
				defer d.wg.Done()
				defer func() { <-d.slots }()
				defer c.Close()
				stop := context.AfterFunc(ctx, func() { c.Close() })
				defer stop()
				for {
					c.SetDeadline(time.Now().Add(5 * time.Second))
					req, err := readDNS(c)
					if err != nil {
						return
					}
					out, forward, reqID, hdr, q := local(req, "tcp", nil)
					if forward {
						out = s.dnsForwardReply(ctx, d.upstream, req, "tcp", reqID, hdr, q)
					}
					if out == nil || sendDNS(c, out) != nil {
						return
					}
				}
			}()
		}
	}()
	return d, nil
}
func readDNS(r io.Reader) ([]byte, error) {
	var h [2]byte
	if _, err := io.ReadFull(r, h[:]); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint16(h[:])
	if length < 12 {
		return nil, errors.New("invalid DNS frame")
	}
	b := make([]byte, length)
	_, err := io.ReadFull(r, b)
	return b, err
}
func sendDNS(w io.Writer, b []byte) error {
	if len(b) > math.MaxUint16 {
		return errors.New("DNS message exceeds TCP frame limit")
	}
	var h [2]byte
	binary.BigEndian.PutUint16(h[:], uint16(len(b)))
	if _, err := w.Write(h[:]); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

func lowerDNSName(name *dnsmessage.Name, dst *[255]byte) ([]byte, bool) {
	n := int(name.Length)
	if n > 0 && name.Data[n-1] == '.' {
		n--
	}
	hasDot := false
	for i := range n {
		c := name.Data[i]
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		} else if c == '.' {
			hasDot = true
		}
		dst[i] = c
	}
	return dst[:n], hasDot
}

func (s *dockerEngine) dnsLocalReply(n *workerNetwork, packet []byte, network string, dst []byte) ([]byte, bool, uint16, dnsmessage.Header, dnsmessage.Question) {
	return s.dnsNetworksReply([]*workerNetwork{n}, n.Internal, packet, network, dst)
}

func (s *dockerEngine) dnsNetworksReply(networks []*workerNetwork, internal bool, packet []byte, network string, dst []byte) ([]byte, bool, uint16, dnsmessage.Header, dnsmessage.Question) {
	var parser dnsmessage.Parser
	var zeroHdr dnsmessage.Header
	var zeroQ dnsmessage.Question
	h, err := parser.Start(packet)
	if err != nil || h.Response {
		return nil, false, 0, zeroHdr, zeroQ
	}
	q, err := parser.Question()
	if err != nil {
		return nil, false, 0, zeroHdr, zeroQ
	}
	if err = parser.SkipQuestion(); err != dnsmessage.ErrSectionDone {
		return nil, false, 0, zeroHdr, zeroQ
	}
	var hostBuf [255]byte
	host, hasDot := lowerDNSName(&q.Name, &hostBuf)
	var addresses [8]netip.Addr
	var count int
	var ips []netip.Addr
	var found bool
	for _, n := range networks {
		if q.Type == dnsmessage.TypeA || q.Type == dnsmessage.TypeALL {
			// Eight IPv4 records fit legacy UDP even with the longest question.
			// Most queries can finish the lookup without parsing EDNS options.
			ips, count = n.services.lookupBytes(host, addresses[:], len(addresses))
			if count > len(addresses) {
				additional := parser
				limit := serviceAnswerLimit(&q, network, &additional, binary.BigEndian.Uint16(packet[10:12]) != 0, count)
				if count <= limit {
					// Membership may have changed. Take both the data and count from
					// this lookup, under the packet's effective limit.
					ips, count = n.services.lookupBytes(host, addresses[:], limit)
				}
			}
			found = count > 0
		} else {
			found = n.services.containsBytes(host)
		}
		if found {
			break
		}
	}
	header := dnsmessage.Header{ID: h.ID, Response: true, Authoritative: true, RecursionDesired: h.RecursionDesired, RecursionAvailable: !internal}
	if found {
		s.metrics.networks.dnsLocal.Add(1)
		if len(ips) == 1 {
			wire, err := packSingleServiceAInto(dst, header, q, ips[0].As4())
			if err != nil {
				return nil, false, 0, zeroHdr, zeroQ
			}
			return wire, false, 0, zeroHdr, zeroQ
		}
		if count > 1 {
			raw, err := packServiceAddressesInto(dst, header, q, ips, count)
			if err != nil {
				return nil, false, 0, zeroHdr, zeroQ
			}
			return raw, false, 0, zeroHdr, zeroQ
		}
	} else if internal || !hasDot {
		s.metrics.networks.dnsMissing.Add(1)
		header.RCode = dnsmessage.RCodeNameError
	} else {
		return nil, true, h.ID, header, q
	}
	// Local NODATA and NXDOMAIN contain only the original question.
	raw, err := packServiceQuestionInto(dst, header, q, 0)
	if err != nil {
		return nil, false, 0, zeroHdr, zeroQ
	}
	return raw, false, 0, zeroHdr, zeroQ
}

func (s *dockerEngine) dnsForwardReply(ctx context.Context, upstream []string, packet []byte, network string, reqID uint16, header dnsmessage.Header, q dnsmessage.Question) []byte {
	s.metrics.networks.dnsForwarded.Add(1)
	header.Authoritative = false
	for _, addr := range upstream {
		if raw := forwardDNS(ctx, addr, network, packet, reqID); raw != nil {
			return raw
		}
	}
	s.metrics.networks.dnsFailures.Add(1)
	header.RCode = dnsmessage.RCodeServerFailure
	raw, err := packServiceQuestion(header, q)
	if err != nil {
		return nil
	}
	return raw
}

func (s *dockerEngine) dnsReply(ctx context.Context, n *workerNetwork, upstream []string, packet []byte, network string) []byte {
	out, forward, reqID, hdr, q := s.dnsLocalReply(n, packet, network, nil)
	if !forward {
		return out
	}
	return s.dnsForwardReply(ctx, upstream, packet, network, reqID, hdr, q)
}
func forwardDNS(ctx context.Context, addr, network string, req []byte, id uint16) []byte {
	dialer := net.Dialer{Timeout: time.Second}
	c, err := dialer.DialContext(ctx, network, addr)
	if err != nil {
		return nil
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(2 * time.Second))
	stop := context.AfterFunc(ctx, func() { c.Close() })
	defer stop()
	var out []byte
	if network == "tcp" {
		if sendDNS(c, req) != nil {
			return nil
		}
		out, err = readDNS(c)
	} else {
		if _, err = c.Write(req); err != nil {
			return nil
		}
		buf := make([]byte, 4096)
		var count int
		count, err = c.Read(buf)
		out = buf[:count]
	}
	if err != nil || len(out) < 12 || binary.BigEndian.Uint16(out) != id || out[2]&0x80 == 0 {
		return nil
	}
	return out
}
