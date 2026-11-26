// Read the live cgroup-v2 hierarchy of a disposable worker's owned cohort.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"

	"golang.org/x/sys/unix"
)

const cgroupRoot = "/sys/fs/cgroup"
const bootPath = "/proc/sys/kernel/random/boot_id"

type process struct {
	PID       int      `json:"pid"`
	Birth     uint64   `json:"birth_ticks"`
	Namespace string   `json:"pid_namespace"`
	Argv      []string `json:"argv"`
	Cgroup    string   `json:"cgroup"`
}

type leaf struct {
	Boot     string  `json:"boot"`
	Inode    uint64  `json:"inode"`
	Resident process `json:"resident"`
}

type request struct {
	ID   string `json:"id"`
	Leaf leaf   `json:"leaf"`
}

type membership struct {
	ID       string  `json:"id"`
	Path     string  `json:"path"`
	Resident process `json:"resident"`
}

type group struct {
	Inode    uint64            `json:"inode"`
	Children int               `json:"children"`
	Files    map[string]string `json:"files"`
}

type tree struct {
	Boot        string                `json:"boot"`
	Observer    map[string]string     `json:"observer"`
	Memberships map[string]membership `json:"memberships"`
	Groups      map[string]group      `json:"groups"`
}

func read(path string) (string, error) {
	raw, err := os.ReadFile(path)
	return strings.TrimSpace(string(raw)), err
}

func readProcess(pid int) (process, error) {
	var result process
	root := fmt.Sprintf("/proc/%d", pid)
	stat, err := read(root + "/stat")
	if err != nil {
		return result, err
	}
	end := strings.LastIndexByte(stat, ')')
	if end < 0 {
		return result, fmt.Errorf("malformed process stat for %d", pid)
	}
	fields := strings.Fields(stat[end+1:])
	if len(fields) <= 19 {
		return result, fmt.Errorf("incomplete process stat for %d", pid)
	}
	birth, err := strconv.ParseUint(fields[19], 10, 64)
	if err != nil {
		return result, fmt.Errorf("process %d birth ticks: %w", pid, err)
	}
	argv, err := os.ReadFile(root + "/cmdline")
	if err != nil {
		return result, err
	}
	ns, err := os.Readlink(root + "/ns/pid")
	if err != nil {
		return result, err
	}
	cgroup, err := read(root + "/cgroup")
	return process{pid, birth, ns, strings.Split(strings.TrimRight(string(argv), "\x00"), "\x00"), cgroup}, err
}

func inode(path string) (uint64, error) {
	var stat unix.Stat_t
	err := unix.Stat(path, &stat)
	return stat.Ino, err
}

func readLeaf(boot string, pid int) (leaf, error) {
	result := leaf{Boot: boot}
	where, err := read("/proc/self/cgroup")
	if err != nil {
		return result, err
	}
	result.Resident, err = readProcess(pid)
	if err != nil {
		return result, err
	}
	if where != "0::/" || result.Resident.Cgroup != where {
		return result, errors.New("the container cgroup mount is not rooted at both observed processes")
	}
	result.Inode, err = inode(cgroupRoot)
	return result, err
}

func readGroup(dir string, inode uint64) (group, error) {
	result := group{Inode: inode, Files: make(map[string]string)}
	for _, name := range []string{"cgroup.type", "cgroup.controllers", "cgroup.subtree_control",
		"cgroup.events", "cpu.weight", "cpu.max", "cpuset.cpus.effective", "memory.max", "pids.max"} {
		value, err := read(filepath.Join(dir, name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return result, err
		}
		result.Files[name] = value
	}
	entries, err := os.ReadDir(dir)
	for _, entry := range entries {
		if entry.IsDir() {
			result.Children++
		}
	}
	return result, err
}

func findResident(dir, path string, want process) (process, error) {
	pids, err := read(dir + "/cgroup.procs")
	if err != nil {
		return process{}, err
	}
	for _, word := range strings.Fields(pids) {
		pid, err := strconv.Atoi(word)
		if err != nil {
			return process{}, err
		}
		got, err := readProcess(pid)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return process{}, err
		}
		if got.Birth == want.Birth && got.Namespace == want.Namespace && slices.Equal(got.Argv, want.Argv) &&
			got.Cgroup == "0::"+path {
			return got, nil
		}
	}
	return process{}, fmt.Errorf("resident process disappeared from %s", path)
}

func observerNamespace() (map[string]string, error) {
	self, err := os.Readlink("/proc/self/ns/cgroup")
	if err != nil {
		return nil, err
	}
	init, err := os.Readlink("/proc/1/ns/cgroup")
	if err != nil {
		return nil, err
	}
	mounts, err := read("/proc/self/mountinfo")
	if err != nil {
		return nil, err
	}
	for _, line := range strings.Split(mounts, "\n") {
		mount, filesystem, _ := strings.Cut(line, " - ")
		fields, fs := strings.Fields(mount), strings.Fields(filesystem)
		if len(fields) >= 6 && fields[3] == "/" && fields[4] == cgroupRoot && len(fs) == 3 && fs[0] == "cgroup2" && self == init {
			return map[string]string{"self_cgroup_namespace": self, "init_cgroup_namespace": init, "mountinfo": line}, nil
		}
	}
	return nil, errors.New("trusted observer is not in the guest init cgroup namespace and root mount")
}

func readTree(boot, requestPath string) (tree, error) {
	result := tree{Boot: boot, Memberships: make(map[string]membership), Groups: make(map[string]group)}
	var err error
	result.Observer, err = observerNamespace()
	if err != nil {
		return result, err
	}
	raw, err := os.ReadFile(requestPath)
	if err != nil {
		return result, err
	}
	var requested []request
	if err := json.Unmarshal(raw, &requested); err != nil {
		return result, err
	}
	if len(requested) != 64 {
		return result, fmt.Errorf("expected 64 verified leaves, received %d", len(requested))
	}
	pending := make(map[uint64]request, len(requested))
	ids := make(map[string]bool, len(requested))
	for _, row := range requested {
		if row.Leaf.Boot != boot || row.Leaf.Inode == 0 || pending[row.Leaf.Inode].ID != "" ||
			row.ID == "" || ids[row.ID] {
			return result, errors.New("request has a duplicate identity or belongs to a different guest boot")
		}
		pending[row.Leaf.Inode], ids[row.ID] = row, true
	}
	err = filepath.WalkDir(cgroupRoot, func(dir string, entry fs.DirEntry, err error) error {
		if err != nil || !entry.IsDir() {
			return err
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		ino := info.Sys().(*syscall.Stat_t).Ino
		target, found := pending[ino]
		if !found {
			return nil
		}
		path := strings.TrimPrefix(dir, cgroupRoot)
		if path == "" {
			return errors.New("observed a container in the worker root cgroup")
		}
		resident, err := findResident(dir, path, target.Leaf.Resident)
		if err != nil {
			return err
		}
		result.Memberships[target.ID] = membership{target.ID, path, resident}
		for scope := path; ; scope = filepath.Dir(scope) {
			if _, seen := result.Groups[scope]; seen {
				break
			}
			nodeDir := filepath.Join(cgroupRoot, scope)
			nodeIno, err := inode(nodeDir)
			if err != nil {
				return err
			}
			node, err := readGroup(nodeDir, nodeIno)
			if err != nil {
				return err
			}
			result.Groups[scope] = node
			if scope == "/" {
				break
			}
		}
		delete(pending, ino)
		if len(pending) == 0 {
			return fs.SkipAll
		}
		return nil
	})
	if err != nil {
		return result, err
	}
	if len(pending) != 0 {
		return result, fmt.Errorf("%d live cgroup inodes absent from the worker", len(pending))
	}
	return result, nil
}

func readScheduler(boot string, pid int) (map[string]any, error) {
	attr, err := unix.SchedGetAttr(pid, 0)
	if err != nil {
		return nil, err
	}
	status, err := read(fmt.Sprintf("/proc/%d/status", pid))
	if err != nil {
		return nil, err
	}
	fields := make(map[string]string)
	for _, line := range strings.Split(status, "\n") {
		key, value, _ := strings.Cut(line, ":")
		switch key {
		case "Uid", "PPid", "CapEff", "CapPrm", "CapAmb", "NoNewPrivs", "Cpus_allowed_list":
			fields[key] = strings.Join(strings.Fields(value), " ")
		}
	}
	cpuMax, err := read(cgroupRoot + "/cpu.max")
	if err != nil {
		return nil, err
	}
	ino, err := inode(cgroupRoot)
	if err != nil {
		return nil, err
	}
	proc, err := readProcess(pid)
	if err != nil {
		return nil, err
	}
	return map[string]any{"boot": boot, "process": proc, "inode": ino, "cpu.max": cpuMax,
		"status": fields, "policy": attr.Policy, "nice": attr.Nice, "priority": attr.Priority,
		"slice_ns": attr.Runtime}, nil
}

func run(args []string) error {
	if len(args) != 2 {
		return errors.New("expected leaf PID, tree REQUEST, or scheduler PID")
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
	var data any
	switch args[0] {
	case "tree":
		data, err = readTree(boot, args[1])
	case "leaf", "scheduler":
		pid, parseErr := strconv.Atoi(args[1])
		if args[0] == "scheduler" && args[1] == "self" {
			pid, parseErr = os.Getpid(), nil
		}
		if parseErr != nil || pid <= 0 {
			return errors.New("expected a positive process ID")
		}
		if args[0] == "leaf" {
			data, err = readLeaf(boot, pid)
		} else {
			data, err = readScheduler(boot, pid)
		}
	default:
		return fmt.Errorf("unknown observation %q", args[0])
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(data)
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
