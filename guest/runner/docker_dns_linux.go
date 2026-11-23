package main

import (
	"context"
	"encoding/binary"
	"errors"
	"io"
	"net"
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

func (s *dockerEngine) listenDNS(n *workerNetwork) (*networkDNS, error) {
	ctx, cancel := context.WithCancel(context.Background())
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
	udp, err := config.ListenPacket(ctx, "udp4", addr)
	if err != nil {
		cancel()
		return nil, err
	}
	tcp, err := config.Listen(ctx, "tcp4", addr)
	if err != nil {
		cancel()
		udp.Close()
		return nil, err
	}
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
		for {
			size, to, err := udp.ReadFrom(buf)
			if err != nil {
				return
			}
			select {
			case d.slots <- struct{}{}:
			default:
				s.metrics.networks.dnsDropped.Add(1)
				continue
			}
			req := slices.Clone(buf[:size])
			d.wg.Add(1)
			go func() {
				defer d.wg.Done()
				defer func() { <-d.slots }()
				if out := s.dnsReply(ctx, n, d.upstream, req, "udp"); out != nil {
					_, _ = udp.WriteTo(out, to)
				}
			}()
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
					out := s.dnsReply(ctx, n, d.upstream, req, "tcp")
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
	var h [2]byte
	binary.BigEndian.PutUint16(h[:], uint16(len(b)))
	if _, err := w.Write(h[:]); err != nil {
		return err
	}
	_, err := w.Write(b)
	return err
}

func (s *dockerEngine) dnsReply(ctx context.Context, n *workerNetwork, upstream []string, packet []byte, network string) []byte {
	var parser dnsmessage.Parser
	h, err := parser.Start(packet)
	if err != nil || h.Response {
		return nil
	}
	q, err := parser.Question()
	if err != nil {
		return nil
	}
	if _, err = parser.Question(); err != dnsmessage.ErrSectionDone {
		return nil
	}
	host := strings.ToLower(strings.TrimSuffix(q.Name.String(), "."))
	ips := n.services.lookup(host)
	out := dnsmessage.Message{Header: dnsmessage.Header{ID: h.ID, Response: true, Authoritative: true, RecursionDesired: h.RecursionDesired, RecursionAvailable: !n.Internal}, Questions: []dnsmessage.Question{q}}
	if len(ips) > 0 {
		s.metrics.networks.dnsLocal.Add(1)
		if len(ips) == 1 && (q.Type == dnsmessage.TypeA || q.Type == dnsmessage.TypeALL) {
			wire, err := packSingleServiceA(out.Header, q, ips[0].As4())
			if err != nil {
				return nil
			}
			return wire
		}
		for _, ip := range ips {
			if q.Type == dnsmessage.TypeA || q.Type == dnsmessage.TypeALL {
				out.Answers = append(out.Answers, dnsmessage.Resource{Header: dnsmessage.ResourceHeader{Name: q.Name, Class: dnsmessage.ClassINET, TTL: 1}, Body: &dnsmessage.AResource{A: ip.As4()}})
			}
		}
	} else if n.Internal || !strings.Contains(host, ".") {
		s.metrics.networks.dnsMissing.Add(1)
		out.RCode = dnsmessage.RCodeNameError
	} else {
		s.metrics.networks.dnsForwarded.Add(1)
		out.Authoritative = false
		for _, addr := range upstream {
			if raw := forwardDNS(ctx, addr, network, packet, h.ID); raw != nil {
				return raw
			}
		}
		s.metrics.networks.dnsFailures.Add(1)
		out.RCode = dnsmessage.RCodeServerFailure
	}
	raw, err := out.Pack()
	if err != nil {
		return nil
	}
	if network == "udp" && len(raw) > 512 {
		limit := 512
		if parser.SkipAllAnswers() == nil && parser.SkipAllAuthorities() == nil {
			for {
				h, err := parser.AdditionalHeader()
				if err != nil {
					break
				}
				if h.Type == dnsmessage.TypeOPT {
					limit = min(4096, max(512, int(h.Class)))
					break
				}
				if parser.SkipAdditional() != nil {
					break
				}
			}
		}
		if len(raw) > limit {
			out.Truncated = true
			out.Answers = nil
			raw, _ = out.Pack()
		}
	}
	return raw
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
