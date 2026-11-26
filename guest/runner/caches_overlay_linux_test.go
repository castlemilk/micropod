package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The overlay tier (B11) on a real overlayfs where the kernel and the
// process allow one (root with CAP_SYS_ADMIN: a bare test VM), else on the
// stand-in views useOverlay installs, where only what does not need a mount
// is checked.

// fillStore has a trusted writer leave name=body in the default scope's gomod
// store, then exit and the fence clear its mark.
func fillStore(t *testing.T, name, body string) string {
	t.Helper()
	w := goPlan(t, "default")
	a := openCacheMounts(&w, "")
	p := filepath.Join(cacheRoot, "scopes/default/gomod", name)
	if err := os.WriteFile(p, []byte(body), 0666); err != nil {
		t.Fatal(err)
	}
	a.close()
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	return p
}

// The overlay's lower layer is the store directory the start pinned, by
// descriptor: replacing the store's path with a symlink between the plan's
// replay and the mount changes nothing about what the view shows.
func TestCacheViewLowerIsThePinnedStoreNotItsPath(t *testing.T) {
	useFence(t, "boot-a")
	real := useOverlay(t)
	fillStore(t, "marker", "pinned")
	evil := filepath.Join(filepath.Dir(cacheRoot), "evil")
	if err := os.MkdirAll(evil, 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(evil, "marker"), []byte("planted"), 0666); err != nil {
		t.Fatal(err)
	}
	store := filepath.Join(cacheRoot, "scopes/default/gomod")
	inner := cacheOverlayMount
	var lower string
	cacheOverlayMount = func(lowerDir, baseDir string) (string, error) {
		if strings.HasSuffix(baseDir, "-gomod") {
			lower = lowerDir
			// Between the replay's open and the mount: the store's path
			// now leads somewhere else.
			if err := os.Rename(store, store+".pinned"); err != nil {
				t.Fatal(err)
			}
			if err := os.Symlink(evil, store); err != nil {
				t.Fatal(err)
			}
		}
		return inner(lowerDir, baseDir)
	}
	t.Cleanup(func() { cacheOverlayMount = inner })
	plan := untrustedGoPlan(t, "default")
	a := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "c1", "shim"))
	defer a.close()
	if !strings.HasPrefix(lower, "/proc/") {
		t.Fatalf("lowerdir %q is a path, not the pinned descriptor", lower)
	}
	if got, err := os.Readlink(lower); err != nil || got != store+".pinned" {
		t.Fatalf("lowerdir resolves to %q (%v), want the pinned store", got, err)
	}
	if b, err := os.ReadFile(filepath.Join(lower, "marker")); err != nil || string(b) != "pinned" {
		t.Fatalf("lowerdir reads %q (%v)", b, err)
	}
	_, merged := mountAt(t, a, cacheMountRoot+"/gomod")
	if real {
		if b, err := os.ReadFile(filepath.Join(merged, "marker")); err != nil || string(b) != "pinned" {
			t.Fatalf("the view shows %q (%v), want the pinned store's content", b, err)
		}
	}
}

// Every start builds its view from nothing: an upper directory a crashed
// start left (with an entry shadowing the store's) is removed before the
// mount, so a restart reads the store's current content.
func TestCacheViewNeverReusesAnEarlierUpper(t *testing.T) {
	useFence(t, "boot-a")
	real := useOverlay(t)
	fillStore(t, "marker", "v1")
	shim := filepath.Join(filepath.Dir(cacheRoot), "c2", "shim")
	plan := untrustedGoPlan(t, "default")
	a := openCacheMounts(&plan, shim)
	_, merged := mountAt(t, a, cacheMountRoot+"/gomod")
	if err := os.WriteFile(filepath.Join(merged, "marker"), []byte("stale-write"), 0666); err != nil {
		t.Fatal(err)
	}
	a.close()
	// A crash left a view directory behind with a shadowing upper entry.
	stale := filepath.Join(filepath.Dir(merged), "upper")
	if err := os.MkdirAll(stale, 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stale, "marker"), []byte("stale-upper"), 0666); err != nil {
		t.Fatal(err)
	}
	fillStore(t, "marker", "v2")
	if !real {
		// The stand-in views never mount; the real mount's own first step
		// is what removes the earlier view, mounted or not.
		if _, err := mountCacheOverlay("", filepath.Dir(merged)); err == nil {
			t.Fatal("overlayfs mounted where useOverlay found none")
		}
		if exists(filepath.Join(stale, "marker")) {
			t.Fatal("an earlier start's upper survived the next mount")
		}
		return
	}
	b := openCacheMounts(&plan, shim)
	defer b.close()
	_, merged2 := mountAt(t, b, cacheMountRoot+"/gomod")
	if merged2 != merged {
		t.Fatalf("restart view at %s, first at %s", merged2, merged)
	}
	if exists(filepath.Join(stale, "marker")) {
		t.Fatal("the earlier start's upper survived into the restart")
	}
	if got, err := os.ReadFile(filepath.Join(merged2, "marker")); err != nil || string(got) != "v2" {
		t.Fatalf("the restart reads %q (%v), want the store's current v2", got, err)
	}
	if got, _ := os.ReadFile(filepath.Join(cacheRoot, "scopes/default/gomod/marker")); string(got) != "v2" {
		t.Fatalf("store %q", got)
	}
}

// An untrusted container's writes, however large, land in its own upper on
// the OS disk and go with its exit: the trusted store's bytes are unchanged
// and nothing of the view is left in the container's directory.
func TestCacheUntrustedWritesLeaveWithTheContainer(t *testing.T) {
	useFence(t, "boot-a")
	real := useOverlay(t)
	fillStore(t, "marker", "trusted")
	before := treeBytes(t, filepath.Join(cacheRoot, "scopes/default"))
	shim := filepath.Join(filepath.Dir(cacheRoot), "c3", "shim")
	plan := untrustedGoPlan(t, "default")
	a := openCacheMounts(&plan, shim)
	_, merged := mountAt(t, a, cacheMountRoot+"/gomod")
	size := 1 << 20
	if real {
		size = 100 << 20
	}
	if err := os.WriteFile(filepath.Join(merged, "big.bin"), bytes.Repeat([]byte{'u'}, size), 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(merged, "marker"), []byte("untrusted"), 0666); err != nil {
		t.Fatal(err)
	}
	if after := treeBytes(t, filepath.Join(cacheRoot, "scopes/default")); after != before {
		t.Fatalf("store bytes %d -> %d while the untrusted container writes", before, after)
	}
	a.release()
	closeMounts(a.files)
	if after := treeBytes(t, filepath.Join(cacheRoot, "scopes/default")); after != before {
		t.Fatalf("store bytes %d -> %d after the untrusted container", before, after)
	}
	if got, _ := os.ReadFile(filepath.Join(cacheRoot, "scopes/default/gomod/marker")); string(got) != "trusted" {
		t.Fatalf("store marker %q", got)
	}
	if left := treeBytes(t, shim); left != 0 {
		t.Fatalf("%d bytes of the view are left in the container's directory", left)
	}
}

func treeBytes(t *testing.T, root string) int64 {
	t.Helper()
	var n int64
	err := filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			if os.IsNotExist(err) {
				return nil
			}
			return err
		}
		if info.Mode().IsRegular() {
			n += info.Size()
		}
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return n
}
