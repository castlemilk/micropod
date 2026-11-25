package main

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

type ctrlCommandKind int

const (
	ctrlCmdUnknown ctrlCommandKind = iota
	ctrlCmdClock
	ctrlCmdPoweroff
)

type ctrlCommand struct {
	kind   ctrlCommandKind
	unixNs int64
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
	return ctrlCommand{kind: ctrlCmdUnknown}, fmt.Errorf("unknown control command %q", trimmed)
}

func processCtrlStream(r io.Reader, onClock func(unixNs int64) error, onPoweroff func()) error {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		cmd, err := parseCtrlCommand(scanner.Text())
		if err != nil {
			continue
		}
		switch cmd.kind {
		case ctrlCmdClock:
			if onClock != nil {
				_ = onClock(cmd.unixNs)
			}
		case ctrlCmdPoweroff:
			if onPoweroff != nil {
				onPoweroff()
			}
		}
	}
	return scanner.Err()
}
