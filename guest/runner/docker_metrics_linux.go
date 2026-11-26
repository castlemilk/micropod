package main

import "sync/atomic"

// Boot-scoped totals avoid per-container and per-image metric cardinality.
type dockerMetrics struct {
	networks                                                          networkMetrics
	api                                                               apiMetrics
	reaper                                                            reaperMetrics
	setupWaitUS                                                       atomic.Int64
	creates, completions, failures, imageHits, prepared, sharedMounts atomic.Uint64
	podMS, createMS, startMS                                          atomic.Int64
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
	return map[string]any{"containers_created": m.creates.Load(), "runs_finished": m.completions.Load(), "runtime_failures": m.failures.Load(), "image_cache_hits": m.imageHits.Load(), "prepared_pods_used": m.prepared.Load(), "shared_cache_attachments": m.sharedMounts.Load(), "pod_ms_total": m.podMS.Load(), "create_ms_total": m.createMS.Load(), "start_ms_total": m.startMS.Load()}
}
