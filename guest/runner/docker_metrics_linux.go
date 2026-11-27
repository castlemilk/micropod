package main

import (
	"sync"
	"sync/atomic"
	"time"
)

// Boot-scoped totals avoid per-container and per-image metric cardinality.
type dockerMetrics struct {
	networks                                                          networkMetrics
	api                                                               apiMetrics
	reaper                                                            reaperMetrics
	setupWaitUS                                                       atomic.Int64
	creates, completions, failures, imageHits, prepared, sharedMounts atomic.Uint64
	podMS, createMS, startMS                                          atomic.Int64
	cache                                                             cacheMetrics
}

// cacheMetrics counts auto-attach decisions: attaches per tool, skips per
// reason (create-time rules and start-time busy/store failures), probes,
// bounded LRU eviction measurements and the units prunes left to the crash
// fence because they were marked dirty.
type cacheMetrics struct {
	mu                    sync.Mutex
	attach, skips         map[string]uint64
	probes, probeFailures uint64
	probeMS               int64
	evictions             uint64
	evictedUnits          uint64
	evictedFiles          uint64
	evictedBytes          uint64
	lastSweepUnix         int64
	lastSweepReason       string
	pruneSkippedDirty     uint64
}

func (m *cacheMetrics) recordSkippedDirty(units uint64) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.pruneSkippedDirty += units
}

func (m *cacheMetrics) recordEviction(units, files, bytes uint64, reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.evictions++
	m.evictedUnits += units
	m.evictedFiles += files
	m.evictedBytes += bytes
	m.lastSweepUnix = time.Now().Unix()
	m.lastSweepReason = reason
}

type cacheEvictionSummary struct {
	Evictions       uint64 `json:"evictions"`
	EvictedUnits    uint64 `json:"evictedUnits"`
	EvictedFiles    uint64 `json:"evictedFiles"`
	EvictedBytes    uint64 `json:"evictedBytes"`
	LastSweepUnix   int64  `json:"lastSweepUnix,omitempty"`
	LastSweepReason string `json:"lastSweepReason,omitempty"`
}

func (m *cacheMetrics) evictionSummary() cacheEvictionSummary {
	m.mu.Lock()
	defer m.mu.Unlock()
	return cacheEvictionSummary{
		Evictions:       m.evictions,
		EvictedUnits:    m.evictedUnits,
		EvictedFiles:    m.evictedFiles,
		EvictedBytes:    m.evictedBytes,
		LastSweepUnix:   m.lastSweepUnix,
		LastSweepReason: m.lastSweepReason,
	}
}

func (m *cacheMetrics) recordPlan(p *cachePlan) {
	if p == nil {
		return
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.attach == nil {
		m.attach, m.skips = map[string]uint64{}, map[string]uint64{}
	}
	if p.Reason != "" && len(p.Tools) == 0 {
		m.skips[p.Reason]++
	}
	for tool, st := range p.Tools {
		if st.Mode == "skipped" {
			if st.Reason != skipNotSelected {
				m.skips[st.Reason]++
			}
		} else {
			m.attach[tool]++
		}
	}
}

func (m *cacheMetrics) skip(reason string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.skips == nil {
		m.attach, m.skips = map[string]uint64{}, map[string]uint64{}
	}
	m.skips[reason]++
}

func (m *cacheMetrics) recordProbe(ms int64, ok bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.probes++
	m.probeMS += ms
	if !ok {
		m.probeFailures++
	}
}

func (m *cacheMetrics) snapshot() map[string]any {
	// The crash fence's startup recovery (caches_dirty_linux.go), read before
	// m.mu so the two mutexes are never held together.
	discarded, kept := cacheRecoveryReport()
	m.mu.Lock()
	defer m.mu.Unlock()
	attach, skips := map[string]uint64{}, map[string]uint64{}
	for k, v := range m.attach {
		attach[k] = v
	}
	for k, v := range m.skips {
		skips[k] = v
	}
	return map[string]any{
		"cache_attach":              attach,
		"cache_skip":                skips,
		"cache_probes":              m.probes,
		"cache_probe_failures":      m.probeFailures,
		"cache_probe_ms":            m.probeMS,
		"cache_evictions":           m.evictions,
		"cache_evicted_units":       m.evictedUnits,
		"cache_evicted_files":       m.evictedFiles,
		"cache_evicted_bytes":       m.evictedBytes,
		"cache_last_sweep_unix":     m.lastSweepUnix,
		"cache_prune_skipped_dirty": m.pruneSkippedDirty,
		"cache_discarded_at_start":  uint64(len(discarded)),
		"cache_kept_at_start":       uint64(len(kept)),
	}
}

func (m *dockerMetrics) record(r result, err error) {
	m.completions.Add(1)
	if err != nil {
		m.failures.Add(1)
	}
	if r.Hit {
		m.imageHits.Add(1)
	}
	if r.Prepared {
		m.prepared.Add(1)
	}
	m.podMS.Add(r.PodMS)
	m.createMS.Add(r.CreateMS)
	m.startMS.Add(r.StartMS)
}
func (m *dockerMetrics) snapshot() map[string]any {
	out := map[string]any{"containers_created": m.creates.Load(), "runs_finished": m.completions.Load(), "runtime_failures": m.failures.Load(), "image_cache_hits": m.imageHits.Load(), "prepared_pods_used": m.prepared.Load(), "shared_cache_attachments": m.sharedMounts.Load(), "pod_ms_total": m.podMS.Load(), "create_ms_total": m.createMS.Load(), "start_ms_total": m.startMS.Load(),
		// The container records' saves: durable ones (a journal commit each)
		// and ones that need only be whole (records_sync_linux.go).
		"record_commits": recordCommits.Load(), "record_writes": recordWrites.Load(),
		"image_syncs": imageSyncs.Load(), "image_sync_usec_total": imageSyncUS.Load(),
		"image_sync_fs_usec_total": imageSyncFSUS.Load()}
	for k, v := range m.cache.snapshot() {
		out[k] = v
	}
	return out
}
