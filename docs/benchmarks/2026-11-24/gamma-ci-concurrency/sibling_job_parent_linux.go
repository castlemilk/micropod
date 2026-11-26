// Read the owned payload cgroups from the initial guest namespace and their
// members from both the guest and each container PID namespace.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"golang.org/x/sys/unix"
)

type member struct {
	process
	Executable string `json:"executable"`
	LocalPID   int    `json:"local_pid"`
	Parent     int    `json:"parent_pid"`
	CPUs       string `json:"cpus_allowed_list"`
	Policy     uint32 `json:"policy"`
	Nice       int32  `json:"nice"`
	Priority   uint32 `json:"priority"`
	SliceNS    uint64 `json:"slice_ns"`
}

type nodeState struct {
	Children []string `json:"children"`
	Procs    string   `json:"cgroup.procs"`
	Threads  string   `json:"cgroup.threads"`
	CPUStat  string   `json:"cpu.stat"`
	Pressure string   `json:"cpu.pressure,omitempty"`
}

func observeMember(pid int) (member, error) {
	proc, err := readProcess(pid)
	if err != nil {
		return member{}, err
	}
	status, err := read(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return member{}, err
	}
	result := member{process: proc}
	result.Executable, err = os.Readlink(fmt.Sprintf("/proc/%d/exe", pid))
	if err != nil {
		return member{}, err
	}
	for _, line := range strings.Split(status, "\n") {
		name, value, _ := strings.Cut(line, ":")
		switch name {
		case "PPid":
			result.Parent, err = strconv.Atoi(strings.TrimSpace(value))
		case "NSpid":
			fields := strings.Fields(value)
			if len(fields) == 0 {
				return member{}, errors.New("empty namespace PIDs")
			}
			result.LocalPID, err = strconv.Atoi(fields[len(fields)-1])
		case "Cpus_allowed_list":
			result.CPUs = strings.TrimSpace(value)
		}
		if err != nil {
			return member{}, fmt.Errorf("read %s for PID %d: %w", name, pid, err)
		}
	}
	if result.LocalPID <= 0 || result.CPUs == "" || result.Birth == 0 {
		return member{}, fmt.Errorf("incomplete process identity for PID %d", pid)
	}
	attr, err := unix.SchedGetAttr(pid, 0)
	if err != nil {
		return member{}, fmt.Errorf("read scheduling for PID %d: %w", pid, err)
	}
	result.Policy, result.Nice, result.Priority, result.SliceNS = attr.Policy, attr.Nice, attr.Priority, attr.Runtime
	return result, nil
}

func observeMembers(raw string, skip int) ([]member, error) {
	words := strings.Fields(raw)
	result := make([]member, 0, len(words))
	for _, word := range words {
		pid, err := strconv.Atoi(word)
		if err != nil || pid <= 0 {
			return nil, fmt.Errorf("invalid cgroup PID %q", word)
		}
		if pid == skip {
			continue
		}
		observed, err := observeMember(pid)
		if err != nil {
			return nil, err
		}
		result = append(result, observed)
	}
	return result, nil
}

func observeInside(boot string, pid int) (any, error) {
	target, err := readLeaf(boot, pid)
	if err != nil {
		return nil, err
	}
	raw, err := read(cgroupRoot + "/cgroup.procs")
	if err != nil {
		return nil, err
	}
	members, err := observeMembers(raw, os.Getpid())
	if err != nil {
		return nil, err
	}
	group, err := readGroup(cgroupRoot, target.Inode)
	if err != nil {
		return nil, err
	}
	return struct {
		Leaf     leaf              `json:"leaf"`
		ProbePID int               `json:"probe_pid"`
		Procs    string            `json:"cgroup.procs"`
		Members  []member          `json:"members"`
		Files    map[string]string `json:"files"`
		UnixNS   int64             `json:"guest_unix_ns"`
	}{target, os.Getpid(), raw, members, group.Files, time.Now().UnixNano()}, nil
}

func observeWorker(boot, requestPath string) (any, error) {
	topology, err := readTree(boot, requestPath)
	// An unrelated cgroup can finish cleanup during the directory walk.
	// Retry the whole observation so every requested leaf still has to match.
	for attempt := 0; attempt < 4 && errors.Is(err, os.ErrNotExist); attempt++ {
		time.Sleep(20 * time.Millisecond)
		topology, err = readTree(boot, requestPath)
	}
	if err != nil {
		return nil, err
	}
	nodes := make(map[string]nodeState, len(topology.Groups))
	for path := range topology.Groups {
		root := filepath.Join(cgroupRoot, path)
		procs, err := read(root + "/cgroup.procs")
		if err != nil {
			return nil, err
		}
		threads, err := read(root + "/cgroup.threads")
		if err != nil {
			return nil, err
		}
		cpu, err := read(root + "/cpu.stat")
		if err != nil {
			return nil, err
		}
		pressure, err := read(root + "/cpu.pressure")
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		entries, err := os.ReadDir(root)
		if err != nil {
			return nil, err
		}
		children := make([]string, 0)
		for _, entry := range entries {
			if entry.IsDir() {
				children = append(children, entry.Name())
			}
		}
		nodes[path] = nodeState{Children: children, Procs: procs, Threads: threads, CPUStat: cpu, Pressure: pressure}
	}
	members := make(map[string][]member, len(topology.Memberships))
	for id, loc := range topology.Memberships {
		observed, err := observeMembers(nodes[loc.Path].Procs, 0)
		if err != nil {
			return nil, fmt.Errorf("read members of %s: %w", id, err)
		}
		members[id] = observed
	}
	return struct {
		tree
		Nodes   map[string]nodeState `json:"nodes"`
		Members map[string][]member  `json:"members"`
	}{topology, nodes, members}, nil
}

func awaitRelease(marker, release string) error {
	if err := os.WriteFile(marker, []byte("ready\n"), 0600); err != nil {
		return fmt.Errorf("publish compiler ready: %w", err)
	}
	deadline := time.Now().Add(80 * time.Second)
	for time.Now().Before(deadline) {
		_, err := os.Stat(release)
		if err == nil {
			return nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return fmt.Errorf("read compiler release: %w", err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errors.New("timed out waiting for compiler proof release")
}

func observeAbsent(boot, requestPath string) (any, error) {
	observer, err := observerNamespace()
	if err != nil {
		return nil, err
	}
	raw, err := os.ReadFile(requestPath)
	if err != nil {
		return nil, err
	}
	var paths []string
	if err := json.Unmarshal(raw, &paths); err != nil {
		return nil, fmt.Errorf("decode retirement paths: %w", err)
	}
	if len(paths) != 64 && len(paths) != 96 {
		return nil, errors.New("unexpected retirement path count")
	}
	seen := make(map[string]bool, len(paths))
	for _, path := range paths {
		if !strings.HasPrefix(path, "/k8s.io/") || filepath.Clean(path) != path || seen[path] {
			return nil, fmt.Errorf("invalid or duplicate retirement path %q", path)
		}
		seen[path] = true
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		present := make([]string, 0)
		for _, path := range paths {
			_, err := os.Stat(filepath.Join(cgroupRoot, path))
			if err == nil {
				present = append(present, path)
			} else if !errors.Is(err, os.ErrNotExist) {
				return nil, fmt.Errorf("inspect retired path %s: %w", path, err)
			}
		}
		if len(present) == 0 || !time.Now().Before(deadline) {
			return map[string]any{"boot": boot, "observer": observer, "paths": paths,
				"present": present, "guest_unix_ns": time.Now().UnixNano()}, nil
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func runJobParent(args []string) error {
	if len(args) == 3 && args[0] == "wait" {
		return awaitRelease(args[1], args[2])
	}
	if len(args) != 2 {
		return errors.New("expected inside PID, worker REQUEST, absent REQUEST or wait MARKER RELEASE")
	}
	boot, err := read(bootPath)
	if err != nil {
		return err
	}
	var filesystem unix.Statfs_t
	if err := unix.Statfs(cgroupRoot, &filesystem); err != nil {
		return err
	}
	if filesystem.Type != unix.CGROUP2_SUPER_MAGIC {
		return errors.New("expected cgroup v2")
	}
	var output any
	switch args[0] {
	case "inside":
		pid, parseErr := strconv.Atoi(args[1])
		if parseErr != nil || pid <= 0 {
			return errors.New("expected a positive resident PID")
		}
		output, err = observeInside(boot, pid)
	case "worker":
		output, err = observeWorker(boot, args[1])
	case "absent":
		output, err = observeAbsent(boot, args[1])
	default:
		return fmt.Errorf("unknown job-parent probe %q", args[0])
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(output)
}

func main() {
	if err := runJobParent(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
