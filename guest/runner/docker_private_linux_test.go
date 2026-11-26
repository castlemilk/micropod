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

// The mask goes where the machine directory is when a bind opens, not where
// it was at boot: a container that writes the workspace can rename the
// directory, or one above it, and a bind of the new parent covers it under
// another name.
func TestMachineDirectoryMaskFollowsARename(t *testing.T) {
	ws := t.TempDir()
	machine := filepath.Join(ws, ".micropod", "hvf")
	if err := os.MkdirAll(filepath.Join(machine, "run", "guest-config"), 0755); err != nil {
		t.Fatal(err)
	}
	mask := filepath.Join(t.TempDir(), "private-mask")
	r, err := loadPrivateRoot(machine, mask)
	if err != nil {
		t.Fatal(err)
	}
	defer r.dir.Close()
	s := &dockerEngine{workspace: ws, machineDir: r}
	open := func(bind string) (string, error) {
		t.Helper()
		var masked []string
		for _, create := range []bool{true, false} {
			files, mounts, _, err := s.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{bind}}}, cacheVolumeRules{}, create, "", t.TempDir())
			closeMounts(files)
			if err != nil {
				return "", err
			}
			masked = masked[:0]
			for _, m := range mounts {
				if m.HostPath == mask {
					masked = append(masked, m.ContainerPath)
				}
			}
		}
		return strings.Join(masked, ","), nil
	}
	masks := func(want map[string]string) {
		t.Helper()
		for bind, at := range want {
			if got, err := open(bind); err != nil || got != at {
				t.Errorf("%s: mask at %q (%v), want %q", bind, got, err, at)
			}
		}
	}
	refused := func(binds ...string) {
		t.Helper()
		for _, bind := range binds {
			_, err := open(bind)
			var api apiError
			if !errors.As(err, &api) || api.code != 400 || !strings.Contains(err.Error(), "machine's own directory") {
				t.Errorf("%s: %v, want 400", bind, err)
			}
		}
	}

	// ~/.micropod moves below another directory, which then covers it.
	if err := os.Mkdir(filepath.Join(ws, "a"), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(filepath.Join(ws, ".micropod"), filepath.Join(ws, "a", ".micropod")); err != nil {
		t.Fatal(err)
	}
	masks(map[string]string{
		ws + "/a:/x":           "/x/.micropod/hvf",
		ws + ":/h":             "/h/a/.micropod/hvf",
		ws + "/a/.micropod:/m": "/m/hvf",
	})
	// The machine directory itself is renamed, and a directory is made where
	// it was: the mask follows the machine's, and the new one is a bind's.
	if err := os.Rename(filepath.Join(ws, "a", ".micropod", "hvf"), filepath.Join(ws, "a", ".micropod", "other")); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(ws, ".micropod", "hvf"), 0755); err != nil {
		t.Fatal(err)
	}
	masks(map[string]string{
		ws + "/a:/x":           "/x/.micropod/other",
		ws + ":/h":             "/h/a/.micropod/other",
		ws + "/a/.micropod:/m": "/m/other",
		ws + "/.micropod:/o":   "",
	})
	refused(ws+"/a/.micropod/other:/o", ws+"/a/.micropod/other/run:/r:ro")
}
