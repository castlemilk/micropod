// Observe all available Linux task affinities from inside a sibling container.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

type Scheduler struct {
	Policy   uint32 `json:"policy"`
	Nice     int32  `json:"nice"`
	Priority uint32 `json:"priority"`
	SliceNS  uint64 `json:"slice_ns"`
}

type thread struct {
	TID  int    `json:"tid"`
	CPUs string `json:"cpus_allowed_list"`
	*Scheduler
}

func servicePID(wanted []string) (int, error) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return 0, err
	}
	pid := 0
	for _, entry := range entries {
		candidate, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		data, _ := os.ReadFile("/proc/" + entry.Name() + "/cmdline")
		argv := strings.Split(strings.TrimSuffix(string(data), "\x00"), "\x00")
		if !slices.Equal(argv, wanted) {
			continue
		}
		if pid != 0 {
			return 0, fmt.Errorf("multiple service processes match %q", wanted)
		}
		pid = candidate
	}
	if pid == 0 {
		return 0, fmt.Errorf("no service process matches %q", wanted)
	}
	return pid, nil
}

func readThreads(pid int, scheduler bool) ([]thread, error) {
	var tasks []thread
	if scheduler {
		out, err := exec.Command("/mpcheck/slice", "-inspect", strconv.Itoa(pid)).Output()
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal(out, &tasks); err != nil {
			return nil, err
		}
	} else {
		entries, err := os.ReadDir(fmt.Sprintf("/proc/%d/task", pid))
		if err != nil {
			return nil, err
		}
		for _, entry := range entries {
			tid, err := strconv.Atoi(entry.Name())
			if err != nil {
				return nil, err
			}
			tasks = append(tasks, thread{TID: tid})
		}
	}
	observed := tasks[:0]
	for _, task := range tasks {
		path := fmt.Sprintf("/proc/%d/task/%d/status", pid, task.TID)
		data, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) && task.TID != pid {
			continue
		}
		if err != nil {
			return nil, err
		}
		for _, line := range strings.Split(string(data), "\n") {
			if cpus, ok := strings.CutPrefix(line, "Cpus_allowed_list:"); ok {
				task.CPUs = strings.TrimSpace(cpus)
				break
			}
		}
		if task.CPUs == "" {
			return nil, fmt.Errorf("missing CPU affinity in %s", path)
		}
		observed = append(observed, task)
	}
	return observed, nil
}

func run() error {
	pid := flag.Int("inspect", 0, "read task affinity for the warmed HTTP client")
	marker := flag.String("service", "", "read task affinity for the named sibling service")
	program := flag.String("service-program", "/netbench", "exact executable used by the service")
	flag.Parse()
	if flag.NArg() != 0 || (*pid > 0) == (*marker != "") {
		return errors.New("expected one process ID or service marker")
	}
	out := json.NewEncoder(os.Stdout)
	if *marker != "" {
		argv := []string{*program, "-listen", ":8080", "-marker", *marker}
		id, err := servicePID(argv)
		if err != nil {
			return err
		}
		tasks, err := readThreads(id, false)
		if err != nil {
			return err
		}
		return out.Encode(struct {
			PID     int      `json:"pid"`
			Argv    []string `json:"argv"`
			Threads []thread `json:"threads"`
		}{id, argv, tasks})
	}
	if *pid != os.Getppid() {
		return fmt.Errorf("HTTP client PID %d is not the probe parent", *pid)
	}
	_, err := os.Stat("/mpcheck/slice")
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	tasks, err := readThreads(*pid, err == nil)
	if err != nil {
		return err
	}
	return out.Encode(tasks)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
