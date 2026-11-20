package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

type portBinding struct {
	HostIP   string `json:"HostIp"`
	HostPort string
}
type portMap map[string][]portBinding

func tcpPort(key string) (uint16, error) {
	s, proto, ok := strings.Cut(key, "/")
	n, err := strconv.ParseUint(s, 10, 16)
	if !ok || proto != "tcp" || err != nil || n == 0 {
		return 0, fmt.Errorf("expected a TCP container port, got %q", key)
	}
	return uint16(n), nil
}
func requestedPort(b portBinding) (uint16, error) {
	if b.HostIP != "" && b.HostIP != "127.0.0.1" {
		return 0, errors.New("published ports bind the Mac loopback address 127.0.0.1")
	}
	if b.HostPort == "" {
		return 0, nil
	}
	n, e := strconv.ParseUint(b.HostPort, 10, 16)
	return uint16(n), e
}
func (c dockerConfig) requestedPorts() (portMap, error) {
	out := portMap{}
	for key := range c.ExposedPorts {
		if c.HostConfig.PublishAllPorts {
			out[key] = []portBinding{{}}
		}
	}
	for key, bindings := range c.HostConfig.PortBindings {
		out[key] = bindings
	}
	if c.HostConfig.NetworkMode == "none" && len(out) > 0 {
		return nil, errors.New("an offline container cannot publish ports")
	}
	count := 0
	for key, bindings := range out {
		if _, err := tcpPort(key); err != nil {
			return nil, err
		}
		count += len(bindings)
		for _, b := range bindings {
			if _, err := requestedPort(b); err != nil {
				return nil, err
			}
		}
	}
	if count > 64 {
		return nil, errors.New("a container may publish at most 64 TCP ports")
	}
	return out, nil
}

type publishedPort struct {
	listener *net.TCPListener
	lease    io.Closer
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

func (p *publishedPort) close() {
	if p.cancel != nil {
		p.cancel()
	}
	p.lease.Close()
	if p.listener != nil {
		p.listener.Close()
	}
	p.wg.Wait()
}

// Only the guest NIC accepts a forwarded connection. The Mac owns the actual
// loopback port and releases it when the private vsock lease closes.
func openPublishedPort(ctx context.Context, ip, target string, host uint16) (*publishedPort, uint16, error) {
	l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.ParseIP(ip)})
	if err != nil {
		return nil, 0, err
	}
	var dial net.Dialer
	control, err := dial.DialContext(ctx, "unix", "/var/lib/micropod/ports.sock")
	if err != nil {
		l.Close()
		return nil, 0, err
	}
	var req [4]byte
	binary.BigEndian.PutUint16(req[:2], host)
	binary.BigEndian.PutUint16(req[2:], uint16(l.Addr().(*net.TCPAddr).Port))
	control.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = control.Write(req[:])
	if err == nil {
		_, err = io.ReadFull(control, req[:2])
	}
	if err != nil {
		control.Close()
		l.Close()
		return nil, 0, fmt.Errorf("reserve Mac loopback port %d: %w", host, err)
	}
	control.SetDeadline(time.Time{})
	// The setup deadline ends when crun starts. Established listeners live
	// until the container releases its port, including across long SQL sessions.
	relayCtx, cancel := context.WithCancel(context.WithoutCancel(ctx))
	p := &publishedPort{listener: l, lease: control, cancel: cancel}
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		for {
			in, err := l.AcceptTCP()
			if err != nil {
				return
			}
			p.wg.Add(1)
			go func() {
				defer p.wg.Done()
				defer in.Close()
				out, err := dial.DialContext(relayCtx, "tcp4", target)
				if err != nil {
					return
				}
				defer out.Close()
				stop := context.AfterFunc(relayCtx, func() { in.Close(); out.Close() })
				defer stop()
				done := make(chan struct{})
				go func() { io.Copy(out, in); out.(*net.TCPConn).CloseWrite(); close(done) }()
				io.Copy(in, out)
				in.CloseWrite()
				<-done
			}()
		}
	}()
	return p, binary.BigEndian.Uint16(req[:2]), nil
}
func guestIPv4() (string, error) {
	iface, err := net.InterfaceByName("eth0")
	if err != nil {
		return "", err
	}
	addrs, err := iface.Addrs()
	if err != nil {
		return "", err
	}
	for _, addr := range addrs {
		ip, _, err := net.ParseCIDR(addr.String())
		if err == nil && ip.To4() != nil {
			return ip.String(), nil
		}
	}
	return "", errors.New("worker network has no IPv4 address")
}
func (s *dockerEngine) publish(ctx context.Context, c *dockerContainer, podID string) ([]*publishedPort, error) {
	ports, err := c.Config.requestedPorts()
	if err != nil {
		return nil, err
	}
	if c.Config.HostConfig.NetworkMode == "none" {
		return nil, configurePodNetwork(ctx, s.node, podID, nil, "")
	}
	var target string
	if c.NetworkID != "" {
		s.mu.Lock()
		n := s.namedNetworks[c.NetworkID]
		s.mu.Unlock()
		if n == nil {
			return nil, errors.New("container network no longer exists")
		}
		start := time.Now()
		err := configurePodNetwork(ctx, s.node, podID, n, c.NetworkIP)
		s.metrics.networks.attachment(n.Driver, start, err)
		if err != nil {
			return nil, err
		}
		target = c.NetworkIP
	} else {
		pod, err := s.node.runtime.PodSandboxStatus(ctx, &cri.PodSandboxStatusRequest{PodSandboxId: podID})
		if err != nil {
			return nil, err
		}
		target = pod.GetStatus().GetNetwork().GetIp()
	}
	if net.ParseIP(target) == nil {
		return nil, errors.New("container has no network address")
	}
	s.mu.Lock()
	c.IP = target
	s.mu.Unlock()
	if len(ports) == 0 {
		return nil, nil
	}
	var ip string
	if !privateRootless() {
		ip, err = guestIPv4()
		if err != nil {
			return nil, err
		}
	}
	actual := portMap{}
	var open []*publishedPort
	for key, bindings := range ports {
		port, _ := tcpPort(key)
		for _, b := range bindings {
			request, _ := requestedPort(b)
			var p *publishedPort
			var n uint16
			var err error
			if privateRootless() {
				p, n, err = publishRootless(ctx, target, port, request)
			} else {
				p, n, err = openPublishedPort(ctx, ip, net.JoinHostPort(target, strconv.Itoa(int(port))), request)
			}
			if err != nil {
				for _, other := range open {
					other.close()
				}
				return nil, err
			}
			open = append(open, p)
			actual[key] = append(actual[key], portBinding{HostIP: "127.0.0.1", HostPort: strconv.Itoa(int(n))})
		}
	}
	s.mu.Lock()
	c.Ports = actual
	s.mu.Unlock()
	return open, nil
}
