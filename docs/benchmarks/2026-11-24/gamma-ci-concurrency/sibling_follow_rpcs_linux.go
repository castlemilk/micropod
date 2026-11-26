//go:build linux && arm64

// Count entries to the native Docker engine's real CRI client on a disposable VM.
package main

import (
	"bytes"
	"crypto/sha256"
	"debug/elf"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"

	"golang.org/x/net/http2"
	"golang.org/x/sys/unix"
)

const runner = "/opt/micropod-oci/runner/bin/job"

var phases = []string{"idle-before", "positive", "dense-0", "dense-1", "dense-2", "dense-3", "idle-after"}
var symbols = map[string]string{
	"status": "k8s.io/cri-api/pkg/apis/runtime/v1.(*runtimeServiceClient).ContainerStatus",
	"stats":  "main.(*dockerEngine).kernelStats",
	"drain":  "main.(*criOutput).drain",
}

type point struct {
	Name   string `json:"name"`
	PC     uint64 `json:"pc"`
	Offset uint64 `json:"offset"`
}
type counting struct {
	Kind    string `json:"kind"`
	CPU     int    `json:"cpu"`
	Count   uint64 `json:"count"`
	Enabled uint64 `json:"enabled_ns"`
	Running uint64 `json:"running_ns"`
	fd      int
}
type activity struct {
	PID    int    `json:"pid"`
	Birth  string `json:"birth_ticks"`
	User   uint64 `json:"user_ticks"`
	System uint64 `json:"system_ticks"`
	Reads  uint64 `json:"read_syscalls"`
}

func save(dir, key string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	file := filepath.Join(dir, key+".json")
	if err = os.WriteFile(file+".tmp", b, 0600); err != nil {
		return err
	}
	return os.Rename(file+".tmp", file)
}
func wait(dir, key string) error {
	end := time.Now().Add(200 * time.Second)
	for time.Now().Before(end) {
		if _, err := os.Stat(filepath.Join(dir, "abort")); err == nil {
			return errors.New("diagnostic cancelled")
		}
		if _, err := os.Stat(filepath.Join(dir, key)); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("timeout waiting for %s", key)
}
func text(path string) (string, error) {
	b, e := os.ReadFile(path)
	return strings.TrimSpace(string(b)), e
}

// Read the settings from the same local Unix socket used by the runner's CRI client.
func containerdSettings() (map[string]uint32, error) {
	conn, err := net.DialTimeout("unix", "/run/containerd/containerd.sock", 3*time.Second)
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return nil, err
	}
	if _, err := io.WriteString(conn, http2.ClientPreface); err != nil {
		return nil, err
	}
	wire := http2.NewFramer(conn, conn)
	if err := wire.WriteSettings(); err != nil {
		return nil, err
	}
	frame, err := wire.ReadFrame()
	if err != nil {
		return nil, err
	}
	settings, ok := frame.(*http2.SettingsFrame)
	if !ok || settings.IsAck() {
		return nil, errors.New("missing initial HTTP/2 SETTINGS from containerd")
	}
	values := map[string]uint32{}
	if err := settings.ForeachSetting(func(s http2.Setting) error {
		values[s.ID.String()] = s.Val
		return nil
	}); err != nil {
		return nil, err
	}
	return values, wire.WriteSettingsAck()
}

func identify() (int, map[string]point, map[string]any, error) {
	file, e := os.Open(runner)
	if e != nil {
		return 0, nil, nil, e
	}
	defer file.Close()
	exe, e := elf.NewFile(file)
	if e != nil {
		return 0, nil, nil, e
	}
	if exe.Machine != elf.EM_AARCH64 || exe.Type != elf.ET_EXEC {
		return 0, nil, nil, errors.New("unexpected native runner ELF")
	}
	syms, e := exe.Symbols()
	if e != nil {
		return 0, nil, nil, e
	}
	found := map[string]point{}
	for key, name := range symbols {
		for _, s := range syms {
			if s.Name != name || elf.ST_TYPE(s.Info) != elf.STT_FUNC {
				continue
			}
			for _, seg := range exe.Progs {
				if seg.Type == elf.PT_LOAD && seg.Flags&elf.PF_X != 0 && s.Value >= seg.Vaddr && s.Value+s.Size <= seg.Vaddr+seg.Filesz && s.Size >= 4 {
					if _, ok := found[key]; ok {
						return 0, nil, nil, fmt.Errorf("ambiguous code for %s", name)
					}
					found[key] = point{name, s.Value, s.Value - seg.Vaddr + seg.Off}
				}
			}
		}
	}
	if len(found) != len(symbols) {
		return 0, nil, nil, errors.New("absent runner function")
	}
	hash := sha256.New()
	if _, e = file.Seek(0, 0); e != nil {
		return 0, nil, nil, e
	}
	if _, e = io.Copy(hash, file); e != nil {
		return 0, nil, nil, e
	}
	info, e := file.Stat()
	if e != nil {
		return 0, nil, nil, e
	}
	names, e := os.ReadDir("/proc")
	if e != nil {
		return 0, nil, nil, e
	}
	pid := 0
	for _, v := range names {
		n, err := strconv.Atoi(v.Name())
		if err != nil {
			continue
		}
		p := "/proc/" + v.Name()
		b, err := os.ReadFile(p + "/cmdline")
		if err != nil {
			continue
		}
		args := bytes.Split(bytes.TrimSuffix(b, []byte{0}), []byte{0})
		if len(args) != 2 || string(args[1]) != "engine" {
			continue
		}
		target, err := os.Stat(p + "/exe")
		if err != nil || !os.SameFile(info, target) {
			continue
		}
		if pid != 0 {
			return 0, nil, nil, errors.New("multiple engines with measured executable")
		}
		pid = n
	}
	if pid == 0 {
		return 0, nil, nil, errors.New("active engine does not map the probed executable")
	}
	boot, e := text("/proc/sys/kernel/random/boot_id")
	if e != nil {
		return 0, nil, nil, e
	}
	online, e := text("/sys/devices/system/cpu/online")
	if e != nil || online != "0-3" {
		return 0, nil, nil, fmt.Errorf("unexpected online CPUs %q: %v", online, e)
	}
	return pid, found, map[string]any{"runner": runner, "sha256": fmt.Sprintf("%x", hash.Sum(nil)), "inode": info.Sys().(*syscall.Stat_t).Ino, "boot": boot, "pid": pid, "online": online, "symbols": found}, nil
}
func activityAt(pid int) (activity, error) {
	root := fmt.Sprintf("/proc/%d/", pid)
	raw, e := text(root + "stat")
	if e != nil {
		return activity{}, e
	}
	_, tail, ok := strings.Cut(raw, ") ")
	s := strings.Fields(tail)
	if !ok || len(s) < 20 {
		return activity{}, errors.New("unexpected proc stat")
	}
	row := activity{PID: pid, Birth: s[19]}
	if row.User, e = strconv.ParseUint(s[11], 10, 64); e != nil {
		return row, e
	}
	if row.System, e = strconv.ParseUint(s[12], 10, 64); e != nil {
		return row, e
	}
	stats, e := text(root + "io")
	if e != nil {
		return row, e
	}
	for _, line := range strings.Split(stats, "\n") {
		if value, ok := strings.CutPrefix(line, "syscr: "); ok {
			row.Reads, e = strconv.ParseUint(value, 10, 64)
			return row, e
		}
	}
	return row, errors.New("missing engine read syscall count")
}

func watchCounts(pid int) (map[string]int, error) {
	root := fmt.Sprintf("/proc/%d", pid)
	files, err := os.ReadDir(root + "/fd")
	if err != nil {
		return nil, err
	}
	counts := map[string]int{}
	for _, entry := range files {
		link, err := os.Readlink(root + "/fd/" + entry.Name())
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if link != "anon_inode:inotify" && link != "anon_inode:[inotify]" {
			continue
		}
		raw, err := os.ReadFile(root + "/fdinfo/" + entry.Name())
		if err != nil {
			return nil, err
		}
		counts[entry.Name()] = bytes.Count(raw, []byte("\ninotify wd:"))
	}
	return counts, nil
}
func openCounters(pmu int, points map[string]point) (items []counting, err error) {
	path, e := unix.BytePtrFromString(runner)
	if e != nil {
		return nil, e
	}
	defer func() {
		runtime.KeepAlive(path)
		if err != nil {
			for _, p := range items {
				unix.Close(p.fd)
			}
		}
	}()
	for _, kind := range []string{"status", "stats", "drain"} {
		for cpu := 0; cpu < 4; cpu++ {
			attr := unix.PerfEventAttr{Type: uint32(pmu), Bits: unix.PerfBitDisabled, Read_format: unix.PERF_FORMAT_TOTAL_TIME_ENABLED | unix.PERF_FORMAT_TOTAL_TIME_RUNNING, Ext1: uint64(uintptr(unsafe.Pointer(path))), Ext2: points[kind].Offset}
			attr.Size = uint32(unsafe.Sizeof(attr))
			fd, e := unix.PerfEventOpen(&attr, -1, cpu, -1, unix.PERF_FLAG_FD_CLOEXEC)
			if e != nil {
				return items, fmt.Errorf("open %s on CPU %d at file offset %#x: %w", kind, cpu, points[kind].Offset, e)
			}
			items = append(items, counting{Kind: kind, CPU: cpu, fd: fd})
		}
	}
	return items, nil
}
func phase(dir, name string, pid, pmu int, points map[string]point) (err error) {
	if err = wait(dir, name+".start"); err != nil {
		return err
	}
	items, err := openCounters(pmu, points)
	if err != nil {
		return err
	}
	defer func() {
		for _, p := range items {
			err = errors.Join(err, unix.Close(p.fd))
		}
	}()
	before, err := activityAt(pid)
	if err != nil {
		return err
	}
	first := time.Now()
	for _, p := range items {
		if err = unix.IoctlSetInt(p.fd, unix.PERF_EVENT_IOC_ENABLE, 0); err != nil {
			return err
		}
	}
	if err = save(dir, name+"-armed", map[string]any{"unix_ns": time.Now().UnixNano()}); err != nil {
		return err
	}
	if err = wait(dir, name+".stop"); err != nil {
		return err
	}
	for _, p := range items {
		if err = unix.IoctlSetInt(p.fd, unix.PERF_EVENT_IOC_DISABLE, 0); err != nil {
			return err
		}
	}
	elapsed := time.Since(first)
	after, err := activityAt(pid)
	if err != nil {
		return err
	}
	if after.Birth != before.Birth {
		return errors.New("native job engine restarted during measurement")
	}
	for i, p := range items {
		var buf [24]byte
		n, e := unix.Read(p.fd, buf[:])
		if e != nil || n != len(buf) {
			return fmt.Errorf("short perf counter: %d: %v", n, e)
		}
		items[i].Count = binary.LittleEndian.Uint64(buf[:8])
		items[i].Enabled = binary.LittleEndian.Uint64(buf[8:16])
		items[i].Running = binary.LittleEndian.Uint64(buf[16:24])
	}
	return save(dir, name, map[string]any{"started_unix_ns": first.UnixNano(), "duration_ns": elapsed.Nanoseconds(), "before": before, "after": after, "counters": items})
}
func run(dir string) error {
	if err := wait(dir, "idle-before.start"); err != nil {
		return err
	}
	pid, points, meta, err := identify()
	if err != nil {
		return err
	}
	raw, err := text("/sys/bus/event_source/devices/uprobe/type")
	if err != nil {
		return err
	}
	pmu, err := strconv.Atoi(raw)
	if err != nil {
		return err
	}
	meta["pmu_type"] = pmu
	meta["probe_phases"] = phases
	if len(os.Args) == 3 {
		before, err := watchCounts(pid)
		if err != nil {
			return err
		}
		meta["engine_inotify_watches_before"] = before
	}
	settings, err := containerdSettings()
	if err != nil {
		return fmt.Errorf("read bundled containerd stream settings: %w", err)
	}
	meta["containerd_initial_settings"] = settings
	if err = save(dir, "identity", meta); err != nil {
		return err
	}
	for _, name := range phases {
		if err = phase(dir, name, pid, pmu, points); err != nil {
			return fmt.Errorf("%s: %w", name, err)
		}
	}
	if len(os.Args) == 3 {
		after, err := watchCounts(pid)
		if err != nil {
			return err
		}
		if err := save(dir, "engine-watches-after", after); err != nil {
			return err
		}
	}
	return save(dir, "retired", map[string]any{"counter_fds_closed": len(phases) * len(symbols) * 4, "boot": meta["boot"]})
}
func main() {
	if len(os.Args) == 3 && os.Args[2] == "log-positive" {
		phases = append([]string{"idle-before", "positive", "log-positive"}, phases[2:]...)
	} else if len(os.Args) != 2 {
		os.Exit(2)
	}
	if err := run(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		_ = save(os.Args[1], "error", err.Error())
		os.Exit(1)
	}
}
