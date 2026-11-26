// Measure the CPU delivered to a pinned ordinary container during a shared wall-clock interval.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type receipt struct {
	Weight    int    `json:"weight"`
	Scheduled int64  `json:"scheduled_ns,omitempty"`
	Started   int64  `json:"started_ns,omitempty"`
	Finished  int64  `json:"finished_ns,omitempty"`
	CPU       int64  `json:"cpu_ns,omitempty"`
	Rounds    uint64 `json:"rounds,omitempty"`
	Digest    uint64 `json:"digest,omitempty"`
}

func cpuTime() (int64, error) {
	var use syscall.Rusage
	err := syscall.Getrusage(syscall.RUSAGE_SELF, &use)
	return use.Utime.Nano() + use.Stime.Nano(), err
}

func measure(ready, start string, row *receipt) error {
	now := time.Now()
	if err := os.WriteFile(ready, []byte(strconv.FormatInt(now.UnixNano(), 10)), 0600); err != nil {
		return err
	}
	for {
		data, err := os.ReadFile(start)
		if err == nil {
			row.Scheduled, err = strconv.ParseInt(string(data), 10, 64)
			if err != nil || row.Scheduled <= now.UnixNano() {
				return errors.New("invalid CPU probe deadline")
			}
			break
		}
		if !errors.Is(err, os.ErrNotExist) || time.Since(now) > 10*time.Second {
			return fmt.Errorf("waiting for CPU probe start: %w", err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	startAt := time.Unix(0, row.Scheduled)
	time.Sleep(time.Until(startAt))
	row.Started = time.Now().UnixNano()
	before, err := cpuTime()
	if err != nil {
		return err
	}
	end := startAt.Add(1200 * time.Millisecond)
	x := uint64(1)
	for time.Now().Before(end) {
		for i := 0; i < 8192; i++ {
			x = x*6364136223846793005 + 1
		}
		row.Rounds++
	}
	row.Finished = time.Now().UnixNano()
	after, err := cpuTime()
	row.CPU, row.Digest = after-before, x
	return err
}

func run() error {
	ready := flag.String("ready", "", "file marking readiness")
	start := flag.String("start", "", "file containing the common guest deadline")
	flag.Parse()
	if (*ready == "") != (*start == "") || flag.NArg() != 0 {
		return errors.New("provide both gate paths or neither")
	}
	data, err := os.ReadFile("/sys/fs/cgroup/cpu.weight")
	if err != nil {
		return err
	}
	row := receipt{}
	row.Weight, err = strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		return err
	}
	if *ready != "" {
		if err := measure(*ready, *start, &row); err != nil {
			return err
		}
	}
	return json.NewEncoder(os.Stdout).Encode(row)
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
