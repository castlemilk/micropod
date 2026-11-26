package main

import (
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	cri "k8s.io/cri-api/pkg/apis/runtime/v1"
)

// ContainerStats supplies CPU and working-set counters. Read the remaining
// v2 counters only after the kernel confirms the task belongs to this CRI ID.
func (s *dockerEngine) kernelStats(r *http.Request, id string, sample map[string]any) {
	status, err := s.node.runtime.ContainerStatus(r.Context(), &cri.ContainerStatusRequest{ContainerId: id, Verbose: true})
	if err != nil || status.GetStatus().GetId() != id {
		return
	}
	var task struct{ Pid int }
	if json.Unmarshal([]byte(status.Info["info"]), &task) != nil || task.Pid <= 1 {
		return
	}
	proc := filepath.Join("/proc", strconv.Itoa(task.Pid))
	// Open the process directory once so PID reuse cannot redirect later reads.
	dir, err := os.Open(proc)
	if err != nil {
		return
	}
	defer dir.Close()
	proc = filepath.Join("/proc/self/fd", strconv.Itoa(int(dir.Fd())))
	b, err := os.ReadFile(filepath.Join(proc, "cgroup"))
	if err != nil {
		return
	}
	cg, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "0::")
	if !ok || !filepath.IsAbs(cg) || filepath.Base(cg) != id || filepath.Clean(cg) != cg {
		return
	}
	if r.URL.Query().Get("micropod-cgroup") == "1" {
		sample["micropod_cgroup"] = cg
	}
	root := filepath.Join("/sys/fs/cgroup", cg)
	pidsStats := map[string]uint64{}
	if b, err := os.ReadFile(filepath.Join(root, "pids.current")); err == nil {
		if n, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil {
			pidsStats["current"] = n
		}
	}
	if b, err := os.ReadFile(filepath.Join(root, "pids.max")); err == nil {
		if raw := strings.TrimSpace(string(b)); raw != "" && raw != "max" {
			if n, err := strconv.ParseUint(raw, 10, 64); err == nil {
				pidsStats["limit"] = n
			}
		}
	}
	if len(pidsStats) > 0 {
		sample["pids_stats"] = pidsStats
	}
	if b, err := os.ReadFile(filepath.Join(root, "cpu.stat")); err == nil {
		kv := parseCgroupKV(string(b))
		if cpuMap, ok := sample["cpu_stats"].(map[string]any); ok {
			if usageMap, ok := cpuMap["cpu_usage"].(map[string]any); ok {
				if u, ok := kv["user_usec"]; ok {
					usageMap["usage_in_usermode"] = u * 1000
				}
				if sys, ok := kv["system_usec"]; ok {
					usageMap["usage_in_kernelmode"] = sys * 1000
				}
			}
			cpuMap["throttling_data"] = map[string]uint64{
				"periods":           kv["nr_periods"],
				"throttled_periods": kv["nr_throttled"],
				"throttled_time":    kv["throttled_usec"] * 1000,
			}
		}
	}
	if memMap, ok := sample["memory_stats"].(map[string]any); ok {
		if b, err := os.ReadFile(filepath.Join(root, "memory.peak")); err == nil {
			if peak, err := strconv.ParseUint(strings.TrimSpace(string(b)), 10, 64); err == nil {
				memMap["max_usage"] = peak
			}
		}
		if b, err := os.ReadFile(filepath.Join(root, "memory.events")); err == nil {
			kv := parseCgroupKV(string(b))
			memMap["events"] = map[string]uint64{
				"high":     kv["high"],
				"max":      kv["max"],
				"oom":      kv["oom"],
				"oom_kill": kv["oom_kill"],
			}
		}
	}
	psi := map[string]uint64{}
	for _, res := range []struct{ key, file string }{
		{"cpu_some_usec", "cpu.pressure"},
		{"memory_some_usec", "memory.pressure"},
		{"io_some_usec", "io.pressure"},
	} {
		if b, err := os.ReadFile(filepath.Join(root, res.file)); err == nil {
			if total, ok := parsePSISomeTotalUsec(string(b)); ok {
				psi[res.key] = total
			}
		}
	}
	if len(psi) > 0 {
		sample["psi_stats"] = psi
	}
	if b, err := os.ReadFile(filepath.Join(root, "io.stat")); err == nil {
		var byteCounts []map[string]any
		var opCounts []map[string]any
		for _, line := range strings.Split(string(b), "\n") {
			fields := strings.Fields(line)
			if len(fields) < 2 {
				continue
			}
			for _, field := range fields[1:] {
				key, value, _ := strings.Cut(field, "=")
				n, err := strconv.ParseUint(value, 10, 64)
				if err != nil {
					continue
				}
				switch key {
				case "rbytes":
					byteCounts = append(byteCounts, map[string]any{"op": "Read", "value": n})
				case "wbytes":
					byteCounts = append(byteCounts, map[string]any{"op": "Write", "value": n})
				case "rios":
					opCounts = append(opCounts, map[string]any{"op": "Read", "value": n})
				case "wios":
					opCounts = append(opCounts, map[string]any{"op": "Write", "value": n})
				}
			}
		}
		sample["blkio_stats"] = map[string]any{
			"io_service_bytes_recursive": byteCounts,
			"io_serviced_recursive":      opCounts,
		}
	}
	if b, err := os.ReadFile(filepath.Join(proc, "net/dev")); err == nil {
		nets := map[string]map[string]uint64{}
		for _, line := range strings.Split(string(b), "\n") {
			iface, data, ok := strings.Cut(line, ":")
			iface = strings.TrimSpace(iface)
			values := strings.Fields(data)
			if !ok || iface == "lo" || len(values) != 16 {
				continue
			}
			rx, er := strconv.ParseUint(values[0], 10, 64)
			tx, et := strconv.ParseUint(values[8], 10, 64)
			if er == nil && et == nil {
				nets[iface] = map[string]uint64{"rx_bytes": rx, "tx_bytes": tx}
			}
		}
		sample["networks"] = nets
	}
}

// /proc/stat exports aggregate USER_HZ (100 Hz on Linux arm64). Guest and
// guest_nice are already included in user and nice.
func systemCPU() (uint64, error) {
	b, err := os.ReadFile("/proc/stat")
	if err != nil {
		return 0, err
	}
	first, _, _ := strings.Cut(string(b), "\n")
	fields := strings.Fields(first)
	if len(fields) < 9 || fields[0] != "cpu" {
		return 0, errors.New("missing aggregate CPU counters")
	}
	var total uint64
	for _, v := range fields[1:9] {
		n, err := strconv.ParseUint(v, 10, 64)
		if err != nil {
			return 0, err
		}
		total += n
	}
	return total * 10_000_000, nil
}
func (s *dockerEngine) stats(w http.ResponseWriter, r *http.Request, c *dockerContainer) error {
	stream := r.URL.Query().Get("stream") != "false" && r.URL.Query().Get("stream") != "0"
	first := true
	var previous map[string]any
	var preRead time.Time
	for {
		s.mu.Lock()
		id := c.RuntimeID
		limit := c.Config.HostConfig.Memory
		s.mu.Unlock()
		if id == "" {
			if first {
				return fail(409, "container is not running")
			}
			return nil
		}
		res, err := s.node.runtime.ContainerStats(r.Context(), &cri.ContainerStatsRequest{ContainerId: id})
		if err != nil {
			if first {
				return err
			}
			return nil
		}
		stats := res.GetStats()
		cpu, mem := stats.GetCpu(), stats.GetMemory()
		if cpu.GetUsageCoreNanoSeconds() == nil || mem.GetUsageBytes() == nil {
			if first {
				return errors.New("CRI has no CPU or memory sample")
			}
			return nil
		}
		system, err := systemCPU()
		if err != nil {
			return err
		}
		current := map[string]any{"cpu_usage": map[string]any{"total_usage": cpu.UsageCoreNanoSeconds.Value}, "system_cpu_usage": system, "online_cpus": runtime.NumCPU()}
		usage := mem.UsageBytes.Value
		memory := map[string]any{"usage": usage}
		if limit == 0 {
			limit = 1 << 30
		}
		memory["limit"] = limit
		if work := mem.GetWorkingSetBytes(); work != nil && work.Value <= usage {
			memory["stats"] = map[string]uint64{"inactive_file": usage - work.Value}
		}
		read := time.Unix(0, cpu.Timestamp).UTC()
		if first {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			first = false
		}
		sample := map[string]any{"id": c.ID, "name": "/" + c.Name, "read": read, "preread": preRead, "cpu_stats": current, "precpu_stats": previous, "memory_stats": memory}
		s.kernelStats(r, id, sample)
		if err := json.NewEncoder(w).Encode(sample); err != nil {
			return nil
		}
		w.(http.Flusher).Flush()
		if !stream {
			return nil
		}
		previous, preRead = current, read
		select {
		case <-r.Context().Done():
			return nil
		case <-time.After(time.Second):
		}
	}
}
