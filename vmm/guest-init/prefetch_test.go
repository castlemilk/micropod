package main

import (
	"os"
	"path/filepath"
	"slices"
	"strings"
	"syscall"
	"testing"
)

func TestPrefetchToolsReadsEveryNamedFileOnceAndSkipsTheRest(t *testing.T) {
	dir := t.TempDir()
	write := func(name string, size int) {
		t.Helper()
		path := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, make([]byte, size), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	write("runner/bin/containerd", 3<<20+5)
	write("runner/bin/job", 1<<20)
	write("crun-1.31-arm64", 4097)
	write("crun-1.32-arm64", 3)
	write("runner/bin/buildkitd", 7<<20) // not run at boot: not read
	if err := syscall.Mkfifo(filepath.Join(dir, "service"), 0o600); err != nil {
		t.Fatal(err)
	}
	// runner/bin/containerd-shim-runc-v2 is missing: skipped.
	if got, want := prefetchTools(dir, bootTools), int64(3<<20+5+1<<20+4097+3); got != want {
		t.Fatalf("read %d bytes, want %d", got, want)
	}
}

func TestBootToolsNameWhatStartShRunsBeforeTheEngineAnswers(t *testing.T) {
	// The bundle's own start.sh and containerd config: what they run must be
	// in the list, or its first run reads it a page fault at a time.
	start, err := os.ReadFile("../../ci/runner/start.sh")
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []struct{ file, invocation string }{
		{"runner/bin/containerd", "exec containerd --config"},
		{"runner/bin/job", `"$tools/runner/bin/job" engine`},
		{"service", `"$tools/service" serve`},
	} {
		if !strings.Contains(string(start), want.invocation) {
			t.Fatalf("start.sh no longer runs %q; update bootTools", want.invocation)
		}
		if !slices.Contains(bootTools, want.file) {
			t.Fatalf("bootTools leaves out %s", want.file)
		}
	}
	config, err := os.ReadFile("../../ci/runner/containerd.toml")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(config), `BinaryName = "/opt/micropod-oci/crun-`) || !slices.Contains(bootTools, "crun-*") {
		t.Fatal("the CRI runtime is no longer the bundle's crun-*; update bootTools")
	}
}
