package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestSchedSlice(t *testing.T) {
	for _, c := range []struct {
		params map[string]string
		ns     uint64
		ok     bool
		err    bool
	}{
		// No setting: the measured default.
		{map[string]string{}, defaultSchedSliceNs, true, false},
		{map[string]string{schedSliceArg: "default"}, 0, false, false},
		{map[string]string{schedSliceArg: "1000000"}, 1_000_000, true, false},
		{map[string]string{schedSliceArg: "100000"}, minSchedSliceNs, true, false},
		{map[string]string{schedSliceArg: "100000000"}, maxSchedSliceNs, true, false},
		// Out of range or malformed: reported, and the default is set.
		{map[string]string{schedSliceArg: "99999"}, defaultSchedSliceNs, true, true},
		{map[string]string{schedSliceArg: "100000001"}, defaultSchedSliceNs, true, true},
		{map[string]string{schedSliceArg: "0.4ms"}, defaultSchedSliceNs, true, true},
		{map[string]string{schedSliceArg: ""}, defaultSchedSliceNs, true, true},
	} {
		ns, ok, err := schedSlice(c.params)
		if ns != c.ns || ok != c.ok || (err != nil) != c.err {
			t.Errorf("%v: ns=%d ok=%v err=%v", c.params, ns, ok, err)
		}
	}
}

func fakeSchedDebugfs(t *testing.T, slice, scaling string) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "sched"), 0o755); err != nil {
		t.Fatal(err)
	}
	for name, body := range map[string]string{"base_slice_ns": slice, "tunable_scaling": scaling} {
		if body == "" {
			continue
		}
		if err := os.WriteFile(filepath.Join(dir, "sched", name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

// The slice is written, then tunable_scaling is rewritten with its own value
// (so the kernel renormalizes from the new slice), and the result is read
// back.
func TestSetSchedSliceWritesAndRenormalizes(t *testing.T) {
	dir := fakeSchedDebugfs(t, "2800000\n", "1\n")
	before, after, err := setSchedSlice(dir, 400_000)
	if err != nil || before != 2_800_000 || after != 400_000 {
		t.Fatalf("before=%d after=%d err=%v", before, after, err)
	}
	for name, want := range map[string]string{"base_slice_ns": "400000", "tunable_scaling": "1"} {
		got, err := os.ReadFile(filepath.Join(dir, "sched", name))
		if err != nil || strings.TrimSpace(string(got)) != want {
			t.Errorf("%s = %q (%v), want %q", name, got, err, want)
		}
	}
}

func TestSetSchedSliceReportsWhatItCannotDo(t *testing.T) {
	// No scheduler directory (a kernel without the debug files): nothing set.
	if _, _, err := setSchedSlice(t.TempDir(), 400_000); err == nil {
		t.Error("a missing base_slice_ns was not reported")
	}
	// The slice is set but the scaling file is missing: reported, with the
	// slice that is now live.
	dir := fakeSchedDebugfs(t, "2800000\n", "")
	if _, after, err := setSchedSlice(dir, 400_000); err == nil || after != 400_000 {
		t.Errorf("missing tunable_scaling: after=%d err=%v", after, err)
	}
}
