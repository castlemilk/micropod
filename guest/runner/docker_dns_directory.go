package main

import (
	"net/netip"
	"sync"
)

type serviceDirectory struct {
	mu      sync.RWMutex
	records map[string][]netip.Addr
}

// IPv4 service aliases still exist for other question types. Only their
// presence is needed to distinguish a local NODATA response from a missing name.
func (d *serviceDirectory) contains(name string) bool {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return len(d.records[name]) != 0
}

// Records may change as soon as the lock is released. If the entire answer
// must truncate, keep just its count. Otherwise copy into request-owned space.
func (d *serviceDirectory) lookup(name string, scratch []netip.Addr, limit int) ([]netip.Addr, int) {
	d.mu.RLock()
	defer d.mu.RUnlock()
	records := d.records[name]
	if len(records) == 0 || len(records) > limit {
		return nil, len(records)
	}
	return append(scratch[:0], records...), len(records)
}
