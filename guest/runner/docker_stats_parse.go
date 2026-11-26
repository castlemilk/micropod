package main

import (
	"strconv"
	"strings"
)

func parseCgroupKV(raw string) map[string]uint64 {
	out := make(map[string]uint64)
	for _, line := range strings.Split(raw, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		if v, err := strconv.ParseUint(fields[1], 10, 64); err == nil {
			out[fields[0]] = v
		}
	}
	return out
}

func parsePSISomeTotalUsec(raw string) (uint64, bool) {
	for _, line := range strings.Split(raw, "\n") {
		if !strings.HasPrefix(line, "some ") {
			continue
		}
		for _, field := range strings.Fields(line)[1:] {
			if k, v, ok := strings.Cut(field, "="); ok && k == "total" {
				if n, err := strconv.ParseUint(v, 10, 64); err == nil {
					return n, true
				}
			}
		}
	}
	return 0, false
}
