//go:build linux && arm64

// Record queue entries from a disposable tracefs instance on the native worker.
package main

import (
	"bufio"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

const (
	event   = "events/csd/csd_queue_cpu"
	cpuRoot = "/sys/devices/system/cpu"
	bootID  = "/proc/sys/kernel/random/boot_id"
)

func read(path string) (string, error) {
	data, err := os.ReadFile(path)
	return strings.TrimSpace(string(data)), err
}

func files(root string, paths ...string) (map[string]string, error) {
	result := make(map[string]string, len(paths))
	for _, name := range paths {
		value, err := read(filepath.Join(root, name))
		if err != nil {
			return nil, err
		}
		result[name] = value
	}
	return result, nil
}

func save(dir, name string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	path := filepath.Join(dir, name+".json")
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func await(dir, name string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(filepath.Join(dir, "abort")); err == nil {
			return fmt.Errorf("host cancelled before %s", name)
		}
		if _, err := os.Stat(filepath.Join(dir, name)); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		time.Sleep(200 * time.Millisecond)
	}
	return fmt.Errorf("wait for %s exceeded %s", name, timeout)
}

func monotonic() (int64, error) {
	var value syscall.Timespec
	_, _, errno := syscall.RawSyscall(syscall.SYS_CLOCK_GETTIME, 1, uintptr(unsafe.Pointer(&value)), 0)
	if errno != 0 {
		return 0, errno
	}
	return value.Nano(), nil
}

func clock() ([]int64, error) {
	first, err := monotonic()
	if err != nil {
		return nil, err
	}
	wall := time.Now().UnixNano()
	last, err := monotonic()
	return []int64{first, wall, last}, err
}

func topology() (map[string]string, error) {
	result, err := files(cpuRoot, "online", "possible")
	if err != nil {
		return nil, err
	}
	for cpu := range 4 {
		prefix := fmt.Sprintf("cpu%d", cpu)
		for _, name := range []string{"core_cpus_list", "cluster_cpus_list", "package_cpus_list", "physical_package_id"} {
			path := prefix + "/topology/" + name
			value, err := read(filepath.Join(cpuRoot, path))
			if err == nil {
				result[path] = value
			} else if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
		}
		indices, err := filepath.Glob(filepath.Join(cpuRoot, prefix, "cache", "index*"))
		if err != nil {
			return nil, err
		}
		for _, index := range indices {
			values, err := files(index, "level", "type", "shared_cpu_list")
			if err != nil {
				return nil, err
			}
			for k, v := range values {
				result[filepath.Join(prefix, "cache", filepath.Base(index), k)] = v
			}
			if id, err := read(filepath.Join(index, "id")); err == nil {
				result[filepath.Join(prefix, "cache", filepath.Base(index), "id")] = id
			} else if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
		}
	}
	return result, nil
}

func symbols() (map[string]string, error) {
	file, err := os.Open("/proc/kallsyms")
	if err != nil {
		return nil, err
	}
	defer file.Close()
	lookup := map[string]string{}
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) != 3 || (fields[2] != "sched_ttwu_pending" && fields[2] != "ipi_mb") {
			continue
		}
		if _, exists := lookup[fields[2]]; exists {
			return nil, fmt.Errorf("ambiguous kernel symbol %s", fields[2])
		}
		lookup[fields[2]] = line
	}
	return lookup, scanner.Err()
}

func setCPU(cpu byte) error {
	var mask [128]byte
	mask[0] = 1 << cpu
	_, _, errno := syscall.RawSyscall(syscall.SYS_SCHED_SETAFFINITY, 0, uintptr(len(mask)), uintptr(unsafe.Pointer(&mask[0])))
	if errno != 0 {
		return errno
	}
	return nil
}

func osCPU() (uint32, error) {
	var cpu uint32
	_, _, errno := syscall.RawSyscall(syscall.SYS_GETCPU, uintptr(unsafe.Pointer(&cpu)), 0, 0)
	if errno != 0 {
		return cpu, errno
	}
	return cpu, nil
}

func membarrier(cmd uintptr) error {
	const sysMembarrierARM64 = 283
	_, _, errno := syscall.Syscall(sysMembarrierARM64, cmd, 0, 0)
	if errno != 0 {
		return errno
	}
	return nil
}

func positive() (map[string]any, error) {
	// Use two pinned threads in one mm to make an ordinary expedited
	// membarrier send a known callback to a second live vCPU.
	const registerPrivateExpedited = 16
	const privateExpedited = 8
	type pinned struct {
		cpu int
		tid int
		comm string
		err error
	}
	caller := make(chan pinned)
	target := make(chan pinned)
	var finished atomic.Bool
	go func() {
		runtime.LockOSThread()
		if err := setCPU(3); err != nil {
			target <- pinned{err: err}
			return
		}
		cpu, err := osCPU()
		target <- pinned{cpu: int(cpu), tid: syscall.Gettid(), err: err}
		deadline := time.Now().Add(250 * time.Millisecond)
		for !finished.Load() && time.Now().Before(deadline) {
		}
	}()
	remote := <-target
	if remote.err != nil {
		return nil, remote.err
	}
	defer finished.Store(true)
	go func() {
		runtime.LockOSThread()
		if err := setCPU(0); err != nil {
			caller <- pinned{err: err}
			return
		}
		const prSetName = 15
		name := []byte("mp-ttwu-waker\x00")
		_, _, errno := syscall.RawSyscall6(syscall.SYS_PRCTL, prSetName, uintptr(unsafe.Pointer(&name[0])), 0, 0, 0, 0)
		if errno != 0 {
			caller <- pinned{err: errno}
			return
		}
		comm, err := read("/proc/thread-self/comm")
		if err != nil || comm != "mp-ttwu-waker" {
			caller <- pinned{err: fmt.Errorf("control waker comm %q: %v", comm, err)}
			return
		}
		cpu, err := osCPU()
		if err == nil {
			err = membarrier(registerPrivateExpedited)
		}
		for i := 0; err == nil && i < 8; i++ {
			err = membarrier(privateExpedited)
		}
		caller <- pinned{cpu: int(cpu), tid: syscall.Gettid(), comm: comm, err: err}
	}()
	local := <-caller
	return map[string]any{"source_cpu": local.cpu, "target_cpu": remote.cpu, "source_comm": local.comm,
		"source_proc_tid": local.tid, "target_proc_tid": remote.tid, "membarriers": 8}, local.err
}

func set(root, path, value string) error {
	return os.WriteFile(filepath.Join(root, path), []byte(value), 0600)
}

func stats(root string) (map[string]string, error) {
	return files(root, "per_cpu/cpu0/stats", "per_cpu/cpu1/stats", "per_cpu/cpu2/stats", "per_cpu/cpu3/stats")
}

func dump(src, dst string) error {
	raw, err := os.Open(src)
	if err != nil {
		return err
	}
	defer raw.Close()
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	gzipWriter, _ := gzip.NewWriterLevel(out, gzip.BestSpeed)
	_, err = io.Copy(gzipWriter, raw)
	return errors.Join(err, gzipWriter.Close(), out.Close())
}

func tranche(root, dir, name string) error {
	// Opening trace with O_TRUNC clears the instance while tracing is off.
	if err := set(root, "trace", ""); err != nil {
		return err
	}
	empty, err := stats(root)
	if err != nil {
		return err
	}
	before, err := files(root, "tracing_on", event+"/enable", "set_event")
	if err != nil {
		return err
	}
	if err := set(root, event+"/enable", "1"); err != nil {
		return err
	}
	if err := set(root, "tracing_on", "1"); err != nil {
		return err
	}
	active, err := files(root, "tracing_on", event+"/enable", "set_event")
	if err != nil {
		return err
	}
	if active["tracing_on"] != "1" || active[event+"/enable"] != "1" || active["set_event"] != "csd:csd_queue_cpu" {
		return fmt.Errorf("unexpected active trace state: %v", active)
	}
	start, err := clock()
	if err != nil {
		return err
	}
	if err := set(root, "trace_marker", "mp-ttwu-begin-"+name); err != nil {
		return err
	}
	if err := save(dir, name+"-armed", start); err != nil {
		return err
	}
	var control map[string]any
	if name == "control" {
		control, err = positive()
	} else {
		err = await(dir, name+".stop", 35*time.Second)
	}
	if err != nil {
		return err
	}
	if err := set(root, "trace_marker", "mp-ttwu-end-"+name); err != nil {
		return err
	}
	end, err := clock()
	if err != nil {
		return err
	}
	if err := set(root, "tracing_on", "0"); err != nil {
		return err
	}
	if err := set(root, event+"/enable", "0"); err != nil {
		return err
	}
	stopped, err := files(root, "tracing_on", event+"/enable", "set_event")
	if err != nil {
		return err
	}
	full, err := stats(root)
	if err != nil {
		return err
	}
	if err := dump(filepath.Join(root, "trace"), filepath.Join(dir, name+".ftrace.gz")); err != nil {
		return err
	}
	return save(dir, name, map[string]any{"before": before, "active": active, "after": stopped,
		"empty": empty, "full": full, "start_clock": start, "end_clock": end, "control": control})
}

func trace(dir, mount, root string) error {
	settings := [][2]string{{"tracing_on", "0"}, {"events/enable", "0"}, {"trace_clock", "mono"},
		{"buffer_size_kb", "4096"}, {"options/overwrite", "0"}, {"tracing_cpumask", "f"}}
	for _, entry := range settings {
		if err := set(root, entry[0], entry[1]); err != nil {
			return err
		}
	}
	config, err := files(root, "trace_clock", "buffer_size_kb", "options/overwrite", "current_tracer",
		"tracing_cpumask", event+"/format", event+"/filter", "set_event")
	if err != nil {
		return err
	}
	topo, err := topology()
	if err != nil {
		return err
	}
	lookup, err := symbols()
	if err != nil {
		return err
	}
	boot, err := read(bootID)
	if err != nil {
		return err
	}
	mountinfo, err := read("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	var mountLine string
	for _, line := range strings.Split(mountinfo, "\n") {
		if strings.Contains(line, " "+mount+" ") {
			mountLine = line
		}
	}
	if err := save(dir, "setup", map[string]any{"boot": boot, "root": root, "mount": mount, "mountinfo": mountLine,
		"trace": config, "topology": topo, "kallsyms": lookup}); err != nil {
		return err
	}
	for _, name := range []string{"control", "dense-0", "dense-1", "dense-2", "dense-3"} {
		if err := await(dir, name+".start", 240*time.Second); err != nil {
			return err
		}
		if err := tranche(root, dir, name); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	return nil
}

func run(dir string) error {
	mount, err := os.MkdirTemp("/run", "mp-ttwu-")
	if err != nil {
		return err
	}
	if err := syscall.Mount("tracefs", mount, "tracefs", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, ""); err != nil {
		return errors.Join(err, os.Remove(mount))
	}
	root := filepath.Join(mount, "instances", filepath.Base(mount))
	if err := os.Mkdir(root, 0700); err != nil {
		return errors.Join(err, syscall.Unmount(mount, 0), os.Remove(mount))
	}
	traceErr := trace(dir, mount, root)
	stopped := errors.Join(set(root, "tracing_on", "0"), set(root, event+"/enable", "0"))
	final, readErr := files(root, "tracing_on", event+"/enable", "set_event")
	instanceErr := os.Remove(root)
	unmountErr := syscall.Unmount(mount, 0)
	rootErr := os.Remove(mount)
	cleanupErr := errors.Join(stopped, readErr, instanceErr, unmountErr, rootErr)
	topology, topoErr := topology()
	receipt := map[string]any{"instance": root, "mount": mount, "state": final,
		"instance_removed": instanceErr == nil, "tracefs_unmounted": unmountErr == nil,
		"mount_removed": rootErr == nil, "topology": topology}
	return errors.Join(traceErr, cleanupErr, topoErr, save(dir, "retired", receipt))
}

func main() {
	if len(os.Args) != 2 || os.Geteuid() != 0 {
		fmt.Fprintln(os.Stderr, "expected a private evidence directory and native guest root")
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		_ = save(os.Args[1], "error", err.Error())
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
