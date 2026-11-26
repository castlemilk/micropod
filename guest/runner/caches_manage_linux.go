package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"log"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	// Bound every automated janitor sweep so a misreading disk or clock skew
	// can never wipe the cache in one pass.
	janitorMaxUnitsPerSweep        = 50
	janitorMaxPartialFilesPerSweep = 10000
	defaultPartialSafetyCutoffSecs = 600 // 10 minutes
	janitorInterval                = 5 * time.Minute
)

func (p *cachePlan) scopeFor(override string) string {
	if override != "" {
		return override
	}
	if p == nil {
		return ""
	}
	return p.Scope
}

// parseCacheUnit splits a unit identifier ("gobuild" or "pip.u1000") into kind
// and optional uid.
func parseCacheUnit(unit string) (kind string, uid *uint32, ok bool) {
	if idx := strings.Index(unit, ".u"); idx > 0 {
		k := unit[:idx]
		if cacheToolByKind(k) == nil {
			return "", nil, false
		}
		n, err := strconv.ParseUint(unit[idx+2:], 10, 32)
		if err != nil {
			return "", nil, false
		}
		u := uint32(n)
		return k, &u, true
	}
	if cacheToolByKind(unit) == nil {
		return "", nil, false
	}
	return unit, nil, true
}

func cacheLayerForKind(kind string) string {
	if t := cacheToolByKind(kind); t != nil && t.Layer != "" {
		return t.Layer
	}
	return cacheLayerL0
}

type cacheUnitUsage struct {
	Scope        string  `json:"scope"`
	Kind         string  `json:"kind"`
	Unit         string  `json:"unit"`
	UID          *uint32 `json:"uid,omitempty"`
	Layer        string  `json:"layer"`
	Path         string  `json:"path"`
	Bytes        uint64  `json:"bytes"`
	LogicalBytes uint64  `json:"logicalBytes"`
	Files        uint64  `json:"files"`
	LastUsedUnix int64   `json:"lastUsedUnix"`
	InUse        bool    `json:"inUse"`
}

type cacheTotals struct {
	TotalBytes   uint64 `json:"totalBytes"`
	LogicalBytes uint64 `json:"logicalBytes"`
	TotalFiles   uint64 `json:"totalFiles"`
	ScopeCount   int    `json:"scopeCount"`
	UnitCount    int    `json:"unitCount"`
	InUseCount   int    `json:"inUseCount"`
	L0Bytes      uint64 `json:"l0Bytes"`
	L1Bytes      uint64 `json:"l1Bytes"`
}

type cacheBudgetStatus struct {
	MaxBytes       uint64   `json:"maxBytes"`
	MinFreeBytes   uint64   `json:"minFreeBytes"`
	MaxAgeDays     int      `json:"maxAgeDays"`
	UtilizationPct *float64 `json:"utilizationPct,omitempty"`
}

type cacheInspection struct {
	Root         string               `json:"root"`
	MountPoint   string               `json:"mountPoint"`
	MountL0Point string               `json:"mountL0Point"`
	Policy       cachePolicy          `json:"policy"`
	PolicyDigest string               `json:"policyDigest"`
	Scopes       map[string][]string  `json:"scopes"`
	Units        []cacheUnitUsage     `json:"units"`
	Totals       cacheTotals          `json:"totals"`
	Budget       cacheBudgetStatus    `json:"budget"`
	Evictions    cacheEvictionSummary `json:"evictions"`
	Metrics      map[string]any       `json:"metrics"`
}

// isUnitInUse probes unitLock non-blockingly with LOCK_EX|LOCK_NB. Because
// containers take LOCK_SH (or LOCK_EX for yarn v1) across both Docker and CI
// scheduler processes, EWOULDBLOCK accurately detects any live writer/reader.
func isUnitInUse(scope, unit string) bool {
	lockPath := filepath.Join(cacheRoot, ".meta", scope, unit+".lock")
	f, err := os.OpenFile(lockPath, os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		return false
	}
	defer f.Close()
	err = unix.Flock(int(f.Fd()), unix.LOCK_EX|unix.LOCK_NB)
	if errors.Is(err, unix.EWOULDBLOCK) {
		return true
	}
	if err == nil {
		_ = unix.Flock(int(f.Fd()), unix.LOCK_UN)
	}
	return false
}

func walkDirUsage(dir string) (diskBytes, logicalBytes, files uint64) {
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		files++
		if info.Size() > 0 {
			logicalBytes += uint64(info.Size())
		}
		if st, ok := info.Sys().(*syscall.Stat_t); ok && st.Blocks > 0 {
			diskBytes += uint64(st.Blocks) * 512
		} else if info.Size() > 0 {
			diskBytes += uint64(info.Size())
		}
		return nil
	})
	return diskBytes, logicalBytes, files
}

func discoverCacheUnits() (map[string][]string, []cacheUnitUsage) {
	scopes := map[string][]string{}
	seen := map[string]map[string]bool{}
	entries, _ := os.ReadDir(filepath.Join(cacheRoot, "scopes"))
	for _, e := range entries {
		if !e.IsDir() || !scopeName.MatchString(e.Name()) {
			continue
		}
		scope := e.Name()
		seen[scope] = map[string]bool{}
		units := []string{}
		// 1. Units recorded in .meta/<scope>/*.used (preserves existing behavior)
		metaEntries, _ := os.ReadDir(filepath.Join(cacheRoot, ".meta", scope))
		for _, m := range metaEntries {
			if u, ok := strings.CutSuffix(m.Name(), ".used"); ok {
				if _, _, valid := parseCacheUnit(u); valid {
					units = append(units, u)
					seen[scope][u] = true
				}
			}
		}
		// 2. Also pick up on-disk unit dirs whose .used stamp was missing
		kindEntries, _ := os.ReadDir(filepath.Join(cacheRoot, "scopes", scope))
		for _, ke := range kindEntries {
			if !ke.IsDir() {
				continue
			}
			t := cacheToolByKind(ke.Name())
			if t == nil {
				continue
			}
			if t.Partition {
				subEntries, _ := os.ReadDir(filepath.Join(cacheRoot, "scopes", scope, t.Kind))
				for _, se := range subEntries {
					if !se.IsDir() || !strings.HasPrefix(se.Name(), "u") {
						continue
					}
					u := t.Kind + "." + se.Name()
					if _, _, valid := parseCacheUnit(u); valid && !seen[scope][u] {
						units = append(units, u)
						seen[scope][u] = true
					}
				}
			} else if !seen[scope][t.Kind] {
				units = append(units, t.Kind)
				seen[scope][t.Kind] = true
			}
		}
		sort.Strings(units)
		scopes[scope] = units
	}

	scopeNames := make([]string, 0, len(scopes))
	for s := range scopes {
		scopeNames = append(scopeNames, s)
	}
	sort.Strings(scopeNames)

	var out []cacheUnitUsage
	for _, scope := range scopeNames {
		for _, unit := range scopes[scope] {
			kind, uid, ok := parseCacheUnit(unit)
			if !ok {
				continue
			}
			relSub := cacheStoreSub(kind, uid)
			storeDir := filepath.Join(cacheRoot, "scopes", scope, relSub)
			var lastUsed int64
			if st, err := os.Stat(filepath.Join(cacheRoot, ".meta", scope, unit+".used")); err == nil {
				lastUsed = st.ModTime().Unix()
			} else if st, err := os.Stat(storeDir); err == nil {
				lastUsed = st.ModTime().Unix()
			}
			out = append(out, cacheUnitUsage{
				Scope:        scope,
				Kind:         kind,
				Unit:         unit,
				UID:          uid,
				Layer:        cacheLayerForKind(kind),
				Path:         path.Join("scopes", scope, relSub),
				LastUsedUnix: lastUsed,
				InUse:        isUnitInUse(scope, unit),
			})
		}
	}
	return scopes, out
}

func (s *dockerEngine) inspectCaches(includeStats bool) cacheInspection {
	pol := s.cachePolicy.get()
	scopes, units := discoverCacheUnits()
	var totals cacheTotals
	totals.ScopeCount = len(scopes)
	totals.UnitCount = len(units)
	for i := range units {
		if includeStats {
			dir := filepath.Join(cacheRoot, units[i].Path)
			units[i].Bytes, units[i].LogicalBytes, units[i].Files = walkDirUsage(dir)
		}
		totals.TotalBytes += units[i].Bytes
		totals.LogicalBytes += units[i].LogicalBytes
		totals.TotalFiles += units[i].Files
		if units[i].InUse {
			totals.InUseCount++
		}
		if units[i].Layer == cacheLayerL1 {
			totals.L1Bytes += units[i].Bytes
		} else {
			totals.L0Bytes += units[i].Bytes
		}
	}
	budget := cacheBudgetStatus{
		MaxBytes:     pol.MaxBytes,
		MinFreeBytes: pol.MinFreeBytes,
		MaxAgeDays:   pol.MaxAgeDays,
	}
	if pol.MaxBytes > 0 {
		pct := float64(totals.TotalBytes) * 100.0 / float64(pol.MaxBytes)
		pct = float64(int64(pct*10+0.5)) / 10.0
		budget.UtilizationPct = &pct
	}
	return cacheInspection{
		Root:         cacheRoot,
		MountPoint:   cacheMountRoot,
		MountL0Point: cacheMountL0Root,
		Policy:       pol,
		PolicyDigest: pol.digest(),
		Scopes:       scopes,
		Units:        units,
		Totals:       totals,
		Budget:       budget,
		Evictions:    s.metrics.cache.evictionSummary(),
		Metrics:      s.metrics.cache.snapshot(),
	}
}

// ---- Cross-scope Go build-cache dedupe sampler ----

type cacheDedupeSample struct {
	ScopesSampled               []string `json:"scopesSampled"`
	BucketsSampled              int      `json:"bucketsSampled"`
	TotalObjects                uint64   `json:"totalObjects"`
	UniqueObjects               uint64   `json:"uniqueObjects"`
	DuplicateObjects            uint64   `json:"duplicateObjects"`
	DuplicateBytes              uint64   `json:"duplicateBytes"`
	EstimatedFullDuplicateBytes uint64   `json:"estimatedFullDuplicateBytes"`
}

// sampleCacheDedupe samples the first `buckets` (1..256) hex shard directories
// of Go build caches across all scopes on disk, reporting cross-scope identical
// content-addressed objects (actionID-d / actionID-a) and wasted bytes.
func sampleCacheDedupe(buckets int) cacheDedupeSample {
	if buckets < 1 {
		buckets = 16
	}
	if buckets > 256 {
		buckets = 256
	}
	entries, _ := os.ReadDir(filepath.Join(cacheRoot, "scopes"))
	var scopes []string
	for _, e := range entries {
		if !e.IsDir() || !scopeName.MatchString(e.Name()) {
			continue
		}
		if st, err := os.Stat(filepath.Join(cacheRoot, "scopes", e.Name(), "gobuild")); err == nil && st.IsDir() {
			scopes = append(scopes, e.Name())
		}
	}
	sort.Strings(scopes)

	res := cacheDedupeSample{
		ScopesSampled:  scopes,
		BucketsSampled: buckets,
	}
	if len(scopes) == 0 {
		res.ScopesSampled = []string{}
		return res
	}
	type objKey struct {
		bucket string
		name   string
		size   int64
	}
	seen := map[objKey]int{}
	for b := 0; b < buckets; b++ {
		bucket := fmt.Sprintf("%02x", b)
		for _, scope := range scopes {
			bdir := filepath.Join(cacheRoot, "scopes", scope, "gobuild", bucket)
			files, err := os.ReadDir(bdir)
			if err != nil {
				continue
			}
			for _, f := range files {
				if f.IsDir() {
					continue
				}
				info, err := f.Info()
				if err != nil {
					continue
				}
				sz := info.Size()
				if sz <= 0 {
					continue
				}
				res.TotalObjects++
				k := objKey{bucket: bucket, name: f.Name(), size: sz}
				seen[k]++
				if seen[k] > 1 {
					res.DuplicateObjects++
					res.DuplicateBytes += uint64(sz)
				}
			}
		}
	}
	res.UniqueObjects = uint64(len(seen))
	if buckets > 0 {
		res.EstimatedFullDuplicateBytes = (res.DuplicateBytes * 256) / uint64(buckets)
	}
	return res
}

// ---- Bounded LRU Janitor & Prune ----

type cachePruneRequest struct {
	Scope            string `json:"scope,omitempty"`
	Tool             string `json:"tool,omitempty"`
	OlderThanSecs    int64  `json:"olderThanSecs,omitempty"`
	MaxBytes         uint64 `json:"maxBytes,omitempty"`
	PartialGoBuild   *bool  `json:"partialGoBuild,omitempty"`
	SafetyCutoffSecs int64  `json:"safetyCutoffSecs,omitempty"`
	MaxUnits         int    `json:"maxUnits,omitempty"`
	DryRun           bool   `json:"dryRun,omitempty"`
	Reason           string `json:"reason,omitempty"`
}

type cachePruneAction struct {
	Scope  string `json:"scope"`
	Unit   string `json:"unit"`
	Action string `json:"action"` // "evicted", "partial-evicted", "skipped-in-use", "would-evict", "would-partial-evict"
	Files  uint64 `json:"files,omitempty"`
	Bytes  uint64 `json:"bytes"`
}

type cachePruneResult struct {
	DryRun       bool               `json:"dryRun"`
	Reason       string             `json:"reason"`
	FreedBytes   uint64             `json:"freedBytes"`
	FreedFiles   uint64             `json:"freedFiles"`
	EvictedUnits uint64             `json:"evictedUnits"`
	SkippedInUse uint64             `json:"skippedInUse"`
	BeforeBytes  uint64             `json:"beforeBytes"`
	AfterBytes   uint64             `json:"afterBytes"`
	Actions      []cachePruneAction `json:"actions"`
}

func (s *dockerEngine) handleCachePrune(w http.ResponseWriter, r *http.Request) error {
	var req cachePruneRequest
	if r.Body != nil && r.ContentLength != 0 {
		b, err := readBody(w, r)
		if err != nil {
			return err
		}
		if len(strings.TrimSpace(string(b))) > 0 {
			if err := json.Unmarshal(b, &req); err != nil {
				return fail(400, "invalid cache prune request JSON")
			}
		}
	}
	q := r.URL.Query()
	if v := q.Get("scope"); v != "" && req.Scope == "" {
		req.Scope = v
	}
	if v := q.Get("tool"); v != "" && req.Tool == "" {
		req.Tool = v
	}
	if v := q.Get("older_than_secs"); v != "" && req.OlderThanSecs == 0 {
		n, err := strconv.ParseInt(v, 10, 64)
		if err != nil || n < 0 {
			return fail(400, "invalid older_than_secs")
		}
		req.OlderThanSecs = n
	}
	if v := q.Get("max_bytes"); v != "" && req.MaxBytes == 0 {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return fail(400, "invalid max_bytes")
		}
		req.MaxBytes = n
	}
	if truth(q.Get("dry_run")) {
		req.DryRun = true
	}
	if v := q.Get("partial"); v != "" && req.PartialGoBuild == nil {
		b := truth(v)
		req.PartialGoBuild = &b
	}
	if req.Scope != "" && !scopeName.MatchString(req.Scope) {
		return fail(400, "invalid cache scope")
	}
	if req.Tool != "" {
		if _, ok := expandCacheTool(req.Tool); !ok {
			return fail(400, fmt.Sprintf("unknown cache tool %q", req.Tool))
		}
	}
	res, err := s.pruneCaches(req)
	if err != nil {
		return err
	}
	writeJSON(w, 200, res)
	return nil
}

// evictPartialGoBuild performs safe, mtime-ordered partial eviction inside a
// Go build-cache store (`00..ff` shard files) while holding LOCK_EX|LOCK_NB,
// skipping any file newer than safetyCutoff so hot/active compile objects are
// never removed.
func evictPartialGoBuild(dir string, targetFree uint64, safetyCutoff time.Time, dryRun bool) (freedBytes, freedFiles uint64) {
	type shardFile struct {
		path  string
		mtime int64
		bytes uint64
	}
	var candidates []shardFile
	for b := 0; b < 256; b++ {
		bdir := filepath.Join(dir, fmt.Sprintf("%02x", b))
		entries, err := os.ReadDir(bdir)
		if err != nil {
			continue
		}
		for _, e := range entries {
			if e.IsDir() || e.Type()&fs.ModeSymlink != 0 {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			if !safetyCutoff.IsZero() && info.ModTime().After(safetyCutoff) {
				continue
			}
			var sz uint64
			if st, ok := info.Sys().(*syscall.Stat_t); ok && st.Blocks > 0 {
				sz = uint64(st.Blocks) * 512
			} else if info.Size() > 0 {
				sz = uint64(info.Size())
			}
			candidates = append(candidates, shardFile{
				path:  filepath.Join(bdir, e.Name()),
				mtime: info.ModTime().UnixNano(),
				bytes: sz,
			})
		}
	}
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].mtime != candidates[j].mtime {
			return candidates[i].mtime < candidates[j].mtime
		}
		return candidates[i].path < candidates[j].path
	})
	for _, c := range candidates {
		if targetFree > 0 && freedBytes >= targetFree {
			break
		}
		if freedFiles >= janitorMaxPartialFilesPerSweep {
			break
		}
		if !dryRun {
			if err := os.Remove(c.path); err != nil && !errors.Is(err, os.ErrNotExist) {
				continue
			}
		}
		freedBytes += c.bytes
		freedFiles++
	}
	return freedBytes, freedFiles
}

// evictWholeUnit moves an unlocked cache unit into .trash under LOCK_EX|LOCK_NB,
// deletes its .used stamp, releases the lock, and removes the trashed directory.
func evictWholeUnit(scope, kind string, uid *uint32, unit string) error {
	l, err := openCacheLayout()
	if err != nil {
		return err
	}
	defer l.Close()

	scopeDir, err := openDirNoFollow(int(l.scopes.Fd()), scope, filepath.Join(l.scopes.Name(), scope))
	if err != nil {
		if errors.Is(err, unix.ENOENT) {
			return nil
		}
		return err
	}
	defer scopeDir.Close()

	var parent *os.File
	var targetName string
	if uid == nil {
		parent = scopeDir
		targetName = kind
	} else {
		kindDir, err := openDirNoFollow(int(scopeDir.Fd()), kind, filepath.Join(scopeDir.Name(), kind))
		if err != nil {
			if errors.Is(err, unix.ENOENT) {
				return nil
			}
			return err
		}
		defer kindDir.Close()
		parent = kindDir
		targetName = "u" + strconv.FormatUint(uint64(*uid), 10)
	}

	trashed := trashName(scope + "-" + unit)
	if err := unix.Renameat(int(parent.Fd()), targetName, int(l.trash.Fd()), trashed); err != nil {
		if !errors.Is(err, unix.ENOENT) {
			return err
		}
		trashed = ""
	}
	_ = os.Remove(filepath.Join(cacheRoot, ".meta", scope, unit+".used"))
	if trashed != "" {
		_ = os.RemoveAll(filepath.Join(cacheRoot, ".trash", trashed))
	}
	return nil
}

func (s *dockerEngine) pruneCaches(req cachePruneRequest) (cachePruneResult, error) {
	now := time.Now()
	reason := req.Reason
	if reason == "" {
		reason = "manual"
	}
	safetySecs := req.SafetyCutoffSecs
	if safetySecs <= 0 {
		safetySecs = defaultPartialSafetyCutoffSecs
	}
	maxUnits := req.MaxUnits
	if maxUnits <= 0 {
		maxUnits = janitorMaxUnitsPerSweep
	}
	var allowedKinds []string
	if req.Tool != "" {
		var ok bool
		allowedKinds, ok = expandCacheTool(req.Tool)
		if !ok {
			return cachePruneResult{}, fail(400, fmt.Sprintf("unknown cache tool %q", req.Tool))
		}
	}

	snap := s.inspectCaches(true)
	res := cachePruneResult{
		DryRun:      req.DryRun,
		Reason:      reason,
		BeforeBytes: snap.Totals.TotalBytes,
		AfterBytes:  snap.Totals.TotalBytes,
		Actions:     []cachePruneAction{},
	}

	// Select eligible units by scope/tool filter
	var eligible []cacheUnitUsage
	for _, u := range snap.Units {
		if req.Scope != "" && u.Scope != req.Scope {
			continue
		}
		if len(allowedKinds) > 0 && !slices.Contains(allowedKinds, u.Kind) {
			continue
		}
		eligible = append(eligible, u)
	}
	// Strict LRU order: oldest LastUsedUnix first
	sort.Slice(eligible, func(i, j int) bool {
		if eligible[i].LastUsedUnix != eligible[j].LastUsedUnix {
			return eligible[i].LastUsedUnix < eligible[j].LastUsedUnix
		}
		if eligible[i].Scope != eligible[j].Scope {
			return eligible[i].Scope < eligible[j].Scope
		}
		return eligible[i].Unit < eligible[j].Unit
	})

	budgetMode := req.MaxBytes > 0
	ageMode := req.OlderThanSecs > 0
	explicitWipe := !budgetMode && !ageMode
	partialGoBuild := budgetMode
	if req.PartialGoBuild != nil {
		partialGoBuild = *req.PartialGoBuild
	}
	ageCutoff := now.Add(-time.Duration(req.OlderThanSecs) * time.Second).Unix()
	safetyCutoff := now.Add(-time.Duration(safetySecs) * time.Second)

	remainingBytes := snap.Totals.TotalBytes
	var touchedUnits int

	for _, u := range eligible {
		if touchedUnits >= maxUnits {
			break
		}
		needAge := ageMode && u.LastUsedUnix > 0 && u.LastUsedUnix < ageCutoff
		needBudget := budgetMode && remainingBytes > req.MaxBytes
		if !explicitWipe && !needAge && !needBudget {
			continue
		}

		// Rule 1: Never evict in-flight. Acquire non-blocking LOCK_EX before touching.
		lock, err := unitLock(u.Scope, u.Unit, true)
		if err != nil {
			if errors.Is(err, unix.EWOULDBLOCK) {
				res.SkippedInUse++
				res.Actions = append(res.Actions, cachePruneAction{
					Scope:  u.Scope,
					Unit:   u.Unit,
					Action: "skipped-in-use",
					Bytes:  u.Bytes,
				})
				continue
			}
			continue
		}

		// Rule 5: Partial mtime-ordered eviction for Go build cache under budget
		// pressure avoids all-or-nothing cold rebuilds.
		if u.Kind == "gobuild" && partialGoBuild && !explicitWipe && !needAge {
			var targetFree uint64
			if remainingBytes > req.MaxBytes {
				targetFree = remainingBytes - req.MaxBytes
			}
			fb, ff := evictPartialGoBuild(filepath.Join(cacheRoot, u.Path), targetFree, safetyCutoff, req.DryRun)
			lock.Close()
			if ff > 0 {
				touchedUnits++
				res.FreedBytes += fb
				res.FreedFiles += ff
				if remainingBytes > fb {
					remainingBytes -= fb
				} else {
					remainingBytes = 0
				}
				act := "partial-evicted"
				if req.DryRun {
					act = "would-partial-evict"
				}
				res.Actions = append(res.Actions, cachePruneAction{
					Scope:  u.Scope,
					Unit:   u.Unit,
					Action: act,
					Files:  ff,
					Bytes:  fb,
				})
			}
			continue
		}

		if req.DryRun {
			lock.Close()
			touchedUnits++
			res.FreedBytes += u.Bytes
			res.FreedFiles += u.Files
			res.EvictedUnits++
			if remainingBytes > u.Bytes {
				remainingBytes -= u.Bytes
			} else {
				remainingBytes = 0
			}
			res.Actions = append(res.Actions, cachePruneAction{
				Scope:  u.Scope,
				Unit:   u.Unit,
				Action: "would-evict",
				Files:  u.Files,
				Bytes:  u.Bytes,
			})
			continue
		}

		evictErr := evictWholeUnit(u.Scope, u.Kind, u.UID, u.Unit)
		lock.Close()
		if evictErr != nil {
			log.Printf("cache prune %s/%s: %v", u.Scope, u.Unit, evictErr)
			continue
		}
		touchedUnits++
		res.FreedBytes += u.Bytes
		res.FreedFiles += u.Files
		res.EvictedUnits++
		if remainingBytes > u.Bytes {
			remainingBytes -= u.Bytes
		} else {
			remainingBytes = 0
		}
		res.Actions = append(res.Actions, cachePruneAction{
			Scope:  u.Scope,
			Unit:   u.Unit,
			Action: "evicted",
			Files:  u.Files,
			Bytes:  u.Bytes,
		})
	}

	res.AfterBytes = remainingBytes
	if !req.DryRun && (res.FreedBytes > 0 || res.EvictedUnits > 0 || res.FreedFiles > 0) {
		s.metrics.cache.recordEviction(res.EvictedUnits, res.FreedFiles, res.FreedBytes, reason)
	}
	return res, nil
}

func sweepCacheTrash() {
	trashDir := filepath.Join(cacheRoot, ".trash")
	entries, err := os.ReadDir(trashDir)
	if err != nil {
		return
	}
	for _, e := range entries {
		_ = os.RemoveAll(filepath.Join(trashDir, e.Name()))
	}
}

func (s *dockerEngine) runCacheJanitorPass() {
	pol := s.cachePolicy.get()
	if pol.MaxBytes == 0 && pol.MaxAgeDays == 0 && pol.MinFreeBytes == 0 {
		return
	}
	targetMax := pol.MaxBytes
	if pol.MinFreeBytes > 0 {
		var st unix.Statfs_t
		if unix.Statfs(cacheRoot, &st) == nil {
			avail := st.Bavail * uint64(st.Bsize)
			if avail < pol.MinFreeBytes {
				deficit := pol.MinFreeBytes - avail
				snap := s.inspectCaches(true)
				var pressureTarget uint64
				if snap.Totals.TotalBytes > deficit {
					pressureTarget = snap.Totals.TotalBytes - deficit
				} else {
					pressureTarget = 1
				}
				if targetMax == 0 || pressureTarget < targetMax {
					targetMax = pressureTarget
				}
			}
		}
	}
	if targetMax == 0 && pol.MaxAgeDays == 0 {
		return
	}
	partial := true
	res, err := s.pruneCaches(cachePruneRequest{
		MaxBytes:       targetMax,
		OlderThanSecs:  int64(pol.MaxAgeDays) * 86400,
		PartialGoBuild: &partial,
		MaxUnits:       janitorMaxUnitsPerSweep,
		Reason:         "janitor",
	})
	if err != nil {
		log.Printf("cache janitor sweep failed: %v", err)
		return
	}
	if res.FreedBytes > 0 || res.EvictedUnits > 0 {
		log.Printf("cache janitor freed %d bytes (%d units, %d files, skipped_in_use=%d)", res.FreedBytes, res.EvictedUnits, res.FreedFiles, res.SkippedInUse)
	}
}

func (s *dockerEngine) runCacheJanitor(ctx context.Context) {
	ticker := time.NewTicker(janitorInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.runCacheJanitorPass()
		}
	}
}
