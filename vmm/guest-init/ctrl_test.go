package main

import (
	"strings"
	"syscall"
	"testing"
	"time"
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

	cmd, err = parseCtrlCommand("SHUTDOWN_BUDGET 9000\n")
	if err != nil || cmd.kind != ctrlCmdShutdownBudget || cmd.budget != 9*time.Second {
		t.Fatalf("unexpected SHUTDOWN_BUDGET parse: %+v %v", cmd, err)
	}

	for _, bad := range []string{
		"CLOCK 0", "CLOCK -1", "CLOCK abc", "CLOCK 1577836799999999999", "NOOP",
		"SHUTDOWN_BUDGET 999", "SHUTDOWN_BUDGET -5", "SHUTDOWN_BUDGET 600001", "SHUTDOWN_BUDGET x",
	} {
		if _, err := parseCtrlCommand(bad); err == nil {
			t.Fatalf("expected error for %q", bad)
		}
	}
}

func TestProcessCtrlStream(t *testing.T) {
	input := "CLOCK 1770000000000000000\nGARBAGE\nSHUTDOWN_BUDGET 4000\nCLOCK 1770000005000000000\nPOWEROFF\n"
	var clocks []int64
	var budgets []time.Duration
	poweroffs := 0
	if err := processCtrlStream(strings.NewReader(input), ctrlHandlers{
		clock: func(ns int64) error {
			clocks = append(clocks, ns)
			return nil
		},
		poweroff: func() { poweroffs++ },
		budget:   func(d time.Duration) { budgets = append(budgets, d) },
	}); err != nil {
		t.Fatalf("processCtrlStream failed: %v", err)
	}
	if len(clocks) != 2 || clocks[0] != 1770000000000000000 || clocks[1] != 1770000005000000000 {
		t.Fatalf("unexpected clocks: %v", clocks)
	}
	if poweroffs != 1 {
		t.Fatalf("expected 1 poweroff, got %d", poweroffs)
	}
	if len(budgets) != 1 || budgets[0] != 4*time.Second {
		t.Fatalf("unexpected budgets: %v", budgets)
	}
	// Handlers are optional: an older host or a test may not care about all of them.
	if err := processCtrlStream(strings.NewReader(input), ctrlHandlers{}); err != nil {
		t.Fatalf("nil handlers: %v", err)
	}
}

func TestShutdownBudgetDefaultsAndSplit(t *testing.T) {
	var b shutdownBudget
	if b.Load() != defaultShutdownBudget {
		t.Fatalf("default budget = %v", b.Load())
	}
	b.Store(9 * time.Second)
	if b.Load() != 9*time.Second {
		t.Fatalf("stored budget = %v", b.Load())
	}
	for _, total := range []time.Duration{0, time.Second, 7 * time.Second, 9 * time.Second, time.Minute} {
		p := splitShutdownBudget(total)
		effective := max(total, minShutdownBudget)
		if p.engine <= 0 || p.term <= 0 || p.kill < 100*time.Millisecond {
			t.Fatalf("%v: degenerate phases %+v", total, p)
		}
		// The phases leave time for sync and the read-only remount.
		if used := p.engine + p.term + p.kill; used >= effective {
			t.Fatalf("%v: phases use %v of the budget", total, used)
		}
	}
	if engineStopGrace(9*time.Second) != splitShutdownBudget(9*time.Second).engine {
		t.Fatal("engine grace must be the first phase")
	}
}

func TestWaitDescription(t *testing.T) {
	if got := waitDescription(syscall.WaitStatus(3 << 8)); got != "status=3" {
		t.Fatalf("exit 3: %q", got)
	}
	if got := waitDescription(0); got != "status=0" {
		t.Fatalf("exit 0: %q", got)
	}
	if got := waitDescription(syscall.WaitStatus(syscall.SIGKILL)); got != "signal="+syscall.SIGKILL.String() {
		t.Fatalf("SIGKILL: %q", got)
	}
}

func TestGuestFailureLine(t *testing.T) {
	if got := guestFailureLine("engine-exited", "status=1"); got != "MICROPOD_VMM_GUEST_STATUS engine-exited status=1" {
		t.Fatalf("unexpected line %q", got)
	}
	got := guestFailureLine("init-failed", "mount workspace:\n  "+strings.Repeat("x", 400))
	if strings.Contains(got, "\n") || len(got) > len(guestStatusMarker)+len(" init-failed ")+160 {
		t.Fatalf("failure line must be one bounded line, got %q", got)
	}
}
