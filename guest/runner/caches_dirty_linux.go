package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// Crash safety of the shared stores.
//
// Tools write cache entries to a temporary name and rename them into place
// without fsync (Go's module cache does). On ext4 with delayed allocation the
// journal can commit such a rename seconds before the file's data reaches the
// disk, so a kill -9 of the VMM leaves zero-length entries behind (measured:
// two empty .mod files in gomod, after which `go mod verify` and every build
// failed with a checksum mismatch for every container of the scope). A shared
// store would keep serving that damage until someone cleaned it by hand.
//
// So a unit is marked dirty (.meta/<scope>/<unit>.dirty) before any writer can
// touch it, and the mark goes only when no writer is left and a sync has put
// their writes on disk. Ownership is the unit lock (.meta/<scope>/<unit>.lock),
// not anything kept in memory: every writer, in any process (this engine, a
// standalone scheduler job), holds it LOCK_SH (yarn v1 LOCK_EX) from before it
// marks the unit until its container has exited.
//
//   - attach (the caller holds the lock) replaces the mark with a new file whose
//     content is this boot's id, so a mark that changed identity names a writer
//     that came after whoever looked at it;
//   - a mark is cleared only by someone who opened it, then completed a syncfs,
//     then took the lock LOCK_EX|LOCK_NB (no writer left anywhere) and found the
//     mark still the file it opened (no writer arrived since it was opened);
//   - at engine start a unit whose lock is held is left alone. A mark written
//     in this boot, or in the boot guest init stopped cleanly (it writes
//     cleanStopPath with that boot's id after every process exited and its final
//     sync returned), is cleared: its writes are on disk or in this boot's page
//     cache. Any other mark's unit is moved to .trash while its locks are held.
//
// Every writable path into a store is covered: env-mode tools see the scope
// read-only with a writable bind of each unit they attached (openCacheMounts),
// path-mode binds are per unit, and a legacy alias volume pins its kind.
//
// The janitor (caches_manage_linux.go) composes with this fence through the
// same files. Lock order: the cache maintenance lock (.meta/maintenance.lock,
// LOCK_EX, the only flock anyone waits for) is taken by startup recovery and by
// every prune or janitor pass, never by a writer, clearer or inventory read;
// then unit locks, always LOCK_NB, the unit's own first and then its guards
// (cacheUnitGuards), all released on the first one that is busy. Nobody waits
// for a flock while holding another, so no wait-for cycle can form. Under its
// unit locks the janitor checks the marks of the unit and its guards and skips
// a marked unit; a mark is only ever made under a lock it then holds, so none
// appears while it works. Recovery waits for a janitor pass in flight instead
// of meeting its locks, so it only ever leaves a unit marked for a real writer.

var (
	bootIDPath    = "/proc/sys/kernel/random/boot_id"
	cleanStopPath = "/var/lib/micropod/clean-stop"
)

type cacheDirtyTracker struct {
	mu      sync.Mutex
	pending map[string]int // scope/unit released here and not yet cleared -> attempts left
	kick    chan struct{}
}

var cacheDirty = newCacheDirtyTracker()

func newCacheDirtyTracker() *cacheDirtyTracker {
	return &cacheDirtyTracker{pending: map[string]int{}, kick: make(chan struct{}, 1)}
}

func dirtyMarker(scope, unit string) string {
	return filepath.Join(cacheRoot, ".meta", scope, unit+".dirty")
}

func unitLockPath(scope, unit string) string {
	return filepath.Join(cacheRoot, ".meta", scope, unit+".lock")
}

// currentBootID is this kernel's boot id, "" if it cannot be read.
func currentBootID() string {
	b, err := os.ReadFile(bootIDPath)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// attach marks a unit dirty for one writer. The caller already holds the
// unit's lock, so no clearer can be between its checks. The new mark is a
// journaled rename made before any of the writer's own metadata changes, so any
// rename of the writer's that survives a crash implies the mark did too.
func (t *cacheDirtyTracker) attach(scope, unit string) error {
	dir := filepath.Join(cacheRoot, ".meta", scope)
	var b [6]byte
	_, _ = rand.Read(b[:])
	tmp := filepath.Join(dir, "."+unit+".dirty."+hex.EncodeToString(b[:]))
	f, err := os.OpenFile(tmp, os.O_CREATE|os.O_EXCL|os.O_WRONLY|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return err
	}
	_, err = f.WriteString(currentBootID() + "\n")
	if err = errors.Join(err, f.Close()); err == nil {
		err = os.Rename(tmp, dirtyMarker(scope, unit))
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// release queues a unit whose writer here has exited (and closed its lock) for
// a clear; the syncer clears the mark once no writer is left anywhere.
func (t *cacheDirtyTracker) release(scope, unit string) {
	t.mu.Lock()
	t.pending[scope+"/"+unit] = 3
	t.mu.Unlock()
	select {
	case t.kick <- struct{}{}:
	default:
	}
}

// syncOnce tries to clear the marks of the units released here: it opens each
// mark, syncs the cache filesystem, then clears the marks whose units no writer
// holds and that nobody replaced since they were opened. A unit another writer
// still holds is that writer's to clear when it exits; one whose lock is held
// only briefly (its container's files are being closed) is retried twice.
func (t *cacheDirtyTracker) syncOnce() error {
	t.mu.Lock()
	snap := t.pending
	t.pending = map[string]int{}
	t.mu.Unlock()
	if len(snap) == 0 {
		return nil
	}
	type candidate struct {
		scope, unit string
		left        int
		mark        *os.File
	}
	var cands []candidate
	for k, left := range snap {
		scope, unit, _ := strings.Cut(k, "/")
		f, err := os.OpenFile(dirtyMarker(scope, unit), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			log.Printf("cache %s: open dirty mark: %v", k, err)
			continue
		}
		cands = append(cands, candidate{scope, unit, left, f})
	}
	defer func() {
		for _, c := range cands {
			c.mark.Close()
		}
	}()
	if len(cands) == 0 {
		return nil
	}
	if err := syncCacheFS(); err != nil {
		t.requeue(snap)
		return err
	}
	cleared := 0
	for _, c := range cands {
		switch removed, err := clearMarkIfRetired(c.scope, c.unit, c.mark); {
		case removed:
			cleared++
		case errors.Is(err, errUnitHeld):
			if c.left > 1 {
				t.mu.Lock()
				if _, again := t.pending[c.scope+"/"+c.unit]; !again {
					t.pending[c.scope+"/"+c.unit] = c.left - 1
				}
				t.mu.Unlock()
			}
		case err != nil:
			log.Printf("cache %s/%s: clear dirty mark: %v", c.scope, c.unit, err)
		}
	}
	if cleared > 0 {
		// Commit the removals now rather than at the next journal commit, so
		// a crash seconds later does not discard units that were clean.
		return syncCacheFS()
	}
	return nil
}

func (t *cacheDirtyTracker) requeue(snap map[string]int) {
	t.mu.Lock()
	defer t.mu.Unlock()
	for k, left := range snap {
		if _, again := t.pending[k]; !again {
			t.pending[k] = left
		}
	}
}

var errUnitHeld = errors.New("a writer still holds the unit")

// clearMarkIfRetired removes the unit's mark if no writer holds the unit and
// the mark is still the file opened before the caller's sync. It reports
// whether it removed the mark.
func clearMarkIfRetired(scope, unit string, opened *os.File) (bool, error) {
	lock, err := unitLock(scope, unit, true)
	if errors.Is(err, unix.EWOULDBLOCK) {
		return false, errUnitHeld
	} else if err != nil {
		return false, err
	}
	defer lock.Close()
	var was, now unix.Stat_t
	if err := unix.Fstat(int(opened.Fd()), &was); err != nil {
		return false, err
	}
	path := dirtyMarker(scope, unit)
	if err := unix.Lstat(path, &now); errors.Is(err, unix.ENOENT) {
		return false, nil
	} else if err != nil {
		return false, err
	}
	if was.Dev != now.Dev || was.Ino != now.Ino {
		return false, nil // a newer writer marked it; that writer clears it
	}
	if err := os.Remove(path); err != nil {
		return false, err
	}
	return true, nil
}

// run clears marks a couple of seconds after containers exit (coalescing
// exits that arrive together) until ctx ends.
func (t *cacheDirtyTracker) run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.kick:
		}
		for {
			select {
			case <-ctx.Done():
				return
			case <-time.After(2 * time.Second):
			}
			if err := t.syncOnce(); err != nil {
				log.Printf("cache sync: %v", err)
			}
			t.mu.Lock()
			more := len(t.pending) > 0
			t.mu.Unlock()
			if !more {
				break
			}
		}
	}
}

// shutdown is the engine's orderly stop: clear the mark of every unit no
// writer holds any more. Units still held (containers keep running until guest
// init stops them) stay marked; guest init's clean-stop record covers them.
func (t *cacheDirtyTracker) shutdown() {
	var opened []*os.File
	var marks [][2]string
	for _, m := range listDirtyMarks() {
		f, err := os.OpenFile(dirtyMarker(m[0], m[1]), os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			continue
		}
		opened = append(opened, f)
		marks = append(marks, m)
	}
	defer closeMounts(opened)
	if len(marks) == 0 {
		return
	}
	if err := syncCacheFS(); err != nil {
		log.Printf("cache sync at shutdown: %v", err)
		return
	}
	for i, m := range marks {
		if _, err := clearMarkIfRetired(m[0], m[1], opened[i]); err != nil && !errors.Is(err, errUnitHeld) {
			log.Printf("cache %s/%s: clear dirty mark: %v", m[0], m[1], err)
		}
	}
	if err := syncCacheFS(); err != nil {
		log.Printf("cache sync at shutdown: %v", err)
	}
}

func syncCacheFS() error {
	f, err := os.Open(cacheRoot)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	defer f.Close()
	return unix.Syncfs(int(f.Fd()))
}

// listDirtyMarks returns {scope, unit} for every .meta/<scope>/<unit>.dirty.
func listDirtyMarks() [][2]string {
	var out [][2]string
	scopes, _ := os.ReadDir(filepath.Join(cacheRoot, ".meta"))
	for _, s := range scopes {
		if !s.IsDir() || !scopeName.MatchString(s.Name()) {
			continue
		}
		entries, _ := os.ReadDir(filepath.Join(cacheRoot, ".meta", s.Name()))
		for _, e := range entries {
			if unit, ok := strings.CutSuffix(e.Name(), ".dirty"); ok && !strings.HasPrefix(unit, ".") && e.Type().IsRegular() {
				out = append(out, [2]string{s.Name(), unit})
			}
		}
	}
	return out
}

// cacheUnitGuards lists the units whose locks a writer into unit's directory
// holds: the unit itself and, for a partitioned kind, the kind-wide unit a
// legacy alias volume pins (for a partition, whose directory it contains) or
// every partition with a lock file (for the kind-wide unit, whose directory
// holds them all). The unit comes first and the rest in name order, so every
// holder of several (startup recovery, the janitor) takes them in one order.
// (parseCacheUnit is in caches_manage_linux.go.)
func cacheUnitGuards(scope, unit string) []string {
	units := []string{unit}
	kind, uid, ok := parseCacheUnit(unit)
	if !ok || !cacheToolByKind(kind).Partition {
		return units
	}
	if uid != nil {
		return append(units, kind)
	}
	entries, _ := os.ReadDir(filepath.Join(cacheRoot, ".meta", scope))
	for _, e := range entries {
		if u, ok := strings.CutSuffix(e.Name(), ".lock"); ok && strings.HasPrefix(u, kind+".u") {
			units = append(units, u)
		}
	}
	return units
}

// markedGuard returns the first of units (a cacheUnitGuards list) that has a
// dirty mark: a writer may have left unsynced entries in the guarded directory.
func markedGuard(scope string, units []string) (string, bool) {
	for _, u := range units {
		if _, err := os.Lstat(dirtyMarker(scope, u)); err == nil {
			return u, true
		}
	}
	return "", false
}

// cacheDiscarded lists the units this boot moved to .trash and cacheKept the
// marked units it kept (marked in this boot or a cleanly stopped one), for
// GET /micropod/caches and the engine metrics. Recovery appends to them under
// cacheRecoveryMu; readers copy them with cacheRecoveryReport.
var (
	cacheRecoveryMu           sync.Mutex
	cacheDiscarded, cacheKept []string
)

// cacheRecoveryReport copies what startup recovery discarded and kept.
func cacheRecoveryReport() (discarded, kept []string) {
	cacheRecoveryMu.Lock()
	defer cacheRecoveryMu.Unlock()
	return append([]string{}, cacheDiscarded...), append([]string{}, cacheKept...)
}

// discardDirtyCaches runs at engine start, before the socket opens. It holds
// the cache maintenance lock throughout, so a janitor or prune pass in flight
// finishes first and none starts until recovery is done (in production none
// can be in flight: the janitor starts after this returns and one engine owns
// the guest). A unit still held by a writer (another process) is left alone. A
// mark from this boot or from a cleanly stopped boot is cleared after a sync.
// Every other marked unit may hold torn entries and is moved to .trash under
// its locks, with the used stamps of what it held (the inventory and the
// janitor's LRU then no longer list a store that is gone).
func discardDirtyCaches() {
	if maint, err := lockCacheMaintenance(); err != nil {
		log.Printf("cache recovery: maintenance lock: %v", err)
	} else if maint != nil {
		defer maint.Close()
	}
	removeMarkTemps()
	marks := listDirtyMarks()
	if len(marks) == 0 {
		go emptyCacheTrash()
		return
	}
	boot := currentBootID()
	clean := ""
	if b, err := os.ReadFile(cleanStopPath); err == nil {
		clean = strings.TrimSpace(string(b))
	}
	l, err := openCacheLayout()
	if err != nil {
		log.Printf("cache recovery: %v", err)
		return
	}
	defer l.Close()
	held := map[string]*os.File{} // scope/unit -> our LOCK_EX, until the end
	defer func() {
		for _, f := range held {
			f.Close()
		}
	}()
	var keep [][2]string
	for _, m := range marks {
		scope, unit := m[0], m[1]
		if err := lockForDiscard(held, scope, unit); err != nil {
			if errors.Is(err, unix.EWOULDBLOCK) {
				log.Printf("cache %s/%s: still held by a running writer; left marked", scope, unit)
			} else {
				log.Printf("cache %s/%s: lock for recovery: %v", scope, unit, err)
			}
			continue
		}
		b, _ := os.ReadFile(dirtyMarker(scope, unit))
		if from := strings.TrimSpace(string(b)); from != "" && (from == boot || from == clean) {
			keep = append(keep, m) // on disk (clean stop) or in this boot's page cache
			continue
		}
		if clean == "" {
			log.Printf("cache %s/%s: no clean-stop record from the previous boot", scope, unit)
		}
		if err := discardUnit(l, scope, unit); err != nil {
			log.Printf("cache %s/%s: discard after an unclean stop: %v", scope, unit, err)
			continue
		}
		if err := os.Remove(dirtyMarker(scope, unit)); err != nil && !errors.Is(err, os.ErrNotExist) {
			log.Printf("cache %s/%s: clear dirty mark: %v", scope, unit, err)
		}
		// The stamps of every unit whose directory went with it (all
		// partitions, for a kind-wide unit); their locks are held here.
		inside := []string{unit}
		if kind, uid, ok := parseCacheUnit(unit); ok && uid == nil && cacheToolByKind(kind).Partition {
			inside = cacheUnitGuards(scope, unit)
		}
		for _, u := range inside {
			if err := os.Remove(filepath.Join(cacheRoot, ".meta", scope, u+".used")); err != nil && !errors.Is(err, os.ErrNotExist) {
				log.Printf("cache %s/%s: remove used stamp: %v", scope, u, err)
			}
		}
		cacheRecoveryMu.Lock()
		cacheDiscarded = append(cacheDiscarded, scope+"/"+unit)
		cacheRecoveryMu.Unlock()
		log.Printf("cache %s/%s: discarded: the machine stopped while it could hold unsynced writes", scope, unit)
	}
	if err := unix.Syncfs(int(l.root.Fd())); err != nil {
		log.Printf("cache recovery sync: %v", err)
	} else {
		for _, m := range keep {
			if err := os.Remove(dirtyMarker(m[0], m[1])); err != nil && !errors.Is(err, os.ErrNotExist) {
				log.Printf("cache %s/%s: clear dirty mark: %v", m[0], m[1], err)
				continue
			}
			cacheRecoveryMu.Lock()
			cacheKept = append(cacheKept, m[0]+"/"+m[1])
			cacheRecoveryMu.Unlock()
			log.Printf("cache %s/%s: kept: its last writers stopped with the boot cleanly (or this boot is still running)", m[0], m[1])
		}
	}
	go emptyCacheTrash()
}

// lockForDiscard takes LOCK_EX|LOCK_NB on every lock whose holder could write
// into the unit's directory (cacheUnitGuards). Locks already in held are this
// function's own from an earlier mark; new ones are added. On a busy lock it
// drops the ones it took for this unit and returns the error.
func lockForDiscard(held map[string]*os.File, scope, unit string) error {
	var taken []string
	for _, u := range cacheUnitGuards(scope, unit) {
		k := scope + "/" + u
		if held[k] != nil {
			continue
		}
		f, err := unitLock(scope, u, true)
		if err != nil {
			for _, t := range taken {
				held[t].Close()
				delete(held, t)
			}
			return err
		}
		held[k] = f
		taken = append(taken, k)
	}
	return nil
}

// removeMarkTemps deletes mark temporaries a crash left between create and rename.
func removeMarkTemps() {
	scopes, _ := os.ReadDir(filepath.Join(cacheRoot, ".meta"))
	for _, s := range scopes {
		if !s.IsDir() || !scopeName.MatchString(s.Name()) {
			continue
		}
		dir := filepath.Join(cacheRoot, ".meta", s.Name())
		entries, _ := os.ReadDir(dir)
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), ".") && strings.Contains(e.Name(), ".dirty.") && e.Type().IsRegular() {
				os.Remove(filepath.Join(dir, e.Name()))
			}
		}
	}
}

// discardUnit renames scopes/<scope>/<kind>[/u<uid>] into .trash without
// following a symlink anywhere on the way.
func discardUnit(l cacheLayout, scope, unit string) error {
	kind, uid, ok := parseCacheUnit(unit)
	if !ok || !scopeName.MatchString(scope) {
		return fmt.Errorf("not a cache unit")
	}
	scopeDir, err := openDirNoFollow(int(l.scopes.Fd()), scope, filepath.Join(l.scopes.Name(), scope))
	if errors.Is(err, unix.ENOENT) {
		return nil
	} else if err != nil {
		return err
	}
	defer scopeDir.Close()
	parent, name := scopeDir, kind
	if uid != nil {
		kindDir, err := openDirNoFollow(int(scopeDir.Fd()), kind, filepath.Join(scopeDir.Name(), kind))
		if errors.Is(err, unix.ENOENT) {
			return nil
		} else if err != nil {
			return err
		}
		defer kindDir.Close()
		parent, name = kindDir, "u"+strconv.FormatUint(uint64(*uid), 10)
	}
	err = unix.Renameat(int(parent.Fd()), name, int(l.trash.Fd()), trashName(scope+"."+unit))
	if errors.Is(err, unix.ENOENT) {
		return nil
	}
	return err
}

// emptyCacheTrash deletes what earlier boots and this one moved to .trash.
func emptyCacheTrash() {
	dir := filepath.Join(cacheRoot, ".trash")
	entries, _ := os.ReadDir(dir)
	for _, e := range entries {
		if err := os.RemoveAll(filepath.Join(dir, e.Name())); err != nil {
			log.Printf("cache trash %s: %v", e.Name(), err)
		}
	}
}
