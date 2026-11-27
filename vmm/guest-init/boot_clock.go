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

// maxBackwardSlew bounds the backward corrections made by slewing. The host
// resends its wall clock every minute and after a jump; guest and host drift
// apart by well under a millisecond a minute, and the correction is as often
// backward as forward.
const maxBackwardSlew = 500 * time.Millisecond

// backwardSlew says how a host clock reading (target) is applied when the
// guest clock reads now: a guest that is ahead by less than maxBackwardSlew is
// slewed back by the returned amount (the kernel runs the clock slower until
// it has lost that much; it never reads earlier than it did), anything else
// is stepped (slew false): forward, or back by a real change of the host's
// clock.
//
// The realtime clock must not step back in ordinary running: the engine
// decides after a crash which image layers reached the disk by comparing the
// times containerd stamped on them with the time of its last sync
// (guest/runner image_durability_linux.go), and a layer stamped after a
// backward step could look older than the sync that never covered it.
func backwardSlew(now, target int64) (back time.Duration, slew bool) {
	ahead := now - target
	if ahead < 0 || ahead >= int64(maxBackwardSlew) {
		return 0, false
	}
	return time.Duration(ahead), true
}

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
