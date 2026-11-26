package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os/exec"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

// The machine's own connections into its container networks.
//
// Every container network's gateway is an address of the engine's own
// namespace, so that namespace has a connected route to every network, the
// internal ones included. A connection a process of the machine itself
// starts (buildkitd fetching a build's ADD URL or git context, containerd
// pulling an image, the engine's registry probe for docker login) goes
// straight out through the network's link: past the FORWARD rules that keep
// networks apart (workerNetwork.firewall), which see only what a container
// sends, and past the gateway relay's rule (relayAdmits), which sees only
// what the relay carries. A build or a pull through a container's Docker
// socket would reach another job's services that way. So a connection the
// machine starts out through a container network's link is refused (an
// administratively prohibited unreachable, at once), unless one of the
// engine's relays starts it (they mark their sockets, markHostOutput), whose
// rule decided it already. What a container starts, and every reply, is
// untouched.

// hostOutputMark marks the engine relays' sockets (SO_MARK) in the bits of
// hostOutputMask.
const (
	hostOutputMark  = 0x4d500000
	hostOutputMask  = 0xffff0000
	hostOutputChain = "MP-HOST-OUT"
)

// hostOutputLinks are the links of the container networks: the default
// network's bridge, and each named network's bridge (linkName) and gateway
// link (gatewayLink), as iptables interface patterns.
var hostOutputLinks = []string{defaultBridge, "mpb+", "mpg+"}

// hostOutputFamily is one address family's tables.
type hostOutputFamily struct {
	iptables, reject string
	// required: without this family's rules the engine does not start;
	// IPv6, which no container network routes, is best effort.
	required bool
}

var hostOutputFamilies = []hostOutputFamily{
	{iptables: "iptables", reject: "icmp-admin-prohibited", required: true},
	// A container's link-local IPv6 address is reachable on its bridge.
	{iptables: "ip6tables", reject: "icmp6-adm-prohibited"},
}

// guardHostOutput installs the rule: the chain, replaced whole, and the
// OUTPUT jumps to it for each container network link, added once.
func guardHostOutput(ctx context.Context) error {
	for _, f := range hostOutputFamilies {
		err := f.install(ctx)
		if err == nil {
			continue
		}
		if f.required {
			return err
		}
		log.Printf("the machine's own IPv6 connections into container networks are not refused: %v", err)
	}
	return nil
}

func (f hostOutputFamily) install(ctx context.Context) error {
	restore := exec.CommandContext(ctx, f.iptables+"-restore", "-w", "5", "--noflush")
	restore.Stdin = strings.NewReader(fmt.Sprintf(`*filter
:%[1]s - [0:0]
-F %[1]s
-A %[1]s -m mark --mark %#[2]x/%#[3]x -j RETURN
-A %[1]s -m conntrack --ctstate NEW -j REJECT --reject-with %[4]s
COMMIT
`, hostOutputChain, hostOutputMark, hostOutputMask, f.reject))
	if out, err := restore.CombinedOutput(); err != nil {
		return fmt.Errorf("%s-restore %s: %w: %.512s", f.iptables, hostOutputChain, err, out)
	}
	for _, link := range hostOutputLinks {
		jump := []string{"OUTPUT", "-o", link, "-j", hostOutputChain}
		check := exec.CommandContext(ctx, f.iptables, append([]string{"-w", "5", "-t", "filter", "-C"}, jump...)...)
		if check.Run() == nil {
			continue
		}
		if out, err := exec.CommandContext(ctx, f.iptables, append([]string{"-w", "5", "-t", "filter", "-A"}, jump...)...).CombinedOutput(); err != nil {
			return fmt.Errorf("%s OUTPUT -o %s: %w: %.512s", f.iptables, link, err, out)
		}
	}
	return nil
}

// markHostOutput is a net.Dialer Control that marks an engine relay's
// socket, so the rule lets it into a container network. Only a process
// without CAP_NET_ADMIN (a test outside the machine) cannot set it, and no
// rule is installed there.
func markHostOutput(_, _ string, c syscall.RawConn) error {
	var set error
	if err := c.Control(func(fd uintptr) {
		set = unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, hostOutputMark)
	}); err != nil {
		return err
	}
	if errors.Is(set, unix.EPERM) {
		return nil
	}
	return set
}
