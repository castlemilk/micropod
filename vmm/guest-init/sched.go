package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// The fair scheduler's base slice: how long a CPU-bound task may run before
// a task that just woke on its CPU gets to run. The kernel's default is
// 0.7 ms scaled by 1+log2(min(CPUs, 8)), 2.8 ms on the machine's 16 vCPUs, so
// with every CPU busy compiling, a container start waits for one or more
// slices at each of its many wake-ups (engine, containerd, shim, crun, the
// container's process). With 32 busy loops on 16 vCPUs, 0.4 ms took
// `docker run` p50 from 0.77-1.13 s to 0.45-0.56 s in 5 of 7 interleaved
// pairs and lower in all 7 (the Mac busy with another machine: 1.1-2.6 s to
// 0.9-2.0 s), and cost no throughput: 16 concurrent cold `go build`s
// 19.0-20.1 s against 19.3-21.9 s at 2.8 ms, 500 short runs 7.8-8.5 s both.
//
// mp.sched_base_slice_ns (machine.json kernelArguments) sets another slice,
// in nanoseconds (0.1 to 100 ms, the kernel's range for a task's own slice),
// or "default" keeps the kernel's. start.sh's micropod.ci_sched hrtick-*
// settings, which run later, still set their own.
const (
	schedSliceArg       = "mp.sched_base_slice_ns"
	defaultSchedSliceNs = 400_000
	minSchedSliceNs     = 100_000
	maxSchedSliceNs     = 100_000_000
)

// schedSlice is the base slice to set: ok false keeps the kernel's. A value
// it cannot use is reported and the default is set.
func schedSlice(params map[string]string) (ns uint64, ok bool, err error) {
	value, present := params[schedSliceArg]
	if !present {
		return defaultSchedSliceNs, true, nil
	}
	if value == "default" {
		return 0, false, nil
	}
	n, perr := strconv.ParseUint(value, 10, 64)
	if perr != nil || n < minSchedSliceNs || n > maxSchedSliceNs {
		return defaultSchedSliceNs, true, fmt.Errorf("%s=%q is not a slice of %d to %d ns or \"default\"; using %d ns",
			schedSliceArg, value, minSchedSliceNs, maxSchedSliceNs, defaultSchedSliceNs)
	}
	return n, true, nil
}

// setSchedSlice writes ns as the base slice in debug, a mounted debugfs, and
// returns the slice before and after. The debugfs file sets the live value
// only, and the kernel recomputes it from a CPU-count-normalized copy
// whenever a run queue comes online (a sched domain rebuild, a CPU coming
// up); rewriting tunable_scaling with its own value makes the kernel derive
// that copy from the new slice, so the slice survives those.
func setSchedSlice(debug string, ns uint64) (before, after uint64, err error) {
	slice := filepath.Join(debug, "sched", "base_slice_ns")
	scaling := filepath.Join(debug, "sched", "tunable_scaling")
	read := func(path string) (uint64, error) {
		b, err := os.ReadFile(path)
		if err != nil {
			return 0, err
		}
		return strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64)
	}
	if before, err = read(slice); err != nil {
		return 0, 0, fmt.Errorf("read %s: %w", slice, err)
	}
	if err = os.WriteFile(slice, []byte(strconv.FormatUint(ns, 10)), 0); err != nil {
		return before, before, fmt.Errorf("write %s: %w", slice, err)
	}
	mode, err := read(scaling)
	if err != nil {
		return before, ns, fmt.Errorf("read %s: %w", scaling, err)
	}
	if err = os.WriteFile(scaling, []byte(strconv.FormatUint(mode, 10)), 0); err != nil {
		return before, ns, fmt.Errorf("write %s: %w", scaling, err)
	}
	if after, err = read(slice); err != nil {
		return before, ns, fmt.Errorf("read %s: %w", slice, err)
	}
	if after != ns {
		return before, after, fmt.Errorf("the kernel kept a base slice of %d ns, not %d", after, ns)
	}
	return before, after, nil
}
