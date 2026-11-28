package main

import (
	"fmt"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

func TestPhaseHistogramBucketsTotalAndLongest(t *testing.T) {
	var h phaseHistogram
	for _, ms := range []int64{0, 10, 11, 400, 7000, 45000} {
		h.observe(time.Duration(ms) * time.Millisecond)
	}
	h.observe(-time.Second) // a clock step reads as 0
	got := h.snapshot()
	le := got["le_ms"].(map[string]uint64)
	for bound, want := range map[string]uint64{"10": 3, "25": 4, "250": 4, "500": 5, "5000": 5, "10000": 6, "30000": 6, "+Inf": 7} {
		if le[bound] != want {
			t.Errorf("le %s ms: %d, want %d", bound, le[bound], want)
		}
	}
	if got["count"] != uint64(7) || got["total_ms"] != int64(52421) || got["max_ms"] != int64(45000) {
		t.Fatalf("snapshot %v", got)
	}
}

func TestDiskIOIsTheLineOfThePathsDevice(t *testing.T) {
	var st unix.Stat_t
	if err := unix.Stat("/", &st); err != nil {
		t.Fatal(err)
	}
	maj, minor := unix.Major(st.Dev), unix.Minor(st.Dev)
	stats := fmt.Sprintf(" 254       16 vdb 1 0 8 0 2 0 16 0 0 0 0 0 0 0 0 9 9\n"+
		" %4d %8d vda 100 3 2000 50 700 20 40960 90 0 300 400 5 0 80 1 1234 567\n", maj, minor)
	if maj == 254 && minor == 16 {
		t.Skip("/ is on the decoy device number")
	}
	got := diskIOOf(stats, "/")
	if got != (diskIO{Device: "vda", Writes: 700, WriteBytes: 40960 * 512, Flushes: 1234, FlushMS: 567}) {
		t.Fatalf("diskIO %+v", got)
	}
	// A kernel without flush fields (before 5.5): flushes read as zero.
	old := fmt.Sprintf(" %d %d vda 100 3 2000 50 700 20 40960 90 0 300 400\n", maj, minor)
	if got := diskIOOf(old, "/"); got.Writes != 700 || got.Flushes != 0 {
		t.Fatalf("pre-5.5 diskstats %+v", got)
	}
	if got := diskIOOf(stats, "/nonexistent/path"); got != (diskIO{}) {
		t.Fatalf("missing path %+v", got)
	}
}
