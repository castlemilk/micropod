//go:build linux && arm64

// Calibrate per-vCPU host counters with a fixed number of guest instructions.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"strings"
)

func burn(iterations uint64) uint64

func main() {
	if len(os.Args) != 2 {
		os.Exit(2)
	}
	iterations, err := strconv.ParseUint(os.Args[1], 10, 32)
	if err != nil || iterations == 0 {
		os.Exit(2)
	}
	runtime.LockOSThread()
	status, err := os.ReadFile("/proc/thread-self/status")
	if err != nil {
		panic(err)
	}
	mask := ""
	for _, line := range strings.Split(string(status), "\n") {
		if v, ok := strings.CutPrefix(line, "Cpus_allowed_list:"); ok {
			mask = strings.TrimSpace(v)
		}
	}
	result := burn(iterations)
	if mask == "" || result != 16*iterations {
		os.Exit(1)
	}
	fmt.Printf("%s %d %d\n", mask, iterations, result)
}

