package main

import (
	"net/netip"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type serviceDirectory struct {
	mu      sync.RWMutex
	records map[string][]netip.Addr
}

func (d *serviceDirectory) publish(c *dockerContainer, add bool) {
	ip, err := netip.ParseAddr(c.IP)
	if err != nil || !ip.Is4() {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.records == nil {
		d.records = map[string][]netip.Addr{}
	}
	names := append([]string{c.Name, c.Config.Hostname}, c.Config.Aliases...)
	for _, name := range names {
		key := strings.ToLower(name)
		if key == "" {
			continue
		}
		a := d.records[key]
		if add {
			if !slices.Contains(a, ip) {
				d.records[key] = append(a, ip)
			}
		} else if i := slices.Index(a, ip); i >= 0 {
			a = slices.Delete(a, i, i+1)
			if len(a) == 0 {
				delete(d.records, key)
			} else {
				d.records[key] = a
			}
		}
	}
}
func (d *serviceDirectory) lookup(name string) []netip.Addr {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return slices.Clone(d.records[name])
}

// Counts are boot scoped and aggregate across network names, aliases and jobs.
type networkMetrics struct {
	dnsLocal, dnsMissing, dnsForwarded, dnsFailures, dnsDropped atomic.Uint64
	attachCount, attachFailures, attachUS                       [3]atomic.Uint64
}

func (m *networkMetrics) attachment(driver string, start time.Time, err error) {
	i := 0
	switch driver {
	case "macvlan":
		i = 1
	case "ipvlan":
		i = 2
	}
	m.attachCount[i].Add(1)
	m.attachUS[i].Add(uint64(time.Since(start).Microseconds()))
	if err != nil {
		m.attachFailures[i].Add(1)
	}
}
func (m *networkMetrics) snapshot() map[string]any {
	result := map[string]any{"dns_local_answers": m.dnsLocal.Load(), "dns_name_misses": m.dnsMissing.Load(), "dns_forwarded": m.dnsForwarded.Load(), "dns_upstream_failures": m.dnsFailures.Load(), "dns_overload_drops": m.dnsDropped.Load()}
	for i, driver := range []string{"bridge", "macvlan", "ipvlan"} {
		result[driver] = map[string]uint64{"attach_attempts": m.attachCount[i].Load(), "attach_errors": m.attachFailures[i].Load(), "attach_usec_total": m.attachUS[i].Load()}
	}
	return result
}
