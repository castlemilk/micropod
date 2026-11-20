package main

import (
	"bytes"
	"strings"
	"testing"
)

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
