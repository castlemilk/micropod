// The observer and its timestamps all run inside one Linux guest boot.
package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"math"
	"time"
)

type config struct {
	StartNS, EndNS                                          uint64
	NetNS, Ifindex, Queue                                   uint32
	ServiceTGID, ServiceNetNS, ServicePort, ServicePad, Pad uint32
}

// guest_tx.h defines the matching per-CPU map value.
var counterNames = [...]string{
	"attempts", "attempted_bytes", "completed_calls", "tx_ok", "tx_busy",
	"tx_other", "dql_charged_bytes", "read_errors", "overlaps", "boundary_crossings",
}

type counts [len(counterNames)]uint64

func aggregate(cpus []counts) (map[string]uint64, error) {
	if len(cpus) == 0 {
		return nil, errors.New("no per-CPU map values")
	}
	out := make(map[string]uint64, len(counterNames))
	for _, row := range cpus {
		for i, n := range row {
			key := counterNames[i]
			if n > math.MaxUint64-out[key] {
				return nil, fmt.Errorf("counter overflow: %s", key)
			}
			out[key] += n
		}
	}
	return out, nil
}

func matched(c map[string]uint64) bool {
	// Subtract for the return split to avoid accepting a wrapped sum.
	d := c["completed_calls"]
	if c["tx_ok"] > d || c["tx_busy"] > d-c["tx_ok"] {
		return false
	}
	return c["attempts"] > 0 && c["attempts"] == d &&
		c["tx_other"] == d-c["tx_ok"]-c["tx_busy"] &&
		c["read_errors"] == 0 && c["overlaps"] == 0 && c["boundary_crossings"] == 0
}

func stopCommand(r io.Reader) string {
	// Bound the read even if a client sends a command without a newline.
	s, err := bufio.NewReaderSize(r, 16).ReadSlice('\n')
	if err != nil {
		if len(s) == 0 && errors.Is(err, io.EOF) {
			return "stdin_eof"
		}
		return "invalid_stop"
	}
	if string(s) != "stop\n" {
		return "invalid_stop"
	}
	return "stop"
}

func waitEnd(ctx context.Context, stdin io.Reader, remaining time.Duration) string {
	t := time.NewTimer(remaining)
	defer t.Stop()
	var cmd chan string
	if stdin != nil {
		cmd = make(chan string, 1)
		go func() { cmd <- stopCommand(stdin) }()
	}
	select {
	case <-ctx.Done():
		return "signal"
	case reason := <-cmd:
		return reason
	case <-t.C:
		return "timeout"
	}
}
