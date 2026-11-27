package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"strconv"
	"strings"
)

// dockerUlimit is one --ulimit (HostConfig.Ulimits): a resource limit the
// container's processes start with. -1 is unlimited, as Docker reads it.
type dockerUlimit struct {
	Name       string
	Soft, Hard int64
}

// dockerUlimitResources are the --ulimit names Docker accepts and the OCI
// rlimit each sets.
var dockerUlimitResources = map[string]string{
	"as": "RLIMIT_AS", "core": "RLIMIT_CORE", "cpu": "RLIMIT_CPU", "data": "RLIMIT_DATA",
	"fsize": "RLIMIT_FSIZE", "locks": "RLIMIT_LOCKS", "memlock": "RLIMIT_MEMLOCK",
	"msgqueue": "RLIMIT_MSGQUEUE", "nice": "RLIMIT_NICE", "nofile": "RLIMIT_NOFILE",
	"nproc": "RLIMIT_NPROC", "rss": "RLIMIT_RSS", "rtprio": "RLIMIT_RTPRIO",
	"rttime": "RLIMIT_RTTIME", "sigpending": "RLIMIT_SIGPENDING", "stack": "RLIMIT_STACK",
}

// fileLimit is the most open files a process can be given (fs.nr_open).
func fileLimit() int64 {
	b, err := os.ReadFile("/proc/sys/fs/nr_open")
	if n, perr := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && perr == nil && n > 0 {
		return n
	}
	return 1 << 20
}

func validateDockerUlimits(limits []dockerUlimit) error {
	seen := map[string]bool{}
	for _, l := range limits {
		if _, ok := dockerUlimitResources[l.Name]; !ok {
			return fmt.Errorf("unsupported ulimit %q", l.Name)
		}
		if seen[l.Name] {
			return fmt.Errorf("ulimit %s is given twice", l.Name)
		}
		seen[l.Name] = true
		if l.Soft < -1 || l.Hard < -1 || l.Hard != -1 && (l.Soft == -1 || l.Soft > l.Hard) {
			return fmt.Errorf("ulimit %s: soft limit %d must not exceed hard limit %d", l.Name, l.Soft, l.Hard)
		}
		if l.Name == "nofile" {
			// The kernel refuses more open files than fs.nr_open, unlimited
			// included, and the container would not start.
			if most := fileLimit(); l.Hard == -1 || l.Hard > most {
				return fmt.Errorf("ulimit nofile: at most %d open files", most)
			}
		}
	}
	return nil
}

// specWithUlimits sets the container process's rlimits to the requested
// ulimits, replacing the runtime's default for the same resource.
func (c dockerConfig) specWithUlimits(original []byte) ([]byte, error) {
	if len(c.HostConfig.Ulimits) == 0 {
		return original, nil
	}
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(original, &spec); err != nil {
		return nil, err
	}
	var process map[string]json.RawMessage
	if err := json.Unmarshal(spec["process"], &process); err != nil || process == nil {
		return nil, errors.New("containerd OCI spec has no process")
	}
	type rlimit struct {
		Type string `json:"type"`
		Hard uint64 `json:"hard"`
		Soft uint64 `json:"soft"`
	}
	var limits []rlimit
	if raw := process["rlimits"]; raw != nil {
		if err := json.Unmarshal(raw, &limits); err != nil {
			return nil, fmt.Errorf("decode OCI rlimits: %w", err)
		}
	}
	value := func(v int64) uint64 {
		if v < 0 {
			return math.MaxUint64
		}
		return uint64(v)
	}
	for _, u := range c.HostConfig.Ulimits {
		want := rlimit{Type: dockerUlimitResources[u.Name], Hard: value(u.Hard), Soft: value(u.Soft)}
		replaced := false
		for i := range limits {
			if limits[i].Type == want.Type {
				limits[i], replaced = want, true
			}
		}
		if !replaced {
			limits = append(limits, want)
		}
	}
	process["rlimits"], _ = json.Marshal(limits)
	spec["process"], _ = json.Marshal(process)
	return json.Marshal(spec)
}
