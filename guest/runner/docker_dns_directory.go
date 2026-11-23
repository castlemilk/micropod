package main

import (
	"net/netip"
	"slices"
	"sync"
)

type serviceDirectory struct {
	mu      sync.RWMutex
	records map[string][]netip.Addr
}

// Copy the aliases before releasing the lock. Each DNS request owns its
// scratch buffer, so publication can remove an address while a reply is packed.
func (d *serviceDirectory) lookup(name string, one *[1]netip.Addr) []netip.Addr {
	d.mu.RLock()
	defer d.mu.RUnlock()
	records := d.records[name]
	if len(records) == 1 {
		one[0] = records[0]
		return one[:]
	}
	return slices.Clone(records)
}
