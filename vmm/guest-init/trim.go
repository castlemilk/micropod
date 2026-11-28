package main

import (
	"bytes"
	"errors"
	"fmt"
	"math"
	"strconv"
	"strings"
	"time"
)

// Idle trim: the machine's disks are sparse files on the Mac, and a block the
// guest frees stays allocated there until the guest discards it. Nothing
// discarded them, so the OS disk file only grew: on a throwaway machine,
// writing and deleting 5 GiB left the file at 19.7 GiB, and one `fstrim /`
// (24.8 GB in 4.2 s) took it to 8.8 GiB; the rig's file was 71 GiB for
// 28.5 GiB in use. A whole-disk trim while containers start raised their p95
// from 0.07 to 0.49 s (the host punches each hole on the disk's one I/O
// queue), so guest init trims each filesystem a range at a time, and only
// while the machine is idle: before each range it samples the CPUs and the
// I/O pressure over trimIdleWindow, and a busy machine ends the pass where it
// is, to resume there at the next interval. ext4 remembers which block
// groups it trimmed, so a later pass only discards what was freed since.
//
// mp.idle_trim (machine.json kernelArguments): "off", or the interval in
// seconds between passes (default 600; the first pass waits one interval).
const (
	idleTrimArg             = "mp.idle_trim"
	defaultIdleTrimInterval = 10 * time.Minute
	minIdleTrimInterval     = 5 * time.Second
	// trimRangeBytes is how much of a filesystem one FITRIM covers: ~0.2 s
	// of discards on a disk that is all free.
	trimRangeBytes = 1 << 30
	// trimIdleWindow is how long the machine must have been idle before
	// each range.
	trimIdleWindow = time.Second
	// Idle: under trimBusyCPUs CPUs busy and under trimIOStallShare of the
	// window with a task stalled on I/O (PSI io "some").
	trimBusyCPUs     = 1.0
	trimIOStallShare = 0.10
)

// idleTrimInterval is the time between trim passes; ok false turns idle
// trim off. A value it cannot use is reported and the default is used.
func idleTrimInterval(params map[string]string) (interval time.Duration, ok bool, err error) {
	value, present := params[idleTrimArg]
	if !present {
		return defaultIdleTrimInterval, true, nil
	}
	if value == "off" {
		return 0, false, nil
	}
	seconds, perr := strconv.ParseUint(value, 10, 32)
	if d := time.Duration(seconds) * time.Second; perr == nil && d >= minIdleTrimInterval {
		return d, true, nil
	}
	return defaultIdleTrimInterval, true, fmt.Errorf("%s=%q is not \"off\" or an interval of at least %d seconds; trimming every %s",
		idleTrimArg, value, int(minIdleTrimInterval/time.Second), defaultIdleTrimInterval)
}

// cpuSample is the aggregate "cpu" line of /proc/stat: jiffies spent busy
// (everything but idle and iowait) and in all, and the number of CPUs.
type cpuSample struct {
	busy, total uint64
	cpus        int
}

func parseProcStat(stat []byte) (cpuSample, error) {
	var s cpuSample
	found := false
	for line := range bytes.Lines(stat) {
		fields := strings.Fields(string(line))
		if len(fields) == 0 {
			continue
		}
		switch {
		case fields[0] == "cpu":
			if len(fields) < 6 {
				return s, fmt.Errorf("short cpu line in /proc/stat")
			}
			// user nice system idle iowait irq softirq steal; guest and
			// guest_nice are already counted in user and nice.
			for i, f := range fields[1:min(len(fields), 9)] {
				n, err := strconv.ParseUint(f, 10, 64)
				if err != nil {
					return s, fmt.Errorf("/proc/stat cpu field %d: %w", i+1, err)
				}
				s.total += n
				if i != 3 && i != 4 { // idle, iowait
					s.busy += n
				}
			}
			found = true
		case strings.HasPrefix(fields[0], "cpu"):
			s.cpus++
		}
	}
	if !found || s.cpus == 0 {
		return s, fmt.Errorf("no cpu lines in /proc/stat")
	}
	return s, nil
}

// busyCPUs is how many CPUs were busy on average between two samples.
func busyCPUs(a, b cpuSample) float64 {
	if b.total <= a.total || b.busy < a.busy {
		return 0
	}
	return float64(b.busy-a.busy) / float64(b.total-a.total) * float64(b.cpus)
}

// psiSomeTotal is the "some" line's total (microseconds with a task
// stalled) of a /proc/pressure file.
func psiSomeTotal(psi []byte) (uint64, bool) {
	for line := range bytes.Lines(psi) {
		rest, ok := strings.CutPrefix(strings.TrimSpace(string(line)), "some ")
		if !ok {
			continue
		}
		for _, field := range strings.Fields(rest) {
			if v, ok := strings.CutPrefix(field, "total="); ok {
				n, err := strconv.ParseUint(v, 10, 64)
				return n, err == nil
			}
		}
	}
	return 0, false
}

// errTrimUnsupported is a filesystem or disk that takes no discards (a
// read-only disk, a device without discard): it is not tried again.
var errTrimUnsupported = errors.New("the filesystem takes no discards")

// trimTarget is one mounted filesystem and how far its current pass got.
type trimTarget struct {
	path string
	// size is statfs's data blocks in bytes: where the last range starts.
	size uint64
	// next is where the pass resumes; trimmed and took add up the pass.
	next    uint64
	trimmed uint64
	ranges  int
	took    time.Duration
	// off: the filesystem takes no discards.
	off bool
}

// trimmer runs passes over its targets. trim discards the free space of
// [start, start+length) of the filesystem at path and returns the bytes it
// discarded; idle reports whether the machine has been idle (it may take
// trimIdleWindow to answer); stopped reports a stop under way.
type trimmer struct {
	trim    func(path string, start, length uint64) (uint64, error)
	idle    func() bool
	stopped func() bool
	now     func() time.Time
	logf    func(format string, args ...any)
}

// pass trims t from where its last pass stopped until it is done (true:
// the next pass starts from the beginning) or the machine is busy, a stop
// begins or the filesystem refuses (false: resume here next time).
func (tr *trimmer) pass(t *trimTarget) bool {
	if t.off {
		return false
	}
	for t.next < t.size {
		// idle takes trimIdleWindow, and a stop may begin meanwhile.
		if tr.stopped() || !tr.idle() || tr.stopped() {
			return false
		}
		length := uint64(trimRangeBytes)
		if t.size-t.next <= length {
			// The last range runs to the end of the filesystem, which is
			// larger than statfs's count of data blocks; ext4 ends a range
			// at its last block, as for fstrim's default.
			length = math.MaxUint64 - t.next
		}
		began := tr.now()
		n, err := tr.trim(t.path, t.next, length)
		t.took += tr.now().Sub(began)
		if errors.Is(err, errTrimUnsupported) {
			tr.logf("[mp-hvf-init] idle trim %s: %v; not trimmed this boot", t.path, err)
			t.off = true
			return false
		}
		if err != nil {
			tr.logf("[mp-hvf-init] idle trim %s at %d: %v; trying again next interval", t.path, t.next, err)
			return false
		}
		t.trimmed += n
		t.ranges++
		t.next = min(t.size, t.next+length)
	}
	tr.logf("[mp-hvf-init] idle trim %s: discarded %d bytes in %d ranges, %s", t.path, t.trimmed, t.ranges, t.took.Round(time.Millisecond))
	t.next, t.trimmed, t.ranges, t.took = 0, 0, 0, 0
	return true
}
