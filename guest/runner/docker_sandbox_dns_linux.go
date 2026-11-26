package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"runtime"
	"slices"
	"strings"
	"sync/atomic"
	"time"

	"golang.org/x/net/dns/dnsmessage"
	"golang.org/x/sys/unix"
)

const dockerBridgeResolverPath = engineRoot + "/embedded-dns-resolv.conf"

func prepareDockerBridgeResolver() (string, error) {
	f, err := os.CreateTemp(engineRoot, ".embedded-dns-resolv-")
	if err != nil {
		return "", err
	}
	defer os.Remove(f.Name())
	_, err = f.WriteString("nameserver 127.0.0.11\noptions ndots:0\n")
	if err == nil {
		err = f.Chmod(0644)
	}
	if err := errors.Join(err, f.Close()); err != nil {
		return "", err
	}
	if err := os.Rename(f.Name(), dockerBridgeResolverPath); err != nil {
		return "", err
	}
	return dockerBridgeResolverPath, nil
}

type sandboxDNSNetworks struct{ networks []*workerNetwork }

type dockerSandboxDNS struct {
	engine   *dockerEngine
	internal bool
	attached atomic.Pointer[sandboxDNSNetworks]
	server   *networkDNS
}

func (d *dockerSandboxDNS) setNetworks(networks []*workerNetwork) {
	d.attached.Store(&sandboxDNSNetworks{networks: slices.Clone(networks)})
}

func (d *dockerSandboxDNS) answer(packet []byte, transport string, dst []byte) ([]byte, bool, uint16, dnsmessage.Header, dnsmessage.Question) {
	scope := d.attached.Load()
	return d.engine.dnsNetworksReply(scope.networks, d.internal, packet, transport, dst)
}

func (s *dockerEngine) listenDockerSandboxDNS(ctx context.Context, ns *os.File, primary *workerNetwork) (*dockerSandboxDNS, error) {
	d := &dockerSandboxDNS{engine: s, internal: primary.Internal}
	d.setNetworks([]*workerNetwork{primary})
	udp, tcp, err := sandboxDNSListeners(ns)
	if err != nil {
		return nil, err
	}
	start := time.Now()
	err = installSandboxDNSRedirect(ctx, ns, udp.LocalAddr().(*net.UDPAddr).Port, tcp.Addr().(*net.TCPAddr).Port)
	s.metrics.networks.dnsRedirectAttempts.Add(1)
	s.metrics.networks.dnsRedirectUS.Add(uint64(time.Since(start).Microseconds()))
	if err != nil {
		s.metrics.networks.dnsRedirectErrors.Add(1)
		udp.Close()
		tcp.Close()
		return nil, err
	}
	d.server, err = s.serveNetworkDNS(udp, tcp, d.answer)
	if err != nil {
		return nil, err
	}
	return d, nil
}

// setns acts on the calling thread. A failed restoration leaves that thread
// locked until Go discards it when the dedicated goroutine exits.
func inDockerNetworkNamespace(ns *os.File, work func() error) error {
	done := make(chan error, 1)
	go func() {
		runtime.LockOSThread()
		restored := true
		defer func() {
			if restored {
				runtime.UnlockOSThread()
			}
		}()
		original, err := os.Open("/proc/thread-self/ns/net")
		if err != nil {
			done <- err
			return
		}
		defer original.Close()
		if err := unix.Setns(int(ns.Fd()), unix.CLONE_NEWNET); err != nil {
			done <- err
			return
		}
		restored = false
		err = work()
		if restoreErr := unix.Setns(int(original.Fd()), unix.CLONE_NEWNET); restoreErr != nil {
			done <- errors.Join(err, fmt.Errorf("restore worker network namespace: %w", restoreErr))
			return
		}
		restored = true
		done <- err
	}()
	return <-done
}

func sandboxDNSListeners(ns *os.File) (net.PacketConn, net.Listener, error) {
	var udpFile, tcpFile *os.File
	err := inDockerNetworkNamespace(ns, func() error {
		var err error
		udpFile, err = bindSandboxDNS(unix.SOCK_DGRAM)
		if err != nil {
			return err
		}
		tcpFile, err = bindSandboxDNS(unix.SOCK_STREAM)
		return err
	})
	if udpFile != nil {
		defer udpFile.Close()
	}
	if tcpFile != nil {
		defer tcpFile.Close()
	}
	if err != nil {
		return nil, nil, fmt.Errorf("bind sandbox DNS: %w", err)
	}
	udp, err := net.FilePacketConn(udpFile)
	if err != nil {
		return nil, nil, err
	}
	tcp, err := net.FileListener(tcpFile)
	if err != nil {
		udp.Close()
		return nil, nil, err
	}
	return udp, tcp, nil
}

func bindSandboxDNS(kind int) (*os.File, error) {
	fd, err := unix.Socket(unix.AF_INET, kind|unix.SOCK_NONBLOCK|unix.SOCK_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	f := os.NewFile(uintptr(fd), "sandbox DNS")
	if err = unix.SetsockoptString(fd, unix.SOL_SOCKET, unix.SO_BINDTODEVICE, "lo"); err == nil {
		err = unix.Bind(fd, &unix.SockaddrInet4{Addr: [4]byte{127, 0, 0, 11}})
	}
	if err == nil && kind == unix.SOCK_STREAM {
		err = unix.Listen(fd, 64)
	}
	if err != nil {
		f.Close()
		return nil, err
	}
	return f, nil
}

func sandboxDNSRules(udpPort, tcpPort int) string {
	return fmt.Sprintf(`*nat
-A OUTPUT -o lo -d 127.0.0.11/32 -p udp --dport 53 -j DNAT --to-destination 127.0.0.11:%d
-A POSTROUTING -o lo -s 127.0.0.11/32 -p udp --sport %d -j SNAT --to-source :53
-A OUTPUT -o lo -d 127.0.0.11/32 -p tcp --dport 53 -j DNAT --to-destination 127.0.0.11:%d
-A POSTROUTING -o lo -s 127.0.0.11/32 -p tcp --sport %d -j SNAT --to-source :53
COMMIT
`, udpPort, udpPort, tcpPort, tcpPort)
}

func installSandboxDNSRedirect(ctx context.Context, ns *os.File, udpPort, tcpPort int) error {
	// Private, ephemeral listeners leave wildcard application port 53
	// available. The four rules travel in one namespace-local transaction.
	cmd := exec.CommandContext(ctx, "nsenter", "--net=/proc/self/fd/3", "--", "iptables-restore", "-w", "5", "--noflush")
	cmd.ExtraFiles = []*os.File{ns}
	cmd.Stdin = strings.NewReader(sandboxDNSRules(udpPort, tcpPort))
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("install sandbox DNS redirects: %w: %.512s", err, out)
	}
	return nil
}
