package main

import (
	"strconv"
	"sync/atomic"
	"time"
)

// phaseHistogram counts how long one phase of a container's life took, in
// fixed buckets of milliseconds, plus the total and the longest: atomic
// adds only, so the phase it measures pays nothing measurable for it.
//
// The phases it measures are the ones a profile found time in:
//   - teardown: from the container's exit to its pod gone (the CRI stop and
//     removal: the shim's unmount, which syncs the whole filesystem of a
//     non-volatile writable layer, the network's removal, containerd's
//     commits). 364 such syncs summed 40-68 s in one burst of 32 builds
//     (profiling CONFIRMED.md §3).
//   - start: from the start request to the container's process running,
//     which waited 15-21 s for CPU behind a compile burst (§1).
type phaseHistogram struct {
	counts   [len(phaseBucketsMS) + 1]atomic.Uint64
	totalMS  atomic.Int64
	maxMS    atomic.Int64
	observed atomic.Uint64
}

// phaseBucketsMS are the upper bounds; the last count is everything above.
var phaseBucketsMS = [...]int64{10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000}

func (h *phaseHistogram) observe(d time.Duration) {
	ms := max(d.Milliseconds(), 0)
	i := 0
	for i < len(phaseBucketsMS) && ms > phaseBucketsMS[i] {
		i++
	}
	h.counts[i].Add(1)
	h.totalMS.Add(ms)
	h.observed.Add(1)
	for {
		old := h.maxMS.Load()
		if ms <= old || h.maxMS.CompareAndSwap(old, ms) {
			return
		}
	}
}

// snapshot is cumulative counts per upper bound ("le", as Prometheus has
// them; "+Inf" is the number observed), the total and the longest.
func (h *phaseHistogram) snapshot() map[string]any {
	le := make(map[string]uint64, len(phaseBucketsMS)+1)
	var running uint64
	for i, bound := range phaseBucketsMS {
		running += h.counts[i].Load()
		le[strconv.FormatInt(bound, 10)] = running
	}
	le["+Inf"] = running + h.counts[len(phaseBucketsMS)].Load()
	return map[string]any{"le_ms": le, "count": h.observed.Load(), "total_ms": h.totalMS.Load(), "max_ms": h.maxMS.Load()}
}
