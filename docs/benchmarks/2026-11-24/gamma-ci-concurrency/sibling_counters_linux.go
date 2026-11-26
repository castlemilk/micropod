// Sample the guest's ARM timer and scheduler counters at the HTTP window boundaries.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

type snapshot struct {
	Begin      int64  `json:"begin_ns"`
	End        int64  `json:"end_ns"`
	Interrupts string `json:"interrupts"`
	Stat       string `json:"stat"`
	SoftIRQs   string `json:"softirqs"`
}

type window struct {
	Tag      string   `json:"tag"`
	Start    int64    `json:"start_ns"`
	Duration int64    `json:"duration_ns"`
	Before   snapshot `json:"before"`
	After    snapshot `json:"after"`
}

func sample() (snapshot, error) {
	s := snapshot{Begin: time.Now().UnixNano()}
	for _, file := range []struct {
		name string
		dst  *string
	}{{"interrupts", &s.Interrupts}, {"stat", &s.Stat}, {"softirqs", &s.SoftIRQs}} {
		b, err := os.ReadFile(filepath.Join("/proc", file.name))
		if err != nil {
			return s, err
		}
		*file.dst = string(b)
	}
	s.End = time.Now().UnixNano()
	return s, nil
}

func capture(work, tag string, duration time.Duration) error {
	if tag == "" || filepath.Base(tag) != tag {
		return errors.New("invalid traffic gate")
	}
	gate := filepath.Join(work, "gate", tag)
	until := time.Now().Add(20 * time.Minute)
	var start int64
	for {
		raw, err := os.ReadFile(gate)
		if err == nil {
			start, err = strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
			if err != nil || start <= 0 {
				return errors.New("invalid traffic deadline")
			}
			break
		}
		if !errors.Is(err, os.ErrNotExist) || time.Now().After(until) {
			return fmt.Errorf("waiting for %s: %w", gate, err)
		}
		time.Sleep(5 * time.Millisecond)
	}
	deadline := time.Unix(0, start)
	time.Sleep(time.Until(deadline))
	before, err := sample()
	if err != nil {
		return err
	}
	time.Sleep(time.Until(deadline.Add(duration)))
	after, err := sample()
	if err != nil {
		return err
	}
	data, err := json.Marshal(window{tag, start, int64(duration), before, after})
	if err != nil {
		return err
	}
	path := filepath.Join(work, "guest-counters", tag+".json")
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func main() {
	work := flag.String("workspace", "", "owned worker workspace")
	ms := flag.Int("duration-ms", 0, "traffic interval in milliseconds")
	flag.Parse()
	if *work == "" || *ms <= 0 || flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}
	for _, tag := range flag.Args() {
		if err := capture(*work, tag, time.Duration(*ms)*time.Millisecond); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
	}
}
