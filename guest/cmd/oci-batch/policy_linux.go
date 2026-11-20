package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	specs "github.com/opencontainers/runtime-spec/specs-go"
)

// Placement and scheduling apply only to this worker's offline job cgroups.
type launchPolicy struct {
	oneThread       bool
	window          int
	batch, affinity bool
}

var allocationCPUs []int

func policyFor(name string, n int) (launchPolicy, error) {
	switch name {
	case "", "default":
		// Gamma's two interleaved trials favored SCHED_BATCH in four of five 32-job pairs each.
		// Keep the ordinary scheduler for worker sizes and smaller batches outside that measurement.
		useBatch := native && n >= 32 && len(allocationCPUs) == 4 && os.Getenv("MICROPOD_JOB_RUNTIME") == "runc"
		return launchPolicy{batch: useBatch}, nil
	case "parallel":
		return launchPolicy{}, nil
	case "single":
		return launchPolicy{oneThread: true}, nil
	case "window4", "window8", "window16":
		window, _ := strconv.Atoi(strings.TrimPrefix(name, "window"))
		return launchPolicy{oneThread: true, window: window}, nil
	case "affinity":
		return launchPolicy{affinity: true}, nil
	case "batch":
		return launchPolicy{batch: true}, nil
	case "batch-affinity":
		return launchPolicy{batch: true, affinity: true}, nil
	default:
		return launchPolicy{}, errors.New("unknown OCI scheduling policy")
	}
}
func cpuList(raw string) ([]int, error) {
	var cpus []int
	for _, part := range strings.Split(strings.TrimSpace(raw), ",") {
		a, b, span := strings.Cut(part, "-")
		lo, err := strconv.Atoi(a)
		if err != nil || lo < 0 {
			return nil, fmt.Errorf("invalid CPU range %q", part)
		}
		hi := lo
		if span {
			hi, err = strconv.Atoi(b)
			if err != nil || hi < lo {
				return nil, fmt.Errorf("invalid CPU range %q", part)
			}
		}
		if hi >= 8192 {
			return nil, errors.New("unsupported CPU range")
		}
		for i := lo; i <= hi; i++ {
			cpus = append(cpus, i)
		}
	}
	return cpus, nil
}
func (p launchPolicy) apply(s *specs.Spec, index int) error {
	if p.batch {
		s.Process.Scheduler = &specs.Scheduler{Policy: specs.SchedBatch}
	}
	if p.affinity {
		if len(allocationCPUs) == 0 {
			return errors.New("worker has no delegated cpuset")
		}
		res := *s.Linux.Resources
		cpu := *res.CPU
		cpu.Cpus = strconv.Itoa(allocationCPUs[index%len(allocationCPUs)])
		res.CPU = &cpu
		s.Linux.Resources = &res
	}
	return nil
}
func availableCPUs(parent string, controllers string) ([]int, error) {
	if !strings.Contains(" "+strings.TrimSpace(controllers)+" ", " cpuset ") {
		return nil, nil
	}
	buf, err := os.ReadFile(parent + "/cpuset.cpus.effective")
	if err != nil {
		return nil, err
	}
	return cpuList(string(buf))
}
