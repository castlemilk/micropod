package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The machine's own directory inside the workspace (the standard machine's
// ~/.micropod/hvf under a home-directory workspace) is never a bind source:
// not directly, not through a relative symlink a checkout carries, not as a
// file below it; a bind that covers it gets an empty read-only directory over
// it. Binds elsewhere are untouched.
func TestMachineDirectoryIsNeverBound(t *testing.T) {
	ws := t.TempDir()
	machine := filepath.Join(ws, ".micropod", "hvf")
	if err := os.MkdirAll(filepath.Join(machine, "run", "guest-config"), 0755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"run/guest-config/cache-policy.json": `{"defaultTrust":"untrusted"}`, "machine.json": `{}`} {
		if err := os.WriteFile(filepath.Join(machine, name), []byte(body), 0644); err != nil {
			t.Fatal(err)
		}
	}
	fork := filepath.Join(ws, "src", "fork")
	if err := os.MkdirAll(filepath.Join(fork, "data"), 0755); err != nil {
		t.Fatal(err)
	}
	// Relative, so they stay beneath the workspace: openMount follows them.
	if err := os.Symlink("../../.micropod/hvf/run/guest-config", filepath.Join(fork, "build")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../.micropod/hvf/machine.json", filepath.Join(fork, "machine.json")); err != nil {
		t.Fatal(err)
	}
	mask := filepath.Join(t.TempDir(), "private-mask")
	r, err := loadPrivateRoot(machine, mask)
	if err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: ws, machineDir: r}
	open := func(bind string, create bool) ([]string, error) {
		spec := dockerConfig{HostConfig: dockerHost{Binds: []string{bind}}}
		files, mounts, _, err := s.openMounts(spec, cacheVolumeRules{}, create, "", t.TempDir())
		closeMounts(files)
		var out []string
		for _, m := range mounts {
			ro := ""
			if m.Readonly {
				ro = ":ro"
			}
			src := m.HostPath
			if src != mask {
				src = "fd"
			}
			out = append(out, src+":"+m.ContainerPath+ro)
		}
		return out, err
	}
	for _, bind := range []string{
		fork + "/build:/out",
		fork + "/machine.json:/m.json:ro",
		machine + ":/m",
		filepath.Join(machine, "run") + ":/r:ro",
		filepath.Join(ws, ".micropod/hvf/run/guest-config/cache-policy.json") + ":/p",
	} {
		for _, create := range []bool{true, false} {
			_, err := open(bind, create)
			var api apiError
			if !errors.As(err, &api) || api.code != 400 || !strings.Contains(err.Error(), "machine's own directory") {
				t.Fatalf("%s (create %v): %v", bind, create, err)
			}
		}
	}
	for bind, want := range map[string]string{
		ws + ":/h": "fd:/h," + mask + ":/h/.micropod/hvf:ro",
		filepath.Join(ws, ".micropod") + ":/x:ro": "fd:/x:ro," + mask + ":/x/hvf:ro",
		fork + ":/w":                        "fd:/w",
		filepath.Join(fork, "data") + ":/d": "fd:/d",
	} {
		got, err := open(bind, false)
		if err != nil || strings.Join(got, ",") != want {
			t.Fatalf("%s: %v %v, want %s", bind, got, err, want)
		}
	}
	entries, err := os.ReadDir(mask)
	if err != nil || len(entries) != 0 {
		t.Fatalf("mask %v %v", entries, err)
	}
	if st, err := os.Stat(mask); err != nil || st.Mode().Perm() != 0555 {
		t.Fatalf("mask mode %v %v", st, err)
	}
	// No machine directory to protect: nothing changes.
	s.machineDir = nil
	if got, err := open(machine+":/m", false); err != nil || strings.Join(got, ",") != "fd:/m" {
		t.Fatalf("unprotected: %v %v", got, err)
	}
	if r, err := loadPrivateRoot("", mask); r != nil || err != nil {
		t.Fatalf("empty: %v %v", r, err)
	}
	if _, err := loadPrivateRoot(filepath.Join(ws, "absent"), mask); err == nil {
		t.Fatal("a missing machine directory loaded")
	}
}
