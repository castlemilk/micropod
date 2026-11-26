package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCacheDiskRequested(t *testing.T) {
	for _, c := range []struct {
		params    map[string]string
		requested bool
		err       bool
	}{
		{map[string]string{}, false, false},
		{map[string]string{cacheDiskArg: "0"}, false, false},
		{map[string]string{cacheDiskArg: "1"}, true, false},
		// A malformed value still counts as attached: a missing disk then
		// turns shared caches off rather than putting stores on the OS disk.
		{map[string]string{cacheDiskArg: "yes"}, true, true},
	} {
		requested, err := cacheDiskRequested(c.params)
		if requested != c.requested || (err != nil) != c.err {
			t.Fatalf("%v: requested=%v err=%v", c.params, requested, err)
		}
	}
	if cacheDiskDevicePresent(filepath.Join(t.TempDir(), "vdb"), false) {
		t.Fatal("a missing device counted as present")
	}
}

// The clean-stop record goes with the stores (.meta below the cache root, the
// cache disk when there is one); a successful record retires the one on the
// OS disk, and a boot without its cache disk records nothing.
func TestRecordCleanStopLivesWithTheStores(t *testing.T) {
	dir := t.TempDir()
	oldRecord, oldLegacy := cleanStopRecord, legacyCleanStopRecord
	t.Cleanup(func() { cleanStopRecord, legacyCleanStopRecord = oldRecord, oldLegacy })
	cleanStopRecord = filepath.Join(dir, "caches", ".meta", "clean-stop")
	legacyCleanStopRecord = filepath.Join(dir, "clean-stop")
	if err := os.WriteFile(legacyCleanStopRecord, []byte("b0\n"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(cleanStopRecord), 0700); err != nil {
		t.Fatal(err)
	}

	if err := recordCleanStop(cacheDiskUnavailable, "b1"); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(cleanStopRecord); !os.IsNotExist(err) || readBootID(legacyCleanStopRecord) != "b0" {
		t.Fatalf("an unavailable cache disk recorded a clean stop: %v", err)
	}
	for _, disk := range []string{cacheDiskMounted, cacheDiskNone} {
		if err := recordCleanStop(disk, "b-"+disk); err != nil {
			t.Fatal(err)
		}
		if got := lastBootID(cleanStopRecord); got != "b-"+disk {
			t.Fatalf("%q: record %q", disk, got)
		}
		if _, err := os.Lstat(legacyCleanStopRecord); !os.IsNotExist(err) {
			t.Fatalf("%q: the OS disk's record survived: %v", disk, err)
		}
	}
	// Without a boot id nothing changes.
	if err := recordCleanStop(cacheDiskMounted, ""); err != nil || lastBootID(cleanStopRecord) != "b-" {
		t.Fatalf("empty boot id: %v %q", err, readBootID(cleanStopRecord))
	}
}

// BuildKit's root stays on the OS disk; a root an earlier version kept on the
// cache disk is moved into .trash once, never left where it could be mounted.
func TestRetireSplitBuildkit(t *testing.T) {
	dir := t.TempDir()
	old := splitBuildkitDir
	t.Cleanup(func() { splitBuildkitDir = old })
	splitBuildkitDir = filepath.Join(dir, "_buildkit")
	if dest, err := retireSplitBuildkit(); dest != "" || err != nil {
		t.Fatalf("nothing to retire: %q %v", dest, err)
	}
	if err := os.MkdirAll(filepath.Join(splitBuildkitDir, "runc-overlayfs"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(splitBuildkitDir, "runc-overlayfs", "cache.db"), []byte("records"), 0600); err != nil {
		t.Fatal(err)
	}
	dest, err := retireSplitBuildkit()
	if err != nil || filepath.Dir(dest) != filepath.Join(dir, ".trash") {
		t.Fatalf("retired to %q: %v", dest, err)
	}
	if _, err := os.Lstat(splitBuildkitDir); !os.IsNotExist(err) {
		t.Fatalf("the split root is still there: %v", err)
	}
	if b, err := os.ReadFile(filepath.Join(dest, "runc-overlayfs", "cache.db")); err != nil || string(b) != "records" {
		t.Fatalf("trash holds %q: %v", b, err)
	}
	if st, err := os.Stat(filepath.Join(dir, ".trash")); err != nil || st.Mode().Perm() != 0700 {
		t.Fatalf(".trash %v %v", st, err)
	}
	if dest, err := retireSplitBuildkit(); dest != "" || err != nil {
		t.Fatalf("a second boot: %q %v", dest, err)
	}
}
