// Buffer CI phase markers and their cgroup reads until the dispatcher ends.
package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	markerCount = 20
	cgroupRoot  = "/sys/fs/cgroup"
)

type marker struct {
	Revision      string            `json:"revision"`
	Phase         string            `json:"phase"`
	StartedUnixNS int64             `json:"started_unix_ns"`
	EndedUnixNS   int64             `json:"ended_unix_ns"`
	MonotonicNS   int64             `json:"monotonic_ns"`
	SampleNS      int64             `json:"sample_ns"`
	Counters      map[string]string `json:"counters"`
}

type trace struct {
	Tag       string            `json:"tag"`
	Slot      int               `json:"slot"`
	Container string            `json:"container"`
	Boot      string            `json:"boot"`
	Cgroup    string            `json:"cgroup"`
	Mounts    map[string]string `json:"mounts"`
	Markers   []marker          `json:"markers"`
}

func mountRows(raw string) (map[string]string, error) {
	mounts := make(map[string]string, 2)
	for _, row := range strings.Split(raw, "\n") {
		left, right, ok := strings.Cut(row, " - ")
		m, fs := strings.Fields(left), strings.Fields(right)
		if !ok || len(m) < 6 || len(fs) < 3 {
			continue
		}
		destination := m[4]
		switch destination {
		case "/dev/shm":
			if fs[0] != "tmpfs" {
				return nil, errors.New("phase sidecar path is not tmpfs")
			}
		case cgroupRoot:
			if fs[0] != "cgroup2" || m[3] != "/" {
				return nil, errors.New("phase observer cannot read its container cgroup root")
			}
		default:
			continue
		}
		if _, duplicate := mounts[destination]; duplicate {
			return nil, errors.New("ambiguous phase observer mount")
		}
		mounts[destination] = row
	}
	if len(mounts) != 2 {
		return nil, errors.New("phase observer mounts are incomplete")
	}
	return mounts, nil
}

func snapshot(root string) (map[string]string, error) {
	result := make(map[string]string, 3)
	for _, file := range []string{"cpu.stat", "cpu.pressure", "io.pressure"} {
		raw, err := os.ReadFile(filepath.Join(root, file))
		if file != "cpu.stat" && errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		result[file] = strings.TrimSpace(string(raw))
	}
	return result, nil
}

func markers(in io.Reader, acks io.Writer, root string) ([]marker, error) {
	rows := make([]marker, 0, markerCount)
	scan := bufio.NewScanner(in)
	scan.Buffer(make([]byte, 128), 256)
	origin := time.Now()
	for scan.Scan() {
		request := scan.Text()
		if request == "finish" && len(rows) == markerCount {
			return rows, nil
		}
		revision, phase, ok := strings.Cut(request, "\t")
		if !ok || revision == "" || phase == "" || len(rows) == markerCount {
			return nil, fmt.Errorf("unexpected phase request %q after %d markers", request, len(rows))
		}
		started := time.Now()
		values, err := snapshot(root)
		ended := time.Now()
		if err != nil {
			return nil, err
		}
		rows = append(rows, marker{
			Revision: revision, Phase: phase, StartedUnixNS: started.UnixNano(), EndedUnixNS: ended.UnixNano(),
			MonotonicNS: started.Sub(origin).Nanoseconds(), SampleNS: ended.Sub(started).Nanoseconds(), Counters: values,
		})
		if _, err := fmt.Fprintf(acks, "%s/%s\n", revision, phase); err != nil {
			return nil, err
		}
	}
	if err := scan.Err(); err != nil {
		return nil, err
	}
	return nil, errors.New("phase marker stream ended before the dispatcher finished")
}

func run(args []string) error {
	if len(args) != 3 {
		return errors.New("expected wave tag, slot and private trace path")
	}
	slot, err := strconv.Atoi(args[1])
	if err != nil || slot < 0 || slot > 7 {
		return errors.New("invalid builder slot")
	}
	path := fmt.Sprintf("/dev/shm/mp-build-phases.%s.%d/trace.json", args[0], slot)
	if path != filepath.Clean(args[2]) {
		return errors.New("unexpected marker trace destination")
	}
	container := os.Getenv("MP_RAW_ID")
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return err
	}
	cgroup, err := os.ReadFile("/proc/self/cgroup")
	if err != nil {
		return err
	}
	if container == "" || strings.TrimSpace(string(cgroup)) != "0::/" {
		return errors.New("marker is outside the expected container cgroup namespace")
	}
	raw, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return err
	}
	mounts, err := mountRows(string(raw))
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintln(os.Stdout, "ready"); err != nil {
		return err
	}
	rows, err := markers(os.Stdin, os.Stdout, cgroupRoot)
	if err != nil {
		return err
	}
	out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	record := trace{
		Tag: args[0], Slot: slot, Container: container, Boot: strings.TrimSpace(string(boot)),
		Cgroup: "0::/", Mounts: mounts, Markers: rows,
	}
	return errors.Join(json.NewEncoder(out).Encode(record), out.Close())
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
