package main

import (
	"crypto/sha256"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestServiceSenderScope(t *testing.T) {
	dir := t.TempDir()
	write := func(name, text string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(dir, name), []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	stat := "42 (test ) thread) S " + strings.Repeat("0 ", 18) + "6789"
	status := "Tgid:\t42\nPid:\t42\nNSpid:\t42\t1\n"
	group := "0::/pod/container\n"
	argv := "netbench\x00-listen\x00:8080\x00-marker\x00service\x00"
	for f, v := range map[string]string{"stat": stat, "status": status, "cgroup": group, "cmdline": argv, "pid": "42\n"} {
		write(f, v)
	}
	if err := os.Mkdir(filepath.Join(dir, "ns"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("net:[220]", filepath.Join(dir, "ns", "net")); err != nil {
		t.Fatal(err)
	}
	id, err := readSender(dir, 42, 220, 8080)
	if err != nil {
		t.Fatal(err)
	}
	wantHash := fmt.Sprintf("%x", sha256.Sum256([]byte("-listen\x00:8080\x00-marker\x00service\x00")))
	if id.StartTicks != 6789 || id.NamespacePID != 1 || id.CgroupV2 != "/pod/container" || id.ArgsSHA256 != wantHash {
		t.Fatalf("wrong identity %+v", id)
	}
	pidfile := filepath.Join(dir, "pid")
	if err := verifySender(dir, id, pidfile); err != nil {
		t.Fatal(err)
	}
	if _, err := readSender(dir, 42, 221, 8080); err == nil {
		t.Fatal("accepted wrong service namespace")
	}
	for _, tc := range []struct{ name, value, restore string }{
		{"pid", "43\n", "42\n"}, {"stat", strings.Replace(stat, "6789", "6790", 1), stat},
		{"cmdline", strings.TrimSuffix(argv, "\x00"), argv}, {"cmdline", strings.Replace(argv, "service", "other", 1), argv},
		{"cgroup", "0::/pod/stale\n", group}, {"cgroup", "0::/pod/container (deleted)\n", group},
		{"status", strings.Replace(status, "\t1\n", "\t2\n", 1), status},
		{"status", strings.Replace(status, "Tgid:\t42\n", "", 1), status},
	} {
		write(tc.name, tc.value)
		if err := verifySender(dir, id, pidfile); err == nil {
			t.Errorf("accepted changed %s", tc.name)
		}
		write(tc.name, tc.restore)
	}
	for _, bad := range []string{"0", "-1", "", "42 43", "042", " 42", "42\n\n", strings.Repeat("9", 128)} {
		write("pid", bad)
		if _, err := servicePIDFile(pidfile); err == nil {
			t.Errorf("accepted PID file %q", bad)
		}
	}
}

func TestServiceCounterCoverage(t *testing.T) {
	a := serviceCounts{4, 400, 120, 1, 1, 1, 1, 0, 0}
	c, ok, err := summarizeService([]serviceCounts{a, a})
	if err != nil || !ok || c["accepted_bytes"] != 240 || c["error_calls"] != 2 {
		t.Fatal(c, ok, err)
	}
	for _, bad := range []serviceCounts{{}, {1, 20, 21, 1}, {2, 20, 0, 0, 0, 0, 2}, {1, 20, 19, 1, 1}, {1, 20, 19, 0, 1, 0, 0, 1}, {1, 20, 19, 0, 1, 0, 0, 0, 1}} {
		if _, ok, _ := summarizeService([]serviceCounts{bad}); ok {
			t.Errorf("accepted invalid counters %v", bad)
		}
	}
	if _, _, err = summarizeService([]serviceCounts{{math.MaxUint64}, {1}}); err == nil {
		t.Fatal("missed per-CPU sum overflow")
	}
}
