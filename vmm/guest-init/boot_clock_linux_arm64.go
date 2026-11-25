package main

import (
	"errors"
	"fmt"
	"math"
	"os"
	"syscall"
	"time"
	"unsafe"
)

func setRealtimeClock(unixNs int64) error {
	if unixNs < minBootRealtimeNano {
		return errors.New("realtime timestamp precedes minimum valid UTC floor")
	}
	const clockRealtime = 0
	now := syscall.NsecToTimespec(unixNs)
	_, _, errno := syscall.Syscall(syscall.SYS_CLOCK_SETTIME, clockRealtime, uintptr(unsafe.Pointer(&now)), 0)
	if errno != 0 {
		return fmt.Errorf("set CLOCK_REALTIME: %w", errno)
	}
	return nil
}

func initializeBootClock() error {
	cmdline, err := os.ReadFile("/proc/cmdline")
	if err != nil {
		return fmt.Errorf("read /proc/cmdline: %w", err)
	}
	stamp, err := parseBootRealtime(string(cmdline))
	if err != nil {
		return err
	}
	if stamp == 0 {
		if time.Now().Unix() < minBootRealtimeNano/int64(time.Second) {
			return errors.New("no VMM clock handoff and the guest clock is unset; use a matching VMM and initrd")
		}
		fmt.Fprintln(os.Stderr, "[mp-hvf-init] no VMM clock handoff; using the existing guest clock")
		return nil
	}

	// Linux UAPI clock IDs. Use uptime to compensate for time spent booting the guest.
	const clockBoottime = 7
	var uptime syscall.Timespec
	_, _, errno := syscall.Syscall(syscall.SYS_CLOCK_GETTIME, clockBoottime, uintptr(unsafe.Pointer(&uptime)), 0)
	if errno != 0 {
		return fmt.Errorf("read CLOCK_BOOTTIME: %w", errno)
	}
	elapsed := uptime.Nano()
	if elapsed < 0 || elapsed > math.MaxInt64-stamp {
		return errors.New("boot realtime plus guest uptime is out of range")
	}
	target := stamp + elapsed
	if err := setRealtimeClock(target); err != nil {
		return err
	}
	now := syscall.NsecToTimespec(target)
	fmt.Printf("[mp-hvf-init] initialized UTC clock from host at %s\n", time.Unix(now.Sec, now.Nsec).UTC().Format(time.RFC3339Nano))
	return nil
}
