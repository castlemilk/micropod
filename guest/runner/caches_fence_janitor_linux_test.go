package main

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

// The crash fence (caches_dirty_linux.go) and the janitor (caches_manage_linux.go)
// share the unit locks and dirty marks. These tests run them together.

// useFence gives a test a fresh cache root, boot id, mark tracker and
// recovery report, and restores them afterwards.
func useFence(t *testing.T, boot string) (setBoot, setCleanStop func(string)) {
	t.Helper()
	needRoot(t)
	useCacheRoot(t)
	setBoot, setCleanStop = useBoot(t, boot)
	oldDirty, oldHook, oldAliasHook := cacheDirty, cachePruneHook, cacheAliasHeldHook
	cacheDirty = newCacheDirtyTracker()
	resetRecovery := func() {
		cacheRecoveryMu.Lock()
		cacheDiscarded, cacheKept = nil, nil
		cacheRecoveryMu.Unlock()
	}
	resetRecovery()
	t.Cleanup(func() {
		cacheDirty, cachePruneHook, cacheAliasHeldHook = oldDirty, oldHook, oldAliasHook
		resetRecovery()
	})
	return setBoot, setCleanStop
}

func goPlan(t *testing.T, scope string) cachePlan {
	t.Helper()
	return decide(t, defaultCachePolicy(), dockerConfig{Labels: map[string]string{
		"io.micropod.cache": "go", "io.micropod.cache.scope": scope,
	}}, testFacts(golangEnv, nil))
}

func pruneActions(res cachePruneResult) map[string]string {
	out := map[string]string{}
	for _, a := range res.Actions {
		out[a.Scope+"/"+a.Unit] = a.Action
	}
	return out
}

func unitUsage(t *testing.T, snap cacheInspection, scope, unit string) cacheUnitUsage {
	t.Helper()
	for _, u := range snap.Units {
		if u.Scope == scope && u.Unit == unit {
			return u
		}
	}
	t.Fatalf("%s/%s not in the inventory: %+v", scope, unit, snap.Units)
	return cacheUnitUsage{}
}

func writeAged(t *testing.T, p string, size int, age time.Duration) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, bytes.Repeat([]byte("x"), size), 0666); err != nil {
		t.Fatal(err)
	}
	if age > 0 {
		ts := time.Now().Add(-age)
		if err := os.Chtimes(p, ts, ts); err != nil {
			t.Fatal(err)
		}
	}
}

func exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// While a writer holds a unit the janitor skips it as in use; after the
// writer exits and before the fence's sync clears the mark it skips it as
// dirty. Neither a wipe nor a budget trim moves or trims it until the mark is
// gone. The inventory and the metrics show each state.
func TestCacheJanitorLeavesHeldAndDirtyUnitsToTheFence(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	plan := goPlan(t, "default")
	a := openCacheMounts(&plan, "")
	if !slices.Contains(a.units, "gomod") || !slices.Contains(a.units, "gobuild") {
		closeMounts(a.files)
		t.Fatalf("units %v skipped %v", a.units, a.skipped)
	}
	entry := filepath.Join(cacheRoot, "scopes/default/gomod", "held.mod")
	cold := filepath.Join(cacheRoot, "scopes/default/gobuild", "00", "00c0ffee-d")
	writeAged(t, entry, 16, 0)
	writeAged(t, cold, 64<<10, 2*time.Hour)
	partial := true
	requests := []cachePruneRequest{{Reason: "test-wipe"}, {MaxBytes: 1, PartialGoBuild: &partial, Reason: "test-trim"}}

	for _, req := range requests {
		res, err := eng.pruneCaches(context.Background(), req, 0)
		if err != nil {
			t.Fatal(err)
		}
		if res.SkippedInUse != 2 || res.SkippedDirty != 0 || res.EvictedUnits != 0 || res.FreedFiles != 0 {
			t.Fatalf("%s while held: %+v", req.Reason, res)
		}
	}
	if !exists(entry) || !exists(cold) {
		t.Fatal("the janitor removed entries of a store a writer holds")
	}
	snap := eng.inspectCaches(false)
	for _, u := range []string{"gomod", "gobuild"} {
		if got := unitUsage(t, snap, "default", u); !got.InUse || !got.Dirty {
			t.Fatalf("held %s: %+v", u, got)
		}
	}
	if snap.Totals.InUseCount != 2 || snap.Totals.DirtyCount != 2 {
		t.Fatalf("totals while held: %+v", snap.Totals)
	}

	// The container exits: no writer is left, the marks wait for a sync.
	a.touchAll()
	a.release()
	closeMounts(a.files)
	for _, req := range requests {
		res, err := eng.pruneCaches(context.Background(), req, 0)
		if err != nil {
			t.Fatal(err)
		}
		acts := pruneActions(res)
		if res.SkippedDirty != 2 || res.SkippedInUse != 0 || res.EvictedUnits != 0 || res.FreedFiles != 0 ||
			acts["default/gomod"] != "skipped-dirty" || acts["default/gobuild"] != "skipped-dirty" {
			t.Fatalf("%s while marked: %+v", req.Reason, res)
		}
	}
	if !exists(entry) || !exists(cold) || !marked("default", "gomod") || !marked("default", "gobuild") {
		t.Fatal("the janitor acted on a store the fence still has marked")
	}
	snap = eng.inspectCaches(false)
	for _, u := range []string{"gomod", "gobuild"} {
		if got := unitUsage(t, snap, "default", u); got.InUse || !got.Dirty {
			t.Fatalf("released %s: %+v", u, got)
		}
	}
	if snap.Totals.InUseCount != 0 || snap.Totals.DirtyCount != 2 {
		t.Fatalf("totals while marked: %+v", snap.Totals)
	}
	if got := eng.metrics.cache.snapshot()["cache_prune_skipped_dirty"]; got != uint64(4) {
		t.Fatalf("cache_prune_skipped_dirty = %v", got)
	}

	// The fence's sync clears the marks; now the janitor trims and evicts.
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") || marked("default", "gobuild") {
		t.Fatal("marks survive the sync")
	}
	res, err := eng.pruneCaches(context.Background(), requests[1], 0)
	if err != nil {
		t.Fatal(err)
	}
	acts := pruneActions(res)
	if acts["default/gobuild"] != "partial-evicted" || acts["default/gomod"] != "evicted" || res.SkippedDirty != 0 {
		t.Fatalf("after the clear: %+v", res)
	}
	if exists(cold) || exists(entry) {
		t.Fatal("the trim or the eviction left its victims")
	}
	if exists(filepath.Join(cacheRoot, ".meta/default/gomod.used")) {
		t.Fatal("the evicted unit kept its used stamp")
	}
}

// A writable legacy alias volume pins its kind-wide unit, which covers every
// partition: the janitor must not evict a partition while the alias writer
// runs, nor while the kind-wide mark waits for its sync.
func TestCacheJanitorHonoursAliasVolumePins(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	uid := uint32(1000)
	if _, err := ensureStore("default", "pip", &uid); err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "pip.u1000"); err != nil {
		t.Fatal(err)
	}
	wheel := filepath.Join(cacheRoot, "scopes/default/pip/u1000", "wheel")
	writeAged(t, wheel, 16, 0)
	files, _, pins, err := eng.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-pip:/cache/pip"}}}, false, "")
	if err != nil || len(pins) != 1 || pins[0].unit != "pip" {
		t.Fatalf("alias pins %+v: %v", pins, err)
	}
	prune := func() cachePruneResult {
		t.Helper()
		res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Tool: "pip", Reason: "test"}, 0)
		if err != nil {
			t.Fatal(err)
		}
		return res
	}
	if res := prune(); pruneActions(res)["default/pip.u1000"] != "skipped-in-use" {
		t.Fatalf("partition evicted under a kind-wide alias writer: %+v", res)
	}
	if got := unitUsage(t, eng.inspectCaches(false), "default", "pip.u1000"); !got.InUse || !got.Dirty {
		t.Fatalf("partition under an alias writer: %+v", got)
	}
	releasePins(pins)
	closeMounts(files)
	if res := prune(); pruneActions(res)["default/pip.u1000"] != "skipped-dirty" {
		t.Fatalf("partition evicted while the kind-wide mark waits for its sync: %+v", res)
	}
	if !exists(wheel) {
		t.Fatal("partition entry lost")
	}
	if err := cacheDirty.syncOnce(); err != nil || marked("default", "pip") {
		t.Fatalf("kind-wide mark not cleared: %v", err)
	}
	if res := prune(); pruneActions(res)["default/pip.u1000"] != "evicted" {
		t.Fatalf("clean partition not evicted: %+v", res)
	}
	if exists(wheel) {
		t.Fatal("evicted partition still on disk")
	}
}

// A container can write anything inside its writable gobuild bind, a symlink
// in place of a shard directory included; a trim never follows it out of the
// store, while it still trims the real shards.
func TestCacheJanitorTrimDoesNotFollowShardSymlinks(t *testing.T) {
	useFence(t, "boot-a")
	dir, err := ensureStore("default", "gobuild", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "gobuild"); err != nil {
		t.Fatal(err)
	}
	outside := filepath.Join(filepath.Dir(cacheRoot), "outside")
	victim := filepath.Join(outside, "00victim-d")
	writeAged(t, victim, 4096, 2*time.Hour)
	if err := os.Symlink(outside, filepath.Join(dir, "01")); err != nil {
		t.Fatal(err)
	}
	cold := filepath.Join(dir, "00", "00cold-d")
	writeAged(t, cold, 4096, 2*time.Hour)
	partial := true
	res, err := (&dockerEngine{}).pruneCaches(context.Background(), cachePruneRequest{MaxBytes: 1, PartialGoBuild: &partial, Reason: "test"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if !exists(victim) {
		t.Fatalf("the trim followed a shard symlink out of the store: %+v", res)
	}
	if exists(cold) || res.FreedFiles != 1 {
		t.Fatalf("the trim skipped the real shard: %+v", res)
	}
}

// Writers in several goroutines lock, mark, write and release the same units
// while janitor passes wipe and trim them. No writer ever sees its store moved
// or an entry it wrote (fresh or aged past the trim cutoff) removed while it
// holds the unit, and once the writers are gone and the marks cleared one pass
// evicts everything.
func TestCacheJanitorConcurrentWithWriters(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	plan := goPlan(t, "default")
	const writers, rounds = 4, 40
	var violations, skips, held atomic.Int64
	stop := make(chan struct{})
	var janitor sync.WaitGroup
	var acted atomic.Int64
	janitor.Add(1)
	go func() {
		defer janitor.Done()
		partial := true
		for i := 0; ; i++ {
			select {
			case <-stop:
				return
			default:
			}
			req := cachePruneRequest{Reason: "stress-wipe"}
			if i%2 == 1 {
				req = cachePruneRequest{MaxBytes: 1, PartialGoBuild: &partial, SafetyCutoffSecs: 60, Reason: "stress-trim"}
			}
			res, err := eng.pruneCaches(context.Background(), req, 0)
			if err != nil {
				t.Errorf("prune: %v", err)
				return
			}
			acted.Add(int64(len(res.Actions)))
		}
	}()
	var wg sync.WaitGroup
	for w := 0; w < writers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for r := 0; r < rounds; r++ {
				a := openCacheMounts(&plan, "")
				for _, kind := range []string{"gomod", "gobuild"} {
					if _, gone := a.skipped[kind]; gone {
						skips.Add(1)
						continue
					}
					held.Add(1)
					dir := filepath.Join(cacheRoot, "scopes/default", kind)
					var before, after unix.Stat_t
					if err := unix.Lstat(dir, &before); err != nil {
						violations.Add(1)
						t.Errorf("w%d r%d: held %s missing: %v", w, r, kind, err)
						continue
					}
					fresh := filepath.Join(dir, "w", string(rune('a'+w)))
					aged := filepath.Join(dir, "00", "00"+string(rune('a'+w))+"-d")
					for _, p := range []string{fresh, aged} {
						_ = os.MkdirAll(filepath.Dir(p), 0777)
						if err := os.WriteFile(p, []byte{byte(r)}, 0666); err != nil {
							t.Errorf("w%d: write %s: %v", w, p, err)
						}
					}
					ts := time.Now().Add(-time.Hour)
					_ = os.Chtimes(aged, ts, ts)
					time.Sleep(time.Millisecond)
					for _, p := range []string{fresh, aged} {
						if b, err := os.ReadFile(p); err != nil || len(b) != 1 || b[0] != byte(r) {
							violations.Add(1)
							t.Errorf("w%d r%d: %s changed under the writer: %q %v", w, r, p, b, err)
						}
					}
					if err := unix.Lstat(dir, &after); err != nil || after.Ino != before.Ino {
						violations.Add(1)
						t.Errorf("w%d r%d: %s moved under the writer: %v", w, r, kind, err)
					}
				}
				a.touchAll()
				a.release()
				closeMounts(a.files)
				if r%5 == 4 {
					if err := cacheDirty.syncOnce(); err != nil {
						t.Errorf("sync: %v", err)
					}
				}
			}
		}(w)
	}
	wg.Wait()
	close(stop)
	janitor.Wait()
	t.Logf("held %d, skipped %d, janitor actions %d", held.Load(), skips.Load(), acted.Load())
	if violations.Load() != 0 {
		t.Fatalf("%d violations", violations.Load())
	}
	if held.Load() == 0 || acted.Load() == 0 {
		t.Fatalf("no interleaving: held %d, janitor actions %d", held.Load(), acted.Load())
	}
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if m := listDirtyMarks(); len(m) != 0 {
		t.Fatalf("marks left after every writer exited and a sync: %v", m)
	}
	res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Reason: "final"}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if res.SkippedInUse != 0 || res.SkippedDirty != 0 {
		t.Fatalf("final pass: %+v", res)
	}
	for _, kind := range []string{"gomod", "gobuild"} {
		if exists(filepath.Join(cacheRoot, "scopes/default", kind)) {
			t.Fatalf("%s survived the final wipe: %+v", kind, res)
		}
	}
}

// An unclean stop left gomod and the uid-0 pip partition marked. A janitor
// wipe is in flight (held at its hook on pip.u1000, which shares the kind-wide
// pip lock with the marked partition) when the crash recovery starts. The
// recovery waits for the pass; the pass leaves both marked units to the fence;
// the recovery then discards exactly those two. No unit is both evicted and
// discarded and no mark is left.
func TestCacheCrashDiscardWhileJanitorPassInFlight(t *testing.T) {
	setBoot, _ := useFence(t, "boot-old")
	eng := &dockerEngine{}
	u0, u1000 := uint32(0), uint32(1000)
	ages := map[string]time.Duration{"gomod": 4 * time.Hour, "pip.u0": 3 * time.Hour, "pip.u1000": 2 * time.Hour, "npm": time.Hour}
	for unit, uid := range map[string]*uint32{"gomod": nil, "pip.u0": &u0, "pip.u1000": &u1000, "npm": nil} {
		kind, _, _ := parseCacheUnit(unit)
		dir, err := ensureStore("default", kind, uid)
		if err != nil {
			t.Fatal(err)
		}
		writeAged(t, filepath.Join(dir, "entry"), 16, 0)
		if err := touchUsed("default", unit); err != nil {
			t.Fatal(err)
		}
		ts := time.Now().Add(-ages[unit])
		if err := os.Chtimes(filepath.Join(cacheRoot, ".meta/default", unit+".used"), ts, ts); err != nil {
			t.Fatal(err)
		}
	}
	// The crash: two writers' marks from the old boot, their locks gone.
	for _, unit := range []string{"gomod", "pip.u0"} {
		if err := os.WriteFile(dirtyMarker("default", unit), []byte("boot-old\n"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	setBoot("boot-new") // and no clean-stop record

	inFlight, resume := make(chan struct{}), make(chan struct{})
	cachePruneHook = func(scope, unit string) {
		if unit == "pip.u1000" {
			close(inFlight)
			<-resume
		}
	}
	pass := make(chan cachePruneResult, 1)
	go func() {
		res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", Reason: "test"}, 0)
		if err != nil {
			t.Error(err)
		}
		pass <- res
	}()
	select {
	case <-inFlight:
	case <-time.After(10 * time.Second):
		t.Fatal("the janitor pass never reached pip.u1000")
	}
	recovered := make(chan struct{})
	go func() {
		discardDirtyCaches()
		close(recovered)
	}()
	select {
	case <-recovered:
		t.Fatal("recovery ran while a janitor pass was in flight")
	case <-time.After(300 * time.Millisecond):
	}
	for _, unit := range []string{"gomod", "pip.u0"} {
		kind, uid, _ := parseCacheUnit(unit)
		if !marked("default", unit) || !exists(filepath.Join(cacheRoot, "scopes/default", cacheStoreSub(kind, uid), "entry")) {
			t.Fatalf("%s touched while both passes were in flight", unit)
		}
	}
	close(resume)
	res := <-pass
	select {
	case <-recovered:
	case <-time.After(10 * time.Second):
		t.Fatal("recovery did not run after the janitor pass")
	}
	acts := pruneActions(res)
	for unit, want := range map[string]string{"gomod": "skipped-dirty", "pip.u0": "skipped-dirty", "pip.u1000": "evicted", "npm": "evicted"} {
		if acts["default/"+unit] != want {
			t.Fatalf("janitor %s = %q, want %q (%+v)", unit, acts["default/"+unit], want, res)
		}
	}
	discarded, _ := cacheRecoveryReport()
	slices.Sort(discarded)
	if !slices.Equal(discarded, []string{"default/gomod", "default/pip.u0"}) {
		t.Fatalf("discarded %v", discarded)
	}
	if m := listDirtyMarks(); len(m) != 0 {
		t.Fatalf("marks left: %v", m)
	}
	for _, sub := range []string{"gomod", "pip/u0", "pip/u1000", "npm"} {
		if exists(filepath.Join(cacheRoot, "scopes/default", sub)) {
			t.Fatalf("%s still on disk", sub)
		}
	}
	snap := eng.inspectCaches(false)
	if len(snap.Units) != 0 || !slices.Equal(snap.DiscardedAtStart, discarded) {
		t.Fatalf("inventory after recovery: units %+v discarded %v", snap.Units, snap.DiscardedAtStart)
	}
	if got := eng.metrics.cache.snapshot()["cache_discarded_at_start"]; got != uint64(2) {
		t.Fatalf("cache_discarded_at_start = %v", got)
	}
}

// A prune waits while the maintenance lock is held (by a recovery in this or
// another process) and runs once it is released.
func TestCachePruneWaitsForRecovery(t *testing.T) {
	useFence(t, "boot-a")
	if _, err := ensureStore("default", "npm", nil); err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "npm"); err != nil {
		t.Fatal(err)
	}
	maint, err := lockCacheMaintenance(context.Background())
	if err != nil || maint == nil {
		t.Fatalf("maintenance lock: %v %v", maint, err)
	}
	done := make(chan cachePruneResult, 1)
	go func() {
		res, err := (&dockerEngine{}).pruneCaches(context.Background(), cachePruneRequest{Reason: "test"}, 0)
		if err != nil {
			t.Error(err)
		}
		done <- res
	}()
	select {
	case res := <-done:
		maint.Close()
		t.Fatalf("prune ran during a recovery: %+v", res)
	case <-time.After(300 * time.Millisecond):
	}
	maint.Close()
	select {
	case res := <-done:
		if pruneActions(res)["default/npm"] != "evicted" {
			t.Fatalf("after the recovery: %+v", res)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("prune never ran")
	}
}

// With shared L0 a plan's stores live in two scopes. Every store is locked
// and marked in its own scope, each scope bind is read-only with the scope's
// env-mode units bound writable over it, the units are stamped in their own
// scopes, and a crash discards the global unit like any other.
func TestCacheFenceWithSharedL0(t *testing.T) {
	setBoot, _ := useFence(t, "boot-a")
	pol := defaultCachePolicy()
	pol.SharedL0 = true
	plan := decide(t, pol, dockerConfig{Labels: map[string]string{"io.micropod.cache": "go", "io.micropod.cache.scope": "proj-alpha"}}, testFacts(golangEnv, nil))
	a := openCacheMounts(&plan, "")
	if len(a.skipped) != 0 {
		closeMounts(a.files)
		t.Fatalf("skipped %v", a.skipped)
	}
	targets, readonly := map[string]string{}, map[string]bool{}
	for _, m := range a.mounts {
		src, err := os.Readlink(m.HostPath)
		if err != nil {
			t.Fatal(err)
		}
		targets[m.ContainerPath], readonly[m.ContainerPath] = src, m.Readonly
	}
	for target, want := range map[string]struct {
		src string
		ro  bool
	}{
		"/micropod/cache":          {filepath.Join(cacheRoot, "scopes/proj-alpha"), true},
		"/micropod/cache/gobuild":  {filepath.Join(cacheRoot, "scopes/proj-alpha/gobuild"), false},
		"/micropod/cache-l0":       {filepath.Join(cacheRoot, "scopes/global"), true},
		"/micropod/cache-l0/gomod": {filepath.Join(cacheRoot, "scopes/global/gomod"), false},
	} {
		if targets[target] != want.src || readonly[target] != want.ro {
			t.Errorf("%s bound from %q readonly=%v, want %q readonly=%v", target, targets[target], readonly[target], want.src, want.ro)
		}
	}
	if len(a.mounts) != 4 {
		t.Errorf("mounts %v", targets)
	}
	if !marked("global", "gomod") || !marked("proj-alpha", "gobuild") || marked("proj-alpha", "gomod") || marked("global", "gobuild") {
		t.Fatal("marks are not in the stores' own scopes")
	}
	a.touchAll()
	for _, p := range []string{".meta/global/gomod.used", ".meta/proj-alpha/gobuild.used"} {
		if !exists(filepath.Join(cacheRoot, p)) {
			t.Fatalf("%s not stamped", p)
		}
	}
	if exists(filepath.Join(cacheRoot, ".meta/proj-alpha/gomod.used")) {
		t.Fatal("the L0 unit was stamped in the container's scope")
	}
	if snap := (&dockerEngine{}).inspectCaches(false); !unitUsage(t, snap, "global", "gomod").Dirty || !unitUsage(t, snap, "global", "gomod").InUse {
		t.Fatalf("global/gomod while held: %+v", snap.Units)
	}
	// The machine dies with the container running.
	writeAged(t, filepath.Join(cacheRoot, "scopes/global/gomod", "torn.mod"), 0, 0)
	closeMounts(a.files)
	setBoot("boot-b")
	discardDirtyCaches()
	discarded, _ := cacheRecoveryReport()
	slices.Sort(discarded)
	if !slices.Equal(discarded, []string{"global/gomod", "proj-alpha/gobuild"}) {
		t.Fatalf("discarded %v", discarded)
	}
	if exists(filepath.Join(cacheRoot, "scopes/global/gomod")) || exists(filepath.Join(cacheRoot, ".meta/global/gomod.used")) {
		t.Fatal("the discarded L0 unit or its stamp survived")
	}
}

func pendingClears() []string {
	cacheDirty.mu.Lock()
	defer cacheDirty.mu.Unlock()
	var out []string
	for k := range cacheDirty.pending {
		out = append(out, k)
	}
	slices.Sort(out)
	return out
}

// A read-only legacy alias volume, and a docker cp out of a stopped
// container's alias volume, hold the kind-wide unit while the descriptor is in
// use: the janitor skips the store as in use instead of emptying it under the
// reader. A reader makes no mark, so once it lets go the store is evicted.
func TestCacheJanitorHonoursReadOnlyAliasVolumes(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{workspace: t.TempDir()}
	dir, err := ensureStore("default", "gomod", nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "gomod"); err != nil {
		t.Fatal(err)
	}
	entry := filepath.Join(dir, "cache", "download", "x.mod")
	writeAged(t, entry, 16, 0)
	wipe := func() string {
		t.Helper()
		res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", Reason: "test"}, 0)
		if err != nil {
			t.Fatal(err)
		}
		return pruneActions(res)["default/gomod"]
	}

	files, _, pins, err := eng.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-gomod:/go/pkg/mod:ro"}}}, false, "")
	if err != nil || len(pins) != 1 || pins[0].unit != "gomod" {
		t.Fatalf("read-only alias pins %+v: %v", pins, err)
	}
	if act := wipe(); act != "skipped-in-use" || !exists(entry) {
		t.Fatalf("a wipe gave %q under a read-only alias reader (entry left: %v)", act, exists(entry))
	}
	if got := unitUsage(t, eng.inspectCaches(false), "default", "gomod"); !got.InUse || got.Dirty {
		t.Fatalf("under a read-only alias reader: %+v", got)
	}
	releasePins(pins)
	closeMounts(files)

	c := &dockerContainer{dockerRecord: dockerRecord{Phase: "exited"}}
	c.Config.HostConfig.Binds = []string{"micropod-ci-scoped-default-gomod:/go/pkg/mod"}
	_, closeView, err := eng.openArchive(t.Context(), c, "/go/pkg/mod/cache", false)
	if err != nil {
		t.Fatal(err)
	}
	if act := wipe(); act != "skipped-in-use" || !exists(entry) {
		closeView()
		t.Fatalf("a wipe gave %q during a docker cp out of the alias volume", act)
	}
	closeView()
	if marked("default", "gomod") {
		t.Fatal("a reader marked the store dirty")
	}
	if act := wipe(); act != "evicted" || exists(entry) {
		t.Fatalf("a wipe gave %q once the readers let go", act)
	}
}

// A legacy alias volume holds its unit before its store is created, verified
// and opened. A janitor wipe at that moment skips the unit as in use and the
// start gets the store. (The store used to be checked first and pinned after,
// so a wipe in between moved it away and the start failed with ENOENT.) The
// hold works in a scope that has no .meta directory yet.
func TestCacheAliasVolumeIsHeldBeforeItsStoreOpens(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	if _, err := ensureStore("proj", "gomod", nil); err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("proj", "gomod"); err != nil {
		t.Fatal(err)
	}
	for _, bind := range []string{"micropod-ci-scoped-proj-gomod:/go/pkg/mod", "micropod-ci-scoped-proj-gomod:/go/pkg/mod:ro"} {
		var acts map[string]string
		cacheAliasHeldHook = func(scope, kind string) {
			res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "proj", Reason: "test"}, 0)
			if err != nil {
				t.Error(err)
			}
			acts = pruneActions(res)
		}
		files, _, pins, err := eng.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{bind}}}, false, "")
		cacheAliasHeldHook = nil
		if err != nil {
			t.Fatalf("%s: the start failed: %v", bind, err)
		}
		if acts["proj/gomod"] != "skipped-in-use" {
			t.Fatalf("%s: a wipe between the hold and the open gave %v", bind, acts)
		}
		var st unix.Stat_t
		if len(files) != 1 || unix.Fstat(int(files[0].Fd()), &st) != nil {
			t.Fatalf("%s: no usable bind source", bind)
		}
		releasePins(pins)
		closeMounts(files)
	}
	files, _, pins, err := eng.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-fresh-npm:/root/.npm"}}}, false, "")
	if err != nil || len(pins) != 1 || !marked("fresh", "npm") || !exists(filepath.Join(cacheRoot, "scopes/fresh/npm")) {
		t.Fatalf("alias volume of a fresh scope: pins %+v: %v", pins, err)
	}
	releasePins(pins)
	closeMounts(files)
}

// An inventory probe (unitLockHeld) holds a unit's LOCK_EX for a moment. An
// exclusive pin (yarn v1) and a mark clearer wait that out instead of taking
// the unit for busy, which skipped yarn for a start, or left a standalone
// scheduler job's mark (it tries its clear once, then exits) for the boot. A
// real holder still makes the exclusive pin busy.
func TestCachePinAndClearerWaitOutAProbe(t *testing.T) {
	useFence(t, "boot-a")
	uid := uint32(0)
	if _, err := ensureStore("default", "yarn", &uid); err != nil {
		t.Fatal(err)
	}
	probe := func() {
		t.Helper()
		f, err := unitLock("default", "yarn.u0", true)
		if err != nil {
			t.Fatal(err)
		}
		go func() { time.Sleep(time.Millisecond); f.Close() }()
	}
	probe()
	pin, err := pinUnit("default", "yarn.u0", true)
	if err != nil {
		t.Fatalf("an exclusive pin gave up on a probe: %v", err)
	}
	pin.lock.Close() // the writer exits
	opened, err := os.Open(dirtyMarker("default", "yarn.u0"))
	if err != nil {
		t.Fatal(err)
	}
	defer opened.Close()
	probe()
	if removed, err := clearMarkIfRetired("default", "yarn.u0", opened, clearerLockWait); err != nil || !removed {
		t.Fatalf("a clearer gave up on a probe: removed=%v %v", removed, err)
	}
	holder, err := pinUnit("default", "yarn.u0", true)
	if err != nil {
		t.Fatal(err)
	}
	defer holder.lock.Close()
	start := time.Now()
	if _, err := pinUnit("default", "yarn.u0", true); !errors.Is(err, unix.EWOULDBLOCK) {
		t.Fatalf("an exclusive pin of a held store: %v", err)
	}
	if waited := time.Since(start); waited > time.Second {
		t.Fatalf("a busy exclusive pin waited %v", waited)
	}
}

// A writer killed before its release (a scheduler job's process, an alias
// volume's engine) leaves its mark with no lock held and nothing queued to
// clear it. A prune that finds such a mark under the unit's locks knows no
// writer is left: it skips the unit this time and queues this boot's mark for
// the fence's syncer, so the next pass acts. A mark from an earlier boot (one
// recovery could not discard) stays for the next start's recovery.
func TestCacheJanitorQueuesOrphanedMarks(t *testing.T) {
	useFence(t, "boot-a")
	eng := &dockerEngine{}
	plan := goPlan(t, "default")
	a := openCacheMounts(&plan, "")
	if len(a.skipped) != 0 {
		closeMounts(a.files)
		t.Fatalf("skipped %v", a.skipped)
	}
	a.touchAll()
	closeMounts(a.files) // killed: the kernel drops the locks, nothing is released
	uid := uint32(1000)
	if _, err := ensureStore("default", "pip", &uid); err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "pip.u1000"); err != nil {
		t.Fatal(err)
	}
	files, _, pins, err := eng.openMounts(dockerConfig{HostConfig: dockerHost{Binds: []string{"micropod-ci-scoped-default-pip:/cache/pip"}}}, false, "")
	if err != nil || len(pins) != 1 {
		t.Fatalf("alias pins %+v: %v", pins, err)
	}
	closeMounts(files) // the alias writer is killed too
	for _, p := range pins {
		p.lock.Close()
	}
	if _, err := ensureStore("default", "npm", nil); err != nil {
		t.Fatal(err)
	}
	if err := touchUsed("default", "npm"); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dirtyMarker("default", "npm"), []byte("boot-old\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if q := pendingClears(); len(q) != 0 {
		t.Fatalf("queued before any prune: %v", q)
	}
	wipe := func() map[string]string {
		t.Helper()
		res, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", Reason: "test"}, 0)
		if err != nil {
			t.Fatal(err)
		}
		return pruneActions(res)
	}
	dry, err := eng.pruneCaches(context.Background(), cachePruneRequest{Scope: "default", DryRun: true}, 0)
	if err != nil || dry.SkippedDirty != 4 || len(pendingClears()) != 0 {
		t.Fatalf("a dry run: %+v, queued %v: %v", dry, pendingClears(), err)
	}
	acts := wipe()
	for _, u := range []string{"gomod", "gobuild", "pip.u1000", "npm"} {
		if acts["default/"+u] != "skipped-dirty" {
			t.Fatalf("first pass: %v", acts)
		}
	}
	if q := pendingClears(); !slices.Equal(q, []string{"default/gobuild", "default/gomod", "default/pip"}) {
		t.Fatalf("queued %v", q)
	}
	if err := cacheDirty.syncOnce(); err != nil {
		t.Fatal(err)
	}
	if marked("default", "gomod") || marked("default", "gobuild") || marked("default", "pip") || !marked("default", "npm") {
		t.Fatalf("marks after the sync: %v", listDirtyMarks())
	}
	acts = wipe()
	for u, want := range map[string]string{"gomod": "evicted", "gobuild": "evicted", "pip.u1000": "evicted", "npm": "skipped-dirty"} {
		if acts["default/"+u] != want {
			t.Fatalf("second pass: %v", acts)
		}
	}
}

// POST /micropod/caches/prune waits for a janitor pass at most
// cachePruneMaintenanceWait, then answers 503 and changes nothing. A prune
// whose requester went away while it waited does nothing once the lock frees,
// and one whose requester leaves during the pass stops before the next unit.
func TestCachePruneRequestWaitIsBounded(t *testing.T) {
	useFence(t, "boot-a")
	old := cachePruneMaintenanceWait
	cachePruneMaintenanceWait = 50 * time.Millisecond
	t.Cleanup(func() { cachePruneMaintenanceWait = old })
	eng := &dockerEngine{}
	stores := []string{"npm", "uv"}
	for _, kind := range stores {
		if _, err := ensureStore("default", kind, nil); err != nil {
			t.Fatal(err)
		}
		if err := touchUsed("default", kind); err != nil {
			t.Fatal(err)
		}
	}
	left := func() int {
		n := 0
		for _, kind := range stores {
			if exists(filepath.Join(cacheRoot, "scopes/default", kind)) {
				n++
			}
		}
		return n
	}
	maint, err := lockCacheMaintenance(context.Background())
	if err != nil || maint == nil {
		t.Fatalf("maintenance lock: %v %v", maint, err)
	}
	_, err = cacheRoutes(eng, httptest.NewRecorder(), httptest.NewRequest(http.MethodPost, "/v1.47/micropod/caches/prune", nil), "POST", "micropod/caches/prune")
	var ae apiError
	if !errors.As(err, &ae) || ae.code != http.StatusServiceUnavailable {
		maint.Close()
		t.Fatalf("a prune behind a janitor pass: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := eng.pruneCaches(ctx, cachePruneRequest{Reason: "test"}, 0)
		done <- err
	}()
	time.Sleep(50 * time.Millisecond)
	cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			maint.Close()
			t.Fatalf("a prune whose requester left: %v", err)
		}
	case <-time.After(10 * time.Second):
		maint.Close()
		t.Fatal("a prune kept waiting after its requester left")
	}
	maint.Close()
	time.Sleep(50 * time.Millisecond)
	if left() != len(stores) {
		t.Fatal("a store was evicted for a requester that had gone")
	}
	ctx, cancel = context.WithCancel(context.Background())
	defer cancel()
	cachePruneHook = func(scope, unit string) { cancel() }
	res, err := eng.pruneCaches(ctx, cachePruneRequest{Reason: "test"}, 0)
	cachePruneHook = nil
	if err != nil || res.EvictedUnits != 1 || left() != 1 {
		t.Fatalf("a requester left during the pass: %+v, %d stores left: %v", res, left(), err)
	}
}
