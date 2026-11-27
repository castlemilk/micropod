package main

import (
	"os"
	"runtime"
	"strconv"
	"strings"
)

// The machine's own load, in GET /micropod/metrics?host=1 under "host": what the
// engine, containerd, BuildKit and the shims cost, and how close the guest is
// to the kernel limits that stop containers from starting when many run at
// once (open files, processes, connection tracking, inotify). A scale run
// (scripts/gates/scale.sh) reads it before and after each workload; nothing in
// the engine depends on it.
//
// Every value is read from /proc at the moment of the request. A value that
// cannot be read is left out, never reported as zero.

// hostClockTick is USER_HZ: the unit of the CPU times in /proc/<pid>/stat and
// /proc/stat. Linux fixes it at 100 for every architecture's user ABI.
const hostClockTick = 100

type hostProcess struct {
	Count   int    `json:"count"`
	CPUUsec uint64 `json:"cpu_usec"`
	RSS     uint64 `json:"rss_bytes"`
	FDs     int    `json:"fds,omitempty"`
	Threads uint64 `json:"threads"`
}

// hostProcessGroup names the group a process's comm belongs to; "" for one
// that is not counted.
func hostProcessGroup(comm string) string {
	switch {
	case comm == "containerd":
		return "containerd"
	case comm == "buildkitd":
		return "buildkitd"
	case strings.HasPrefix(comm, "containerd-shim"):
		return "shims"
	}
	return ""
}

// parseProcStat reads comm, utime+stime (clock ticks), the thread count and
// the resident pages from a /proc/<pid>/stat line. comm may hold spaces and
// parentheses, so the fields are counted from its last ')'.
func parseProcStat(line string) (comm string, ticks, threads, rssPages uint64, ok bool) {
	open, end := strings.IndexByte(line, '('), strings.LastIndexByte(line, ')')
	if open < 0 || end < open {
		return "", 0, 0, 0, false
	}
	comm = line[open+1 : end]
	// After ") ": state is field 3, so fields[n-3] is field n.
	fields := strings.Fields(line[end+1:])
	if len(fields) < 22 {
		return "", 0, 0, 0, false
	}
	utime, err1 := strconv.ParseUint(fields[11], 10, 64)
	stime, err2 := strconv.ParseUint(fields[12], 10, 64)
	threads, err3 := strconv.ParseUint(fields[17], 10, 64)
	rss, err4 := strconv.ParseUint(fields[21], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
		return "", 0, 0, 0, false
	}
	return comm, utime + stime, threads, rss, true
}

func countDir(path string) int {
	f, err := os.Open(path)
	if err != nil {
		return 0
	}
	defer f.Close()
	names, _ := f.Readdirnames(-1)
	return len(names)
}

func readUint(path string) (uint64, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	return v, err == nil
}

// hostMetrics is the "host" section. proc is "/proc" (a directory of its
// shape in tests).
func hostMetrics(proc string) map[string]any {
	out := map[string]any{"goroutines": runtime.NumGoroutine(), "cpus": runtime.NumCPU()}
	page := uint64(os.Getpagesize())
	groups := map[string]*hostProcess{}
	self := strconv.Itoa(os.Getpid())
	processes := 0
	if entries, err := os.ReadDir(proc); err == nil {
		for _, e := range entries {
			pid := e.Name()
			if pid[0] < '0' || pid[0] > '9' {
				continue
			}
			b, err := os.ReadFile(proc + "/" + pid + "/stat")
			if err != nil {
				continue // it exited
			}
			comm, ticks, threads, rss, ok := parseProcStat(string(b))
			if !ok {
				continue
			}
			processes++
			group := hostProcessGroup(comm)
			if pid == self {
				group = "engine"
			}
			if group == "" {
				continue
			}
			g := groups[group]
			if g == nil {
				g = &hostProcess{}
				groups[group] = g
			}
			g.Count++
			g.CPUUsec += ticks * (1000000 / hostClockTick)
			g.RSS += rss * page
			g.Threads += threads
			if group != "shims" {
				g.FDs += countDir(proc + "/" + pid + "/fd")
			}
		}
		out["processes"] = processes
		out["process_groups"] = groups
	}
	// user nice system idle iowait irq softirq steal, in clock ticks.
	if b, err := os.ReadFile(proc + "/stat"); err == nil {
		if line, _, _ := strings.Cut(string(b), "\n"); strings.HasPrefix(line, "cpu ") {
			var busy, idle uint64
			for i, f := range strings.Fields(line)[1:] {
				v, err := strconv.ParseUint(f, 10, 64)
				if err != nil || i > 7 {
					break
				}
				if i == 3 || i == 4 {
					idle += v
				} else {
					busy += v
				}
			}
			out["cpu_busy_usec"] = busy * (1000000 / hostClockTick)
			out["cpu_idle_usec"] = idle * (1000000 / hostClockTick)
		}
	}
	if b, err := os.ReadFile(proc + "/meminfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			name, rest, ok := strings.Cut(line, ":")
			if !ok || name != "MemTotal" && name != "MemAvailable" {
				continue
			}
			if kb, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64); err == nil {
				out[map[string]string{"MemTotal": "memory_total_bytes", "MemAvailable": "memory_available_bytes"}[name]] = kb << 10
			}
		}
	}
	// allocated, unused, maximum.
	if b, err := os.ReadFile(proc + "/sys/fs/file-nr"); err == nil {
		if f := strings.Fields(string(b)); len(f) == 3 {
			if open, err := strconv.ParseUint(f[0], 10, 64); err == nil {
				out["open_files"] = open
			}
			if limit, err := strconv.ParseUint(f[2], 10, 64); err == nil {
				out["open_files_max"] = limit
			}
		}
	}
	for name, path := range map[string]string{
		"pid_max":               "/sys/kernel/pid_max",
		"threads_max":           "/sys/kernel/threads-max",
		"conntrack_entries":     "/sys/net/netfilter/nf_conntrack_count",
		"conntrack_max":         "/sys/net/netfilter/nf_conntrack_max",
		"inotify_instances_max": "/sys/fs/inotify/max_user_instances",
		"inotify_watches_max":   "/sys/fs/inotify/max_user_watches",
		"neighbours_gc_thresh3": "/sys/net/ipv4/neigh/default/gc_thresh3",
	} {
		if v, ok := readUint(proc + path); ok {
			out[name] = v
		}
	}
	return out
}
