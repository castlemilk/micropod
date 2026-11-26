package main

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"testing"

	"golang.org/x/sys/unix"
)

const dirtyProbeScope = "qual-dirty-probe"
const dirtyProbeUnit = "gobuild"

func dirtyProbeAttach(t *testing.T) cacheAttachment {
	t.Helper()
	f := testFacts(golangEnv, nil)
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache.scope": dirtyProbeScope,
		"io.micropod.cache":       dirtyProbeUnit,
	}}, f)
	a := openCacheMounts(&plan, "")
	if !slices.Contains(a.units, dirtyProbeUnit) {
		closeMounts(a.files)
		t.Fatalf("unit was not mounted: %#v", a.skipped)
	}
	return a
}

func dirtyProbeRequirePinned(t *testing.T) {
	t.Helper()
	f, err := unitLock(dirtyProbeScope, dirtyProbeUnit, true)
	if f != nil {
		f.Close()
	}
	if !errors.Is(err, unix.EWOULDBLOCK) {
		t.Fatalf("writer did not hold a real shared store lock: %v", err)
	}
}

func dirtyProbeRequireMarker(t *testing.T) {
	t.Helper()
	if _, err := os.Stat(dirtyMarker(dirtyProbeScope, dirtyProbeUnit)); err != nil {
		t.Fatal(err)
	}
}

func TestDirtyPrototypeCrossProcessChild(t *testing.T) {
	root := os.Getenv("MP_CACHE_DIRTY_PROBE_CHILD")
	if root == "" {
		t.Skip("subprocess helper")
	}
	cacheRoot = root
	cacheDirty = newCacheDirtyTracker()
	attachment := dirtyProbeAttach(t)
	attachment.release()
	closeMounts(attachment.files)
	// This is the exiting standalone scheduler process's production sequence.
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
}

func TestDirtyPrototypeCrossProcessPreservesActiveMarker(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	cacheDirty = newCacheDirtyTracker()
	active := dirtyProbeAttach(t)
	defer closeMounts(active.files)
	dirtyProbeRequirePinned(t)
	dirtyProbeRequireMarker(t)
	cmd := exec.Command(os.Args[0], "-test.run=^TestDirtyPrototypeCrossProcessChild$", "-test.v")
	cmd.Env = append(os.Environ(), "MP_CACHE_DIRTY_PROBE_CHILD="+cacheRoot)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("second writer failed before its sync: %v %s", err, out)
	}
	dirtyProbeRequirePinned(t)
	if _, err := os.Stat(dirtyMarker(dirtyProbeScope, dirtyProbeUnit)); errors.Is(err, os.ErrNotExist) {
		t.Fatal("standalone writer cleared the dirtiness of a separately running Docker writer")
	} else if err != nil {
		t.Fatal(err)
	}
}

func TestDirtyPrototypeShutdownPreservesActiveMarker(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	cacheDirty = newCacheDirtyTracker()
	active := dirtyProbeAttach(t)
	defer closeMounts(active.files)
	dirtyProbeRequirePinned(t)
	dirtyProbeRequireMarker(t)
	cacheDirty.shutdown()
	dirtyProbeRequirePinned(t)
	if _, err := os.Stat(dirtyMarker(dirtyProbeScope, dirtyProbeUnit)); errors.Is(err, os.ErrNotExist) {
		t.Fatal("HTTP engine shutdown cleared the marker while the store remained pinned")
	} else if err != nil {
		t.Fatal(err)
	}
}

func TestDirtyPrototypeRecoveryPreservesActiveStore(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	cacheDirty = newCacheDirtyTracker()
	active := dirtyProbeAttach(t)
	defer closeMounts(active.files)
	dirtyProbeRequirePinned(t)
	dirtyProbeRequireMarker(t)
	entry := filepath.Join(cacheRoot, "scopes", dirtyProbeScope, dirtyProbeUnit, "active-entry")
	if err := os.WriteFile(entry, []byte("active-writer"), 0600); err != nil {
		t.Fatal(err)
	}
	discardDirtyCaches()
	dirtyProbeRequirePinned(t)
	if _, err := os.Stat(entry); errors.Is(err, os.ErrNotExist) {
		t.Fatal("startup discarded a cache store while it remained pinned by an active writer")
	} else if err != nil {
		t.Fatal(err)
	}
}
