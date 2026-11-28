package main

import (
	"errors"
	"fmt"
	"math"
	"testing"
	"time"
)

func TestIdleTrimInterval(t *testing.T) {
	for _, c := range []struct {
		params   map[string]string
		interval time.Duration
		ok, err  bool
	}{
		{map[string]string{}, defaultIdleTrimInterval, true, false},
		{map[string]string{idleTrimArg: "off"}, 0, false, false},
		{map[string]string{idleTrimArg: "30"}, 30 * time.Second, true, false},
		{map[string]string{idleTrimArg: "5"}, 5 * time.Second, true, false},
		{map[string]string{idleTrimArg: "4"}, defaultIdleTrimInterval, true, true},
		{map[string]string{idleTrimArg: "10m"}, defaultIdleTrimInterval, true, true},
		{map[string]string{idleTrimArg: ""}, defaultIdleTrimInterval, true, true},
	} {
		interval, ok, err := idleTrimInterval(c.params)
		if interval != c.interval || ok != c.ok || (err != nil) != c.err {
			t.Errorf("%v: interval=%s ok=%v err=%v", c.params, interval, ok, err)
		}
	}
}

func TestBusyCPUsFromProcStat(t *testing.T) {
	stat := func(user, idle, iowait uint64) []byte {
		return fmt.Appendf(nil, "cpu  %d 0 0 %d %d 0 0 0 0 0\ncpu0 1 0 0 1 0 0 0 0 0 0\ncpu1 1 0 0 1 0 0 0 0 0 0\nintr 5\n", user, idle, iowait)
	}
	a, err := parseProcStat(stat(100, 1000, 50))
	if err != nil || a.cpus != 2 || a.busy != 100 || a.total != 1150 {
		t.Fatalf("parse: %+v %v", a, err)
	}
	// 200 jiffies over 2 CPUs: 50 busy, 150 idle or waiting = 0.5 CPUs.
	b, _ := parseProcStat(stat(150, 1100, 100))
	if got := busyCPUs(a, b); got != 0.5 {
		t.Errorf("busy CPUs = %v, want 0.5", got)
	}
	if got := busyCPUs(b, a); got != 0 {
		t.Errorf("a counter going back reads as %v busy CPUs", got)
	}
	if _, err := parseProcStat([]byte("intr 5\n")); err == nil {
		t.Error("a /proc/stat without cpu lines parsed")
	}
}

func TestPSISomeTotal(t *testing.T) {
	psi := []byte("some avg10=1.00 avg60=0.50 avg300=0.10 total=123456\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=99\n")
	if n, ok := psiSomeTotal(psi); !ok || n != 123456 {
		t.Errorf("total=%d ok=%v", n, ok)
	}
	if _, ok := psiSomeTotal([]byte("full avg10=0 total=1\n")); ok {
		t.Error("a file without a some line gave a total")
	}
}

type fakeTrim struct {
	calls   []uint64 // range starts
	lengths []uint64
	busyAt  map[int]bool // idle check number -> busy
	checks  int
	failAt  int // trim call number that fails (1-based)
	stop    bool
}

func (f *fakeTrim) trimmer() *trimmer {
	return &trimmer{
		trim: func(_ string, start, length uint64) (uint64, error) {
			f.calls = append(f.calls, start)
			f.lengths = append(f.lengths, length)
			if len(f.calls) == f.failAt {
				return 0, errors.New("EIO")
			}
			return 1000, nil
		},
		idle: func() bool {
			f.checks++
			return !f.busyAt[f.checks]
		},
		stopped: func() bool { return f.stop },
		now:     func() time.Time { return time.Unix(0, 0) },
		logf:    func(string, ...any) {},
	}
}

// A pass trims range after range while the machine is idle, the last range
// unbounded (ext4 ends it at its last block); a busy machine ends the pass
// where it is and the next pass resumes there.
func TestTrimPassResumesWhereABusyMachineStoppedIt(t *testing.T) {
	f := &fakeTrim{busyAt: map[int]bool{3: true}}
	tr := f.trimmer()
	target := &trimTarget{path: "/", size: 3*trimRangeBytes + 5}
	if tr.pass(target) {
		t.Fatal("a pass the machine interrupted reported done")
	}
	if want := []uint64{0, trimRangeBytes}; fmt.Sprint(f.calls) != fmt.Sprint(want) {
		t.Fatalf("first pass trimmed %v, want %v", f.calls, want)
	}
	if target.next != 2*trimRangeBytes || target.trimmed != 2000 {
		t.Fatalf("after the busy check: next=%d trimmed=%d", target.next, target.trimmed)
	}
	if !tr.pass(target) {
		t.Fatal("an idle pass did not finish")
	}
	if want := []uint64{0, trimRangeBytes, 2 * trimRangeBytes, 3 * trimRangeBytes}; fmt.Sprint(f.calls) != fmt.Sprint(want) {
		t.Fatalf("trimmed %v, want %v", f.calls, want)
	}
	if last := f.lengths[len(f.lengths)-1]; last != math.MaxUint64-3*trimRangeBytes {
		t.Errorf("last range length %d is bounded", last)
	}
	if target.next != 0 || target.trimmed != 0 || target.ranges != 0 {
		t.Errorf("a finished pass left %+v", target)
	}
}

// A filesystem that takes no discards is dropped after its first try.
func TestTrimPassDropsAFilesystemWithoutDiscards(t *testing.T) {
	f := &fakeTrim{}
	tr := f.trimmer()
	tr.trim = func(_ string, start, _ uint64) (uint64, error) {
		f.calls = append(f.calls, start)
		return 0, fmt.Errorf("%w (operation not supported)", errTrimUnsupported)
	}
	target := &trimTarget{path: "/", size: 4 * trimRangeBytes}
	if tr.pass(target) || tr.pass(target) {
		t.Fatal("a filesystem without discards reported a finished pass")
	}
	if len(f.calls) != 1 || !target.off {
		t.Errorf("calls=%v off=%v, want one try and the target off", f.calls, target.off)
	}
}

func TestTrimPassStopsForAStopOrAnError(t *testing.T) {
	f := &fakeTrim{stop: true}
	target := &trimTarget{path: "/", size: 4 * trimRangeBytes}
	if f.trimmer().pass(target) || len(f.calls) != 0 {
		t.Fatalf("a stopping machine trimmed %v", f.calls)
	}
	f = &fakeTrim{failAt: 2}
	if f.trimmer().pass(target) {
		t.Fatal("a pass with a failed range reported done")
	}
	if len(f.calls) != 2 || target.next != trimRangeBytes {
		t.Errorf("after a failed range: calls=%v next=%d", f.calls, target.next)
	}
}
