// Wait for the two original CI revisions and account for their descendants.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

var wave = regexp.MustCompile("^grouped-([0-3])-all-[AB]$")

const publishDelay = 5 * time.Second

type sample struct {
	Tag          string   `json:"tag"`
	Slot         int      `json:"slot"`
	Revision     string   `json:"revision"`
	Boot         string   `json:"boot"`
	Container    string   `json:"container"`
	Cgroup       string   `json:"cgroup"`
	Argv         []string `json:"argv"`
	ChildPID     int      `json:"child_pid"`
	WaitStatus   int      `json:"wait_status"`
	ExitCode     int      `json:"exit_code"`
	Start        int64    `json:"started_unix_ns"`
	ChildStarted int64    `json:"child_started_unix_ns"`
	Finished     int64    `json:"finished_unix_ns"`
	Published    int64    `json:"publish_started_unix_ns"`
	Elapsed      int64    `json:"elapsed_ns"`
	UserUS       int64    `json:"user_usec"`
	SystemUS     int64    `json:"system_usec"`
	MinorFaults  int64    `json:"minor_faults"`
	MajorFaults  int64    `json:"major_faults"`
	Voluntary    int64    `json:"voluntary_switches"`
	Involuntary  int64    `json:"involuntary_switches"`
	InputBlocks  int64    `json:"input_blocks"`
	OutputBlocks int64    `json:"output_blocks"`
	MaxRSS       int64    `json:"max_rss_kib"`
}

func run(args []string) (int, error) {
	if len(args) != 4 {
		return 64, errors.New("expected the wave, slot, original revision and nice value")
	}
	match := wave.FindStringSubmatch(args[0])
	slot, err := strconv.Atoi(args[1])
	if err != nil || match == nil || slot < 0 || slot > 7 || strconv.Itoa(slot) != args[1] ||
		args[2] != fmt.Sprintf("sibling-%s-%d", match[1], slot) || args[3] != "0" {
		return 64, errors.New("wrong paired build identity")
	}
	var fs syscall.Statfs_t
	if err := syscall.Statfs("/dev/shm", &fs); err != nil {
		return 1, err
	}
	if fs.Type != 0x01021994 {
		return 1, errors.New("build usage output is not on the private tmpfs")
	}
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return 1, err
	}
	leaf, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return 1, err
	}
	container := os.Getenv("MP_RAW_ID")
	if container == "" || strings.TrimSpace(string(leaf)) != "0::/" {
		return 1, errors.New("build usage needs the measured container leaf")
	}

	argv := []string{"/bin/sh", "/mpcheck/file-fault-around-build-pair.sh", args[2], args[3]}
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	start := time.Now()
	if err := cmd.Start(); err != nil {
		return 1, err
	}
	childStarted := time.Now()
	waitErr := cmd.Wait()
	finished := time.Now()
	state := cmd.ProcessState
	if state == nil {
		return 1, waitErr
	}
	u := state.SysUsage().(*syscall.Rusage)
	status := state.Sys().(syscall.WaitStatus)
	row := sample{
		Tag: args[0], Slot: slot, Revision: args[2], Boot: strings.TrimSpace(string(boot)), Container: container,
		Cgroup: "0::/", Argv: argv, ChildPID: state.Pid(), WaitStatus: int(status), ExitCode: state.ExitCode(),
		Start: start.UnixNano(), ChildStarted: childStarted.UnixNano(), Finished: finished.UnixNano(),
		Elapsed: finished.Sub(start).Nanoseconds(),
		UserUS:  u.Utime.Nano() / 1000, SystemUS: u.Stime.Nano() / 1000, MinorFaults: u.Minflt, MajorFaults: u.Majflt,
		Voluntary: u.Nvcsw, Involuntary: u.Nivcsw, InputBlocks: u.Inblock, OutputBlocks: u.Oublock, MaxRSS: u.Maxrss,
	}
	// Hold the record in memory. Replay also verifies that every sibling
	// finished before the first sidecar write in its wave.
	time.Sleep(time.Until(start.Add(publishDelay)))
	row.Published = time.Now().UnixNano()
	path := fmt.Sprintf("/dev/shm/mp-file-fault-around.%s.%d.json", args[0], slot)
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return 1, err
	}
	if err := errors.Join(json.NewEncoder(out).Encode(row), out.Close()); err != nil {
		return 1, err
	}
	if status.Signaled() {
		return 128 + int(status.Signal()), nil
	}
	return state.ExitCode(), nil
}

func main() {
	code, err := run(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(code)
}
