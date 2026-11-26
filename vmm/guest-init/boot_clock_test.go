package main

import "testing"

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
