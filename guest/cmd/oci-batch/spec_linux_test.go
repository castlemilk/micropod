package main

import (
	"encoding/json"
	"strings"
	"testing"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

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
