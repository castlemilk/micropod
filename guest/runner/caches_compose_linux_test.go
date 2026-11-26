package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"golang.org/x/sys/unix"
	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// How master's cache disk, untrusted tier, yarn v1 copy-on-write fallback and
// new ecosystems compose with the crash fence and the janitor.

// useOverlay returns true when this process can mount overlayfs with an upper
// directory below TMPDIR (root on a kernel with overlayfs, TMPDIR on ext4 or
// tmpfs). Otherwise views are an empty stand-in directory, so the fence,
// janitor, recovery and cleanup assertions still run; reads through a view
// and its write isolation are checked only on a real overlay.
func useOverlay(t *testing.T) bool {
	t.Helper()
	needRoot(t)
	base := t.TempDir()
	for _, d := range []string{"l", "u", "w", "m"} {
		if err := os.Mkdir(filepath.Join(base, d), 0755); err != nil {
			t.Fatal(err)
		}
	}
	opts := "lowerdir=" + filepath.Join(base, "l") + ",upperdir=" + filepath.Join(base, "u") + ",workdir=" + filepath.Join(base, "w")
	err := unix.Mount("overlay", filepath.Join(base, "m"), "overlay", 0, opts)
	if err == nil {
		unix.Unmount(filepath.Join(base, "m"), unix.MNT_DETACH)
		return true
	}
	t.Logf("overlayfs unavailable here (%v): views are stand-ins, write isolation is not checked", err)
	prev := cacheOverlayMount
	cacheOverlayMount = func(_, baseDir string) (string, error) {
		merged := filepath.Join(baseDir, "merged")
		return merged, os.MkdirAll(merged, 0755)
	}
	t.Cleanup(func() { cacheOverlayMount = prev })
	return false
}

func untrustedGoPlan(t *testing.T, scope string) cachePlan {
	t.Helper()
	return decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache": "go", "io.micropod.cache.scope": scope, "io.micropod.cache.trust": "untrusted",
	}}, testFacts(golangEnv, nil))
}

// mountAt returns the attachment's mount at target and where its source
// resolves.
func mountAt(t *testing.T, a cacheAttachment, target string) (*cri.Mount, string) {
	t.Helper()
	for _, m := range a.mounts {
		if m.ContainerPath == target {
			src, err := os.Readlink(m.HostPath)
			if err != nil {
				t.Fatal(err)
			}
			return m, src
		}
	}
	t.Fatalf("no mount at %s: %+v", target, a.mounts)
	return nil, ""
}

func isMountPoint(t *testing.T, p string) bool {
	t.Helper()
	b, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if f := strings.Fields(line); len(f) > 4 && f[4] == p {
			return true
		}
	}
	return false
}

func markIno(t *testing.T, scope, unit string) uint64 {
	t.Helper()
	var st unix.Stat_t
	if err := unix.Lstat(dirtyMarker(scope, unit), &st); err != nil {
		t.Fatalf("%s/%s not marked: %v", scope, unit, err)
	}
	return st.Ino
}

// An untrusted container reads the trusted stores warm through per-container
// overlays: its unit binds are the overlays' roots, its writes stay in an
// upper directory outside the cache root, and it makes no dirty mark. Its
// holds keep the janitor off the stores the overlays read; once it exits the
// overlays and their upper and work directories are gone and the janitor can
// evict.
func TestCacheUntrustedViewOverAStoreWhileTheJanitorRuns(t *testing.T) {
	useFence(t, "boot-a")
	real := useOverlay(t)
	base := filepath.Dir(cacheRoot)
	eng := &dockerEngine{}

	// A trusted writer fills the store, exits, and the fence clears its mark.
	trusted := goPlan(t, "default")
	w := openCacheMounts(&trusted, "")
	entry := filepath.Join(cacheRoot, "scopes/default/gomod", "cache/download/x/@v/v1.0.0.mod")
	writeAged(t, entry, 32, 0)
	w.close()
	if err := cacheDirty.syncOnce(); err != nil || marked("default", "gomod") {
		t.Fatalf("trusted writer's mark: %v", err)
	}

	plan := untrustedGoPlan(t, "default")
	if !plan.ReadOnly || plan.Trust != "untrusted" {
		t.Fatalf("plan %+v", plan)
	}
	shim := filepath.Join(base, "c-untrusted", "shim")
	a := openCacheMounts(&plan, shim)
	defer a.close()
	if len(a.skipped) != 0 || a.access["gomod"] != accessCopyOnWrite || a.access["gobuild"] != accessCopyOnWrite {
		t.Fatalf("skipped %v access %v", a.skipped, a.access)
	}
	for _, p := range a.pins {
		if p.writer || p.slot != nil {
			t.Fatalf("an untrusted start pinned %s/%s as a writer", p.scope, p.unit)
		}
	}
	if marked("default", "gomod") || marked("default", "gobuild") {
		t.Fatal("an untrusted start marked a trusted store dirty")
	}
	if root, src := mountAt(t, a, cacheMountRoot); !root.Readonly || src != filepath.Join(cacheRoot, "scopes/default") {
		t.Fatalf("scope root %+v from %s", root, src)
	}
	view, src := mountAt(t, a, cacheMountRoot+"/gomod")
	if view.Readonly || filepath.Base(src) != "merged" || strings.HasPrefix(src, cacheRoot+"/") || real != isMountPoint(t, src) {
		t.Fatalf("gomod bound from %s (%+v), want a writable overlay outside the cache root", src, view)
	}
	if real {
		upper := filepath.Join(filepath.Dir(src), "upper")
		// Warm reads come from the store; writes land in the container's upper.
		if b, err := os.ReadFile(filepath.Join(src, "cache/download/x/@v/v1.0.0.mod")); err != nil || len(b) != 32 {
			t.Fatalf("warm read through the view: %v", err)
		}
		if err := os.WriteFile(filepath.Join(src, "cache/download/x/@v/v1.0.0.mod"), []byte("poisoned"), 0666); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(src, "new.mod"), []byte("mine"), 0666); err != nil {
			t.Fatal(err)
		}
		if b, _ := os.ReadFile(entry); len(b) != 32 || exists(filepath.Join(cacheRoot, "scopes/default/gomod/new.mod")) {
			t.Fatalf("an untrusted write reached the trusted store: %q", b)
		}
		if !exists(filepath.Join(upper, "new.mod")) {
			t.Fatalf("the write is not in the container's upper %s", upper)
		}
	}
	// The janitor sees the store in use, not dirty, and leaves it alone.
	snap := eng.inspectCaches(false)
	if u := unitUsage(t, snap, "default", "gomod"); !u.InUse || u.Dirty {
		t.Fatalf("inventory %+v", u)
	}
	res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", Reason: "test"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if acts := pruneActions(res); acts["default/gomod"] != "skipped-in-use" || res.EvictedUnits != 0 {
		t.Fatalf("prune under a view: %+v", res)
	}
	// Nothing of the view is in the cache root: no unit, no lock, no mark.
	_, units := discoverCacheUnits()
	for _, u := range units {
		if u.Scope != "default" || (u.Kind != "gomod" && u.Kind != "gobuild") {
			t.Fatalf("the view shows up in the inventory as %+v", u)
		}
	}

	a.release()
	if (real && isMountPoint(t, src)) || exists(filepath.Dir(src)) {
		t.Fatalf("view %s survived its release", filepath.Dir(src))
	}
	if b, _ := os.ReadFile(entry); len(b) != 32 {
		t.Fatalf("store entry after the view: %q", b)
	}
	res, err = eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", Reason: "test"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if acts := pruneActions(res); acts["default/gomod"] != "evicted" {
		t.Fatalf("prune after the view: %+v", res)
	}
}

// Startup recovery meets an untrusted view of a store an unclean stop left
// marked (a scheduler job in another process still reads it): it leaves the
// unit marked and in place, because the reader's hold is a writer's to it,
// and the view keeps reading. The reader never touched the mark. Once the
// reader is gone the next recovery discards the unit.
func TestCacheUntrustedViewOverAStoreWhileCrashRecoveryRuns(t *testing.T) {
	setBoot, _ := useFence(t, "boot-old")
	real := useOverlay(t)
	base := filepath.Dir(cacheRoot)

	trusted := goPlan(t, "default")
	w := openCacheMounts(&trusted, "")
	entry := filepath.Join(cacheRoot, "scopes/default/gomod", "torn.mod")
	writeAged(t, entry, 8, 0)
	w.close() // the machine dies before the fence's sync: the mark stays
	ino := markIno(t, "default", "gomod")

	setBoot("boot-new") // no clean-stop record: boot-old stopped uncleanly
	plan := untrustedGoPlan(t, "default")
	a := openCacheMounts(&plan, filepath.Join(base, "job", "shim"))
	defer a.close()
	_, src := mountAt(t, a, cacheMountRoot+"/gomod")
	if markIno(t, "default", "gomod") != ino {
		t.Fatal("the reader replaced the writer's mark")
	}
	discardDirtyCaches()
	discarded, _ := cacheRecoveryReport()
	if len(discarded) != 0 || !marked("default", "gomod") || !exists(entry) {
		t.Fatalf("recovery under a view: discarded %v", discarded)
	}
	if b, err := os.ReadFile(filepath.Join(src, "torn.mod")); real && (err != nil || len(b) != 8) {
		t.Fatalf("the view lost its lower: %v", err)
	}
	a.release()
	discardDirtyCaches()
	discarded, _ = cacheRecoveryReport()
	if !slices.Contains(discarded, "default/gomod") || exists(entry) {
		t.Fatalf("recovery after the view: discarded %v", discarded)
	}
}

// yarn v1 under the one lock scheme: every container holds the unit lock
// LOCK_SH; the first also wins the writer slot and marks the unit, the others
// read copy-on-write without a mark and without the slot. The janitor sees the
// unit in use; a clearer waits for the readers too; the next writer after the
// first one exits gets the slot and a fresh mark.
func TestCacheYarnV1ConcurrencyUnderOneLockScheme(t *testing.T) {
	useFence(t, "boot-a")
	real := useOverlay(t)
	base := filepath.Dir(cacheRoot)
	eng := &dockerEngine{}
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "yarn"}},
		testFacts([]string{"HOME=/root"}, nil, "node"))
	const unit = "yarn.u0"
	start := func(name string) cacheAttachment {
		t.Helper()
		return openCacheMounts(&plan, filepath.Join(base, name, "shim"))
	}

	a := start("a")
	defer a.close()
	if a.access["yarn"] != "" || len(a.skipped) != 0 || len(a.pins) != 1 || !a.pins[0].writer || a.pins[0].slot == nil {
		t.Fatalf("writer: access %v skipped %v pins %+v", a.access, a.skipped, a.pins)
	}
	ino := markIno(t, "default", unit)
	_, store := mountAt(t, a, "/usr/local/share/.cache/yarn")
	if store != filepath.Join(cacheRoot, "scopes/default/yarn/u0") {
		t.Fatalf("writer bound %s", store)
	}
	writeAged(t, filepath.Join(store, "v6", "pkg-1", ".yarn-metadata.json"), 4, 0)

	b := start("b")
	defer b.close()
	if b.access["yarn"] != accessCopyOnWrite || len(b.skipped) != 0 || len(b.pins) != 1 || b.pins[0].writer || b.pins[0].slot != nil {
		t.Fatalf("reader: access %v skipped %v pins %+v", b.access, b.skipped, b.pins)
	}
	if markIno(t, "default", unit) != ino {
		t.Fatal("a copy-on-write reader replaced the writer's mark")
	}
	_, view := mountAt(t, b, "/usr/local/share/.cache/yarn")
	if real && !exists(filepath.Join(view, "v6", "pkg-1", ".yarn-metadata.json")) {
		t.Fatal("the reader's view is not warm")
	}
	writeAged(t, filepath.Join(view, "v6", "pkg-2", ".yarn-metadata.json"), 4, 0)
	if exists(filepath.Join(store, "v6", "pkg-2")) {
		t.Fatal("the reader wrote the shared yarn store")
	}
	if slot, err := unitWriterLock("default", unit); !errors.Is(err, unix.EWOULDBLOCK) {
		if slot != nil {
			slot.Close()
		}
		t.Fatalf("the writer slot is free while the writer runs: %v", err)
	}
	res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Tool: "yarn", Reason: "test"}, 0)
	if err != nil || pruneActions(res)["default/"+unit] != "skipped-in-use" {
		t.Fatalf("prune: %+v %v", res, err)
	}

	// The writer exits. The reader still holds the unit: to a clearer it may
	// be a writer, so the mark stays.
	a.touchAll()
	a.close()
	if err := cacheDirty.syncOnce(); err != nil || !marked("default", unit) {
		t.Fatalf("mark cleared under a reader: %v", err)
	}
	// The slot is free (the reader never took it); the next start writes.
	c := start("c")
	defer c.close()
	if c.access["yarn"] != "" || len(c.pins) != 1 || !c.pins[0].writer {
		t.Fatalf("next writer: access %v pins %+v", c.access, c.pins)
	}
	if markIno(t, "default", unit) == ino {
		t.Fatal("the next writer did not renew the mark")
	}
	c.close()
	b.close()
	if exists(filepath.Dir(view)) {
		t.Fatal("the reader's view survived its release")
	}
	for i := 0; i < 3 && marked("default", unit); i++ {
		if err := cacheDirty.syncOnce(); err != nil {
			t.Fatal(err)
		}
	}
	if marked("default", unit) {
		t.Fatal("the mark outlived every container")
	}
	if !exists(filepath.Join(store, "v6", "pkg-1")) || exists(filepath.Join(store, "v6", "pkg-2")) {
		t.Fatal("the store does not hold exactly the writer's entries")
	}
}

// A trusted container that loses yarn's writer slot and cannot get a view
// (no private directory, as for a scheduler job) is skipped as busy-exclusive
// and holds nothing; an untrusted plan never asks for the slot.
func TestCacheYarnV1WithoutAViewIsBusy(t *testing.T) {
	useFence(t, "boot-a")
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "yarn"}},
		testFacts([]string{"HOME=/root"}, nil, "node"))
	a := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "a"))
	defer a.close()
	b := openCacheMounts(&plan, "")
	defer b.close()
	if b.skipped["yarn"] != skipBusyExclusive || len(b.pins) != 0 {
		t.Fatalf("skipped %v pins %+v", b.skipped, b.pins)
	}
	untrusted := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "yarn", "io.micropod.cache.trust": "untrusted"}},
		testFacts([]string{"HOME=/root"}, nil, "node"))
	for _, st := range untrusted.Stores {
		if st.Exclusive {
			t.Fatalf("untrusted store %+v asks for the writer slot", st)
		}
	}
}

// master's five ecosystems are table rows like the other ten: each store is
// created root 0777 with the default ACL, pinned (lock plus dirty mark),
// stamped, kept from the janitor while held, cleared after its writer exits,
// and discarded after an unclean stop.
func TestCacheNewEcosystemStoresGoThroughTheFence(t *testing.T) {
	for _, kind := range []string{"maven", "gradle", "bun", "sccache", "playwright"} {
		t.Run(kind, func(t *testing.T) {
			setBoot, _ := useFence(t, "boot-a")
			eng := &dockerEngine{}
			binary := map[string]string{"maven": "mvn"}[kind]
			if binary == "" {
				binary = kind
			}
			plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": kind}},
				testFacts([]string{"HOME=/root", "PATH=/usr/bin"}, nil, binary))
			if st := plan.Tools[kind]; st.Mode != "path" {
				t.Fatalf("plan %+v", st)
			}
			a := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "c", "shim"))
			if len(a.skipped) != 0 || !slices.Contains(a.units, kind) {
				a.close()
				t.Fatalf("skipped %v units %v", a.skipped, a.units)
			}
			store := filepath.Join(cacheRoot, "scopes/default", kind)
			if mode, owner := modeOf(t, store); mode != 0777 || owner != 0 || string(defaultACL(store)) != string(cacheACL) {
				a.close()
				t.Fatalf("store mode %o owner %d acl %x", mode, owner, defaultACL(store))
			}
			if _, src := mountAt(t, a, plan.Tools[kind].Path); src != store {
				a.close()
				t.Fatalf("bound %s", src)
			}
			if !marked("default", kind) || !markOfThisBoot("default", kind) || !unitLockHeld("default", kind) || !exists(filepath.Join(cacheRoot, ".meta/default", kind+".used")) {
				a.close()
				t.Fatal("not pinned, marked and stamped")
			}
			writeAged(t, filepath.Join(store, "entry"), 8, 0)
			res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Tool: kind, Reason: "test"}, 0)
			if err != nil || pruneActions(res)["default/"+kind] != "skipped-in-use" {
				a.close()
				t.Fatalf("prune while held: %+v %v", res, err)
			}
			a.close()
			if err := cacheDirty.syncOnce(); err != nil || marked("default", kind) {
				t.Fatalf("mark after the writer: %v", err)
			}
			// An unclean stop while a writer holds it discards the unit.
			b := openCacheMounts(&plan, filepath.Join(filepath.Dir(cacheRoot), "c2", "shim"))
			closeMounts(b.files) // killed with the machine: no release, no sync
			setBoot("boot-b")
			discardDirtyCaches()
			if discarded, _ := cacheRecoveryReport(); !slices.Contains(discarded, "default/"+kind) || exists(filepath.Join(store, "entry")) {
				t.Fatalf("discarded %v", discarded)
			}
			if _, k, ok := legacyCacheVolume("micropod-ci-scoped-default-" + kind); !ok || k != kind {
				t.Fatalf("alias volume of %s", kind)
			}
		})
	}
}

// Without the cache disk it should have, the guest has no shared caches: no
// plan attaches, a plan made in a boot that had it replays as skipped, no
// store, lock or mark is created below the mount point, recovery and the
// janitor leave what is there alone, and an alias volume's store is refused
// (its container gets a private directory instead, next test).
func TestCacheDiskAbsentTurnsSharedCachesOff(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	// A plan made while the disk was mounted, and an earlier boot's leftovers
	// below the mount point.
	made := goPlan(t, "default")
	if !made.attached() {
		t.Fatal("no plan to replay")
	}
	if _, err := ensureStore("default", "gomod", nil); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dirtyMarker("default", "gomod"), []byte("boot-old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	old := cacheDiskInit
	t.Cleanup(func() { cacheDiskInit = old })
	for _, state := range []string{"unavailable", "mounted"} { // "mounted", yet cacheRoot is no mount point
		cacheDiskInit = state
		if cacheDiskUnavailable() == "" {
			t.Fatalf("%s: shared caches available", state)
		}
		plan, err := decideCaches(defaultCachePolicy(), dockerConfig{}, testFacts(golangEnv, nil))
		if err != nil || plan.attached() || plan.Reason != planNoCacheDisk {
			t.Fatalf("%s: plan %+v %v", state, plan, err)
		}
		a := openCacheMounts(&made, filepath.Join(filepath.Dir(cacheRoot), "c", "shim"))
		if len(a.mounts) != 0 || len(a.files) != 0 || len(a.pins) != 0 || a.skipped["gomod"] != skipNoCacheDisk || len(a.env) != 0 {
			t.Fatalf("%s: replay %+v", state, a)
		}
		if _, err := ensureStore("other", "npm", nil); !errors.Is(err, errNoCacheDisk) {
			t.Fatalf("%s: ensureStore %v", state, err)
		}
		if _, _, err := openAliasStore("default", "gomod", aliasWrite, t.TempDir()); !errors.Is(err, errNoCacheDisk) {
			t.Fatalf("%s: alias volume %v", state, err)
		}
		discardDirtyCaches()
		if discarded, kept := cacheRecoveryReport(); len(discarded)+len(kept) != 0 || !marked("default", "gomod") {
			t.Fatalf("%s: recovery acted below the mount point: %v %v", state, discarded, kept)
		}
		if _, err := eng.pruneCaches(context.Background(), cachePruneRequest{Reason: "test"}, 0); err == nil {
			t.Fatalf("%s: a prune ran", state)
		}
		if snap := eng.inspectCaches(false); snap.Unavailable == "" || len(snap.Units) != 0 || snap.CacheDisk.State != state || snap.CacheDisk.Mounted {
			t.Fatalf("%s: inventory %+v", state, snap)
		}
		if exists(filepath.Join(cacheRoot, "scopes/other")) || exists(filepath.Join(cacheRoot, ".meta/default/gomod.lock")) {
			t.Fatalf("%s: created below the mount point", state)
		}
	}
}

// fdTarget is where a bind source descriptor resolves.
func fdTarget(t *testing.T, f *os.File) string {
	t.Helper()
	p, err := os.Readlink(dockerMountFDPath(f))
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// Without the cache disk a legacy alias volume is a directory of its
// container's own, so the job runs uncached instead of failing: the start
// succeeds, writable and read-only alike, nothing is held, marked or created
// below the mount point, a restart of the same container (or a docker cp into
// it while stopped) sees what it wrote, another container sees none of it,
// and each such mount counts as cache-disk-unavailable. An untrusted container
// still may not mount one read-write.
func TestCacheDiskAbsentAliasVolumeRunsUncached(t *testing.T) {
	useFence(t, "boot-a")
	old := cacheDiskInit
	t.Cleanup(func() { cacheDiskInit = old })
	cacheDiskInit = "unavailable"
	eng := &dockerEngine{}
	spec := dockerConfig{HostConfig: dockerHost{Binds: []string{
		"micropod-ci-scoped-team-gomod:/go/pkg/mod",
		"micropod-ci-scoped-team-npm:/root/.npm:ro",
	}}}
	privA := filepath.Join(filepath.Dir(cacheRoot), "a", "shim")
	files, mounts, pins, err := eng.openMounts(spec, false, "", privA)
	if err != nil {
		t.Fatalf("the start failed without the cache disk: %v", err)
	}
	if len(files) != 2 || len(mounts) != 2 || len(pins) != 0 {
		t.Fatalf("files %d mounts %+v pins %+v", len(files), mounts, pins)
	}
	gomod, npm := fdTarget(t, files[0]), fdTarget(t, files[1])
	if gomod != filepath.Join(privA, "nocache-micropod-ci-scoped-team-gomod") || mounts[0].Readonly ||
		npm != filepath.Join(privA, "nocache-micropod-ci-scoped-team-npm") || !mounts[1].Readonly {
		t.Fatalf("sources %s %s, mounts %+v", gomod, npm, mounts)
	}
	if mode, _ := modeOf(t, gomod); mode != 0777 {
		t.Fatalf("private directory mode %o", mode)
	}
	writeAged(t, filepath.Join(gomod, "cache", "download", "x.mod"), 8, 0)
	closeMounts(files)
	if got := eng.metrics.cache.skips[skipNoCacheDisk]; got != 2 {
		t.Fatalf("cache-disk-unavailable counted %d times", got)
	}

	// A restart, and a docker cp into the stopped container, reach the same
	// directory; another container gets its own.
	files, _, _, err = eng.openMounts(spec, false, "", privA)
	if err != nil || !exists(filepath.Join(fdTarget(t, files[0]), "cache", "download", "x.mod")) {
		t.Fatalf("restart lost the container's own directory: %v", err)
	}
	closeMounts(files)
	f, cpPins, err := eng.openDockerMount(dockerMount{Type: "volume", Source: "micropod-ci-scoped-team-gomod", Target: "/go/pkg/mod"}, false, aliasWrite, privA)
	if err != nil || len(cpPins) != 0 || fdTarget(t, f) != gomod {
		t.Fatalf("docker cp into the stopped container: %v %+v", err, cpPins)
	}
	f.Close()
	privB := filepath.Join(filepath.Dir(cacheRoot), "b", "shim")
	files, _, _, err = eng.openMounts(spec, false, "", privB)
	if err != nil {
		t.Fatal(err)
	}
	if entries, _ := os.ReadDir(fdTarget(t, files[0])); len(entries) != 0 {
		t.Fatalf("another container shares the directory: %v", entries)
	}
	closeMounts(files)

	for _, p := range []string{"scopes/team", ".meta/team", ".meta/team/gomod.lock", ".meta/team/gomod.dirty"} {
		if exists(filepath.Join(cacheRoot, p)) {
			t.Fatalf("created %s below the mount point", p)
		}
	}
	untrusted := spec
	untrusted.Labels = map[string]string{"io.micropod.cache.trust": "untrusted"}
	if _, _, _, err := eng.openMounts(untrusted, false, "", privB); err == nil {
		t.Fatal("an untrusted container mounted an alias volume read-write")
	}
}

// A read-only alias volume (and a docker cp out of one) holds its kind
// without a mark and, like every reader, never creates or repairs anything in
// a store: a missing store is an empty private directory of the container's,
// a store whose modes drifted keeps them, and a non-directory planted where a
// store belongs stays where it is. A create's probe holds and opens nothing.
func TestCacheAliasReaderNeverCreatesOrRepairsTheStore(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	priv := filepath.Join(filepath.Dir(cacheRoot), "c", "shim")
	reader := func(bind string) dockerConfig {
		return dockerConfig{Labels: map[string]string{"io.micropod.cache.trust": "untrusted"}, HostConfig: dockerHost{Binds: []string{bind}}}
	}
	open := func(bind string) ([]*os.File, []*cri.Mount, []cachePin) {
		t.Helper()
		files, mounts, pins, err := eng.openMounts(reader(bind), false, "", priv)
		if err != nil || len(files) != 1 || len(pins) != 1 || pins[0].writer || !mounts[0].Readonly {
			t.Fatalf("%s: files %d pins %+v mounts %+v: %v", bind, len(files), pins, mounts, err)
		}
		if _, err := unitLock(pins[0].scope, pins[0].unit, true); !errors.Is(err, unix.EWOULDBLOCK) {
			t.Fatalf("%s: the reader does not hold its kind: %v", bind, err)
		}
		if marked(pins[0].scope, pins[0].unit) {
			t.Fatalf("%s: a reader marked the store", bind)
		}
		return files, mounts, pins
	}

	// No store yet: nothing is created in the scope a reader names.
	files, _, pins := open("micropod-ci-scoped-other-pnpm:/x:ro")
	if src := fdTarget(t, files[0]); src != filepath.Join(priv, "ro-empty-alias-other-pnpm") {
		t.Fatalf("missing store bound from %s", src)
	}
	if exists(filepath.Join(cacheRoot, "scopes/other/pnpm")) {
		t.Fatal("a reader created the store")
	}
	releasePins(pins)
	closeMounts(files)

	// A store whose modes drifted is bound as it is.
	store, err := ensureStore("other", "pnpm", nil)
	if err != nil {
		t.Fatal(err)
	}
	index := filepath.Join(store, "v11", "index.db")
	if err := errors.Join(os.Chmod(store, 0755), os.Chmod(index, 0644)); err != nil {
		t.Fatal(err)
	}
	files, _, pins = open("micropod-ci-scoped-other-pnpm:/x:ro")
	if src := fdTarget(t, files[0]); src != store {
		t.Fatalf("existing store bound from %s", src)
	}
	if mode, _ := modeOf(t, store); mode != 0755 {
		t.Fatalf("a reader repaired the store's mode to %o", mode)
	}
	if mode, _ := modeOf(t, index); mode != 0644 {
		t.Fatalf("a reader repaired pnpm's index to %o", mode)
	}
	releasePins(pins)
	closeMounts(files)

	// A non-directory where a store belongs stays there (no move to .trash).
	planted := filepath.Join(cacheRoot, "scopes/other/cargo")
	if err := os.WriteFile(planted, []byte("x"), 0644); err != nil {
		t.Fatal(err)
	}
	files, _, pins = open("micropod-ci-scoped-other-cargo:/c:ro")
	if st, err := os.Lstat(planted); err != nil || !st.Mode().IsRegular() {
		t.Fatalf("a reader moved the planted file: %v", err)
	}
	if trash, _ := os.ReadDir(filepath.Join(cacheRoot, ".trash")); len(trash) != 0 {
		t.Fatalf("a reader filled .trash: %v", trash)
	}
	releasePins(pins)
	closeMounts(files)

	// A docker cp out of a stopped container's alias volume reads the same way.
	f, cpPins, err := eng.openDockerMount(dockerMount{Type: "volume", Source: "micropod-ci-scoped-other-npm", Target: "/n"}, false, aliasRead, priv)
	if err != nil || len(cpPins) != 1 || cpPins[0].writer || exists(filepath.Join(cacheRoot, "scopes/other/npm")) {
		t.Fatalf("docker cp out: %v %+v", err, cpPins)
	}
	f.Close()
	releasePins(cpPins)

	// A create's probe neither holds nor opens the store.
	f, probePins, err := openAliasStore("other", "uv", aliasProbe, "")
	if err != nil || len(probePins) != 0 {
		t.Fatalf("probe: %v %+v", err, probePins)
	}
	f.Close()
	if exists(filepath.Join(cacheRoot, "scopes/other/uv")) || exists(filepath.Join(cacheRoot, ".meta/other/uv.lock")) {
		t.Fatal("a create's probe created the store or its lock")
	}
}

// yarn is partitioned and exclusive: its partition's writer slot
// (.meta/<scope>/yarn.u<uid>.writer.lock) sits next to the unit locks. The
// kind-wide unit's guards are the unit locks alone, so recovery, the janitor
// and the inventory probe never take the slot (lock order step 3), and a yarn
// start that claims its partition while they hold the kind still wins it.
func TestCacheUnitGuardsNeverIncludeTheWriterSlot(t *testing.T) {
	useFence(t, "boot-a")
	uid := uint32(1000)
	if _, err := ensureStore("default", "yarn", &uid); err != nil {
		t.Fatal(err)
	}
	unit := cacheUnit("yarn", &uid)
	w, err := pinUnit("default", unit, true)
	if err != nil || w.slot == nil {
		t.Fatalf("yarn writer: %+v %v", w, err)
	}
	releasePins([]cachePin{w})
	if !exists(filepath.Join(cacheRoot, ".meta/default", unit+".writer.lock")) {
		t.Fatal("no writer slot file to confuse the guards")
	}
	if got := cacheUnitGuards("default", "yarn"); !slices.Equal(got, []string{"yarn", unit}) {
		t.Fatalf("kind-wide guards %v", got)
	}
	if got := cacheUnitGuards("default", unit); !slices.Equal(got, []string{unit, "yarn"}) {
		t.Fatalf("partition guards %v", got)
	}

	// Recovery holds every guard of the kind-wide unit (a yarn.dirty mark a
	// writable alias volume left) for its whole run.
	held := map[string]*os.File{}
	if err := lockForDiscard(held, "default", "yarn"); err != nil {
		t.Fatal(err)
	}
	slot, err := unitWriterLock("default", unit)
	for _, f := range held {
		f.Close()
	}
	if err != nil {
		t.Fatalf("recovery held the writer slot: %v", err)
	}
	slot.Close()

	// A running yarn writer is in use through its unit lock, not its slot.
	w, err = pinUnit("default", unit, true)
	if err != nil {
		t.Fatal(err)
	}
	if !isUnitInUse("default", "yarn") || !isUnitInUse("default", unit) {
		t.Fatal("a running yarn writer is not in use")
	}
	releasePins([]cachePin{w})
	if isUnitInUse("default", "yarn") {
		t.Fatal("in use with no container left")
	}
}

// A cache disk reported mounted that really is mounted at cacheRoot (another
// device than its parent) gives the boot its shared caches.
func TestCacheDiskMountedAtTheCacheRoot(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	if err := os.Mkdir(cacheRoot, 0711); err != nil {
		t.Fatal(err)
	}
	if err := unix.Mount("tmpfs", cacheRoot, "tmpfs", 0, "mode=0711"); err != nil {
		t.Skipf("tmpfs: %v", err)
	}
	defer unix.Unmount(cacheRoot, unix.MNT_DETACH)
	old := cacheDiskInit
	t.Cleanup(func() { cacheDiskInit = old })
	cacheDiskInit = "mounted"
	if why := cacheDiskUnavailable(); why != "" {
		t.Fatalf("mounted: %s", why)
	}
	if plan, err := decideCaches(defaultCachePolicy(), dockerConfig{}, testFacts(golangEnv, nil)); err != nil || !plan.attached() {
		t.Fatalf("mounted: plan %+v %v", plan, err)
	}
	l, err := openCacheLayout()
	if err != nil {
		t.Fatalf("mounted: layout %v", err)
	}
	l.Close()
}

// The clean-stop record lives with the stores (.meta/clean-stop below
// cacheRoot): a mark of the boot it names is kept. The record's old place on
// the OS disk counts only until a new record exists and only on the stores'
// own filesystem.
func TestCacheCleanStopRecordLivesWithTheStores(t *testing.T) {
	setBoot, _ := useFence(t, "boot-a")
	oldClean, oldLegacy := cleanStopPath, legacyCleanStopPath
	t.Cleanup(func() { cleanStopPath, legacyCleanStopPath = oldClean, oldLegacy })
	cleanStopPath = ""
	legacyCleanStopPath = filepath.Join(filepath.Dir(cacheRoot), "legacy-clean-stop")
	plan := goPlan(t, "default")
	run := func(boot string) {
		t.Helper()
		setBoot(boot)
		a := openCacheMounts(&plan, "")
		closeMounts(a.files) // the boot ends with the container still running
	}
	write := func(p, v string) {
		t.Helper()
		if err := os.WriteFile(p, []byte(v+"\n"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if cleanStopRecord() != filepath.Join(cacheRoot, ".meta", "clean-stop") {
		t.Fatalf("record at %s", cleanStopRecord())
	}

	run("boot-1")
	write(cleanStopRecord(), "boot-1") // guest init: a clean stop
	setBoot("boot-2")
	discardDirtyCaches()
	if discarded, kept := cacheRecoveryReport(); len(discarded) != 0 || !slices.Contains(kept, "default/gomod") {
		t.Fatalf("clean stop: discarded %v kept %v", discarded, kept)
	}

	// An upgraded guest bundle: only the legacy record, on the same
	// filesystem, names the clean stop.
	os.Remove(cleanStopRecord())
	run("boot-3")
	write(legacyCleanStopPath, "boot-3")
	setBoot("boot-4")
	discardDirtyCaches()
	if discarded, _ := cacheRecoveryReport(); len(discarded) != 0 || marked("default", "gomod") {
		t.Fatalf("legacy record: discarded %v", discarded)
	}

	// The record lists the recent clean stops: a later boot that stopped
	// cleanly without ever running recovery does not hide the one the marks
	// belong to.
	run("boot-7")
	write(cleanStopRecord(), "boot-7\nboot-8")
	setBoot("boot-9")
	discardDirtyCaches()
	if discarded, _ := cacheRecoveryReport(); len(discarded) != 0 || marked("default", "gomod") {
		t.Fatalf("a later clean boot hid the marks' clean stop: discarded %v", discarded)
	}

	// A new record wins over a legacy one.
	run("boot-5")
	write(legacyCleanStopPath, "boot-5")
	write(cleanStopRecord(), "boot-0")
	setBoot("boot-6")
	discardDirtyCaches()
	if discarded, _ := cacheRecoveryReport(); !slices.Contains(discarded, "default/gomod") {
		t.Fatalf("stale new record: discarded %v", discarded)
	}
}
