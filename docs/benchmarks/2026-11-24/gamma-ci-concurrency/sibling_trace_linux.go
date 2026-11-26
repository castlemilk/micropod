// Capture scheduler events and socket syscall boundaries for selected benchmark pairs in a private guest.
package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/netip"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const traceRoot = "/sys/kernel/tracing"

type pairSpec struct {
	Index    int    `json:"index"`
	Marker   string `json:"marker"`
	ClientIP string `json:"client_ip"`
	ServerIP string `json:"server_ip"`
}

type command struct {
	Tag   string     `json:"tag"`
	Pairs []pairSpec `json:"pairs"`
}

type actor struct {
	Comm   string `json:"comm"`
	PID    int    `json:"pid"`
	TIDs   []int  `json:"tids"`
	FD     int    `json:"fd"`
	Inode  string `json:"inode"`
	Local  string `json:"local"`
	Remote string `json:"remote"`
}

type pair struct {
	Index  int   `json:"index"`
	Client actor `json:"client"`
	Server actor `json:"server"`
}

func pids(dir string) ([]int, error) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	var nums []int
	for _, e := range ents {
		if n, err := strconv.Atoi(e.Name()); err == nil && n > 0 {
			nums = append(nums, n)
		}
	}
	slices.Sort(nums)
	return nums, nil
}

func endpoint(encoded string) (netip.AddrPort, error) {
	ip, port, ok := strings.Cut(encoded, ":")
	raw, err := hex.DecodeString(ip)
	if !ok || err != nil || (len(raw) != 4 && len(raw) != 16) {
		return netip.AddrPort{}, fmt.Errorf("invalid proc address %q", encoded)
	}
	for i := 0; i < len(raw); i += 4 {
		slices.Reverse(raw[i : i+4])
	}
	address, _ := netip.AddrFromSlice(raw)
	number, err := strconv.ParseUint(port, 16, 16)
	return netip.AddrPortFrom(address.Unmap(), uint16(number)), err
}

func locate(pid int, spec pairSpec, server bool, comm string) (actor, error) {
	base := filepath.Join("/proc", strconv.Itoa(pid))
	ids, err := pids(filepath.Join(base, "task"))
	if err != nil {
		return actor{}, err
	}
	a := actor{Comm: comm, PID: pid, TIDs: ids, FD: -1}
	for _, tid := range ids {
		name, err := os.ReadFile(filepath.Join(base, "task", strconv.Itoa(tid), "comm"))
		if err != nil || strings.TrimSpace(string(name)) != comm {
			return a, fmt.Errorf("PID %d thread %d differs from trace role %s", pid, tid, comm)
		}
	}
	for _, name := range []string{"tcp", "tcp6"} {
		data, err := os.ReadFile(filepath.Join(base, "net", name))
		if errors.Is(err, os.ErrNotExist) && name == "tcp6" {
			continue
		}
		if err != nil {
			return a, err
		}
		for _, line := range strings.Split(string(data), "\n") {
			f := strings.Fields(line)
			if len(f) < 10 || f[3] != "01" {
				continue
			}
			local, err := endpoint(f[1])
			if err != nil {
				return a, err
			}
			remote, err := endpoint(f[2])
			if err != nil {
				return a, err
			}
			client, service := local, remote
			if server {
				client, service = remote, local
			}
			if service.Addr().String() != spec.ServerIP || service.Port() != 8080 || client.Addr().String() != spec.ClientIP {
				continue
			}
			fds, err := pids(filepath.Join(base, "fd"))
			if err != nil {
				return a, err
			}
			for _, fd := range fds {
				target, _ := os.Readlink(filepath.Join(base, "fd", strconv.Itoa(fd)))
				if target == "socket:["+f[9]+"]" {
					if a.FD >= 0 {
						return a, errors.New("multiple descriptors match measured socket")
					}
					a.FD, a.Inode, a.Local, a.Remote = fd, f[9], local.String(), remote.String()
				}
			}
		}
	}
	if a.FD < 0 {
		return a, fmt.Errorf("cannot find measured socket in PID %d", pid)
	}
	return a, nil
}

func actors(q command) ([]pair, error) {
	ids, err := pids("/proc")
	if err != nil {
		return nil, err
	}
	args := make(map[int][]string)
	for _, pid := range ids {
		data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
		if err == nil && len(data) > 0 {
			args[pid] = strings.Split(string(bytes.TrimSuffix(data, []byte{0})), "\x00")
		}
	}
	var result []pair
	for _, spec := range q.Pairs {
		row := pair{Index: spec.Index}
		for pid, argv := range args {
			serverPath := fmt.Sprintf("/mpcheck/trace-names/msvc%02d", spec.Index)
			clientPath := fmt.Sprintf("/mpcheck/trace-names/mcli%02d", spec.Index)
			server := slices.Equal(argv, []string{serverPath, "-listen", ":8080", "-marker", spec.Marker})
			client := argv[0] == clientPath && slices.Contains(argv, spec.Marker) &&
				slices.Contains(argv, fmt.Sprintf("/gate/%s.%d", q.Tag, spec.Index))
			if !server && !client {
				continue
			}
			side := &row.Client
			if server {
				side = &row.Server
			}
			if side.PID != 0 {
				return nil, errors.New("multiple processes match a benchmark role")
			}
			*side, err = locate(pid, spec, server, filepath.Base(argv[0]))
			if err != nil {
				return nil, err
			}
		}
		if row.Client.PID == 0 || row.Server.PID == 0 || row.Client.Local != row.Server.Remote ||
			row.Client.Remote != row.Server.Local {
			return nil, fmt.Errorf("unmatched endpoints for index %d", spec.Index)
		}
		result = append(result, row)
	}
	return result, nil
}

func writeJSON(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err = os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func anyName(field string, names []string) string {
	parts := make([]string, len(names))
	for i, name := range names {
		parts[i] = field + " == " + strconv.Quote(name)
	}
	return "(" + strings.Join(parts, " || ") + ")"
}

func dump(inst, out string) error {
	src, err := os.Open(filepath.Join(inst, "trace"))
	if err != nil {
		return err
	}
	defer src.Close()
	file, err := os.OpenFile(out, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	zipper, err := gzip.NewWriterLevel(file, gzip.BestSpeed)
	if err != nil {
		file.Close()
		return err
	}
	_, err = io.Copy(zipper, bufio.NewReaderSize(src, 256*1024))
	return errors.Join(err, zipper.Close(), file.Close())
}

func capture(dir string, q command) error {
	if len(q.Pairs) != 2 || !regexp.MustCompile(`^same-[0-7]-all-A$`).MatchString(q.Tag) {
		return errors.New("unexpected benchmark trace selection")
	}
	roles, err := actors(q)
	if err != nil {
		return err
	}
	base := filepath.Join(dir, q.Tag)
	inst := filepath.Join(traceRoot, "instances/micropod-sibling-ci")
	if err := os.Mkdir(inst, 0700); err != nil {
		return err
	}
	set := func(path, value string) error {
		return os.WriteFile(filepath.Join(inst, path), []byte(value+"\n"), 0600)
	}
	defer func() { _ = set("tracing_on", "0"); _ = os.Remove(inst) }()
	for _, kv := range [][2]string{{"tracing_on", "0"}, {"trace_clock", "mono"}, {"buffer_size_kb", "24576"}} {
		if err := set(kv[0], kv[1]); err != nil {
			return err
		}
	}
	var names []string
	var fds []string
	for _, p := range roles {
		for _, a := range []actor{p.Client, p.Server} {
			names = append(names, a.Comm)
			fds = append(fds, "(COMM == "+strconv.Quote(a.Comm)+" && fd == "+strconv.Itoa(a.FD)+")")
		}
	}
	filters := map[string]string{
		"sched/sched_switch": anyName("prev_comm", names) + " || " + anyName("next_comm", names),
		"sched/sched_wakeup": anyName("comm", names),
	}
	for _, op := range []string{"read", "write", "readv", "writev"} {
		filters["syscalls/sys_enter_"+op] = strings.Join(fds, " || ")
		filters["syscalls/sys_exit_"+op] = anyName("COMM", names)
	}
	for event, filter := range filters {
		if err := set("events/"+event+"/filter", filter); err != nil {
			return fmt.Errorf("filter %s: %w", event, err)
		}
		if err := set("events/"+event+"/enable", "1"); err != nil {
			return err
		}
	}
	if err := set("tracing_on", "1"); err != nil {
		return err
	}
	if err := writeJSON(base+".armed", roles); err != nil {
		return err
	}
	for deadline := time.Now().Add(35 * time.Second); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(base + ".stop"); err == nil {
			break
		}
		if time.Now().After(deadline) {
			return errors.New("trace stop deadline expired")
		}
	}
	if err := set("tracing_on", "0"); err != nil {
		return err
	}
	stats := map[string]string{}
	paths, err := filepath.Glob(filepath.Join(inst, "per_cpu/cpu*/stats"))
	if err != nil || len(paths) != 4 {
		return errors.New("missing per-vCPU trace accounting")
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		stats[filepath.Base(filepath.Dir(path))] = string(data)
	}
	if err := dump(inst, base+".trace.gz"); err != nil {
		return err
	}
	return writeJSON(base+".done", stats)
}

func run(dir string) error {
	if _, err := os.Stat(filepath.Join(traceRoot, "events/sched/sched_switch")); errors.Is(err, os.ErrNotExist) {
		if err = syscall.Mount("tracefs", traceRoot, "tracefs", 0, ""); err != nil {
			return err
		}
	}
	if err := writeJSON(filepath.Join(dir, "ready"), map[string]int{"pid": os.Getpid()}); err != nil {
		return err
	}
	cmd := filepath.Join(dir, "command")
	for {
		data, err := os.ReadFile(cmd)
		if errors.Is(err, os.ErrNotExist) {
			time.Sleep(15 * time.Millisecond)
			continue
		}
		if err != nil {
			return err
		}
		var q command
		if err := json.Unmarshal(data, &q); err != nil {
			return err
		}
		if err := os.Remove(cmd); err != nil {
			return err
		}
		if err := capture(dir, q); err != nil {
			return err
		}
	}
}

func main() {
	dir := flag.String("dir", "", "private benchmark control directory")
	flag.Parse()
	if err := run(*dir); err != nil {
		_ = writeJSON(filepath.Join(*dir, "error"), err.Error())
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
