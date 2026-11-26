// Select and read back the ordinary Linux scheduler policy for a fixture build.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

type thread struct {
	TID      int    `json:"tid"`
	CPUs     string `json:"cpus_allowed_list"`
	Policy   uint32 `json:"policy"`
	Nice     int32  `json:"nice"`
	Priority uint32 `json:"priority"`
	SliceNS  uint64 `json:"slice_ns"`
}

const buildSliceProofEnv = "MICROPOD_BENCH_BUILD_SLICE_PROOF"

type buildSliceProof struct {
	RequestedUS   int    `json:"requested_us"`
	InheritedNS   uint64 `json:"inherited_ns"`
	DispatcherPID int    `json:"dispatcher_pid"`
}

func (p buildSliceProof) expectedNS() uint64 {
	if p.RequestedUS == 0 {
		return p.InheritedNS
	}
	return uint64(p.RequestedUS) * 1000
}

func readThread(pid, tid int) (thread, error) {
	attr, err := unix.SchedGetAttr(tid, 0)
	if err != nil {
		return thread{}, err
	}
	path := fmt.Sprintf("/proc/%d/task/%d/status", pid, tid)
	status, err := os.ReadFile(path)
	if err != nil {
		return thread{}, err
	}
	for _, line := range strings.Split(string(status), "\n") {
		if value, ok := strings.CutPrefix(line, "Cpus_allowed_list:"); ok && strings.TrimSpace(value) != "" {
			return thread{tid, strings.TrimSpace(value), attr.Policy, attr.Nice, attr.Priority, attr.Runtime}, nil
		}
	}
	return thread{}, fmt.Errorf("process %d thread %d lacks an allowed CPU list", pid, tid)
}

func inspect(pid int) ([]thread, error) {
	entries, err := os.ReadDir(fmt.Sprintf("/proc/%d/task", pid))
	if err != nil {
		return nil, err
	}
	threads := make([]thread, 0, len(entries))
	for _, entry := range entries {
		tid, err := strconv.Atoi(entry.Name())
		if err != nil {
			return nil, err
		}
		row, err := readThread(pid, tid)
		if tid != pid && (errors.Is(err, unix.ESRCH) || errors.Is(err, os.ErrNotExist)) {
			continue
		}
		if err != nil {
			return nil, err
		}
		threads = append(threads, row)
	}
	return threads, nil
}

func confirmDispatcher(pid int) error {
	if pid != os.Getppid() {
		return errors.New("dispatcher is not this probe's parent")
	}
	dispatcher, err := readThread(pid, pid)
	if err != nil {
		return err
	}
	child, err := readThread(os.Getpid(), os.Getpid())
	if err != nil {
		return err
	}
	proof := struct {
		Dispatcher thread           `json:"dispatcher"`
		Child      thread           `json:"child"`
		ParentPID  int              `json:"child_parent_pid"`
		Slice      *buildSliceProof `json:"slice,omitempty"`
	}{Dispatcher: dispatcher, Child: child, ParentPID: pid}
	if raw, present := os.LookupEnv(buildSliceProofEnv); present {
		var slice buildSliceProof
		if err := json.Unmarshal([]byte(raw), &slice); err != nil {
			return fmt.Errorf("decode dispatcher slice proof: %w", err)
		}
		if slice.DispatcherPID != pid || slice.InheritedNS == 0 || (slice.RequestedUS != 0 && slice.RequestedUS != 2100) {
			return fmt.Errorf("unexpected dispatcher slice evidence: %+v", slice)
		}
		if want := slice.expectedNS(); dispatcher.Policy != unix.SCHED_NORMAL || child.Policy != unix.SCHED_NORMAL ||
			dispatcher.SliceNS != want || child.SliceNS != want {
			return fmt.Errorf("dispatcher %d and child %d need normal scheduling with slice %d ns, got %+v and %+v",
				pid, child.TID, want, dispatcher, child)
		}
		proof.Slice = &slice
	}
	return json.NewEncoder(os.Stdout).Encode(proof)
}

func execWithPolicy(policy string, buildSliceUS *int, args []string) error {
	var selected uint32
	switch policy {
	case "normal":
		selected = unix.SCHED_NORMAL
	case "batch":
		selected = unix.SCHED_BATCH
	default:
		return fmt.Errorf("unknown ordinary scheduler policy %q", policy)
	}
	if buildSliceUS != nil && (policy != "normal" || (*buildSliceUS != 0 && *buildSliceUS != 2100)) {
		return errors.New("build slice must be 0 or 2100 microseconds with normal scheduling")
	}
	if len(args) == 0 || !filepath.IsAbs(args[0]) {
		return errors.New("expected an absolute dispatcher executable")
	}
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	before, err := unix.SchedGetAttr(0, 0)
	if err != nil {
		return err
	}
	if before.Policy != unix.SCHED_NORMAL || before.Priority != 0 || before.Runtime == 0 || before.Flags&unix.SCHED_FLAG_RESET_ON_FORK != 0 {
		return fmt.Errorf("expected inherited ordinary scheduling, got %+v", before)
	}
	attr := *before
	attr.Policy = selected
	attr.Runtime = 0 // A policy-only launch uses the ordinary kernel default.
	wantRuntime := before.Runtime
	var slice buildSliceProof
	if buildSliceUS != nil {
		slice = buildSliceProof{RequestedUS: *buildSliceUS, InheritedNS: before.Runtime, DispatcherPID: os.Getpid()}
		attr.Runtime = uint64(*buildSliceUS) * 1000
		wantRuntime = slice.expectedNS()
	}
	// Normal scheduling was verified above. An explicit zero control keeps the
	// exact inherited slice by leaving the scheduler attributes alone.
	if buildSliceUS == nil || *buildSliceUS != 0 {
		if err := unix.SchedSetAttr(0, &attr, 0); err != nil {
			return fmt.Errorf("select %s scheduling with slice %d ns: %w", policy, wantRuntime, err)
		}
	}
	after, err := unix.SchedGetAttr(0, 0)
	if err != nil {
		return err
	}
	if after.Policy != selected || after.Nice != before.Nice || after.Priority != 0 || after.Runtime != wantRuntime ||
		(buildSliceUS != nil && after.Flags&unix.SCHED_FLAG_RESET_ON_FORK != 0) {
		return fmt.Errorf("expected %s scheduling at nice %d with slice %d ns, got %+v", policy, before.Nice, wantRuntime, after)
	}
	if buildSliceUS != nil {
		data, err := json.Marshal(slice)
		if err != nil {
			return fmt.Errorf("encode dispatcher slice proof: %w", err)
		}
		if err := os.Setenv(buildSliceProofEnv, string(data)); err != nil {
			return fmt.Errorf("pass dispatcher slice proof to child: %w", err)
		}
	}
	return unix.Exec(args[0], args, os.Environ())
}

func run() error {
	policy := flag.String("policy", "", "apply the normal or batch policy before exec")
	slice := flag.Int("build-slice-us", 0, "normal build slice in microseconds (0 keeps the inherited slice)")
	pid := flag.Int("inspect", 0, "read the thread policies of a process in this namespace")
	dispatcher := flag.Int("dispatcher", 0, "prove this ordinary child inherited its dispatcher policy")
	flag.Parse()
	var buildSlice *int
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "build-slice-us" {
			buildSlice = slice
		}
	})
	switch {
	case *pid > 0 && *dispatcher == 0 && *policy == "" && buildSlice == nil && flag.NArg() == 0:
		threads, err := inspect(*pid)
		if err != nil {
			return err
		}
		return json.NewEncoder(os.Stdout).Encode(threads)
	case *dispatcher > 0 && *pid == 0 && *policy == "" && buildSlice == nil && flag.NArg() == 0:
		return confirmDispatcher(*dispatcher)
	case *pid == 0 && *dispatcher == 0 && *policy != "":
		return execWithPolicy(*policy, buildSlice, flag.Args())
	default:
		return errors.New("expected one policy or process inspection")
	}
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
