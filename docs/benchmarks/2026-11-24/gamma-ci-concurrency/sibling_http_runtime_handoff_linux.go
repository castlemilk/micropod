package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/trace"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// Handoff source appended to the archived boundary client.

const handoffTraceCap = 8 << 20
const handoffCategory = "micropod-http-handoff"

type handoffBuffer struct {
	data     []byte
	seen     int
	overflow bool
}

func (b *handoffBuffer) Write(p []byte) (int, error) {
	b.seen += len(p)
	if b.seen > handoffTraceCap {
		b.overflow = true
	} else {
		b.data = append(b.data, p...)
	}
	return len(p), nil
}

type handoffAnchor struct {
	Phase          string `json:"phase"`
	TID            int    `json:"tid"`
	GoBeforeNS     int64  `json:"go_before_ns"`
	GoAfterNS      int64  `json:"go_after_ns"`
	KernelBeforeNS int64  `json:"kernel_before_ns"`
	KernelAfterNS  int64  `json:"kernel_after_ns"`
}

type handoffEvidence struct {
	Tag             string          `json:"tag"`
	Boot            string          `json:"boot_id"`
	PID             int             `json:"pid"`
	PIDNamespace    string          `json:"pid_namespace"`
	ThreadStatus    string          `json:"thread_status"`
	GoVersion       string          `json:"go_version"`
	Local           string          `json:"local"`
	Remote          string          `json:"remote"`
	Marker          string          `json:"marker"`
	GateNS          int64           `json:"gate_unix_ns"`
	ClockSampleNS   int64           `json:"clock_sample_ns"`
	ClockGoOffsetNS int64           `json:"clock_go_offset_ns"`
	ClockWidthNS    int64           `json:"clock_width_ns"`
	OriginUpperNS   int64           `json:"origin_upper_ns"`
	Anchors         []handoffAnchor `json:"anchors"`
	Bytes           int             `json:"bytes"`
	Seen            int             `json:"seen_bytes"`
	Overflow        bool            `json:"overflow"`
	SHA256          string          `json:"sha256"`
}

type handoffTrace struct {
	path     string
	buffer   handoffBuffer
	evidence handoffEvidence
	stopped  bool
}

func startHandoffTrace(ready string, rate, slot int) (*handoffTrace, error) {
	tag := filepath.Base(ready)
	selected := (slot == 0 && (tag == "grouped-0-all-A.0" || tag == "grouped-0-all-B.0")) ||
		(slot == 9 && (tag == "grouped-1-all-A.9" || tag == "grouped-1-all-B.9"))
	if rate != 64000 || !selected {
		return nil, nil
	}
	if filepath.Dir(ready) != "/gate" || runtime.GOOS != "linux" || runtime.GOARCH != "arm64" {
		return nil, fmt.Errorf("runtime handoff trace needs the private Linux arm64 gate")
	}
	boot, err := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err != nil {
		return nil, err
	}
	ns, err := os.Readlink("/proc/self/ns/pid")
	if err != nil {
		return nil, err
	}
	capture := &handoffTrace{
		path:   ready,
		buffer: handoffBuffer{data: make([]byte, 0, handoffTraceCap)},
		evidence: handoffEvidence{Tag: tag, Boot: strings.TrimSpace(string(boot)), PID: os.Getpid(),
			PIDNamespace: ns, GoVersion: runtime.Version()},
	}
	if err := trace.Start(&capture.buffer); err != nil {
		return nil, err
	}
	return capture, nil
}

func (t *handoffTrace) stop() {
	if t != nil && !t.stopped {
		trace.Stop()
		t.stopped = true
	}
}

func handoffMonotonic() (int64, error) {
	var stamp [2]int64
	// Linux arm64 clock_gettime. This path is guarded before tracing starts.
	_, _, errno := syscall.RawSyscall(113, 1, uintptr(unsafe.Pointer(&stamp)), 0)
	if errno != 0 {
		return 0, errno
	}
	return stamp[0]*int64(time.Second) + stamp[1], nil
}

func (t *handoffTrace) anchor(ctx context.Context, origin time.Time, phase string) error {
	// Linux arm64 gettid. The stock pacer has already locked this OS thread.
	tid, _, errno := syscall.RawSyscall(178, 0, 0, 0)
	if errno != 0 || tid == 0 {
		return fmt.Errorf("trace issuer thread: tid=%d errno=%v", tid, errno)
	}
	k0, err := handoffMonotonic()
	if err != nil {
		return err
	}
	g0 := time.Since(origin).Nanoseconds()
	trace.Log(ctx, handoffCategory, t.evidence.Tag+":"+phase)
	g1 := time.Since(origin).Nanoseconds()
	k1, err := handoffMonotonic()
	if err != nil {
		return err
	}
	t.evidence.Anchors = append(t.evidence.Anchors, handoffAnchor{phase, int(tid), g0, g1, k0, k1})
	if phase == "end" {
		status, err := os.ReadFile("/proc/self/task/" + strconv.FormatUint(uint64(tid), 10) + "/status")
		if err != nil {
			return err
		}
		t.evidence.ThreadStatus = string(status)
	}
	return nil
}

//go:noinline
func handoffControlWake(channel chan<- struct{}) {
	time.Sleep(5 * time.Millisecond)
	channel <- struct{}{}
}

func (t *handoffTrace) save(ctx context.Context) error {
	// This runs only after the ordinary cohort drain signal.
	trace.Log(ctx, handoffCategory, t.evidence.Tag+":control-begin")
	channel := make(chan struct{})
	go handoffControlWake(channel)
	<-channel
	trace.Log(ctx, handoffCategory, t.evidence.Tag+":control-end")
	t.stop()
	t.evidence.Bytes = len(t.buffer.data)
	t.evidence.Seen = t.buffer.seen
	t.evidence.Overflow = t.buffer.overflow
	t.evidence.SHA256 = fmt.Sprintf("%x", sha256.Sum256(t.buffer.data))
	if err := handoffNewFile(t.path+".runtime.trace", t.buffer.data); err != nil {
		return err
	}
	data, err := json.Marshal(t.evidence)
	if err != nil {
		return err
	}
	if err := handoffNewFile(t.path+".runtime.json", data); err != nil {
		return err
	}
	if t.buffer.overflow {
		return fmt.Errorf("runtime handoff trace exceeded bounded buffer")
	}
	return nil
}

func handoffNewFile(path string, data []byte) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(data)
	closeErr := file.Close()
	if err != nil {
		return err
	}
	return closeErr
}
