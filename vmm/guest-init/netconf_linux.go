//go:build linux

package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// rtnl is a blocking NETLINK_ROUTE socket with a receive timeout, so a lost
// reply can never wedge PID 1.
type rtnl struct {
	fd  int
	seq uint32
	buf []byte
}

func openRtnl() (*rtnl, error) {
	fd, err := syscall.Socket(syscall.AF_NETLINK, syscall.SOCK_RAW|syscall.SOCK_CLOEXEC, syscall.NETLINK_ROUTE)
	if err != nil {
		return nil, fmt.Errorf("netlink socket: %w", err)
	}
	tv := syscall.Timeval{Sec: 2}
	if err := syscall.SetsockoptTimeval(fd, syscall.SOL_SOCKET, syscall.SO_RCVTIMEO, &tv); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("netlink timeout: %w", err)
	}
	if err := syscall.Bind(fd, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		syscall.Close(fd)
		return nil, fmt.Errorf("netlink bind: %w", err)
	}
	return &rtnl{fd: fd, buf: make([]byte, 64*1024)}, nil
}

func (r *rtnl) close() { syscall.Close(r.fd) }

func (r *rtnl) nextSeq() uint32 {
	r.seq++
	return r.seq
}

// exchange sends one message and collects the replies carrying its sequence
// number: up to the ACK (an NLMSG_ERROR with errno 0) for a request, or up to
// NLMSG_DONE for a dump.
func (r *rtnl) exchange(seq uint32, msg []byte, dump bool) ([]nlMsg, error) {
	if err := syscall.Sendto(r.fd, msg, 0, &syscall.SockaddrNetlink{Family: syscall.AF_NETLINK}); err != nil {
		return nil, fmt.Errorf("netlink send: %w", err)
	}
	var out []nlMsg
	for {
		n, _, err := syscall.Recvfrom(r.fd, r.buf, 0)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return out, fmt.Errorf("netlink receive: %w", err)
		}
		var done bool
		var errno int
		out, done, errno, err = collectReplies(r.buf[:n], seq, dump, out)
		if err != nil {
			return out, err
		}
		if errno != 0 {
			return out, syscall.Errno(errno)
		}
		if done {
			return out, nil
		}
	}
}

func (r *rtnl) request(build func(seq uint32) []byte) error {
	seq := r.nextSeq()
	_, err := r.exchange(seq, build(seq), false)
	return err
}

func (r *rtnl) dump(typ uint16) ([]nlMsg, error) {
	seq := r.nextSeq()
	return r.exchange(seq, dumpMsg(typ, seq, afInet), true)
}

// waitForInterface allows for a NIC whose driver is still registering it.
func waitForInterface(name string, timeout time.Duration) (*net.Interface, error) {
	deadline := time.Now().Add(timeout)
	for {
		iface, err := net.InterfaceByName(name)
		if err == nil || time.Now().After(deadline) {
			return iface, err
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// configureGuestNetwork applies the plan with rtnetlink (MTU, link up, address,
// default route, permanent neighbour), continuing past failures so one broken
// step, such as an MTU the device rejects, does not leave the rest undone.
func configureGuestNetwork(r *rtnl, plan []ifacePlan) []error {
	var errs []error
	for _, p := range plan {
		iface, err := waitForInterface(p.name, time.Second)
		if err != nil {
			errs = append(errs, fmt.Errorf("%s: %w", p.name, err))
			continue
		}
		idx := iface.Index
		step := func(what string, build func(seq uint32) []byte) {
			if err := r.request(build); err != nil {
				errs = append(errs, fmt.Errorf("%s: %s: %w", p.name, what, err))
			}
		}
		if p.mtu != 0 {
			step(fmt.Sprintf("mtu %d", p.mtu), func(seq uint32) []byte { return linkMTUMsg(seq, idx, p.mtu) })
		}
		step("link up", func(seq uint32) []byte { return linkUpMsg(seq, idx) })
		step("address "+p.addr.String(), func(seq uint32) []byte { return addrReplaceMsg(seq, idx, p.addr, p.scope) })
		if p.gateway.IsValid() {
			step("default route", func(seq uint32) []byte { return defaultRouteReplaceMsg(seq, idx, p.gateway) })
		}
		if p.neighIP.IsValid() {
			step("neighbour "+p.neighIP.String(), func(seq uint32) []byte { return neighReplaceMsg(seq, idx, p.neighIP, p.neighMAC) })
		}
	}
	return errs
}

func observeGuestNetwork(r *rtnl, plan []ifacePlan) (netObservation, error) {
	obs := netObservation{links: map[string]ifaceState{}}
	for _, p := range plan {
		iface, err := net.InterfaceByName(p.name)
		if err != nil {
			continue
		}
		obs.links[p.name] = ifaceState{index: iface.Index, up: iface.Flags&net.FlagUp != 0, mtu: iface.MTU}
	}
	var errs []error
	if msgs, err := r.dump(rtmGetAddr); err == nil {
		for _, m := range msgs {
			if a, ok := parseAddrMsg(m.body); ok {
				obs.addrs = append(obs.addrs, a)
			}
		}
	} else {
		errs = append(errs, fmt.Errorf("dump addresses: %w", err))
	}
	if msgs, err := r.dump(rtmGetRoute); err == nil {
		for _, m := range msgs {
			if rt, ok := parseDefaultRoute(m.body); ok {
				obs.routes = append(obs.routes, rt)
			}
		}
	} else {
		errs = append(errs, fmt.Errorf("dump routes: %w", err))
	}
	if msgs, err := r.dump(rtmGetNeigh); err == nil {
		for _, m := range msgs {
			if n, ok := parseNeighMsg(m.body); ok {
				obs.neighs = append(obs.neighs, n)
			}
		}
	} else {
		errs = append(errs, fmt.Errorf("dump neighbours: %w", err))
	}
	return obs, errors.Join(errs...)
}

// setupGuestNetwork configures lo, eth0 (egress) and, when present, eth1 (the
// published link), then reads the result back and reports it on the console.
// It returns the published link MTU in effect (0 without eth1).
func setupGuestNetwork(mtuParam string) int {
	_, err := os.Stat("/sys/class/net/eth1")
	withPublished := err == nil
	var mtu uint32
	if mtuParam != "" {
		v, err := strconv.ParseUint(mtuParam, 10, 32)
		if err != nil || v < 576 || v > 65535 {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] net: ignoring invalid mp.mtu=%q\n", mtuParam)
		} else {
			mtu = uint32(v)
		}
	}
	plan := guestNetPlan(withPublished, mtu)
	r, err := openRtnl()
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] net: FAILED: %v\n", err)
		return 0
	}
	defer r.close()
	for _, err := range configureGuestNetwork(r, plan) {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] net: %v\n", err)
	}
	obs, err := observeGuestNetwork(r, plan)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] net: %v\n", err)
	}
	for _, p := range plan[1:] {
		fmt.Printf("[mp-hvf-init] net: %s\n", describeIface(p, obs))
	}
	if problems := verifyNetPlan(plan, obs); len(problems) > 0 {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] net: WARNING: %s\n", strings.Join(problems, "; "))
	}
	if !withPublished {
		return 0
	}
	// The engine must not be pointed at a published link that is down.
	if link := obs.links["eth1"]; link.up {
		return link.mtu
	}
	fmt.Fprintln(os.Stderr, "[mp-hvf-init] net: eth1 is down; published ports use eth0")
	return 0
}
