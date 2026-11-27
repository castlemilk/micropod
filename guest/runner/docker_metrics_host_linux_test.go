package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

func TestParseProcStat(t *testing.T) {
	// A comm with spaces and a ')' of its own; utime 7, stime 5, 9 threads, 42 resident pages.
	line := "812 (tmux: a) b) S 1 812 812 0 -1 4194560 100 0 0 0 7 5 0 0 20 0 9 0 1000 1000000 42 18446744073709551615 0 0 0"
	comm, ticks, threads, rss, ok := parseProcStat(line)
	if !ok || comm != "tmux: a) b" || ticks != 12 || threads != 9 || rss != 42 {
		t.Fatalf("%q %d %d %d %v", comm, ticks, threads, rss, ok)
	}
	for _, bad := range []string{"", "1 no-parens S", "1 (x) S 1 2 3", "1 (x) S 1 1 1 0 -1 0 0 0 0 0 x 5 0 0 20 0 9 0 1 1 42 0"} {
		if _, _, _, _, ok := parseProcStat(bad); ok {
			t.Errorf("%q parsed", bad)
		}
	}
}

// The host section groups the engine, containerd, BuildKit and the shims,
// and leaves out what it cannot read instead of reporting zero.
func TestHostMetrics(t *testing.T) {
	proc := t.TempDir()
	write := func(rel, body string) {
		t.Helper()
		path := filepath.Join(proc, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	stat := func(pid int, comm string, utime, stime, threads, rss int) {
		write(strconv.Itoa(pid)+"/stat", strconv.Itoa(pid)+" ("+comm+") S 1 1 1 0 -1 0 0 0 0 0 "+strconv.Itoa(utime)+" "+strconv.Itoa(stime)+
			" 0 0 20 0 "+strconv.Itoa(threads)+" 0 1 1 "+strconv.Itoa(rss)+" 0 0 0 0\n")
	}
	stat(os.Getpid(), "job", 30, 20, 12, 100)
	write(strconv.Itoa(os.Getpid())+"/fd/0", "")
	write(strconv.Itoa(os.Getpid())+"/fd/1", "")
	stat(40, "containerd", 100, 100, 20, 200)
	stat(41, "containerd-shim", 1, 1, 10, 5)
	stat(42, "containerd-shim", 2, 2, 11, 6)
	stat(43, "sleep", 9, 9, 1, 1)
	write("self/ignored", "")
	write("stat", "cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 2 3\n")
	write("meminfo", "MemTotal:       1024 kB\nMemFree: 1 kB\nMemAvailable:    512 kB\n")
	write("sys/fs/file-nr", "640\t0\t9000\n")
	write("sys/net/netfilter/nf_conntrack_max", "262144\n")

	got := hostMetrics(proc)
	groups := got["process_groups"].(map[string]*hostProcess)
	if e := groups["engine"]; e == nil || e.Count != 1 || e.CPUUsec != 500000 || e.FDs != 2 || e.Threads != 12 || e.RSS != 100*uint64(os.Getpagesize()) {
		t.Errorf("engine = %+v", e)
	}
	if c := groups["containerd"]; c == nil || c.CPUUsec != 2000000 || c.Count != 1 {
		t.Errorf("containerd = %+v", c)
	}
	if sh := groups["shims"]; sh == nil || sh.Count != 2 || sh.CPUUsec != 60000 || sh.Threads != 21 || sh.FDs != 0 {
		t.Errorf("shims = %+v", sh)
	}
	if _, counted := groups["buildkitd"]; counted || len(groups) != 3 {
		t.Errorf("groups = %v", groups)
	}
	for name, want := range map[string]any{
		"processes": 5, "cpu_busy_usec": uint64(1500000), "cpu_idle_usec": uint64(8500000),
		"memory_total_bytes": uint64(1 << 20), "memory_available_bytes": uint64(512 << 10),
		"open_files": uint64(640), "open_files_max": uint64(9000), "conntrack_max": uint64(262144),
	} {
		if got[name] != want {
			t.Errorf("%s = %v (%T), want %v", name, got[name], got[name], want)
		}
	}
	for _, absent := range []string{"conntrack_entries", "pid_max", "inotify_instances_max"} {
		if _, ok := got[absent]; ok {
			t.Errorf("%s reported though it could not be read", absent)
		}
	}
}
