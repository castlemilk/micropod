package main

import (
	"bytes"
	"strings"
	"testing"
)

func TestTrustedJobCPUQuotaIsIndependentOfVMSize(t *testing.T) {
	j := job{Trust: "trusted", Image: "fixture", Command: []string{"true"}}
	for _, count := range []int64{1, 4, 64} {
		j.CPUs = &count
		if _, err := j.handler(); err != nil {
			t.Fatal(err)
		}
		_, container, err := config("cpu", "/jobs/cpu", j.Image, j)
		if err != nil {
			t.Fatal(err)
		}
		r := container.Linux.Resources
		if r.CpuPeriod != 100000 || r.CpuQuota != count*100000 || r.MemoryLimitInBytes != 1<<30 || r.Unified["pids.max"] != "512" {
			t.Fatalf("unexpected resources for %d CPUs: %+v", count, r)
		}
	}
	for _, count := range []int64{-1, 0, 65} {
		j.CPUs = &count
		if _, err := j.handler(); err == nil {
			t.Fatalf("accepted invalid job CPU count %d", count)
		}
	}
	one := int64(1)
	j.Trust, j.Image, j.CPUs = "untrusted", "a@sha256:"+strings.Repeat("a", 64), &one
	if _, err := j.handler(); err == nil {
		t.Fatal("accepted a CPU override on an untrusted job")
	}
}

const pinned = "docker.io/library/alpine@sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2"

func TestJobTrustBoundary(t *testing.T) {
	for _, tc := range []struct{ trust, image, scope, want string }{
		{"trusted", "image:dev", "repo-main", "crun"},
		{"trusted", "image:dev", "../other", ""},
		{"untrusted", pinned, "", "kata"},
		{"untrusted", pinned, "repo-main", ""},
		{"untrusted", "image:mutable", "", ""},
		{"", pinned, "", ""},
		{"crun", pinned, "", ""},
	} {
		j := job{Trust: tc.trust, Image: tc.image, Command: []string{"true"}, Cache: tc.scope}
		h, err := j.handler()
		if h != tc.want || (err != nil) != (tc.want == "") {
			t.Fatalf("%+v returned %q, %v", tc, h, err)
		}
	}
	j := job{Trust: "untrusted", Image: pinned, Command: []string{"true"}}
	p, c, err := config(strings.Repeat("a", 32), "/jobs/probe", pinned, j)
	if err != nil {
		t.Fatal(err)
	}
	sc := c.GetLinux().GetSecurityContext()
	if len(c.Mounts) != 0 || len(c.Envs) != 0 || sc.GetPrivileged() || !sc.GetNoNewPrivs() || sc.GetSeccomp() == nil || len(sc.GetCapabilities().GetDropCapabilities()) != 1 || sc.GetCapabilities().GetDropCapabilities()[0] != "ALL" || len(sc.GetCapabilities().GetAddCapabilities()) != 0 || len(p.PortMappings) != 0 || len(p.Annotations) != 0 {
		t.Fatal("unexpected job privileges, mount or network configuration")
	}
	trusted := job{Trust: "trusted", Image: pinned, Command: []string{"true"}}
	_, tc, err := config(strings.Repeat("b", 32), "/jobs/trusted", pinned, trusted)
	if err != nil {
		t.Fatal(err)
	}
	caps := tc.GetLinux().GetSecurityContext().GetCapabilities()
	if got := caps.GetAddCapabilities(); len(got) != 1 || got[0] != "FSETID" || !tc.Linux.SecurityContext.NoNewPrivs {
		t.Fatal("trusted file-mode compatibility exceeded its capability")
	}
	for _, input := range []string{`{"trust":"trusted","mounts":["/"]}`, `{"trust":"untrusted","runtime":"crun"}`, `{"trust":"untrusted","privileged":true}`} {
		if _, err := decodeJob(bytes.NewBufferString(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
}
