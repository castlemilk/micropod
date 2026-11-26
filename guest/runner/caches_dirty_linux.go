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
// not anything kept in memory: every container that uses a unit, in any
// process (this engine, a standalone scheduler job), holds it LOCK_SH from
// before it can reach the unit until its container has exited. A writer
// (pinUnit, claimUnit) also holds the unit's mark lock
// (.meta/<scope>/<unit>.mark.lock) LOCK_SH for as long, and marked the unit
// while holding both; a reader (holdUnit) took neither the mark lock nor a
// mark.
//
//   - attach (the caller holds the lock) replaces the mark with a new file whose
//     content is this boot's id, so a mark that changed identity names a writer
//     that came after whoever looked at it, and the caller has it on disk (its
//     directory synced, markBatch) before the writer can write a byte;
//   - a mark is cleared only by someone who opened it, then completed a syncfs,
//     then took the mark lock LOCK_EX|LOCK_NB (no writer left anywhere) and
//     found the mark still the file it opened (no writer arrived since it was
//     opened);
//   - at engine start a unit whose lock is held is left alone. A mark written
//     in this boot, or in a boot guest init stopped cleanly (it adds that
//     boot's id to the clean-stop record after every process exited and its
//     final sync returned; the record keeps the last few), is cleared: its
//     writes are on disk or in this boot's page cache. Any other mark's unit
//     is moved to .trash while its locks are held.
//
// Every writable path into a store is covered: env-mode tools see the scope
// read-only with a writable bind of each unit they pinned (openCacheMounts),
// path-mode binds are per unit, and a writable legacy alias volume pins its
// kind. Readers never get a writable path into a store: an untrusted or
// read-only plan, and a container that finds an exclusive kind's writer slot
// taken, see each store through a per-container overlayfs view whose upper
// and work directories live in the container's own directory, outside the
// cache root, and go with the start (or read-only without overlayfs). A
// reader holds the store's unit LOCK_SH without a mark for as long as its
// view exists, so the janitor and recovery leave the store where the view's
// lower layer is; a read-only alias volume (or a docker cp out of one) holds
// its kind's lock the same way and, like every reader, never creates or
// repairs anything in the store. A reader never counts as a writer: it takes
// no mark lock, so a clearer clears a writer's mark once that writer exited
// even while readers (an untrusted container that sleeps) still hold the
// unit, and it makes no mark.
//
// The janitor (caches_manage_linux.go) composes with this fence through the
// same files. Lock order, one for every process:
//
//  1. the cache maintenance lock (.meta/maintenance.lock, LOCK_EX, the only
//     flock anyone waits for without a bound), taken by startup recovery and
//     by every prune or janitor pass, never by a container, a clearer or an
//     inventory read;
//  2. unit locks (.meta/<scope>/<unit>.lock), always LOCK_NB or a bounded
//     retry: the unit's own first and then its guards (cacheUnitGuards), all
//     released on the first one that is busy. Containers take them LOCK_SH;
//     recovery, the janitor and the inventory's probe LOCK_EX;
//  3. an exclusive kind's writer slot (.meta/<scope>/<unit>.writer.lock,
//     unitWriterLock), LOCK_EX|LOCK_NB and never waited for, taken only by a
//     container that already holds the unit's lock LOCK_SH (claimUnit). It
//     picks which of several containers writes the store; the fence's notion
//     of a writer stays the lock plus the mark, and nobody in 1 or 2 ever
//     looks at the slot;
//  4. the unit's mark lock (.meta/<scope>/<unit>.mark.lock, markLock), taken
//     LOCK_SH by a writer that holds 2 (and 3 for an exclusive kind), with a
//     bounded retry, and LOCK_EX|LOCK_NB with a bounded retry by a mark
//     clearer, which holds nothing else meanwhile.
//
// A pin, a hold or a clearer may retry one busy unit or mark lock for a
// bounded time (claimUnit, holdUnit, clearMarkIfRetired) and never holds the maintenance
// lock, and the holders it waits out (a probe, a clearer, a janitor batch)
// wait for nothing while they hold the lock. So no wait-for cycle can form.
// Under its unit locks the janitor checks the marks of the unit and its guards
// and skips a marked unit; a mark is only ever made under a lock it then
// holds, so none appears while it works. Those locks being free means the
// marks' writers are gone, so it queues this boot's marks for the syncer: a
// writer killed before its release left one that nobody else would clear.
// Recovery waits for a janitor pass in flight instead of meeting its locks, so
// it only ever leaves a unit marked for a real writer.
//
// Where it lives: the marks, locks, .trash and the clean-stop record are all
// below cacheRoot, on the filesystem that holds the stores. With the
// persistent cache disk (caches.ext4) that is the cache disk, so replacing the
// OS disk (disk.ext4) keeps every mark next to the record that decides it.
// Guest init mounts the cache disk before it starts the engine, so recovery
// always runs on it; when the disk should be there but is not, shared caches
// are off for the boot (cacheDiskUnavailable) and the fence does nothing:
// auto-attached caches are skipped (cache-disk-unavailable) and a legacy alias
// volume is a directory of its container's own outside cacheRoot
// (openUncachedAlias), so jobs run uncached and no store is written onto the
// OS disk.

var (
	bootIDPath = "/proc/sys/kernel/random/boot_id"
	// cleanStopPath overrides the clean-stop record (tests); empty means
	// cleanStopRecord().
	cleanStopPath = ""
	// legacyCleanStopPath is where guest init kept the record before it moved
	// to the stores' filesystem. It is honoured only while the new record is
	// missing and only when it is on the same filesystem as the stores, so a
	// guest bundle upgrade keeps the previous boot's clean stop.
	legacyCleanStopPath = "/var/lib/micropod/clean-stop"
)

// cleanStopRecord is .meta/clean-stop below cacheRoot (vmm/guest-init
// cleanstop.go writes it there).
func cleanStopRecord() string {
	if cleanStopPath != "" {
		return cleanStopPath
	}
	return filepath.Join(cacheRoot, ".meta", "clean-stop")
}

// readCleanStop returns the boot ids of the recent clean stops of the stores'
// filesystem (guest init keeps the last few, one per line, so a boot whose
// engine never started does not hide an earlier clean stop), none when nothing
// is recorded.
func readCleanStop() map[string]bool {
	clean := map[string]bool{}
	b, err := os.ReadFile(cleanStopRecord())
	if errors.Is(err, os.ErrNotExist) && cleanStopPath == "" {
		var legacy, stores unix.Stat_t
		if unix.Stat(legacyCleanStopPath, &legacy) == nil && unix.Stat(cacheRoot, &stores) == nil && legacy.Dev == stores.Dev {
			b, err = os.ReadFile(legacyCleanStopPath)
		}
	}
	if err == nil {
		for _, id := range strings.Fields(string(b)) {
			clean[id] = true
		}
	}
	return clean
}

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

// attach marks a unit dirty for one writer: a new file naming this boot is
// renamed into place. The caller already holds the unit's lock, so no clearer
// can be between its checks. The mark is not yet durable when attach returns;
// the caller adds its scope to a markBatch and lets no writer in before the
// batch's sync has succeeded (claimUnit, openCacheMounts).
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

// markBatch is the scopes in which one start made new marks (attach). Its
// sync puts them on disk with one fsync of each scope's mark directory, so a
// start that marks several units of a scope pays for one journal commit, not
// one per unit.
//
// Why the marks must be on disk before a writer writes. Ordering alone is not
// enough: a rename the journal has not committed yet is lost by a crash, and a
// writer's bytes can reach the disk without any journal commit at all: an
// overwrite in place that the tool fdatasyncs (SQLite does, pnpm's index.db is
// one) or that writeback flushes under memory pressure. A kill -9 of the VMM
// inside the first commit interval then left that unit changed and unmarked,
// and recovery kept it (scripts/gates/phase-b.sh B2X).
//
// Why the directory's sync is enough. ext4 makes a directory's fsync a full
// journal commit (ext4_sync_file forces the running transaction for anything
// but a regular file), and that transaction, or an earlier one, holds every
// mark's create and rename, so all of them survive any later crash. The mark's
// content need not: after a crash the boot it names is not this one and not a
// clean stop, so recovery discards the unit whatever the mark holds, and a
// mark whose content was lost (empty, or cut short) names no boot at all and
// is discarded too (TestCacheMarkWithoutItsContentDiscards). A boot that stops
// cleanly syncs every mark's content before guest init records it. What must
// not happen is a mark that survives naming a cleanly stopped boot it never
// held, which only stale block contents could give; ext4's data=ordered never
// exposes those (a file's size reaches the journal only with its blocks
// written), and it is the mode of the stores' filesystem: ext4's default, and
// the journal mode HVFMachineInstaller.provisionCacheDisk formats the cache
// disk with.
type markBatch map[string]bool

func (b markBatch) add(scope string) { b[scope] = true }

// sync fsyncs each scope's mark directory and returns the scopes whose sync
// failed. A mark in place but not durable is still a mark: its unit stays
// marked (the janitor queues it once no writer holds it); its writer must
// not be let in.
func (b markBatch) sync() map[string]error {
	failed := map[string]error{}
	for scope := range b {
		if err := syncMarkDir(filepath.Join(cacheRoot, ".meta", scope)); err != nil {
			failed[scope] = err
		}
	}
	return failed
}

// syncMarkDir makes the new marks of one directory durable (tests observe it).
var syncMarkDir = syncDir

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
		switch removed, err := clearMarkIfRetired(c.scope, c.unit, c.mark, clearerLockWait); {
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

// clearerLockWait is how long a mark clearer waits out a busy unit lock. An
// inventory probe or the janitor's mark check holds a unit's LOCK_EX for
// microseconds; a writer holds its lock until its container exits. Without the
// wait a standalone scheduler job, which tries its clear once and exits, could
// meet a probe and leave its mark for the rest of the boot.
const clearerLockWait = 20 * time.Millisecond

// clearMarkIfRetired removes the unit's mark if no writer holds the unit (its
// mark lock, markLock, is free: a reader holds only the unit lock and does
// not count) and the mark is still the file opened before the caller's sync.
// A busy lock is retried for up to wait. It reports whether it removed the
// mark.
func clearMarkIfRetired(scope, unit string, opened *os.File, wait time.Duration) (bool, error) {
	lock, err := markLockWaiting(scope, unit, true, wait)
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
	if cacheDiskUnavailable() != "" {
		return
	}
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
		// No wait: the units running containers hold are common here and
		// stay marked anyway (guest init's clean-stop record covers them).
		if _, err := clearMarkIfRetired(m[0], m[1], opened[i], 0); err != nil && !errors.Is(err, errUnitHeld) {
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
// Only unit locks are guards: an exclusive kind's writer slot
// (<kind>.u<uid>.writer.lock, step 3 of the lock order) also ends in .lock but
// names no unit, and nobody in steps 1 or 2 may take it. (parseCacheUnit is in
// caches_manage_linux.go.)
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
		u, ok := strings.CutSuffix(e.Name(), ".lock")
		if !ok {
			continue
		}
		if k, id, ok := parseCacheUnit(u); ok && k == kind && id != nil {
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

// markedGuards returns every one of units that has a dirty mark.
func markedGuards(scope string, units []string) []string {
	var out []string
	for _, u := range units {
		if _, err := os.Lstat(dirtyMarker(scope, u)); err == nil {
			out = append(out, u)
		}
	}
	return out
}

// markOfThisBoot reports whether the unit's mark names this boot. Only such a
// mark may be cleared after a sync once its writers are gone; one from an
// earlier boot is left for the next start's recovery to keep or discard.
func markOfThisBoot(scope, unit string) bool {
	boot := currentBootID()
	b, err := os.ReadFile(dirtyMarker(scope, unit))
	return err == nil && boot != "" && strings.TrimSpace(string(b)) == boot
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

// discardDirtyCaches runs at engine start, before the socket opens (guest init
// has mounted the cache disk by then). It holds the cache maintenance lock
// throughout, so a janitor or prune pass in flight finishes first and none
// starts until recovery is done (in production none can be in flight: the
// janitor starts after this returns and one engine owns the guest). A unit
// still held by a writer or a reader (another process) is left alone. A mark
// from this boot or from a cleanly stopped boot is cleared after a sync.
// Every other marked unit may hold torn entries and is moved to .trash under
// its locks, with the used stamps of what it held (the inventory and the
// janitor's LRU then no longer list a store that is gone).
func discardDirtyCaches() {
	if why := cacheDiskUnavailable(); why != "" {
		return // nothing below the mount point is a store this boot
	}
	if maint, err := lockCacheMaintenance(context.Background()); err != nil {
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
	clean := readCleanStop()
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
		if from := strings.TrimSpace(string(b)); from != "" && (from == boot || clean[from]) {
			keep = append(keep, m) // on disk (clean stop) or in this boot's page cache
			continue
		}
		if len(clean) == 0 {
			log.Printf("cache %s/%s: no clean-stop record", scope, unit)
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
