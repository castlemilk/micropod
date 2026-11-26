package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
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

// An untrusted container in a scope whose env-mode stores no writer made yet
// gets none of them: their binds would need mount points below the scope's
// read-only bind (the runtime fails the start with EROFS), and a reader never
// creates a store. Its variables go too; a store that exists is still read.
func TestCacheReaderOfAMissingEnvStoreLeavesItOut(t *testing.T) {
	useFence(t, "boot-a")
	useOverlay(t)
	fillStore(t, "marker", "trusted") // default/gomod (and gobuild) exist
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache": "gomod,pip", "io.micropod.cache.trust": "untrusted",
	}}, testFacts(golangEnv, nil))
	a := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "c4", "shim"))
	defer a.close()
	if a.skipped["pip"] != skipNoStore || a.skipped["gomod"] != "" {
		t.Fatalf("skipped %v", a.skipped)
	}
	if _, set := envLookup(a.env, "PIP_CACHE_DIR", false); set {
		t.Fatalf("PIP_CACHE_DIR kept without its store: %v", a.env)
	}
	if v, _ := envLookup(a.env, "GOMODCACHE", false); v != cacheMountRoot+"/gomod" {
		t.Fatalf("GOMODCACHE %q", v)
	}
	for _, m := range a.mounts {
		if strings.HasPrefix(m.ContainerPath, cacheMountRoot+"/pip") {
			t.Fatalf("a mount for the missing store: %+v", m)
		}
	}
	if exists(filepath.Join(cacheRoot, "scopes/default/pip")) {
		t.Fatal("the reader created the store")
	}
	// No env-mode store at all: not even the scope is bound.
	fresh := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache": "pip", "io.micropod.cache.trust": "untrusted", "io.micropod.cache.scope": "fresh",
	}}, testFacts(golangEnv, nil))
	b := openCacheMounts(&fresh, filepath.Join(filepath.Dir(cacheRoot), "c5", "shim"))
	defer b.close()
	if len(b.mounts) != 0 || b.skipped["pip"] != skipNoStore {
		t.Fatalf("fresh scope: mounts %+v skipped %v", b.mounts, b.skipped)
	}
}

// A reader sees at the scope's mount point only the mount points of the units
// it reads: not the stores of tools it did not select, not another uid's
// partition, whatever scope it named. A writer still sees its scope.
func TestCacheReaderSeesOnlyItsOwnUnits(t *testing.T) {
	useFence(t, "boot-a")
	useOverlay(t)
	fillStore(t, "marker", "trusted") // default/gomod and default/gobuild
	for _, d := range []string{"scopes/default/cargo/registry", "scopes/default/pip/u1000"} {
		if err := os.MkdirAll(filepath.Join(cacheRoot, d), 0777); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(cacheRoot, "scopes/default/pip/u1000/secret"), []byte("other uid"), 0666); err != nil {
		t.Fatal(err)
	}
	shim := filepath.Join(filepath.Dir(cacheRoot), "c6", "shim")
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache": "gomod,pip", "io.micropod.cache.trust": "untrusted",
	}}, testFacts(golangEnv, nil))
	a := openCacheMounts(&plan, shim)
	defer a.close()
	m, src := mountAt(t, a, cacheMountRoot)
	if !m.Readonly || src != filepath.Join(shim, "ro-scope-default") {
		t.Fatalf("scope mount %+v -> %s", m, src)
	}
	entries, err := os.ReadDir(src)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	if strings.Join(names, ",") != "gomod" {
		t.Fatalf("the reader's scope shows %v, want only gomod", names)
	}
	if _, view := mountAt(t, a, cacheMountRoot+"/gomod"); view == "" {
		t.Fatal("no view of gomod")
	}
	a.release()
	if exists(src) {
		t.Fatal("the reader's scope directory outlived its start")
	}
	w := goPlan(t, "default")
	b := openCacheMounts(&w, "")
	defer b.close()
	if _, src := mountAt(t, b, cacheMountRoot); src != filepath.Join(cacheRoot, "scopes/default") {
		t.Fatalf("a writer's scope mount -> %s", src)
	}
}

// A reader leaves nothing on the cache disk for a scope or a store nobody
// wrote: no scope directory, no .meta, no lock or stamp file.
func TestCacheReaderLeavesNoTraceOfMissingScopesAndStores(t *testing.T) {
	useFence(t, "boot-a")
	useOverlay(t)
	fillStore(t, "marker", "trusted")
	for i, scope := range []string{"nobody-wrote-this", "default"} {
		plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
			"io.micropod.cache": "gomod,pip,cargo", "io.micropod.cache.trust": "untrusted", "io.micropod.cache.scope": scope,
		}}, testFacts(append([]string{"CARGO_HOME=/usr/local/cargo"}, golangEnv...), map[string]pathFact{"/usr/local/cargo": dirFact}))
		a := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "c7", strconv.Itoa(i), "shim"))
		if a.skipped["pip"] != skipNoStore {
			t.Fatalf("%s: skipped %v", scope, a.skipped)
		}
		a.touchAll()
		a.close()
	}
	for _, p := range []string{"scopes/nobody-wrote-this", ".meta/nobody-wrote-this", ".meta/default/pip.u0.lock", ".meta/default/pip.u0.used", ".meta/default/cargo.lock", ".meta/default/cargo.used"} {
		if exists(filepath.Join(cacheRoot, p)) {
			t.Fatalf("a reader made %s", p)
		}
	}
	// An alias volume of a store nobody wrote is a private empty directory,
	// with no scope or lock made for it.
	priv := filepath.Join(filepath.Dir(cacheRoot), "c8")
	f, pins, err := openAliasStore("nobody-either", "gomod", aliasRead, priv)
	if err != nil || len(pins) != 0 || !strings.HasPrefix(f.Name(), priv) {
		t.Fatalf("alias read %v %v %v", f, pins, err)
	}
	f.Close()
	if f, _, err = openAliasStore("nobody-either", "gomod", aliasProbe, ""); err != nil {
		t.Fatal(err)
	}
	f.Close()
	if exists(filepath.Join(cacheRoot, "scopes/nobody-either")) || exists(filepath.Join(cacheRoot, ".meta/nobody-either")) {
		t.Fatal("an alias reader or probe made the scope")
	}
}

// A reader that holds a unit (a sleeping untrusted container) never keeps a
// writer's mark alive: once the writer exited the clearer clears it, so an
// unclean stop then cannot discard the store on the reader's account.
func TestCacheReaderDoesNotKeepAWritersMark(t *testing.T) {
	useFence(t, "boot-a")
	useOverlay(t)
	fillStore(t, "marker", "trusted")
	w := goPlan(t, "default")
	writer := openCacheMounts(&w, "")
	if !marked("default", "gomod") {
		t.Fatal("the writer made no mark")
	}
	r := untrustedGoPlan(t, "default")
	reader := openCacheMounts(&r, filepath.Join(filepath.Dir(cacheRoot), "c9", "shim"))
	defer reader.close()
	if !unitLockHeld("default", "gomod") {
		t.Fatal("the reader does not hold the store")
	}
	writer.close()
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") {
		t.Fatal("a reader's hold kept the writer's mark")
	}
	// While a writer still holds it, the mark stays.
	w2 := openCacheMounts(&w, "")
	other := openCacheMounts(&w, "")
	w2.close()
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if !marked("default", "gomod") {
		t.Fatal("cleared while another writer holds the unit")
	}
	other.close()
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") {
		t.Fatal("not cleared once the last writer exited")
	}
}
