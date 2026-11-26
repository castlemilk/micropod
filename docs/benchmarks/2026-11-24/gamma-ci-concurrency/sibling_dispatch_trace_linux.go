// Capture one bounded trace of the exact Linux threads that issue paced calls.
package main

import (
	"compress/gzip"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const traceRoot = "/sys/kernel/tracing"

type issuer struct {
	PID   int    `json:"pid"`
	TID   int    `json:"tid"`
	PIDNS string `json:"pidns"`
	Comm  string `json:"comm"`
}

type target struct {
	Slot int    `json:"slot"`
	Mask string `json:"mask"`
	issuer
}

type thread struct {
	ProcPID int    `json:"proc_pid"`
	ProcTID int    `json:"proc_tid"`
	PIDNS   string `json:"pidns"`
	Comm    string `json:"comm"`
	Cmdline string `json:"cmdline"`
	Status  string `json:"status"`
	Stat    string `json:"stat"`
}

func values(status, key string) []string {
	for _, line := range strings.Split(status, "\n") {
		if str, ok := strings.CutPrefix(line, key+":"); ok {
			return strings.Fields(str)
		}
	}
	return nil
}

func idsMatch(status, key string, procID, local int) bool {
	ids := values(status, key)
	return len(ids) >= 2 && ids[0] == strconv.Itoa(procID) && ids[len(ids)-1] == strconv.Itoa(local)
}

func identity(proc string, path string, q target, wantedArg string) (thread, error) {
	pid, _ := strconv.Atoi(filepath.Base(proc))
	tid, _ := strconv.Atoi(filepath.Base(path))
	ns, err := os.Readlink(filepath.Join(path, "ns/pid"))
	if err != nil {
		return thread{}, err
	}
	cmd, err := os.ReadFile(filepath.Join(proc, "cmdline"))
	if err != nil {
		return thread{}, err
	}
	status, err := os.ReadFile(filepath.Join(path, "status"))
	if err != nil {
		return thread{}, err
	}
	stat, err := os.ReadFile(filepath.Join(path, "stat"))
	if err != nil {
		return thread{}, err
	}
	name, err := os.ReadFile(filepath.Join(path, "comm"))
	if err != nil {
		return thread{}, err
	}
	comm := strings.TrimSpace(string(name))
	cmdline := string(cmd)
	if ns != q.PIDNS || comm != q.Comm || !strings.HasPrefix(cmdline, "/mpcheck/quiet-http\x00") ||
		!strings.Contains(cmdline, "\x00-ready-file\x00"+wantedArg+"\x00") ||
		!idsMatch(string(status), "NStgid", pid, q.PID) || !idsMatch(string(status), "NSpid", tid, q.TID) ||
		strings.Join(values(string(status), "Cpus_allowed_list"), "") != q.Mask {
		return thread{}, fmt.Errorf("slot %d issuing thread identity changed", q.Slot)
	}
	return thread{pid, tid, ns, comm, cmdline, string(status), string(stat)}, nil
}

func resolve(q target, arg string) (thread, error) {
	procs, err := filepath.Glob("/proc/[0-9]*")
	if err != nil {
		return thread{}, err
	}
	var matches []thread
	for _, proc := range procs {
		pid, err := strconv.Atoi(filepath.Base(proc))
		if err != nil || pid < 1 {
			continue
		}
		if ns, _ := os.Readlink(filepath.Join(proc, "ns/pid")); ns != q.PIDNS {
			continue
		}
		status, err := os.ReadFile(filepath.Join(proc, "status"))
		if err != nil || !idsMatch(string(status), "NStgid", pid, q.PID) {
			continue
		}
		tasks, err := os.ReadDir(filepath.Join(proc, "task"))
		if err != nil {
			return thread{}, err
		}
		for _, task := range tasks {
			path := filepath.Join(proc, "task", task.Name())
			tid, _ := strconv.Atoi(task.Name())
			status, err := os.ReadFile(filepath.Join(path, "status"))
			if err != nil || !idsMatch(string(status), "NSpid", tid, q.TID) {
				continue
			}
			row, err := identity(proc, path, q, arg)
			if err != nil {
				return thread{}, err
			}
			matches = append(matches, row)
		}
	}
	if len(matches) != 1 {
		return thread{}, fmt.Errorf("slot %d has %d guest issuing thread matches", q.Slot, len(matches))
	}
	return matches[0], nil
}

func await(path string, duration time.Duration) error {
	for limit := time.Now().Add(duration); ; time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			return nil
		} else if !errors.Is(err, os.ErrNotExist) {
			return err
		}
		if time.Now().After(limit) {
			return fmt.Errorf("deadline waiting for %s", filepath.Base(path))
		}
	}
}

func save(path string, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", data, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func dump(source, target string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	zipper, err := gzip.NewWriterLevel(output, gzip.BestSpeed)
	if err != nil {
		return errors.Join(err, output.Close())
	}
	_, err = io.Copy(zipper, input)
	return errors.Join(err, zipper.Close(), output.Close())
}

func match(field string, threads []thread) string {
	var terms []string
	for _, t := range threads {
		terms = append(terms, fmt.Sprintf("%s == %q", field, t.Comm))
	}
	return "(" + strings.Join(terms, " || ") + ")"
}

type proof struct {
	Clock        string            `json:"clock"`
	Observer     string            `json:"observer_proc_status"`
	Filters      map[string]string `json:"filters"`
	Formats      map[string]string `json:"formats"`
	EnableBefore map[string]string `json:"enable_before"`
	EnableAfter  map[string]string `json:"enable_after"`
	Before       []thread          `json:"before"`
	After        []thread          `json:"after"`
	Stats        map[string]string `json:"stats"`
}

func capture(dir, tag string, targets []target) (receipt proof, resultErr error) {
	rootns, err := os.Readlink("/proc/1/ns/pid")
	if err != nil {
		return receipt, err
	}
	observer, err := os.ReadFile("/proc/self/status")
	if err != nil {
		return receipt, err
	}
	receipt.Observer = string(observer)
	args := make([]string, len(targets))
	for i, q := range targets {
		if q.PID < 1 || q.TID < 1 || q.Slot < 0 || q.Slot >= 32 ||
			!regexp.MustCompile(`^mpd[0-9a-f]{8}[0-9]{2}$`).MatchString(q.Comm) ||
			!regexp.MustCompile(`^pid:\[[0-9]+\]$`).MatchString(q.PIDNS) || q.PIDNS == rootns {
			return receipt, fmt.Errorf("invalid slot %d PID namespace or issuing thread", q.Slot)
		}
		args[i] = fmt.Sprintf("/gate/%s.%d", tag, q.Slot)
		row, err := resolve(q, args[i])
		if err != nil {
			return receipt, err
		}
		for _, prior := range receipt.Before {
			if prior.ProcTID == row.ProcTID || prior.PIDNS == row.PIDNS || prior.Comm == row.Comm {
				return receipt, errors.New("duplicate issuing thread or container PID namespace")
			}
		}
		receipt.Before = append(receipt.Before, row)
	}
	inst := filepath.Join(traceRoot, "instances/micropod-dispatch")
	if err := os.Mkdir(inst, 0700); err != nil {
		return receipt, err
	}
	set := func(path, value string) error {
		return os.WriteFile(filepath.Join(inst, path), []byte(value+"\n"), 0600)
	}
	defer func() { resultErr = errors.Join(resultErr, set("tracing_on", "0"), os.Remove(inst)) }()
	for _, setting := range [][2]string{{"tracing_on", "0"}, {"current_tracer", "nop"}, {"trace_clock", "mono"}, {"buffer_size_kb", "8192"}} {
		if err := set(setting[0], setting[1]); err != nil {
			return receipt, err
		}
	}
	clock, err := os.ReadFile(filepath.Join(inst, "trace_clock"))
	if err != nil || !strings.Contains(string(clock), "[mono]") {
		return receipt, fmt.Errorf("tracefs did not select monotonic clock: %s %v", clock, err)
	}
	receipt.Clock = string(clock)
	receipt.Filters = map[string]string{
		"sched/sched_switch":                 match("prev_comm", receipt.Before) + " || " + match("next_comm", receipt.Before),
		"sched/sched_wakeup":                 match("comm", receipt.Before),
		"syscalls/sys_enter_clock_nanosleep": match("COMM", receipt.Before),
		"syscalls/sys_exit_clock_nanosleep":  match("COMM", receipt.Before),
	}
	receipt.Formats = map[string]string{}
	for event, filter := range receipt.Filters {
		path := "events/" + event
		if err := set(path+"/filter", filter); err != nil {
			return receipt, fmt.Errorf("filter %s: %w", event, err)
		}
		observed, err := os.ReadFile(filepath.Join(inst, path, "filter"))
		if err != nil || strings.TrimSpace(string(observed)) != filter {
			return receipt, fmt.Errorf("trace filter for %s differs: %s %v", event, observed, err)
		}
		if err := set(path+"/enable", "1"); err != nil {
			return receipt, err
		}
		format, err := os.ReadFile(filepath.Join(inst, path, "format"))
		if err != nil {
			return receipt, err
		}
		receipt.Formats[event] = string(format)
	}
	readEnabled := func() (map[string]string, error) {
		enabled := map[string]string{}
		for event := range receipt.Filters {
			state, err := os.ReadFile(filepath.Join(inst, "events", event, "enable"))
			if err != nil || strings.TrimSpace(string(state)) != "1" {
				return nil, fmt.Errorf("event %s did not enable: %q %v", event, state, err)
			}
			enabled[event] = string(state)
		}
		return enabled, nil
	}
	receipt.EnableBefore, err = readEnabled()
	if err != nil {
		return receipt, err
	}
	if err := set("tracing_on", "1"); err != nil {
		return receipt, err
	}
	if err := set("trace_marker", "micropod-dispatch-start"); err != nil {
		return receipt, err
	}
	if err := save(filepath.Join(dir, "armed"), receipt.Before); err != nil {
		return receipt, err
	}
	if err := await(filepath.Join(dir, "stop"), 12*time.Second); err != nil {
		return receipt, err
	}
	if err := set("trace_marker", "micropod-dispatch-stop"); err != nil {
		return receipt, err
	}
	if err := set("tracing_on", "0"); err != nil {
		return receipt, err
	}
	receipt.EnableAfter, err = readEnabled()
	if err != nil {
		return receipt, err
	}
	for i, old := range receipt.Before {
		proc := fmt.Sprintf("/proc/%d", old.ProcPID)
		path := fmt.Sprintf("%s/task/%d", proc, old.ProcTID)
		row, err := identity(proc, path, targets[i], args[i])
		if err != nil {
			return receipt, err
		}
		receipt.After = append(receipt.After, row)
	}
	receipt.Stats = map[string]string{}
	for cpu := range 4 {
		name := fmt.Sprintf("cpu%d", cpu)
		stats, err := os.ReadFile(filepath.Join(inst, "per_cpu", name, "stats"))
		if err != nil {
			return receipt, err
		}
		receipt.Stats[name] = string(stats)
	}
	return receipt, dump(filepath.Join(inst, "trace"), filepath.Join(dir, "trace.gz"))
}

func run(dir string) (resultErr error) {
	mounted := false
	defer func() {
		if mounted {
			resultErr = errors.Join(resultErr, syscall.Unmount(traceRoot, 0))
		}
	}()
	if _, err := os.Stat(filepath.Join(traceRoot, "events/sched/sched_switch")); errors.Is(err, os.ErrNotExist) {
		if err := syscall.Mount("tracefs", traceRoot, "tracefs", 0, ""); err != nil {
			return err
		}
		mounted = true
	} else if err != nil {
		return err
	}
	if err := save(filepath.Join(dir, "ready"), os.Getpid()); err != nil {
		return err
	}
	path := filepath.Join(dir, "command")
	if err := await(path, 180*time.Second); err != nil {
		return err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var targets []target
	if err := json.Unmarshal(data, &targets); err != nil {
		return err
	}
	if len(targets) < 1 || len(targets) > 2 {
		return errors.New("one or two issuing thread targets required")
	}
	receipt, err := capture(dir, "grouped-0-all-A", targets)
	if err != nil {
		return err
	}
	if mounted {
		if err := syscall.Unmount(traceRoot, 0); err != nil {
			return err
		}
		mounted = false
	}
	return save(filepath.Join(dir, "done"), receipt)
}

func main() {
	dir := flag.String("dir", "", "private trace request and evidence directory")
	flag.Parse()
	if err := run(*dir); err != nil {
		_ = save(filepath.Join(*dir, "error"), err.Error())
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
