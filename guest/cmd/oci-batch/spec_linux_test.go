package main

import (
	"bytes"
	"encoding/json"
	"os"
	"strings"
	"testing"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

func TestNativeRuntimeSelection(t *testing.T) {
	previous := native
	native = true
	t.Cleanup(func() { native = previous })
	for name, path := range map[string]string{
		"runc":  "/usr/local/bin/runc",
		"crun":  "/opt/micropod-oci/crun-1.31-arm64",
		"":      "/opt/micropod-oci/crun-1.31-arm64",
		"youki": "/var/lib/micropod/oci/youki-0.7.0-arm64",
	} {
		t.Setenv("MICROPOD_JOB_RUNTIME", name)
		if got := runtimeBinary(); got != path {
			t.Errorf("runtimeBinary for %s = %q, want %q", name, got, path)
		}
	}
}

func TestJobSpecPreservesPolicyAndRejectsSharedNamespaces(t *testing.T) {
	q, period, memory := int64(100000), uint64(100000), int64(1<<30)
	base := specs.Spec{Version: "1.3.0", Process: &specs.Process{Cwd: "/workspace", User: specs.User{UID: 1000}},
		Root: &specs.Root{Path: "original"}, Linux: &specs.Linux{
			Seccomp:     &specs.LinuxSeccomp{DefaultAction: specs.ActErrno},
			Resources:   &specs.LinuxResources{CPU: &specs.LinuxCPU{Quota: &q, Period: &period}, Memory: &specs.LinuxMemory{Limit: &memory}},
			MaskedPaths: []string{"/proc/kcore"},
		}}
	for _, ns := range []specs.LinuxNamespaceType{specs.PIDNamespace, specs.MountNamespace, specs.NetworkNamespace, specs.UTSNamespace, specs.IPCNamespace, specs.CgroupNamespace} {
		base.Linux.Namespaces = append(base.Linux.Namespaces, specs.LinuxNamespace{Type: ns})
	}
	for dest, kind := range map[string]string{"/proc": "proc", "/dev": "tmpfs", "/dev/pts": "devpts", "/sys": "sysfs", "/sys/fs/cgroup": "cgroup", "/dev/mqueue": "mqueue", "/dev/shm": "tmpfs", "/etc/hostname": "bind", "/etc/hosts": "bind", "/etc/resolv.conf": "bind", "/cache/gomod": "bind", "/cache/gobuild": "bind"} {
		base.Mounts = append(base.Mounts, specs.Mount{Type: kind, Destination: dest, Source: dest})
	}
	for _, test := range []struct {
		name   string
		change func(*specs.Spec)
		valid  bool
	}{
		{"ordinary", func(*specs.Spec) {}, true},
		{"shared PID namespace", func(s *specs.Spec) { s.Linux.Namespaces[0].Path = "/proc/1/ns/pid" }, false},
		{"unknown bind", func(s *specs.Spec) {
			s.Mounts = append(s.Mounts, specs.Mount{Type: "bind", Source: "/unrelated", Destination: "/extra"})
		}, false},
		{"missing seccomp", func(s *specs.Spec) { s.Linux.Seccomp = nil }, false},
		{"missing memory limit", func(s *specs.Spec) { s.Linux.Resources.Memory.Limit = nil }, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			blob, err := json.Marshal(base)
			if err != nil {
				t.Fatal(err)
			}
			var input specs.Spec
			if err = json.Unmarshal(blob, &input); err != nil {
				t.Fatal(err)
			}
			test.change(&input)
			blob, err = json.Marshal(input)
			if err != nil {
				t.Fatal(err)
			}
			cfg, err := jobSpec(blob, "/run/owned", strings.Repeat("a", 64), []string{"go", "build"})
			if (err == nil) != test.valid {
				t.Fatalf("expected valid=%t: %v", test.valid, err)
			}
			if test.valid && (cfg.Process.User.UID != 1000 || cfg.Linux.Seccomp.DefaultAction != specs.ActErrno ||
				cfg.Linux.MaskedPaths[0] != "/proc/kcore" || cfg.Linux.CgroupsPath != "/"+strings.Repeat("a", 64)) {
				t.Fatal("lost the image user, kernel policy or private cgroup")
			}
		})
	}
}

func BenchmarkPreparedDockerPolicy(b *testing.B) {
	path := os.Getenv("MICROPOD_BENCH_SPEC")
	if path == "" {
		b.Skip("set MICROPOD_BENCH_SPEC to the stock Docker OCI specification")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		b.Fatal(err)
	}
	id := strings.Repeat("a", 64)
	var reference []byte
	for _, cached := range []bool{false, true} {
		template, err := prepareTemplate(raw, cached)
		if err != nil {
			b.Fatal(err)
		}
		name := "decode-each-job"
		if cached {
			name = "prepared"
		}
		build := func() []byte {
			s, e := template.spec("/run/job", id, []string{"go", "build", "."})
			if e != nil {
				b.Fatal(e)
			}
			wire, e := json.Marshal(s)
			if e != nil {
				b.Fatal(e)
			}
			return wire
		}
		wire := build()
		if reference != nil && !bytes.Equal(wire, reference) {
			b.Fatal("cached policy changes config bytes")
		}
		reference = wire
		b.Run(name, func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				build()
			}
		})
	}
}

func TestWorkerPolicyWithinMeasuredAllocation(t *testing.T) {
	oldNative, oldCPUs := native, allocationCPUs
	t.Cleanup(func() { native, allocationCPUs = oldNative, oldCPUs })
	native = true
	t.Setenv("MICROPOD_JOB_RUNTIME", "runc")
	for _, tc := range []struct{ cpus, jobs, scheduler int }{{4, 16, 0}, {4, 32, 3}, {8, 32, 0}} {
		allocationCPUs = make([]int, tc.cpus)
		p, err := policyFor("default", tc.jobs)
		if err != nil || p.batch != (tc.scheduler == 3) || p.window != 0 || p.affinity {
			t.Fatalf("unexpected default for %d CPUs and %d jobs: %+v %v", tc.cpus, tc.jobs, p, err)
		}
	}
}
