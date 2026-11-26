package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/cilium/ebpf"
	"github.com/cilium/ebpf/link"
	"golang.org/x/sys/unix"
)

type identity struct {
	BootID    string `json:"boot_id"`
	Kernel    string `json:"kernel"`
	Interface string `json:"interface"`
	Ifindex   uint32 `json:"ifindex"`
	NetNS     uint32 `json:"netns"`
	Queue     uint32 `json:"queue"`
	MAC       string `json:"mac"`
	Driver    string `json:"driver"`
}

func getIdentity(iface, expectedBoot string, queue uint32) (identity, error) {
	var id identity
	read := func(path string) (string, error) {
		b, err := os.ReadFile(path)
		return strings.TrimSpace(string(b)), err
	}
	boot, err := read("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return id, err
	}
	if boot != expectedBoot {
		return id, errors.New("expected guest boot ID differs from observed boot")
	}
	kernel, err := read("/proc/sys/kernel/osrelease")
	if err != nil {
		return id, err
	}
	var ns unix.Stat_t
	if err := unix.Stat("/proc/self/ns/net", &ns); err != nil {
		return id, err
	}
	if ns.Ino == 0 || ns.Ino > math.MaxUint32 {
		return id, errors.New("unsupported network namespace inode")
	}
	dev, err := net.InterfaceByName(iface)
	if err != nil {
		return id, err
	}
	base := filepath.Join("/sys/class/net", iface)
	idx, err := read(filepath.Join(base, "ifindex"))
	if err != nil {
		return id, err
	}
	mac, err := read(filepath.Join(base, "address"))
	if err != nil {
		return id, err
	}
	if dev.Index <= 0 || idx != strconv.Itoa(dev.Index) || len(dev.HardwareAddr) != 6 || mac != dev.HardwareAddr.String() {
		return id, errors.New("sysfs and network namespace disagree about interface identity")
	}
	driver, err := os.Readlink(filepath.Join(base, "device/driver"))
	if err != nil {
		return id, err
	}
	if filepath.Base(driver) != "virtio_net" {
		return id, fmt.Errorf("%s is not a virtio_net interface", iface)
	}
	queuePath := filepath.Join(base, "queues", fmt.Sprintf("tx-%d", queue), "byte_queue_limits")
	stat, err := os.Stat(queuePath)
	if err != nil {
		return id, err
	}
	if !stat.IsDir() {
		return id, fmt.Errorf("missing BQL queue directory %s", queuePath)
	}
	return identity{boot, kernel, iface, uint32(dev.Index), uint32(ns.Ino), queue, mac, filepath.Base(driver)}, nil
}

func monotonicNS() (uint64, error) {
	var ts unix.Timespec
	err := unix.ClockGettime(unix.CLOCK_MONOTONIC, &ts)
	return uint64(ts.Nano()), err
}

// Read existing per-program statistics only. Some guests do not collect
// them. An absent reading must not be represented as zero missed callbacks.
type hookStats struct {
	Runs            uint64 `json:"runs"`
	RecursionMisses uint64 `json:"recursion_misses"`
}

func hookReadbacks(coll *ebpf.Collection) (map[string]*hookStats, bool) {
	observed := make(map[string]*hookStats, len(coll.Programs))
	clean := true
	for name, prog := range coll.Programs {
		observed[name] = nil
		st, err := prog.Stats()
		if err == nil && (st.RunCount != 0 || st.RecursionMisses != 0) {
			observed[name] = &hookStats{st.RunCount, st.RecursionMisses}
			clean = clean && st.RecursionMisses == 0
		}
	}
	return observed, clean
}

type event struct {
	identity
	Event          string                `json:"event"`
	MonoNS         uint64                `json:"monotonic_ns"`
	StartNS        uint64                `json:"start_monotonic_ns"`
	Deadline       uint64                `json:"deadline_monotonic_ns"`
	ObjectSHA      string                `json:"object_sha256"`
	Reason         string                `json:"reason,omitempty"`
	Complete       *bool                 `json:"complete,omitempty"`
	Sender         any                   `json:"sender,omitempty"`
	HookStats      map[string]*hookStats `json:"hook_stats,omitempty"`
	SenderCounters any                   `json:"sender_counters,omitempty"`
	Counts         map[string]uint64     `json:"counters,omitempty"`
}

func run() error {
	iface := flag.String("interface", "", "virtio_net interface in the current Linux network namespace")
	queue := flag.Uint("queue", 0, "zero-based TX queue")
	boot := flag.String("boot", "", "expected Linux boot UUID")
	ms := flag.Int("duration-ms", 0, "maximum observation window, 1..60000 milliseconds")
	obj := flag.String("object", "", "guest_tx.bpf.o (default: next to guest_tx)")
	stopStdin := flag.Bool("stop-stdin", false, "require a stop line from stdin before the watchdog expires")
	addSenderFlags()
	flag.Parse()
	if flag.NArg() != 0 || !regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,14}$`).MatchString(*iface) ||
		!regexp.MustCompile(`^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`).MatchString(*boot) ||
		*queue > math.MaxUint16 || *ms < 1 || *ms > 60000 {
		return errors.New("require --interface NAME --queue N --boot UUID --duration-ms 1..60000 [--stop-stdin]")
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM, syscall.SIGHUP)
	defer stop()
	id, err := getIdentity(*iface, *boot, uint32(*queue))
	if err != nil {
		return err
	}
	if *obj == "" {
		exe, err := os.Executable()
		if err != nil {
			return err
		}
		*obj = filepath.Join(filepath.Dir(exe), "guest_tx.bpf.o")
	}
	b, err := os.ReadFile(*obj)
	if err != nil {
		return err
	}
	spec, err := ebpf.LoadCollectionSpecFromReader(bytes.NewReader(b))
	if err != nil {
		return err
	}
	if err = checkSpec(spec); err != nil {
		return err
	}
	sender, err := prepareSender(spec)
	if err != nil {
		return err
	}
	defer sender.release()
	coll, err := ebpf.NewCollection(spec)
	if err != nil {
		return fmt.Errorf("load guest TX observer (requires matching kernel BTF, BQL and tracing permission): %w", err)
	}
	defer coll.Close()
	// Attach return first. A zeroed config leaves entry disabled until both
	// hooks and the scoped map value are ready.
	exit, err := link.AttachRawTracepoint(link.RawTracepointOptions{Name: "net_dev_xmit", Program: coll.Programs["tx_exit"]})
	if err != nil {
		return err
	}
	defer exit.Close()
	enter, err := link.AttachRawTracepoint(link.RawTracepointOptions{Name: "net_dev_start_xmit", Program: coll.Programs["tx_enter"]})
	if err != nil {
		return err
	}
	defer enter.Close()
	if err := sender.attach(coll); err != nil {
		return err
	}
	defer sender.close()
	if ctx.Err() != nil {
		return ctx.Err()
	}
	beforeArm, err := monotonicNS()
	if err != nil {
		return err
	}
	start := beforeArm + uint64(20*time.Millisecond)
	deadline := start + uint64(time.Duration(*ms)*time.Millisecond)
	cfg := config{StartNS: start, EndNS: deadline, NetNS: id.NetNS, Ifindex: id.Ifindex, Queue: id.Queue}
	sender.configure(&cfg)
	key := uint32(0)
	if err := coll.Maps["config"].Put(key, cfg); err != nil {
		return err
	}
	written, err := monotonicNS()
	if err != nil {
		return err
	}
	if written >= start {
		return errors.New("start bound expired before map write was verified")
	}
	time.Sleep(time.Duration(start - written))
	if ctx.Err() != nil {
		return ctx.Err()
	}
	ready, err := monotonicNS()
	if err != nil {
		return err
	}
	if ready >= deadline {
		return errors.New("watchdog expired while arming")
	}
	enc := json.NewEncoder(os.Stdout)
	ev := event{identity: id, Event: "ready", MonoNS: ready, StartNS: start, Deadline: deadline, ObjectSHA: fmt.Sprintf("%x", sha256.Sum256(b)), Sender: sender.identity()}
	if err := enc.Encode(ev); err != nil {
		return err
	}
	var stdin io.Reader
	if *stopStdin {
		stdin = os.Stdin
	}
	armed, err := monotonicNS()
	if err != nil {
		return err
	}
	var reason string
	if armed >= deadline {
		reason = "timeout"
	} else {
		reason = waitEnd(ctx, stdin, time.Duration(deadline-armed))
	}
	now, err := monotonicNS()
	if err != nil {
		return err
	}
	// Schedule the stop slightly ahead. Updating a live map at a timestamp
	// already in the past would allow a few late starts into the receipt.
	cutoff := deadline
	var freezeErr error
	if now >= deadline {
		reason = "timeout"
	} else {
		cutoff = min(deadline, now+uint64(20*time.Millisecond))
		if cutoff < deadline {
			cfg.EndNS = cutoff
			freezeErr = coll.Maps["config"].Put(key, cfg)
		}
		updated, clockErr := monotonicNS()
		if clockErr != nil {
			freezeErr = errors.Join(freezeErr, clockErr)
		} else if updated >= cutoff && cutoff < deadline {
			freezeErr = errors.Join(freezeErr, errors.New("stop bound expired before map update was verified"))
		} else if updated < cutoff {
			time.Sleep(time.Duration(cutoff - updated))
		}
	}
	// Once links close there can be no new matching starts. Treat calls
	// straddling an edge as incomplete rather than extending the window.
	detachErr := errors.Join(enter.Close(), exit.Close(), sender.close())
	var rows []counts
	readErr := coll.Maps["counts"].Lookup(key, &rows)
	var totals map[string]uint64
	if readErr == nil {
		totals, readErr = aggregate(rows)
	}
	after, identityErr := getIdentity(*iface, *boot, uint32(*queue))
	if identityErr == nil && id != after {
		identityErr = errors.New("interface or namespace changed during capture")
	}
	senderCounts, senderOK, senderErr := sender.report(coll)
	ev.SenderCounters = senderCounts
	hooks, hooksOK := hookReadbacks(coll)
	ev.HookStats = hooks
	err = errors.Join(freezeErr, detachErr, readErr, identityErr, senderErr)
	if err != nil {
		reason = "error"
	}
	complete := err == nil && (reason == "stop" || (!*stopStdin && reason == "timeout")) && matched(totals) && senderOK && hooksOK
	ev.Event, ev.MonoNS, ev.Reason, ev.Complete, ev.Counts = "result", cutoff, reason, &complete, totals
	if e := enc.Encode(ev); e != nil {
		return e
	}
	if err != nil {
		return err
	}
	if !complete {
		return fmt.Errorf("incomplete guest TX observation (%s)", reason)
	}
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
