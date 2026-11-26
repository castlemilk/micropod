// Inspect ordinary Linux fair-scheduler slices or set one on the calling thread before exec.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"

	"golang.org/x/sys/unix"
)

type thread struct {
	TID      int    `json:"tid"`
	Policy   uint32 `json:"policy"`
	Nice     int32  `json:"nice"`
	Priority uint32 `json:"priority"`
	SliceNS  uint64 `json:"slice_ns"`
}

func inspect(pid int) ([]thread, error) {
	entries, err := os.ReadDir(filepath.Join("/proc", strconv.Itoa(pid), "task"))
	if err != nil {
		return nil, err
	}
	var tasks []thread
	for _, entry := range entries {
		tid, err := strconv.Atoi(entry.Name())
		if err != nil {
			return nil, err
		}
		a, err := unix.SchedGetAttr(tid, 0)
		if errors.Is(err, unix.ESRCH) && tid != pid {
			continue
		}
		if err != nil {
			return nil, err
		}
		tasks = append(tasks, thread{tid, a.Policy, a.Nice, a.Priority, a.Runtime})
	}
	return tasks, nil
}

func run() error {
	pid := flag.Int("inspect", 0, "read each thread belonging to this PID")
	marker := flag.String("service", "", "inspect the sibling server with this exact command line")
	program := flag.String("service-program", "/netbench", "executable expected for the service")
	slice := flag.Uint64("slice-ns", 0, "ordinary fair-scheduling slice in nanoseconds, zero keeps the inherited value")
	flag.Parse()
	if *marker != "" && *pid == 0 && *slice == 0 && flag.NArg() == 0 {
		entries, err := os.ReadDir("/proc")
		if err != nil {
			return err
		}
		if *program != "/netbench" && *program != "/mpcheck/netbench" {
			return errors.New("unexpected service executable")
		}
		wanted := []byte(*program + "\x00-listen\x00:8080\x00-marker\x00" + *marker + "\x00")
		service := 0
		for _, entry := range entries {
			p, err := strconv.Atoi(entry.Name())
			if err != nil {
				continue
			}
			cmd, _ := os.ReadFile(filepath.Join("/proc", entry.Name(), "cmdline"))
			if bytes.Equal(cmd, wanted) {
				if service != 0 {
					return errors.New("multiple matching sibling servers")
				}
				service = p
			}
		}
		if service == 0 {
			return errors.New("matching sibling server not found")
		}
		rows, err := inspect(service)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(struct {
			PID     int      `json:"pid"`
			Threads []thread `json:"threads"`
		}{service, rows})
	}
	if *pid > 0 && *slice == 0 && flag.NArg() == 0 {
		threads, err := inspect(*pid)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(threads)
	}
	if *pid != 0 || flag.NArg() < 1 || !filepath.IsAbs(flag.Arg(0)) || (*slice != 0 && (*slice < 100000 || *slice > 100000000)) {
		return errors.New("expected a fair slice and an absolute executable path")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	before, err := unix.SchedGetAttr(0, 0)
	if err != nil {
		return err
	}
	if before.Policy != unix.SCHED_NORMAL || before.Nice != 0 || before.Priority != 0 {
		return fmt.Errorf("expected ordinary scheduling at nice zero, got %+v", before)
	}
	if *slice != 0 {
		a := *before
		a.Runtime = *slice
		if err := unix.SchedSetAttr(0, &a, 0); err != nil {
			return fmt.Errorf("set fair slice %d: %w", *slice, err)
		}
	}
	after, err := unix.SchedGetAttr(0, 0)
	if err != nil {
		return err
	}
	if after.Policy != before.Policy || after.Priority != before.Priority || after.Nice != before.Nice ||
		(*slice != 0 && after.Runtime != *slice) {
		return fmt.Errorf("unexpected scheduling readback: %+v", after)
	}
	return unix.Exec(flag.Arg(0), flag.Args(), os.Environ())
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
