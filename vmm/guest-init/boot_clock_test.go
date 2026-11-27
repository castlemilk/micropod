package main

import (
	"testing"
	"time"
)

// A host clock reading behind the guest's by less than maxBackwardSlew is
// slewed, never stepped: the guest's realtime clock does not go back in
// ordinary running. Forward corrections and real backward changes step.
func TestBackwardSlew(t *testing.T) {
	const now = 1_800_000_000 * int64(time.Second)
	for _, test := range []struct {
		name   string
		target int64
		back   time.Duration
		slew   bool
	}{
		{"host ahead: step forward", now + int64(450*time.Microsecond), 0, false},
		{"host far ahead (a wake from sleep): step forward", now + int64(time.Hour), 0, false},
		{"equal: nothing to lose", now, 0, true},
		{"guest 450 us ahead: slew", now - int64(450*time.Microsecond), 450 * time.Microsecond, true},
		{"guest 499 ms ahead: slew", now - int64(499*time.Millisecond), 499 * time.Millisecond, true},
		{"the host's clock was set back 500 ms: step", now - int64(500*time.Millisecond), 0, false},
		{"the host's clock was set back an hour: step", now - int64(time.Hour), 0, false},
	} {
		if back, slew := backwardSlew(now, test.target); back != test.back || slew != test.slew {
			t.Errorf("%s: backwardSlew = %v, %v; want %v, %v", test.name, back, slew, test.back, test.slew)
		}
	}
}

func TestParseBootRealtime(t *testing.T) {
	const stamp = 1_770_000_000_123_456_789
	const field = "mp.boot_realtime_ns=1770000000123456789"
	for _, test := range []struct {
		name    string
		cmdline string
		want    int64
		invalid bool
	}{
		{name: "managed", cmdline: field + " console=ttyAMA0 mp.instance=sample mp.worker=sample", want: stamp},
		{name: "explicit standalone args", cmdline: field + " console=ttyAMA0 quiet", want: stamp},
		{name: "legacy standalone", cmdline: "console=ttyAMA0 quiet"},
		{name: "missing for managed", cmdline: "console=ttyAMA0 mp.worker=sample", invalid: true},
		{name: "empty managed identifier", cmdline: "mp.instance=", invalid: true},
		{name: "missing value", cmdline: "mp.boot_realtime_ns mp.worker=sample", invalid: true},
		{name: "epoch", cmdline: "mp.boot_realtime_ns=0 mp.instance=sample", invalid: true},
		{name: "overflow", cmdline: "mp.boot_realtime_ns=9223372036854775808", invalid: true},
		{name: "noncanonical", cmdline: "mp.boot_realtime_ns=+1770000000123456789", invalid: true},
		{name: "truncated", cmdline: "mp.boot_realtime_ns=177000000012345678", invalid: true},
		{name: "overridden", cmdline: field + " mp.boot_realtime_ns=2000000000000000000", invalid: true},
		{name: "not first", cmdline: "console=ttyAMA0 " + field, invalid: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			got, err := parseBootRealtime(test.cmdline)
			if got != test.want || (err != nil) != test.invalid {
				t.Fatalf("parseBootRealtime(%q) = %d, %v; want %d, error = %t", test.cmdline, got, err, test.want, test.invalid)
			}
		})
	}
}
