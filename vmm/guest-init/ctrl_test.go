package main

import (
	"strings"
	"testing"
)

func TestParseCtrlCommand(t *testing.T) {
	cmd, err := parseCtrlCommand("CLOCK 1770000000123456789\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cmd.kind != ctrlCmdClock || cmd.unixNs != 1770000000123456789 {
		t.Fatalf("unexpected command: %+v", cmd)
	}

	cmd, err = parseCtrlCommand("POWEROFF\n")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cmd.kind != ctrlCmdPoweroff {
		t.Fatalf("expected POWEROFF, got %+v", cmd)
	}

	for _, bad := range []string{"CLOCK 0", "CLOCK -1", "CLOCK abc", "CLOCK 1577836799999999999", "NOOP"} {
		if _, err := parseCtrlCommand(bad); err == nil {
			t.Fatalf("expected error for %q", bad)
		}
	}
}

func TestProcessCtrlStream(t *testing.T) {
	input := "CLOCK 1770000000000000000\nGARBAGE\nCLOCK 1770000005000000000\nPOWEROFF\n"
	var clocks []int64
	poweroffs := 0
	if err := processCtrlStream(
		strings.NewReader(input),
		func(ns int64) error {
			clocks = append(clocks, ns)
			return nil
		},
		func() { poweroffs++ },
	); err != nil {
		t.Fatalf("processCtrlStream failed: %v", err)
	}
	if len(clocks) != 2 || clocks[0] != 1770000000000000000 || clocks[1] != 1770000005000000000 {
		t.Fatalf("unexpected clocks: %v", clocks)
	}
	if poweroffs != 1 {
		t.Fatalf("expected 1 poweroff, got %d", poweroffs)
	}
}
