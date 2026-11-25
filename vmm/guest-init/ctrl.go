package main

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

type ctrlCommandKind int

const (
	ctrlCmdUnknown ctrlCommandKind = iota
	ctrlCmdClock
	ctrlCmdPoweroff
	ctrlCmdShutdownBudget
)

// Bounds on the shutdown time the host may grant the guest.
const (
	defaultShutdownBudget = 7 * time.Second
	minShutdownBudget     = time.Second
	maxShutdownBudget     = 10 * time.Minute
)

type ctrlCommand struct {
	kind   ctrlCommandKind
	unixNs int64
	budget time.Duration
}

func parseCtrlCommand(line string) (ctrlCommand, error) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" {
		return ctrlCommand{kind: ctrlCmdUnknown}, nil
	}
	if trimmed == "POWEROFF" {
		return ctrlCommand{kind: ctrlCmdPoweroff}, nil
	}
	if val, ok := strings.CutPrefix(trimmed, "CLOCK "); ok {
		ns, err := strconv.ParseInt(strings.TrimSpace(val), 10, 64)
		if err != nil || ns < minBootRealtimeNano {
			return ctrlCommand{}, fmt.Errorf("invalid CLOCK timestamp %q", val)
		}
		return ctrlCommand{kind: ctrlCmdClock, unixNs: ns}, nil
	}
	if val, ok := strings.CutPrefix(trimmed, "SHUTDOWN_BUDGET "); ok {
		ms, err := strconv.ParseInt(strings.TrimSpace(val), 10, 64)
		d := time.Duration(ms) * time.Millisecond
		if err != nil || d < minShutdownBudget || d > maxShutdownBudget {
			return ctrlCommand{}, fmt.Errorf("invalid SHUTDOWN_BUDGET %q", val)
		}
		return ctrlCommand{kind: ctrlCmdShutdownBudget, budget: d}, nil
	}
	return ctrlCommand{kind: ctrlCmdUnknown}, fmt.Errorf("unknown control command %q", trimmed)
}

// ctrlHandlers receive the host's commands; nil handlers are skipped.
type ctrlHandlers struct {
	clock    func(unixNs int64) error
	poweroff func()
	budget   func(time.Duration)
}

func processCtrlStream(r io.Reader, h ctrlHandlers) error {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		cmd, err := parseCtrlCommand(scanner.Text())
		if err != nil {
			continue
		}
		switch cmd.kind {
		case ctrlCmdClock:
			if h.clock != nil {
				_ = h.clock(cmd.unixNs)
			}
		case ctrlCmdPoweroff:
			if h.poweroff != nil {
				h.poweroff()
			}
		case ctrlCmdShutdownBudget:
			if h.budget != nil {
				h.budget(cmd.budget)
			}
		}
	}
	return scanner.Err()
}

// shutdownBudget is how long the host waits for the guest to power off after
// asking it to, minus a margin; the host announces it when the channel opens.
type shutdownBudget struct{ ns atomic.Int64 }

func (b *shutdownBudget) Load() time.Duration {
	if v := b.ns.Load(); v > 0 {
		return time.Duration(v)
	}
	return defaultShutdownBudget
}

func (b *shutdownBudget) Store(d time.Duration) { b.ns.Store(int64(d)) }

// stopPhases splits a shutdown budget: the engine's own graceful stop, then
// SIGTERM to every remaining process, then SIGKILL. What is left covers sync,
// unmounting and the read-only remount that marks ext4 clean.
type stopPhases struct {
	engine, term, kill time.Duration
}

func splitShutdownBudget(total time.Duration) stopPhases {
	if total < minShutdownBudget {
		total = minShutdownBudget
	}
	return stopPhases{
		engine: total * 50 / 100,
		term:   total * 30 / 100,
		kill:   max(total*5/100, 100*time.Millisecond),
	}
}

func engineStopGrace(total time.Duration) time.Duration { return splitShutdownBudget(total).engine }

// guestStatusMarker prefixes the console line that tells micropod-vmm the guest
// is stopping because something failed (see `exit_code` in its summary).
const guestStatusMarker = "MICROPOD_VMM_GUEST_STATUS"

// waitDescription renders a child's wait status as `status=N` or `signal=NAME`.
func waitDescription(ws syscall.WaitStatus) string {
	if ws.Signaled() {
		return "signal=" + ws.Signal().String()
	}
	return "status=" + strconv.Itoa(ws.ExitStatus())
}

func guestFailureLine(kind, detail string) string {
	detail = strings.Join(strings.Fields(detail), " ")
	if len(detail) > 160 {
		detail = detail[:160]
	}
	return strings.TrimSpace(guestStatusMarker + " " + kind + " " + detail)
}
