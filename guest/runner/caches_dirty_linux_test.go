package main

import (
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestParseCacheUnit(t *testing.T) {
	for unit, want := range map[string]string{"gomod": "gomod", "pip.u1000": "pip/u1000", "yarn.u0": "yarn/u0", "uv": "uv"} {
		kind, uid, ok := parseCacheUnit(unit)
		if !ok || cacheStoreSub(kind, uid) != want {
			t.Fatalf("%s: %s %v %v", unit, kind, uid, ok)
		}
	}
	for _, bad := range []string{"", "bogus-tool", "pip.uroot", "pip.u-1", "../x"} {
		if _, _, ok := parseCacheUnit(bad); ok {
			t.Fatalf("parsed %q", bad)
		}
	}
}

// useBoot points the boot id and the clean-stop record at test files.
func useBoot(t *testing.T, id string) (setBoot func(string), setCleanStop func(string)) {
	t.Helper()
	dir := t.TempDir()
	oldBoot, oldClean := bootIDPath, cleanStopPath
	bootIDPath, cleanStopPath = filepath.Join(dir, "boot_id"), filepath.Join(dir, "clean-stop")
	t.Cleanup(func() { bootIDPath, cleanStopPath = oldBoot, oldClean })
	write := func(p string) func(string) {
		return func(v string) {
			if v == "" {
				os.Remove(p)
				return
			}
			if err := os.WriteFile(p, []byte(v+"\n"), 0644); err != nil {
				t.Fatal(err)
			}
		}
	}
	setBoot, setCleanStop = write(bootIDPath), write(cleanStopPath)
	setBoot(id)
	return setBoot, setCleanStop
}

func marked(scope, unit string) bool {
	_, err := os.Lstat(dirtyMarker(scope, unit))
	return err == nil
}

// A unit is marked dirty while a container binds it and until a sync after the
// last writer exits; a mark left by an unclean stop discards exactly that unit.
func TestCacheDirtyMarksAndDiscard(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	setBoot, setCleanStop := useBoot(t, "boot-1")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old; cacheDiscarded, cacheKept = nil, nil })
	f := testFacts(golangEnv, nil)
	plan := decide(t, defaultCachePolicy(), dockerConfig{}, f)
	a := openCacheMounts(&plan, "")
	b := openCacheMounts(&plan, "")
	if !slices.Contains(a.units, "gomod") || !marked("default", "gomod") || !marked("default", "pip.u0") {
		t.Fatalf("units %v not marked", a.units)
	}
	if got, _ := os.ReadFile(dirtyMarker("default", "gomod")); string(got) != "boot-1\n" {
		t.Fatalf("mark content %q", got)
	}
	// One of two containers exits: the unit stays pinned, a sync keeps the mark.
	a.release()
	a.release() // idempotent
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if !marked("default", "gomod") {
		t.Fatal("a sync cleared the mark of a unit another container still binds")
	}
	b.release()
	// Attached again before the sync ran: the newer writer holds the unit.
	c := openCacheMounts(&plan, "")
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if !marked("default", "gomod") {
		t.Fatal("mark cleared while a newer container binds the unit")
	}
	c.release()
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") || marked("default", "pip.u0") {
		t.Fatal("marks survive after every container exited and a sync ran")
	}
	closeMounts(a.files)
	closeMounts(b.files)
	closeMounts(c.files)

	// An unclean stop: a container wrote into the stores and its marks remain.
	d := openCacheMounts(&plan, "")
	store := filepath.Join(cacheRoot, "scopes/default")
	if err := os.WriteFile(filepath.Join(store, "gomod", "torn.mod"), nil, 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(store, "pip", "u0", "torn"), nil, 0666); err != nil {
		t.Fatal(err)
	}
	closeMounts(d.files) // the crash: locks gone, nothing released
	// A unit nobody bound since the last sync is left alone.
	if err := os.WriteFile(filepath.Join(store, "npm", "kept"), []byte("x"), 0666); err != nil {
		t.Fatal(err)
	}
	os.Remove(dirtyMarker("default", "npm"))
	// A mark temporary the crash left between create and rename is swept.
	tmp := filepath.Join(cacheRoot, ".meta", "default", ".uv.dirty.0123456789ab")
	if err := os.WriteFile(tmp, nil, 0600); err != nil {
		t.Fatal(err)
	}
	setBoot("boot-2") // the next boot's engine
	cacheDirty = newCacheDirtyTracker()
	discardDirtyCaches()
	for _, p := range []string{"gomod/torn.mod", "pip/u0/torn"} {
		if _, err := os.Lstat(filepath.Join(store, p)); !os.IsNotExist(err) {
			t.Fatalf("%s survived the discard: %v", p, err)
		}
	}
	if _, err := os.Lstat(filepath.Join(store, "npm", "kept")); err != nil {
		t.Fatalf("an unmarked unit was discarded: %v", err)
	}
	if _, err := os.Lstat(tmp); !os.IsNotExist(err) {
		t.Fatalf("mark temporary left: %v", err)
	}
	if len(listDirtyMarks()) != 0 {
		t.Fatalf("marks left after the discard: %v", listDirtyMarks())
	}
	if !slices.Contains(cacheDiscarded, "default/gomod") || !slices.Contains(cacheDiscarded, "default/pip.u0") || slices.Contains(cacheDiscarded, "default/npm") {
		t.Fatalf("discarded %v", cacheDiscarded)
	}
	// The next container gets fresh, correctly made stores.
	e := openCacheMounts(&plan, "")
	if len(e.skipped) != 0 {
		t.Fatalf("skipped after the discard: %v", e.skipped)
	}
	if mode, _ := modeOf(t, filepath.Join(store, "gomod")); mode != 0777 {
		t.Fatalf("recreated gomod %o", mode)
	}
	if err := os.WriteFile(filepath.Join(store, "gomod", "running.mod"), []byte("x"), 0666); err != nil {
		t.Fatal(err)
	}
	// The engine's orderly stop leaves the units a running container holds
	// marked, and clears a unit nobody holds.
	other := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "other"}}, f)
	g := openCacheMounts(&other, "")
	g.release()
	closeMounts(g.files)
	if !marked("other", "gomod") {
		t.Fatal("no mark in the second scope")
	}
	cacheDirty.shutdown()
	if !marked("default", "gomod") {
		t.Fatal("shutdown cleared the mark of a unit a running container holds")
	}
	if marked("other", "gomod") {
		t.Fatal("shutdown left the mark of a unit no writer holds")
	}
	// Guest init then stops every process, syncs and records the clean stop.
	closeMounts(e.files)
	setCleanStop("boot-2")
	setBoot("boot-3")
	cacheDiscarded = nil
	discardDirtyCaches()
	if len(cacheDiscarded) != 0 || len(listDirtyMarks()) != 0 || !slices.Contains(cacheKept, "default/gomod") {
		t.Fatalf("after a clean stop: discarded %v, kept %v, marks %v", cacheDiscarded, cacheKept, listDirtyMarks())
	}
	if _, err := os.Lstat(filepath.Join(store, "gomod", "running.mod")); err != nil {
		t.Fatalf("a cleanly stopped unit was discarded: %v", err)
	}
}

// Startup recovery by mark origin: this boot's marks and a cleanly stopped
// boot's marks are cleared; an unknown, empty or crashed boot's are discarded.
func TestCacheDirtyRecoveryByBoot(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	setBoot, setCleanStop := useBoot(t, "boot-a")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old; cacheDiscarded, cacheKept = nil, nil })
	f := testFacts(golangEnv, nil)
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "go"}}, f)
	crash := func() string { // a container writes and the machine dies
		a := openCacheMounts(&plan, "")
		p := filepath.Join(cacheRoot, "scopes/default/gomod", "entry")
		if err := os.WriteFile(p, []byte("x"), 0666); err != nil {
			t.Fatal(err)
		}
		closeMounts(a.files)
		return p
	}
	cases := []struct {
		name, markBoot, nextBoot, cleanStop string
		emptyMark, discard                  bool
	}{
		{name: "same boot (engine restarted, page cache intact)", markBoot: "boot-a", nextBoot: "boot-a"},
		{name: "cleanly stopped boot", markBoot: "boot-a", nextBoot: "boot-b", cleanStop: "boot-a"},
		{name: "crashed boot", markBoot: "boot-a", nextBoot: "boot-b", cleanStop: "boot-z", discard: true},
		{name: "no clean-stop record", markBoot: "boot-a", nextBoot: "boot-b", discard: true},
		{name: "mark lost its content in the crash", markBoot: "boot-a", nextBoot: "boot-b", cleanStop: "boot-a", emptyMark: true, discard: true},
	}
	for _, tc := range cases {
		setBoot(tc.markBoot)
		setCleanStop("")
		p := crash()
		if tc.emptyMark {
			if err := os.Truncate(dirtyMarker("default", "gomod"), 0); err != nil {
				t.Fatal(err)
			}
		}
		setBoot(tc.nextBoot)
		setCleanStop(tc.cleanStop)
		cacheDiscarded = nil
		discardDirtyCaches()
		_, err := os.Lstat(p)
		if gone := os.IsNotExist(err); gone != tc.discard || slices.Contains(cacheDiscarded, "default/gomod") != tc.discard {
			t.Fatalf("%s: entry gone=%v discarded=%v, want discard=%v", tc.name, gone, cacheDiscarded, tc.discard)
		}
		if marked("default", "gomod") {
			t.Fatalf("%s: mark left", tc.name)
		}
	}
}

// A mark replaced by a newer writer after a clearer opened it is not the
// clearer's to remove, even when that writer has exited by the time it looks.
func TestCacheDirtyClearKeepsANewerMark(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	useBoot(t, "boot-a")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old })
	f := testFacts(golangEnv, nil)
	plan := decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{"io.micropod.cache": "gomod"}}, f)
	a := openCacheMounts(&plan, "")
	a.release()
	closeMounts(a.files)
	opened, err := os.Open(dirtyMarker("default", "gomod"))
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	b := openCacheMounts(&plan, "") // attaches, writes, exits before the clearer looks
	b.release()
	closeMounts(b.files)
	if removed, err := clearMarkIfRetired("default", "gomod", opened, clearerLockWait); err != nil || removed {
		t.Fatal(removed, err)
	}
	if !marked("default", "gomod") {
		t.Fatal("a clearer removed a mark a later writer made after its sync started")
	}
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") {
		t.Fatal("the later writer's own release did not clear its mark")
	}
}

// A writable legacy alias volume pins its kind: recovery treats the whole kind
// directory as written, and a partition's discard waits for the alias writer.
func TestCacheDirtyAliasVolumeCoversTheKind(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	setBoot, _ := useBoot(t, "boot-a")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old; cacheDiscarded, cacheKept = nil, nil })
	if _, err := ensureStore("default", "pip", nil); err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{}
	spec := dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-pip:/cache/pip"}}}
	files, mounts, pins, err := s.openMounts(spec, rulesFor(t, spec), false, "", t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if len(mounts) != 1 || len(pins) != 1 || pins[0].unit != "pip" || !marked("default", "pip") {
		t.Fatalf("mounts %v pins %v", mounts, pins)
	}
	// A partition marked by a crashed boot cannot be discarded while the alias
	// writer can still write into it.
	if err := os.MkdirAll(filepath.Join(cacheRoot, "scopes/default/pip/u1000"), 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dirtyMarker("default", "pip.u1000"), []byte("boot-old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	discardDirtyCaches()
	if len(cacheDiscarded) != 0 || !marked("default", "pip.u1000") {
		t.Fatalf("discarded %v while the alias writer runs", cacheDiscarded)
	}
	// The alias writer dies with the machine: the whole kind goes.
	closeMounts(files)
	for _, p := range pins {
		p.lock.Close()
	}
	setBoot("boot-b")
	discardDirtyCaches()
	if _, err := os.Lstat(filepath.Join(cacheRoot, "scopes/default/pip")); !os.IsNotExist(err) {
		t.Fatalf("kind directory survived: %v (discarded %v)", err, cacheDiscarded)
	}
	for _, u := range []string{"default/pip", "default/pip.u1000"} {
		if !slices.Contains(cacheDiscarded, u) {
			t.Fatalf("discarded %v", cacheDiscarded)
		}
	}
	if len(listDirtyMarks()) != 0 {
		t.Fatalf("marks left: %v", listDirtyMarks())
	}
	// A read-only alias mount holds its kind's lock and makes no mark.
	files, _, pins, err = s.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-gomod:/cache/gomod:ro"}}}, rulesFor(t, dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-gomod:/cache/gomod:ro"}}}), false, "", t.TempDir())
	if err != nil || len(pins) != 1 || pins[0].unit != "gomod" || marked("default", "gomod") {
		t.Fatalf("read-only alias pins %v %v", pins, err)
	}
	releasePins(pins)
	closeMounts(files)
}

// docker cp into a stopped container's legacy alias volume writes into the
// store without any container running: the transfer pins the kind like a
// start does, and its end queues the clear. A read holds the kind's lock and
// never marks it.
func TestCacheDirtyArchiveWriteIntoAliasVolumePinsTheKind(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	useBoot(t, "boot-a")
	old := cacheDirty
	cacheDirty = newCacheDirtyTracker()
	t.Cleanup(func() { cacheDirty = old })
	if _, err := ensureStore("default", "gomod", nil); err != nil {
		t.Fatal(err)
	}
	s := &dockerEngine{workspace: t.TempDir()}
	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "exited"}}
	c.Config.HostConfig.Binds = []string{"micropod-ci-scoped-default-gomod:/go/pkg/mod"}
	_, closeView, err := s.openArchive(t.Context(), c, "/go/pkg/mod/cache", false)
	if err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") {
		t.Fatal("an archive read marked the store dirty")
	}
	if _, err := unitLock("default", "gomod", true); !errors.Is(err, unix.EWOULDBLOCK) {
		t.Fatalf("the read does not hold the unit: %v", err)
	}
	closeView()
	_, closeView, err = s.openArchive(t.Context(), c, "/go/pkg/mod/cache", true)
	if err != nil {
		t.Fatal(err)
	}
	if !marked("default", "gomod") {
		t.Fatal("an archive write into the alias volume left the store unmarked")
	}
	if _, err := unitLock("default", "gomod", true); !errors.Is(err, unix.EWOULDBLOCK) {
		t.Fatalf("the transfer does not hold the unit: %v", err)
	}
	if err := cacheDirty.syncOnce(); err != nil || !marked("default", "gomod") {
		t.Fatalf("cleared while the transfer runs: %v", err)
	}
	closeView()
	if err := cacheDirty.syncOnce(); err != nil || marked("default", "gomod") {
		t.Fatalf("the transfer's end did not clear its mark: %v", err)
	}
}

// A pin waits out a clearer's brief LOCK_EX instead of dropping the tool, for
// at most sharedPinWait; one held for longer than that reports busy, an
// exclusive pin (yarn v1) included: its unit lock is LOCK_SH like any other.
func TestCachePinWaitsForAClearer(t *testing.T) {
	needRoot(t)
	useCacheRoot(t)
	useBoot(t, "boot-a")
	if _, err := ensureStore("default", "gomod", nil); err != nil {
		t.Fatal(err)
	}
	clearer, err := unitLock("default", "gomod", true)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pinUnit("default", "gomod", true); !errors.Is(err, unix.EWOULDBLOCK) {
		t.Fatalf("exclusive pin under a clearer: %v", err)
	}
	go func() { time.Sleep(20 * time.Millisecond); clearer.Close() }()
	pin, err := pinUnit("default", "gomod", false)
	if err != nil {
		t.Fatalf("shared pin did not wait for the clearer: %v", err)
	}
	pin.lock.Close()
}
