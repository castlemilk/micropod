// Attribute each Go command and its waited-for children to the CI revision that ran it.
package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"
	"time"
)

type sample struct {
	Revision     string `json:"revision"`
	Stage        string `json:"stage"`
	WallUS       int64  `json:"wall_usec"`
	UserUS       int64  `json:"user_usec"`
	SystemUS     int64  `json:"system_usec"`
	MinorFaults  int64  `json:"minor_faults"`
	MajorFaults  int64  `json:"major_faults"`
	Voluntary    int64  `json:"voluntary_switches"`
	Involuntary  int64  `json:"involuntary_switches"`
	InputBlocks  int64  `json:"input_blocks"`
	OutputBlocks int64  `json:"output_blocks"`
	PeakRSS      int64  `json:"max_rss_kib"`
}

func run() (int, error) {
	logPath, revision := os.Getenv("MCI_USAGE_LOG"), os.Getenv("EXPECTED_REVISION")
	if len(os.Args) < 3 || logPath == "" || revision == "" {
		return 64, errors.New("expected a usage log, revision, executable and Go subcommand")
	}
	cmd := exec.Command(os.Args[1], os.Args[2:]...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	start := time.Now()
	err := cmd.Run()
	wall := time.Since(start)
	if cmd.ProcessState == nil {
		return 1, err
	}
	usage := cmd.ProcessState.SysUsage().(*syscall.Rusage)
	row := sample{
		Revision: revision, Stage: os.Args[2], WallUS: wall.Microseconds(),
		UserUS: usage.Utime.Nano() / 1000, SystemUS: usage.Stime.Nano() / 1000,
		MinorFaults: usage.Minflt, MajorFaults: usage.Majflt, Voluntary: usage.Nvcsw, Involuntary: usage.Nivcsw,
		InputBlocks: usage.Inblock, OutputBlocks: usage.Oublock, PeakRSS: usage.Maxrss,
	}
	f, err := os.OpenFile(logPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0600)
	if err != nil {
		return 1, err
	}
	encodeErr := json.NewEncoder(f).Encode(row)
	if err := errors.Join(encodeErr, f.Close()); err != nil {
		return 1, err
	}
	status := cmd.ProcessState.Sys().(syscall.WaitStatus)
	if status.Signaled() {
		return 128 + int(status.Signal()), nil
	}
	return cmd.ProcessState.ExitCode(), nil
}

func main() {
	code, err := run()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
	}
	os.Exit(code)
}
