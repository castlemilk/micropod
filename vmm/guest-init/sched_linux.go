//go:build linux

package main

import (
	"fmt"
	"os"
	"syscall"
)

// schedDebugMount is where guest init mounts debugfs for the scheduler
// settings; it is unmounted again at once, so nothing else sees it.
const schedDebugMount = "/run/mp-hvf-debugfs"

// configureSchedulerSlice sets the fair scheduler's base slice (sched.go)
// before the engine starts. A failure is logged and the boot goes on with
// the kernel's slice.
func configureSchedulerSlice(params map[string]string) {
	ns, ok, err := schedSlice(params)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] %v\n", err)
	}
	if !ok {
		fmt.Printf("[mp-hvf-init] scheduler base slice: kernel default (%s=default)\n", schedSliceArg)
		return
	}
	if err := os.MkdirAll(schedDebugMount, 0700); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] scheduler base slice not set: mkdir %s: %v\n", schedDebugMount, err)
		return
	}
	defer os.Remove(schedDebugMount)
	if err := syscall.Mount("debugfs", schedDebugMount, "debugfs", syscall.MS_NOSUID|syscall.MS_NODEV|syscall.MS_NOEXEC, ""); err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] scheduler base slice not set: mount debugfs: %v\n", err)
		return
	}
	defer func() { _ = syscall.Unmount(schedDebugMount, syscall.MNT_DETACH) }()
	before, after, err := setSchedSlice(schedDebugMount, ns)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[mp-hvf-init] scheduler base slice: %v (now %d ns)\n", err, after)
		return
	}
	fmt.Printf("[mp-hvf-init] scheduler base slice: %d ns (kernel default %d ns)\n", after, before)
}
