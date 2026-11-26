// Measure Linux kernel entry and short I/O paths on one locked OS thread.
// Run this diagnostic separately from the scored TCP workload.
package main

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

type operation struct {
	name  string
	trap  uintptr
	args  [6]uintptr
	want  uintptr
	errno syscall.Errno
}

type sample struct {
	Round       int    `json:"round"`
	Operation   string `json:"operation"`
	Calls       int    `json:"calls"`
	WallNS      int64  `json:"wall_ns"`
	ThreadCPUNS int64  `json:"thread_cpu_ns"`
}

func readText(path string) *string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	value := strings.TrimSpace(string(data))
	return &value
}

func threadCPU() (int64, error) {
	var usage syscall.Rusage
	if err := syscall.Getrusage(syscall.RUSAGE_THREAD, &usage); err != nil {
		return 0, err
	}
	return usage.Utime.Nano() + usage.Stime.Nano(), nil
}

func measure(op operation, calls, round int) (sample, error) {
	before, err := threadCPU()
	if err != nil {
		return sample{}, err
	}
	start := time.Now()
	for i := 0; i < calls; i++ {
		a := &op.args
		n, _, errno := syscall.RawSyscall6(op.trap, a[0], a[1], a[2], a[3], a[4], a[5])
		if n != op.want || errno != op.errno {
			if op.trap == syscall.SYS_ACCEPT4 && errno == 0 {
				syscall.Close(int(n))
			}
			return sample{}, fmt.Errorf("%s at iteration %d returned %d, errno %d", op.name, i, n, errno)
		}
	}
	elapsed := time.Since(start)
	after, err := threadCPU()
	return sample{round, op.name, calls, elapsed.Nanoseconds(), after - before}, err
}

func run(calls, rounds int) error {
	if calls < 1 || calls > 1000000 || rounds < 1 || rounds > 30 {
		return errors.New("calls must be 1..1000000 and rounds 1..30")
	}
	exe, err := os.Open("/proc/self/exe")
	if err != nil {
		return err
	}
	defer exe.Close()
	digest := sha256.New()
	if _, err := io.Copy(digest, exe); err != nil {
		return err
	}

	zero, err := os.Open("/dev/zero")
	if err != nil {
		return err
	}
	defer zero.Close()
	null, err := os.OpenFile("/dev/null", os.O_WRONLY, 0)
	if err != nil {
		return err
	}
	defer null.Close()
	ep, err := syscall.EpollCreate1(syscall.EPOLL_CLOEXEC)
	if err != nil {
		return err
	}
	defer syscall.Close(ep)
	fd, err := syscall.Socket(syscall.AF_INET, syscall.SOCK_STREAM|syscall.SOCK_NONBLOCK|syscall.SOCK_CLOEXEC, 0)
	if err != nil {
		return err
	}
	defer syscall.Close(fd)
	if err := syscall.Bind(fd, &syscall.SockaddrInet4{Addr: [4]byte{127, 0, 0, 1}}); err != nil {
		return err
	}
	if err := syscall.Listen(fd, 1); err != nil {
		return err
	}

	// A non-Go mapping keeps the syscall buffer address stable across samples.
	buf, err := syscall.Mmap(-1, 0, os.Getpagesize(), syscall.PROT_READ|syscall.PROT_WRITE, syscall.MAP_PRIVATE|syscall.MAP_ANON)
	if err != nil {
		return err
	}
	defer syscall.Munmap(buf)
	addr := uintptr(unsafe.Pointer(&buf[0]))
	ops := []operation{
		{name: "getppid", trap: syscall.SYS_GETPPID, want: uintptr(os.Getppid())},
		{name: "read_zero_1b", trap: syscall.SYS_READ, args: [6]uintptr{zero.Fd(), addr, 1}, want: 1},
		{name: "write_null_1b", trap: syscall.SYS_WRITE, args: [6]uintptr{null.Fd(), addr, 1}, want: 1},
		{name: "epoll_pwait_empty", trap: syscall.SYS_EPOLL_PWAIT, args: [6]uintptr{uintptr(ep), addr, 1, 0, 0, 0}},
		{name: "accept4_empty_eagain", trap: syscall.SYS_ACCEPT4, args: [6]uintptr{uintptr(fd), 0, 0, syscall.SOCK_CLOEXEC | syscall.SOCK_NONBLOCK}, want: ^uintptr(0), errno: syscall.EAGAIN},
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	for _, op := range ops {
		if _, err := measure(op, 256, 0); err != nil {
			return err
		}
	}
	rows := make([]sample, 0, rounds*len(ops))
	for round := 0; round < rounds; round++ {
		for i := range ops {
			row, err := measure(ops[(round+i)%len(ops)], calls, round+1)
			if err != nil {
				return err
			}
			rows = append(rows, row)
		}
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]any{
		"architecture": runtime.GOARCH, "kernel_release": readText("/proc/sys/kernel/osrelease"),
		"boot_id":         readText("/proc/sys/kernel/random/boot_id"),
		"meltdown_status": readText("/sys/devices/system/cpu/vulnerabilities/meltdown"),
		"page_bytes":      os.Getpagesize(), "probe_sha256": fmt.Sprintf("%x", digest.Sum(nil)), "samples": rows,
	})
}

func main() {
	calls := flag.Int("calls", 20000, "validated calls per operation and round")
	rounds := flag.Int("rounds", 5, "rotated rounds")
	flag.Parse()
	if err := run(*calls, *rounds); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
