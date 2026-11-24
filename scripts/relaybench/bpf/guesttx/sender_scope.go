package main

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

type senderIdentity struct {
	TGID         uint32 `json:"tgid"`
	NamespacePID uint32 `json:"namespace_pid"`
	StartTicks   uint64 `json:"start_ticks"`
	NetNS        uint32 `json:"netns_inode"`
	Port         uint32 `json:"local_port"`
	CgroupV2     string `json:"cgroup_v2"`
	ArgsSHA256   string `json:"args_sha256"`
}

// A conmon --container-pidfile is an optional source for the candidate init PID.
// A nonblocking open also prevents a mistaken FIFO from stalling the watchdog.
func servicePIDFile(path string) (uint32, error) {
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	stat, err := f.Stat()
	if err != nil {
		return 0, err
	}
	if !stat.Mode().IsRegular() {
		return 0, errors.New("expected a regular container PID file")
	}
	data, err := io.ReadAll(io.LimitReader(f, 32))
	if err != nil {
		return 0, err
	}
	pid := strings.TrimSuffix(string(data), "\n")
	n, err := strconv.ParseUint(pid, 10, 31)
	if err != nil || n == 0 || strconv.FormatUint(n, 10) != pid {
		return 0, errors.New("expected a single positive decimal container PID")
	}
	return uint32(n), nil
}

func readSender(dir string, tgid, netns, port uint32) (senderIdentity, error) {
	id := senderIdentity{TGID: tgid, NetNS: netns, Port: port}
	data, err := os.ReadFile(filepath.Join(dir, "stat"))
	if err != nil {
		return id, err
	}
	stat := string(data)
	end := strings.LastIndex(stat, ") ")
	wantPID := strconv.FormatUint(uint64(tgid), 10)
	if !strings.HasPrefix(stat, wantPID+" (") || end < 0 {
		return id, errors.New("unexpected service process stat identity")
	}
	fields := strings.Fields(stat[end+2:]) // begins at field 3, state
	if len(fields) < 20 {
		return id, errors.New("truncated service process stat")
	}
	if id.StartTicks, err = strconv.ParseUint(fields[19], 10, 64); err != nil {
		return id, errors.New("invalid service process start time")
	}
	status, err := os.ReadFile(filepath.Join(dir, "status"))
	if err != nil {
		return id, err
	}
	seen := make(map[string]bool, 3)
	for _, line := range strings.Split(string(status), "\n") {
		key, val, _ := strings.Cut(line, ":")
		switch key {
		case "Tgid", "Pid":
			if seen[key] || strings.TrimSpace(val) != wantPID {
				return id, errors.New("service PID must be a thread group leader")
			}
			seen[key] = true
		case "NSpid":
			pids := strings.Fields(val)
			if len(pids) == 0 || pids[0] != wantPID || id.NamespacePID != 0 {
				return id, errors.New("unverified service PID namespace")
			}
			n, err := strconv.ParseUint(pids[len(pids)-1], 10, 31)
			if err != nil || n == 0 {
				return id, errors.New("invalid service namespace PID")
			}
			id.NamespacePID = uint32(n)
		}
	}
	if id.NamespacePID == 0 || !seen["Tgid"] || !seen["Pid"] {
		return id, errors.New("missing service process identity")
	}
	ns, err := os.Readlink(filepath.Join(dir, "ns/net"))
	if err != nil {
		return id, err
	}
	if ns != fmt.Sprintf("net:[%d]", netns) {
		return id, errors.New("service process network namespace differs from the requested socket namespace")
	}
	cg, err := os.ReadFile(filepath.Join(dir, "cgroup"))
	if err != nil {
		return id, err
	}
	for _, line := range strings.Split(string(cg), "\n") {
		if p, ok := strings.CutPrefix(line, "0::"); ok {
			if id.CgroupV2 != "" || !filepath.IsAbs(p) || filepath.Clean(p) != p || strings.HasSuffix(p, " (deleted)") {
				return id, errors.New("ambiguous or retired service cgroup v2")
			}
			id.CgroupV2 = p
		}
	}
	if id.CgroupV2 == "" {
		return id, errors.New("missing service cgroup v2")
	}
	argv, err := os.ReadFile(filepath.Join(dir, "cmdline"))
	if err != nil {
		return id, err
	}
	exe, args, ok := bytes.Cut(argv, []byte{0})
	if !ok || len(exe) == 0 || argv[len(argv)-1] != 0 {
		return id, errors.New("missing or unterminated service command line")
	}
	id.ArgsSHA256 = fmt.Sprintf("%x", sha256.Sum256(args))
	return id, nil
}

var serviceFields = [...]string{"calls", "requested_bytes", "accepted_bytes", "full_calls", "short_calls", "zero_calls", "error_calls", "read_errors", "oversized_returns"}

func verifySender(dir string, id senderIdentity, pidfile string) error {
	after, err := readSender(dir, id.TGID, id.NetNS, id.Port)
	if err != nil {
		return err
	}
	if after != id {
		return errors.New("service process identity changed during capture")
	}
	if pidfile != "" {
		pid, err := servicePIDFile(pidfile)
		if err != nil {
			return err
		}
		if pid != id.TGID {
			return errors.New("service container PID file changed during capture")
		}
	}
	return nil
}

type serviceCounts [len(serviceFields)]uint64

func summarizeService(rows []serviceCounts) (map[string]uint64, bool, error) {
	if len(rows) == 0 {
		return nil, false, errors.New("missing service CPU rows")
	}
	out := make(map[string]uint64, len(serviceFields))
	for _, row := range rows {
		for i, count := range row {
			field := serviceFields[i]
			if count > math.MaxUint64-out[field] {
				return nil, false, fmt.Errorf("service counter overflow: %s", field)
			}
			out[field] += count
		}
	}
	left := out["calls"]
	for _, key := range []string{"full_calls", "short_calls", "zero_calls", "error_calls", "oversized_returns"} {
		if out[key] > left {
			return out, false, nil
		}
		left -= out[key]
	}
	observed := out["full_calls"] > 0 || out["short_calls"] > 0
	return out, left == 0 && observed && out["accepted_bytes"] > 0 &&
		out["accepted_bytes"] <= out["requested_bytes"] && out["read_errors"] == 0 && out["oversized_returns"] == 0, nil
}
