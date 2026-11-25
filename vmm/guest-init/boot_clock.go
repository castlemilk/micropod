package main

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

const (
	bootClockArg        = "mp.boot_realtime_ns"
	minBootRealtimeNano = 1_577_836_800 * int64(time.Second) // 2020-01-01 UTC
)

func parseBootRealtime(cmdline string) (int64, error) {
	var stamp int64
	var managed bool
	for i, field := range strings.Fields(cmdline) {
		key, value, _ := strings.Cut(field, "=")
		switch key {
		case bootClockArg:
			if i != 0 {
				return 0, fmt.Errorf("%s must occur only as the first boot argument", bootClockArg)
			}
			var err error
			stamp, err = strconv.ParseInt(value, 10, 64)
			if err != nil || stamp < minBootRealtimeNano || strconv.FormatInt(stamp, 10) != value {
				return 0, fmt.Errorf("invalid UTC timestamp in %s", bootClockArg)
			}
		case "mp.worker", "mp.instance":
			managed = true
		}
	}
	if stamp == 0 && managed {
		return 0, fmt.Errorf("missing %s for managed HVF boot; use a matching VMM and initrd", bootClockArg)
	}
	return stamp, nil
}
