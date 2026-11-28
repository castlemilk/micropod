package main

import (
	"log"
	"math"
	"os"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

// GET /micropod/capacity: what a scheduler outside the machine needs to
// decide whether to send it one more container, in one request and from the
// engine's own counters. Nothing here forks, walks a directory or asks
// containerd: the kernel's totals come from a handful of /proc files (read
// by capacitySampler once a second, not by the request), the containers from
// the engine's own table.
//
// The answer has four parts: what the machine has (capacity), what is in use
// (usage), how hard the kernel says it is being pushed (pressure: PSI, when
// the kernel has it), and one recommendation (headroom): how many more
// typical containers it can take now. The formula is headroomFor's.
//
// Host only: a delegated socket never serves it (engineOwnRoute).

// capacitySampleInterval is how often the kernel's figures are read. CPU
// use is the busy share of the interval before the last sample.
const capacitySampleInterval = time.Second

// startLatencyWindow is how many of the latest starts the start-latency
// percentiles are taken over.
const startLatencyWindow = 256

// familyLabel names the job a container, network or volume belongs to, for
// attribution and cleanup (docker_family_linux.go). A container made through
// a delegated socket belongs to its owner's family.
const familyLabel = "io.micropod.family"

// capacityFamilies bounds the per-family rows: the largest first, the rest
// summed under capacityOtherFamily.
const (
	capacityFamilies    = 64
	capacityOtherFamily = "(other)"
)

type psiLine struct {
	Avg10  float64 `json:"avg10"`
	Avg60  float64 `json:"avg60"`
	Avg300 float64 `json:"avg300"`
}

type psiResource struct {
	Some psiLine `json:"some"`
	Full psiLine `json:"full"`
}

// kernelSample is what one pass over /proc found. A figure the kernel does
// not offer is left at zero with its flag false.
type kernelSample struct {
	at                      time.Time
	cpuBusy, cpuTotal       uint64 // clock ticks since boot
	cpuBusyFraction         float64
	load1, load5, load15    float64
	runnable, tasks         int
	memTotal, memAvailable  uint64
	swapTotal, swapFree     uint64
	psi                     map[string]psiResource
	hasPSI                  bool
	openFiles, openFilesMax uint64
	pidMax                  uint64
	conntrack, conntrackMax uint64
	osDiskTotal, osDiskFree uint64
	cacheDisk               bool
	cacheTotal, cacheFree   uint64
	osIO, cacheIO           diskIO
	inotifyInstancesMax     uint64
	cpus                    int
}

type capacityState struct {
	proc string // "/proc"; a directory of its shape in tests

	mu     sync.Mutex
	sample kernelSample
	once   sync.Once

	creating, starting atomic.Int64

	latencyMu sync.Mutex
	latencies [startLatencyWindow]uint32 // milliseconds
	latencyN  uint64
}

func (c *capacityState) recordStart(d time.Duration) {
	ms := d.Milliseconds()
	if ms < 0 {
		ms = 0
	}
	if ms > math.MaxUint32 {
		ms = math.MaxUint32
	}
	c.latencyMu.Lock()
	c.latencies[c.latencyN%startLatencyWindow] = uint32(ms)
	c.latencyN++
	c.latencyMu.Unlock()
}

// startsTotal is how many starts finished since the engine started.
func (c *capacityState) startsTotal() uint64 {
	c.latencyMu.Lock()
	defer c.latencyMu.Unlock()
	return c.latencyN
}

// startLatency is the p50 and p95 of the latest starts (create's answer to
// the process running), in milliseconds, and how many it is taken over.
func (c *capacityState) startLatency() (p50, p95 uint32, n int) {
	c.latencyMu.Lock()
	n = int(min(c.latencyN, startLatencyWindow))
	recent := make([]uint32, n)
	copy(recent, c.latencies[:n])
	c.latencyMu.Unlock()
	if n == 0 {
		return 0, 0, 0
	}
	slices.Sort(recent)
	return recent[(n-1)/2], recent[(n-1)*95/100], n
}

func readFirstLine(path string) (string, bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	line, _, _ := strings.Cut(string(b), "\n")
	return line, true
}

// parsePSI reads one /proc/pressure file: "some avg10=0.00 avg60=0.00
// avg300=0.00 total=0" and, except for cpu on older kernels, a "full" line.
func parsePSI(text string) (psiResource, bool) {
	var out psiResource
	found := false
	for _, line := range strings.Split(text, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}
		var target *psiLine
		switch fields[0] {
		case "some":
			target = &out.Some
		case "full":
			target = &out.Full
		default:
			continue
		}
		for _, f := range fields[1:] {
			name, value, ok := strings.Cut(f, "=")
			if !ok {
				continue
			}
			v, err := strconv.ParseFloat(value, 64)
			if err != nil {
				continue
			}
			switch name {
			case "avg10":
				target.Avg10 = v
				found = true
			case "avg60":
				target.Avg60 = v
			case "avg300":
				target.Avg300 = v
			}
		}
	}
	return out, found
}

func statfsBytes(path string) (total, free uint64, ok bool) {
	var st unix.Statfs_t
	if unix.Statfs(path, &st) != nil {
		return 0, 0, false
	}
	return st.Blocks * uint64(st.Bsize), st.Bavail * uint64(st.Bsize), true
}

// read takes one sample; previous gives the CPU counters to difference.
func (c *capacityState) read(previous kernelSample) kernelSample {
	s := kernelSample{at: time.Now(), cpus: runtime.NumCPU(), psi: map[string]psiResource{}}
	if line, ok := readFirstLine(c.proc + "/stat"); ok && strings.HasPrefix(line, "cpu ") {
		// user nice system idle iowait irq softirq steal
		for i, f := range strings.Fields(line)[1:] {
			v, err := strconv.ParseUint(f, 10, 64)
			if err != nil || i > 7 {
				break
			}
			s.cpuTotal += v
			if i != 3 && i != 4 {
				s.cpuBusy += v
			}
		}
		if previous.cpuTotal != 0 && s.cpuTotal > previous.cpuTotal {
			s.cpuBusyFraction = float64(s.cpuBusy-previous.cpuBusy) / float64(s.cpuTotal-previous.cpuTotal)
		}
	}
	if line, ok := readFirstLine(c.proc + "/loadavg"); ok {
		if f := strings.Fields(line); len(f) >= 4 {
			s.load1, _ = strconv.ParseFloat(f[0], 64)
			s.load5, _ = strconv.ParseFloat(f[1], 64)
			s.load15, _ = strconv.ParseFloat(f[2], 64)
			if run, all, ok := strings.Cut(f[3], "/"); ok {
				s.runnable, _ = strconv.Atoi(run)
				s.tasks, _ = strconv.Atoi(all)
			}
		}
	}
	if b, err := os.ReadFile(c.proc + "/meminfo"); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			name, rest, ok := strings.Cut(line, ":")
			if !ok {
				continue
			}
			var into *uint64
			switch name {
			case "MemTotal":
				into = &s.memTotal
			case "MemAvailable":
				into = &s.memAvailable
			case "SwapTotal":
				into = &s.swapTotal
			case "SwapFree":
				into = &s.swapFree
			default:
				continue
			}
			if kb, err := strconv.ParseUint(strings.TrimSuffix(strings.TrimSpace(rest), " kB"), 10, 64); err == nil {
				*into = kb << 10
			}
		}
	}
	for _, resource := range []string{"cpu", "memory", "io"} {
		if b, err := os.ReadFile(c.proc + "/pressure/" + resource); err == nil {
			if p, ok := parsePSI(string(b)); ok {
				s.psi[resource] = p
				s.hasPSI = true
			}
		}
	}
	if line, ok := readFirstLine(c.proc + "/sys/fs/file-nr"); ok {
		if f := strings.Fields(line); len(f) == 3 {
			s.openFiles, _ = strconv.ParseUint(f[0], 10, 64)
			s.openFilesMax, _ = strconv.ParseUint(f[2], 10, 64)
		}
	}
	s.pidMax, _ = readUint(c.proc + "/sys/kernel/pid_max")
	s.conntrack, _ = readUint(c.proc + "/sys/net/netfilter/nf_conntrack_count")
	s.conntrackMax, _ = readUint(c.proc + "/sys/net/netfilter/nf_conntrack_max")
	s.inotifyInstancesMax, _ = readUint(c.proc + "/sys/fs/inotify/max_user_instances")
	s.osDiskTotal, s.osDiskFree, _ = statfsBytes(engineRoot)
	if cacheDiskMounted() {
		s.cacheTotal, s.cacheFree, s.cacheDisk = statfsBytes(cacheRoot)
	}
	if b, err := os.ReadFile(c.proc + "/diskstats"); err == nil {
		s.osIO = diskIOOf(string(b), engineRoot)
		if s.cacheDisk {
			s.cacheIO = diskIOOf(string(b), cacheRoot)
		}
	}
	return s
}

// diskIO is a disk's I/O since boot, from /proc/diskstats: writes, bytes
// written, and cache flushes with the time they took. Every containerd
// metadata commit is two flushes, and every non-volatile overlay unmount
// one more, so flushes per container start (with the engine's starts_total)
// shows the commits a start costs, and flush_ms per flush what a flush costs
// with the machine's other writers (profiling CONFIRMED.md §6: 58 flushes per
// container; 1.06 against 0.53 guest ms per flush with volatile layers).
type diskIO struct {
	Device     string `json:"device"`
	Writes     uint64 `json:"writes"`
	WriteBytes uint64 `json:"write_bytes"`
	Flushes    uint64 `json:"flushes"`
	FlushMS    uint64 `json:"flush_ms"`
}

// diskIOOf is the diskstats line of the device that holds path. Kernels
// before 5.5 have no flush fields; they read as zero.
func diskIOOf(diskstats, path string) diskIO {
	var st unix.Stat_t
	if unix.Stat(path, &st) != nil {
		return diskIO{}
	}
	major, minor := strconv.FormatUint(uint64(unix.Major(st.Dev)), 10), strconv.FormatUint(uint64(unix.Minor(st.Dev)), 10)
	for _, line := range strings.Split(diskstats, "\n") {
		f := strings.Fields(line)
		if len(f) < 14 || f[0] != major || f[1] != minor {
			continue
		}
		n := func(i int) uint64 {
			if i >= len(f) {
				return 0
			}
			v, _ := strconv.ParseUint(f[i], 10, 64)
			return v
		}
		return diskIO{Device: f[2], Writes: n(7), WriteBytes: n(9) * 512, Flushes: n(18), FlushMS: n(19)}
	}
	return diskIO{}
}

// cacheDiskMounted reports whether cacheRoot is a filesystem of its own (the
// machine's cache disk) and not a directory of the OS disk.
func cacheDiskMounted() bool {
	var root, parent unix.Stat_t
	if unix.Stat(cacheRoot, &root) != nil || unix.Stat(engineRoot, &parent) != nil {
		return false
	}
	return root.Dev != parent.Dev
}

// latest is the newest sample, read now if the sampler has not run yet or
// has fallen behind (a stalled sampler must not serve an old answer as new).
func (c *capacityState) latest() kernelSample {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.sample.at.IsZero() || time.Since(c.sample.at) > 3*capacitySampleInterval {
		c.sample = c.read(c.sample)
	}
	return c.sample
}

// run samples until stop closes.
func (c *capacityState) run(stop <-chan struct{}) {
	tick := time.NewTicker(capacitySampleInterval)
	defer tick.Stop()
	for {
		c.mu.Lock()
		c.sample = c.read(c.sample)
		c.mu.Unlock()
		select {
		case <-stop:
			return
		case <-tick.C:
		}
	}
}

// containerLoad is what the engine's table says about the containers.
type containerLoad struct {
	total, running, created, starting, exited int
	// requestedMilliCPU and requestedMemory sum the limits of the running
	// and starting containers that have one (a memory limit of the whole
	// machine is none); unlimitedCPU counts those with no CPU limit.
	requestedMilliCPU int64
	requestedMemory   int64
	unlimitedCPU      int
	families          map[string]*familyLoad
}

type familyLoad struct {
	Name     string `json:"name"`
	Running  int    `json:"running"`
	Total    int    `json:"total"`
	MilliCPU int64  `json:"requested_milli_cpu"`
	Memory   int64  `json:"requested_memory_bytes"`
}

// familyOfLocked names the family a container counts under. One made
// through a delegated socket counts as its owner does, whatever it labels
// itself. Otherwise: its familyLabel, else its own name when it owns a
// delegated socket, else "" (the host's, unattributed). Call with s.mu held.
func (s *dockerEngine) familyOfLocked(c *dockerContainer) string {
	if c.CreatedBy != "" {
		owner := s.containers[c.CreatedBy]
		if owner == nil {
			return ""
		}
		c = owner
	}
	if v := c.Config.Labels[familyLabel]; v != "" {
		return v
	}
	if c.EngineSocket {
		return c.Name
	}
	return ""
}

func (s *dockerEngine) containerLoad() containerLoad {
	load := containerLoad{families: map[string]*familyLoad{}}
	s.mu.Lock()
	defer s.mu.Unlock()
	load.total = len(s.containers)
	for _, c := range s.containers {
		active := false
		switch c.Phase {
		case "running":
			load.running++
			active = true
		case "starting":
			load.starting++
			active = true
		case "created":
			load.created++
		default:
			load.exited++
		}
		name := s.familyOfLocked(c)
		f := load.families[name]
		if f == nil {
			f = &familyLoad{Name: name}
			load.families[name] = f
		}
		f.Total++
		if !active {
			continue
		}
		f.Running++
		l := c.Config.HostConfig.limits()
		if machine := machineMemory(); machine == 0 || l.memory < machine {
			load.requestedMemory += l.memory
			f.Memory += l.memory
		}
		if l.quota > 0 && l.period > 0 {
			milli := l.quota * 1000 / l.period
			load.requestedMilliCPU += milli
			f.MilliCPU += milli
		} else {
			load.unlimitedCPU++
		}
	}
	return load
}

// The typical container the headroom is counted in, when nothing runs to
// measure one from, and the bounds a measured one is held to.
const (
	headroomUnitCPU       = 0.5
	headroomUnitCPUMin    = 0.25
	headroomUnitCPUMax    = 2.0
	headroomUnitMemory    = 512 << 20
	headroomUnitMemoryMin = 256 << 20
	headroomUnitMemoryMax = 4 << 30
	// headroomCPUCeiling is the busy share of the CPUs the machine is
	// filled to: the rest is kept for the engine, containerd and bursts.
	headroomCPUCeiling = 0.90
	// headroomMemoryReserveShare of the memory (at least
	// headroomMemoryReserveMin) is never offered.
	headroomMemoryReserveShare = 0.05
	headroomMemoryReserveMin   = 1 << 30
	// headroomDiskReserveShare of a disk (at least headroomDiskReserveMin)
	// free is what a start needs to be offered at all.
	headroomDiskReserveShare = 0.05
	headroomDiskReserveMin   = 2 << 30
	// headroomTaskShare of pid_max is the most tasks the machine is filled
	// to; headroomTasksPerContainer is what one more is assumed to add.
	headroomTaskShare         = 0.80
	headroomTasksPerContainer = 64
	// headroomContainerCeiling is the most containers alive at once the
	// engine is offered: every one holds a shim, a network namespace and
	// descriptors in the engine and containerd.
	headroomContainerCeiling = 1024
	// The PSI avg10 values (percent of the last 10 s some or all tasks were
	// stalled) at which the machine is under pressure.
	pressureMemorySome = 10.0
	pressureMemoryFull = 2.0
	pressureCPUSome    = 80.0
	pressureIOFull     = 25.0
	// pressureStartP95 is the start latency (ms) past which starts are
	// queueing inside the machine.
	pressureStartP95 = 10000
)

type headroom struct {
	// Containers is how many more typical containers the machine can take
	// now: zero under pressure.
	Containers int `json:"containers"`
	// UnderPressure and Reasons: what, if anything, says to back off.
	UnderPressure bool     `json:"under_pressure"`
	Reasons       []string `json:"reasons"`
	// LimitedBy names the resource Containers is the smallest for: cpu,
	// memory, tasks, containers, os-disk, cache-disk or pressure.
	LimitedBy string `json:"limited_by"`
	// The typical container the count is in.
	UnitCPU    float64 `json:"unit_cpu"`
	UnitMemory uint64  `json:"unit_memory_bytes"`
	// What each resource alone would allow.
	ByCPU        int `json:"by_cpu"`
	ByMemory     int `json:"by_memory"`
	ByTasks      int `json:"by_tasks"`
	ByContainers int `json:"by_containers"`
}

func clampFloat(v, low, high float64) float64 { return math.Max(low, math.Min(high, v)) }

// headroomFor is the recommendation.
//
// The unit is one typical container: what the running ones use on average
// now (busy CPUs / running, used memory / running), held to 0.25..2 CPUs and
// 256 MiB..4 GiB; 0.5 CPU and 512 MiB when nothing runs.
//
//	by_cpu        = (cpus * 0.90 - busy CPUs) / unit CPU
//	by_memory     = (MemAvailable - max(5% of MemTotal, 1 GiB)) / unit memory
//	by_tasks      = (pid_max * 0.80 - tasks) / 64
//	by_containers = 1024 - containers running or starting
//	containers    = max(0, min of the four)
//
// and zero when the machine is under pressure: memory PSI some avg10 >= 10
// or full avg10 >= 2, CPU PSI some avg10 >= 80, IO PSI full avg10 >= 25,
// less memory available than the reserve, a disk with less than
// max(5%, 2 GiB) free, or a start-latency p95 of 10 s or more.
//
// CPU is counted on what is busy, not on what was promised: CI containers
// idle most of the time and a CPU limit is a ceiling. Memory is counted on
// MemAvailable for the same reason; the PSI terms are what catches a machine
// whose promised memory is being used after all.
func headroomFor(k kernelSample, load containerLoad, startP95 uint32) headroom {
	h := headroom{UnitCPU: headroomUnitCPU, UnitMemory: headroomUnitMemory, Reasons: []string{}}
	busy := k.cpuBusyFraction * float64(k.cpus)
	active := load.running + load.starting
	if active > 0 {
		h.UnitCPU = clampFloat(busy/float64(active), headroomUnitCPUMin, headroomUnitCPUMax)
		if k.memTotal > k.memAvailable {
			h.UnitMemory = uint64(clampFloat(float64(k.memTotal-k.memAvailable)/float64(active), headroomUnitMemoryMin, headroomUnitMemoryMax))
		}
	}
	floor := func(v float64) int {
		if v <= 0 {
			return 0
		}
		return int(math.Min(v, 1<<20))
	}
	h.ByCPU = floor((float64(k.cpus)*headroomCPUCeiling - busy) / h.UnitCPU)
	reserve := math.Max(float64(k.memTotal)*headroomMemoryReserveShare, headroomMemoryReserveMin)
	h.ByMemory = floor((float64(k.memAvailable) - reserve) / float64(h.UnitMemory))
	h.ByTasks = 1 << 20
	if k.pidMax > 0 {
		h.ByTasks = floor((float64(k.pidMax)*headroomTaskShare - float64(k.tasks)) / headroomTasksPerContainer)
	}
	h.ByContainers = max(0, headroomContainerCeiling-active)
	h.Containers, h.LimitedBy = h.ByCPU, "cpu"
	for _, other := range []struct {
		n    int
		name string
	}{{h.ByMemory, "memory"}, {h.ByTasks, "tasks"}, {h.ByContainers, "containers"}} {
		if other.n < h.Containers {
			h.Containers, h.LimitedBy = other.n, other.name
		}
	}
	because := func(limited, reason string) {
		h.Reasons = append(h.Reasons, reason)
		if !h.UnderPressure {
			h.UnderPressure, h.LimitedBy = true, limited
		}
	}
	if p, ok := k.psi["memory"]; ok && (p.Some.Avg10 >= pressureMemorySome || p.Full.Avg10 >= pressureMemoryFull) {
		because("pressure", "memory pressure (PSI some avg10 "+strconv.FormatFloat(p.Some.Avg10, 'f', 1, 64)+", full "+strconv.FormatFloat(p.Full.Avg10, 'f', 1, 64)+")")
	}
	if p, ok := k.psi["cpu"]; ok && p.Some.Avg10 >= pressureCPUSome {
		because("pressure", "CPU pressure (PSI some avg10 "+strconv.FormatFloat(p.Some.Avg10, 'f', 1, 64)+")")
	}
	if p, ok := k.psi["io"]; ok && p.Full.Avg10 >= pressureIOFull {
		because("pressure", "IO pressure (PSI full avg10 "+strconv.FormatFloat(p.Full.Avg10, 'f', 1, 64)+")")
	}
	if k.memTotal > 0 && float64(k.memAvailable) < reserve {
		because("memory", "less memory available than the reserve")
	}
	low := func(total, free uint64) bool {
		return total > 0 && float64(free) < math.Max(float64(total)*headroomDiskReserveShare, headroomDiskReserveMin)
	}
	if low(k.osDiskTotal, k.osDiskFree) {
		because("os-disk", "the OS disk is nearly full")
	}
	if k.cacheDisk && low(k.cacheTotal, k.cacheFree) {
		because("cache-disk", "the cache disk is nearly full")
	}
	if startP95 >= pressureStartP95 {
		because("pressure", "starts are slow (p95 "+strconv.FormatUint(uint64(startP95), 10)+" ms)")
	}
	if h.UnderPressure {
		h.Containers = 0
	}
	return h
}

// capacityReport is the body of GET /micropod/capacity.
func (s *dockerEngine) capacityReport() map[string]any {
	s.capacity.once.Do(func() {
		if s.capacity.proc == "" {
			s.capacity.proc = "/proc"
		}
	})
	k := s.capacity.latest()
	load := s.containerLoad()
	p50, p95, starts := s.capacity.startLatency()
	families := make([]*familyLoad, 0, len(load.families))
	for _, f := range load.families {
		families = append(families, f)
	}
	slices.SortFunc(families, func(a, b *familyLoad) int {
		if a.Running != b.Running {
			return b.Running - a.Running
		}
		if a.Total != b.Total {
			return b.Total - a.Total
		}
		return strings.Compare(a.Name, b.Name)
	})
	if len(families) > capacityFamilies {
		other := &familyLoad{Name: capacityOtherFamily}
		for _, f := range families[capacityFamilies-1:] {
			other.Running += f.Running
			other.Total += f.Total
			other.MilliCPU += f.MilliCPU
			other.Memory += f.Memory
		}
		families = append(families[:capacityFamilies-1], other)
	}
	pressure := map[string]any{"available": k.hasPSI}
	for name, p := range k.psi {
		pressure[name] = p
	}
	disks := map[string]any{"os": map[string]any{"total_bytes": k.osDiskTotal, "free_bytes": k.osDiskFree, "io": k.osIO}}
	if k.cacheDisk {
		disks["cache"] = map[string]any{"total_bytes": k.cacheTotal, "free_bytes": k.cacheFree, "io": k.cacheIO}
	}
	return map[string]any{
		"sampled_unix_ms": k.at.UnixMilli(),
		"capacity": map[string]any{
			"cpus": k.cpus, "memory_bytes": k.memTotal, "pid_max": k.pidMax, "open_files_max": k.openFilesMax,
			"conntrack_max": k.conntrackMax, "max_containers": headroomContainerCeiling,
			"family_containers_max": delegatedFamilyContainers,
			"relay_connections_max": cap(gatewayRelaySlots), "start_parallelism_limit": cap(s.startSlots),
		},
		"usage": map[string]any{
			"cpu_busy_fraction": k.cpuBusyFraction, "cpu_busy_cpus": k.cpuBusyFraction * float64(k.cpus),
			"load1": k.load1, "load5": k.load5, "load15": k.load15, "runnable": k.runnable, "tasks": k.tasks,
			"memory_available_bytes": k.memAvailable, "memory_used_bytes": k.memTotal - min(k.memAvailable, k.memTotal),
			"swap_used_bytes": k.swapTotal - min(k.swapFree, k.swapTotal),
			"open_files":      k.openFiles, "conntrack_entries": k.conntrack,
			"relay_connections": len(gatewayRelaySlots),
		},
		"containers": map[string]any{
			"total": load.total, "running": load.running, "starting": load.starting, "created": load.created, "exited": load.exited,
			"requested_milli_cpu": load.requestedMilliCPU, "requested_memory_bytes": load.requestedMemory,
			"without_cpu_limit": load.unlimitedCPU, "families": families,
		},
		"engine": map[string]any{
			"creates_in_flight": s.capacity.creating.Load(), "starts_in_flight": s.capacity.starting.Load(),
			"start_p50_ms": p50, "start_p95_ms": p95, "starts_sampled": starts, "starts_total": s.capacity.startsTotal(),
			"setup_slots_in_use": len(s.startSlots),
		},
		"pressure": pressure,
		"disks":    disks,
		"headroom": headroomFor(k, load, p95),
	}
}

// engineFileLimit is the open-file limit the engine gives itself: every live
// container holds descriptors in it (its output, its held binds, its
// delegated socket, a relay's two per connection), and the limit a process
// started by init inherits (1024, 4096 at most) ends a start with "too many
// open files" at about 150 containers.
const engineFileLimit = 1 << 20

// raiseFileLimit raises the engine's open-file limit to engineFileLimit, or
// to the kernel's ceiling for one process if that is lower. A failure is
// logged and the engine runs with what it has.
func raiseFileLimit() {
	want := uint64(engineFileLimit)
	if ceiling, ok := readUint("/proc/sys/fs/nr_open"); ok && ceiling < want {
		want = ceiling
	}
	// syscall's Setrlimit, not x/sys's: it is the one that tells os/exec the
	// limit is ours now, so BuildKit and the helpers the engine starts keep
	// it instead of being handed back the soft limit the engine began with.
	var limit syscall.Rlimit
	if err := syscall.Getrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil || limit.Cur >= want {
		return
	}
	limit.Cur, limit.Max = want, max(limit.Max, want)
	if err := syscall.Setrlimit(syscall.RLIMIT_NOFILE, &limit); err != nil {
		log.Printf("the engine keeps its open-file limit: raising it to %d: %v", want, err)
	}
}
