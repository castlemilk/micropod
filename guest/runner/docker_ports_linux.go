package main

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

const portBrokerSocket = "/var/lib/micropod/ports.sock"

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
	if c.HostConfig.NetworkMode == "none" {
		if len(c.HostConfig.PortBindings) > 0 {
			return nil, errors.New("an offline container cannot publish ports")
		}
		return out, nil
	}
	for key, bindings := range c.HostConfig.PortBindings {
		port, err := tcpPort(key)
		if err != nil {
			return nil, err
		}
		key := strconv.Itoa(int(port)) + "/tcp"
		out[key] = append(out[key], bindings...)
	}
	if c.HostConfig.PublishAllPorts {
		for key := range c.ExposedPorts {
			port, valid := parseDockerSummaryPort(key)
			if !valid || port.Type != "tcp" {
				return nil, fmt.Errorf("expected a TCP container port, got %q", key)
			}
			key := port.key()
			if _, explicit := out[key]; !explicit {
				out[key] = []portBinding{{}}
			}
		}
	}
	count := 0
	for _, bindings := range out {
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
	endpoint *directEndpoint
	mapping  *portMapping
	cancel   context.CancelFunc
	wg       sync.WaitGroup
}

func (p *publishedPort) close() error {
	if p.endpoint != nil {
		return p.endpoint.close()
	}
	if p.cancel != nil {
		p.cancel()
	}
	var err error
	if p.lease != nil {
		err = p.lease.Close()
	}
	if p.listener != nil {
		p.listener.Close()
	}
	p.wg.Wait()
	if p.mapping != nil {
		return p.mapping.close()
	}
	return err
}

// Only the guest NIC accepts a forwarded connection. The Mac owns the actual
// loopback port and releases it when the private vsock lease closes.
func reserveMacPort(ctx context.Context, host, guest uint16) (net.Conn, uint16, error) {
	var dial net.Dialer
	control, err := dial.DialContext(ctx, "unix", portBrokerSocket)
	if err != nil {
		return nil, 0, err
	}
	var req [4]byte
	binary.BigEndian.PutUint16(req[:2], host)
	binary.BigEndian.PutUint16(req[2:], guest)
	control.SetDeadline(time.Now().Add(5 * time.Second))
	_, err = control.Write(req[:])
	if err == nil {
		_, err = io.ReadFull(control, req[:2])
	}
	if err != nil {
		control.Close()
		return nil, 0, fmt.Errorf("reserve Mac loopback port %d: %w", host, err)
	}
	control.SetDeadline(time.Time{})
	return control, binary.BigEndian.Uint16(req[:2]), nil
}

func openPublishedPort(ctx context.Context, ip, target string, host uint16, direct *directEndpoint) (*publishedPort, uint16, error) {
	if kernelPublishedPorts() {
		return openKernelPort(ctx, ip, target, host, direct)
	}
	l, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.ParseIP(ip)})
	if err != nil {
		return nil, 0, err
	}
	control, port, err := reserveMacPort(ctx, host, uint16(l.Addr().(*net.TCPAddr).Port))
	if err != nil {
		l.Close()
		return nil, 0, err
	}
	var dial net.Dialer
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
	return p, port, nil
}
func guestIPv4() (string, error) {
	dev := "eth0"
	if os.Getenv("MICROPOD_CI_PUBLISH_IPV4") != "" {
		dev = "eth1"
	}
	iface, err := net.InterfaceByName(dev)
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
		_, err := configurePodNetwork(ctx, s.node, podID, nil, "")
		return nil, err
	}
	var target, primaryMAC string
	var network *workerNetwork
	if c.NetworkID != "" {
		s.mu.Lock()
		n := s.namedNetworks[c.NetworkID]
		s.mu.Unlock()
		if n == nil {
			return nil, errors.New("container network no longer exists")
		}
		start := time.Now()
		primaryMAC, err = configurePodNetwork(ctx, s.node, podID, n, c.NetworkIP)
		s.metrics.networks.attachment(n.Driver, start, err)
		if err != nil {
			return nil, err
		}
		network = n
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
	c.IP, c.primaryMAC = target, primaryMAC
	s.mu.Unlock()
	if len(ports) == 0 {
		return nil, nil
	}
	var ip string
	var direct *directEndpoint
	var open []*publishedPort
	if kernelPublishedPorts() {
		ip = os.Getenv("MICROPOD_PUBLISH_IPV4")
		if s.direct != nil && (network == nil || network.Driver == "bridge") {
			direct, err = s.direct.attach(ctx, s.node, podID, target)
			if direct != nil {
				open = append(open, &publishedPort{endpoint: direct})
			}
			if err != nil {
				return open, err
			}
		} else if os.Getenv("MICROPOD_CI_PORT_THROUGHPUT") == "1" && (network == nil || network.Driver == "bridge") {
			if err := s.node.preferLocalCongestionControl(ctx, podID, target, network); err != nil {
				// The published mapping and normal routing still work when an
				// installed kernel lacks the optional route metric.
				log.Printf("published TCP return route on pod %.12s: %v", podID, err)
			}
		}
	} else if !privateRootless() {
		ip, err = guestIPv4()
		if err != nil {
			return nil, err
		}
	}
	actual := portMap{}
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
				p, n, err = openPublishedPort(ctx, ip, net.JoinHostPort(target, strconv.Itoa(int(port))), request, direct)
			}
			if err != nil {
				if p != nil {
					open = append(open, p)
				}
				return open, err
			}
			open = append(open, p)
			switch {
			case direct != nil:
				s.metrics.networks.directPorts.Add(1)
			case p.mapping != nil:
				s.metrics.networks.kernelPorts.Add(1)
			case p.listener != nil:
				s.metrics.networks.relayPorts.Add(1)
			default:
				s.metrics.networks.rootlessPorts.Add(1)
			}
			actual[key] = append(actual[key], portBinding{HostIP: "127.0.0.1", HostPort: strconv.Itoa(int(n))})
		}
	}
	s.mu.Lock()
	c.Ports = actual
	s.mu.Unlock()
	return open, nil
}
