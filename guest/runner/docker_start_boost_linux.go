package main

import (
	"errors"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// A young container may start ahead of the CPU-bound ones around it. Off
// unless the machine asks for it.
//
// Every Docker container's cgroup is a child of /k8s.io at the default CPU
// weight. With the boost on, the engine asks crun to create each container's
// cgroup with the highest weight, and gives it the default weight back
// startBoostWindow after the container's process started (or never, if it
// exits first: its cgroup is gone). A request that names its CPU shares
// keeps them, and nothing is written to the container's record: inspect
// still shows what was asked.
//
// Why it is off by default. It was written when `docker run alpine echo ok`
// took 15-21 s under 32 cold builds, which turned out to be the pod's
// sandbox cgroup at weight 1 (sandbox_shares_linux.go). With that fixed, on
// throwaway machines of 16 vCPUs, the boost at 4 s against no boost:
//
//   - 60 sequential `docker run --rm alpine true` under 32 busy loops: p50
//     0.34-0.36 s against 0.35-0.37 s, p95 0.54-0.57 s against 0.45 s, max
//     0.66-1.01 s against 0.49-0.50 s (2 interleaved rounds each);
//   - the same starts during 16 cold Go builds: p50 2.0-2.3 s against
//     2.1-2.4 s, and the builds 17.9-19.1 s against 17.5-20.6 s;
//   - a container that was already running, while 8 streams kept starting
//     containers that each burn 4 CPUs for 3 s: it got 14.5-15.0 % of the
//     loop iterations it makes alone against 45.7-46.4 % (2 rounds each).
//
// So it bought no start time and took two thirds of an established
// container's CPU for as long as new CPU-bound containers kept arriving: a
// long build or a service container waits behind every newcomer.
// micropod.start_boost_ms=<milliseconds> in machine.json's kernelArguments
// (start.sh exports it as MICROPOD_START_BOOST_MS) turns it on for a
// measurement.
const (
	// crun maps CPU shares to a cgroup v2 weight as 1 + (shares-2)*9999/262142:
	// the largest shares are the largest weight.
	startBoostShares = 262144
	startBoostWeight = "10000"
	// The kernel's default weight, which a container that names no shares
	// otherwise has for its whole life.
	defaultCPUWeight = "100"
)

// startBoostWindow is how long a container keeps the boost after its start:
// MICROPOD_START_BOOST_MS in the engine's environment, and 0 (the default)
// is no boost.
var startBoostWindow = startBoostDuration(os.Getenv("MICROPOD_START_BOOST_MS"))

func startBoostDuration(raw string) time.Duration {
	if raw == "" {
		return 0
	}
	ms, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || ms < 0 || ms > 60_000 {
		log.Printf("ignoring MICROPOD_START_BOOST_MS=%q (0 to 60000 milliseconds); no start boost", raw)
		return 0
	}
	return time.Duration(ms) * time.Millisecond
}

// startBoostMetrics counts boosts given, weights given back, and weights that
// could not be given back (a cgroup that is not where it should be).
type startBoostMetrics struct {
	boosted, restored, restoreFailures atomic.Uint64
}

func (m *startBoostMetrics) snapshot() map[string]any {
	return map[string]any{
		"start_boosts": m.boosted.Load(), "start_boost_restores": m.restored.Load(),
		"start_boost_restore_failures": m.restoreFailures.Load(), "start_boost_window_ms": startBoostWindow.Milliseconds(),
	}
}

// boostStartShares gives a container that names no CPU shares the boosted
// shares for its creation. It reports whether it did.
func boostStartShares(r *cri.LinuxContainerResources, window time.Duration) bool {
	if window <= 0 || r == nil || r.CpuShares != 0 {
		return false
	}
	r.CpuShares = startBoostShares
	return true
}

// dockerRuntimeCgroup is the cgroup crun makes for a Docker container's
// runtime container: /k8s.io/<id>, or under its job parent
// (specWithJobParent).
func dockerRuntimeCgroup(root, jobParent, id string) string {
	return filepath.Join(root, jobParent, id)
}

// restoreStartWeight gives a boosted cgroup the default weight back, and
// reports whether it did. A weight that is no longer the boost's was set by
// someone else and stays; a cgroup that is gone belongs to a container that
// has already exited.
func restoreStartWeight(cgroup string) (bool, error) {
	file := filepath.Join(cgroup, "cpu.weight")
	raw, err := os.ReadFile(file)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if strings.TrimSpace(string(raw)) != startBoostWeight {
		return false, nil
	}
	err = os.WriteFile(file, []byte(defaultCPUWeight), 0)
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	return err == nil, err
}

// scheduleStartBoostEnd gives the weight back after the window. The caller
// stops the returned timer when the container exits.
func (s *dockerEngine) scheduleStartBoostEnd(cgroup string, window time.Duration) *time.Timer {
	return time.AfterFunc(window, func() {
		restored, err := restoreStartWeight(cgroup)
		if err != nil {
			s.metrics.startBoost.restoreFailures.Add(1)
			log.Printf("start boost: give %s its CPU weight back: %v", cgroup, err)
		} else if restored {
			s.metrics.startBoost.restored.Add(1)
		}
	})
}
