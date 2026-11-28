//go:build linux

package main

import (
	"fmt"
	"os"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

// fitrim is FITRIM, _IOWR('X', 121, struct fstrim_range).
const fitrim = 0xc0185879

type fstrimRange struct {
	start, len, minlen uint64
}

// trimStopping is set when the machine starts to stop: a pass ends after
// the range under way.
var trimStopping atomic.Bool

// fitrimRange discards the free blocks of [start, start+length) of the
// filesystem mounted at path and returns the bytes discarded.
func fitrimRange(path string, start, length uint64) (uint64, error) {
	fd, err := syscall.Open(path, syscall.O_RDONLY|syscall.O_DIRECTORY|syscall.O_CLOEXEC, 0)
	if err != nil {
		return 0, err
	}
	defer syscall.Close(fd)
	r := fstrimRange{start: start, len: length}
	if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), fitrim, uintptr(unsafe.Pointer(&r))); errno != 0 {
		return 0, errno
	}
	return r.len, nil
}

// machineIdle samples the CPUs and the I/O pressure over trimIdleWindow.
func machineIdle() bool {
	readCPU := func() (cpuSample, bool) {
		b, err := os.ReadFile("/proc/stat")
		if err != nil {
			return cpuSample{}, false
		}
		s, err := parseProcStat(b)
		return s, err == nil
	}
	readIO := func() (uint64, bool) {
		b, err := os.ReadFile("/proc/pressure/io")
		if err != nil {
			return 0, false
		}
		return psiSomeTotal(b)
	}
	cpu0, cpuOK := readCPU()
	io0, ioOK := readIO()
	time.Sleep(trimIdleWindow)
	cpu1, cpuOK1 := readCPU()
	io1, ioOK1 := readIO()
	if !cpuOK || !cpuOK1 || busyCPUs(cpu0, cpu1) >= trimBusyCPUs {
		return false
	}
	// Without PSI (psi=0) the CPUs decide alone.
	if ioOK && ioOK1 && float64(io1-io0) >= trimIOStallShare*float64(trimIdleWindow/time.Microsecond) {
		return false
	}
	return true
}

// startIdleTrim trims the root filesystem and, when it is mounted, the
// cache disk's, while the machine is idle (trim.go).
func startIdleTrim(params map[string]string) {
	interval, ok, err := idleTrimInterval(params)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] %v\n", err)
	}
	if !ok {
		fmt.Printf("[mp-hvf-init] idle trim: off (%s=off)\n", idleTrimArg)
		return
	}
	paths := []string{"/"}
	if cacheDisk == cacheDiskMounted {
		paths = append(paths, cacheDiskMount)
	}
	var targets []*trimTarget
	for _, p := range paths {
		var st syscall.Statfs_t
		if err := syscall.Statfs(p, &st); err != nil {
			fmt.Fprintf(os.Stderr, "[mp-hvf-init] idle trim: statfs %s: %v\n", p, err)
			continue
		}
		targets = append(targets, &trimTarget{path: p, size: st.Blocks * uint64(st.Bsize)})
	}
	if len(targets) == 0 {
		return
	}
	tr := &trimmer{
		trim:    fitrimRange,
		idle:    machineIdle,
		stopped: trimStopping.Load,
		now:     time.Now,
		logf:    func(format string, args ...any) { fmt.Printf(format+"\n", args...) },
	}
	fmt.Printf("[mp-hvf-init] idle trim: every %s\n", interval)
	go func() {
		for !trimStopping.Load() {
			time.Sleep(interval)
			for _, t := range targets {
				tr.pass(t)
			}
		}
	}()
}
