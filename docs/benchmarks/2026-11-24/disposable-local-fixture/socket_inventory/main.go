// Report established service tuples in the caller's network namespace on Linux arm64.
// procfs exposes the endpoints and state, but does not expose TCP_CONGESTION.
package main

import (
	"bufio"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/netip"
	"os"
	"sort"
	"strconv"
	"strings"
)

type connection struct {
	LocalIP    string `json:"local_ip"`
	LocalPort  uint16 `json:"local_port"`
	RemoteIP   string `json:"remote_ip"`
	RemotePort uint16 `json:"remote_port"`
}

type inventory struct {
	Source      string       `json:"source"`
	Connections []connection `json:"connections"`
}

func endpoint(s string, width int) (netip.AddrPort, error) {
	addr, port, ok := strings.Cut(s, ":")
	if !ok || len(addr) != 2*width || len(port) != 4 {
		return netip.AddrPort{}, errors.New("invalid endpoint width")
	}
	raw, err := hex.DecodeString(addr)
	if err != nil {
		return netip.AddrPort{}, err
	}
	// Linux prints each native u32 in the address separately. arm64 is little-endian.
	for i := 0; i < len(raw); i += 4 {
		binary.BigEndian.PutUint32(raw[i:], binary.LittleEndian.Uint32(raw[i:]))
	}
	ip, ok := netip.AddrFromSlice(raw)
	if !ok {
		return netip.AddrPort{}, errors.New("invalid address")
	}
	number, err := strconv.ParseUint(port, 16, 16)
	if err != nil {
		return netip.AddrPort{}, err
	}
	return netip.AddrPortFrom(ip.Unmap(), uint16(number)), nil
}

func number(s string, base int) bool {
	_, err := strconv.ParseUint(s, base, 64)
	return err == nil
}

func hexPair(s string) bool {
	left, right, found := strings.Cut(s, ":")
	return found && number(left, 16) && number(right, 16)
}

func parseTable(input io.Reader, width int) ([]connection, error) {
	reader := bufio.NewReader(input)
	header, err := reader.ReadString('\n')
	if err != nil {
		return nil, errors.New("missing or incomplete TCP table header")
	}
	fields := strings.Fields(header)
	if len(fields) >= 3 && fields[2] == "remote_address" {
		fields[2] = "rem_address"
	}
	if strings.Join(fields, " ") != "sl local_address rem_address st tx_queue rx_queue tr tm->when retrnsmt uid timeout inode" {
		return nil, errors.New("unrecognized TCP table header")
	}

	var out []connection
	for line := 2; ; line++ {
		row, err := reader.ReadString('\n')
		if err == io.EOF && row == "" {
			return out, nil
		}
		if err != nil {
			return nil, fmt.Errorf("incomplete TCP row %d: %w", line, err)
		}
		fields := strings.Fields(row)
		if len(fields) < 10 || !strings.HasSuffix(fields[0], ":") || len(fields[3]) != 2 {
			return nil, fmt.Errorf("invalid TCP row %d", line)
		}
		if !number(strings.TrimSuffix(fields[0], ":"), 10) || !hexPair(fields[4]) || !hexPair(fields[5]) ||
			!number(fields[6], 16) || !number(fields[7], 10) || !number(fields[8], 10) || !number(fields[9], 10) {
			return nil, fmt.Errorf("invalid TCP accounting fields on row %d", line)
		}
		state, stateErr := strconv.ParseUint(fields[3], 16, 8)
		local, localErr := endpoint(fields[1], width)
		remote, remoteErr := endpoint(fields[2], width)
		if stateErr != nil || state == 0 || localErr != nil || remoteErr != nil {
			return nil, fmt.Errorf("invalid TCP endpoint or state on row %d", line)
		}
		if state == 1 && local.Port() == 8080 {
			if local.Addr().IsUnspecified() || remote.Addr().IsUnspecified() || remote.Port() == 0 {
				return nil, fmt.Errorf("incomplete established endpoints on row %d", line)
			}
			out = append(out, connection{local.Addr().String(), local.Port(), remote.Addr().String(), remote.Port()})
		}
	}
}

func collect(v4, v6 io.Reader) (inventory, error) {
	ipv4, err := parseTable(v4, 4)
	if err != nil {
		return inventory{}, fmt.Errorf("/proc/self/net/tcp: %w", err)
	}
	ipv6, err := parseTable(v6, 16)
	if err != nil {
		return inventory{}, fmt.Errorf("/proc/self/net/tcp6: %w", err)
	}
	rows := append(append([]connection{}, ipv4...), ipv6...)
	sort.Slice(rows, func(i, j int) bool {
		a, b := rows[i], rows[j]
		if a.LocalIP != b.LocalIP {
			return a.LocalIP < b.LocalIP
		}
		if a.RemoteIP != b.RemoteIP {
			return a.RemoteIP < b.RemoteIP
		}
		return a.RemotePort < b.RemotePort
	})
	for i := 1; i < len(rows); i++ {
		if rows[i] == rows[i-1] {
			return inventory{}, errors.New("duplicate established service tuple")
		}
	}
	return inventory{"proc_net_tcp", rows}, nil
}

func run() error {
	if len(os.Args) != 1 {
		return errors.New("usage: socket-inventory")
	}
	v4, err := os.Open("/proc/self/net/tcp")
	if err != nil {
		return err
	}
	defer v4.Close()
	v6, err := os.Open("/proc/self/net/tcp6")
	if err != nil {
		return err
	}
	defer v6.Close()
	report, err := collect(v4, v6)
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(report)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
