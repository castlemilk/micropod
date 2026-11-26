package main

import (
	"net/netip"
	"slices"
	"strings"
	"sync/atomic"
	"time"
)

func (d *serviceDirectory) publish(c *dockerContainer, add bool) {
	d.publishEndpoint(c.Name, c.Config.Hostname, c.Config.Aliases, c.IP, add)
}

func (d *serviceDirectory) publishEndpoint(name, hostname string, aliases []string, address string, add bool) {
	ip, err := netip.ParseAddr(address)
	if err != nil || !ip.Is4() {
		return
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.records == nil {
		d.records = map[string][]netip.Addr{}
	}
	names := append([]string{name, hostname}, aliases...)
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

// Counts are boot scoped and aggregate across network names, aliases and jobs.
type networkMetrics struct {
	kernelPorts, directPorts, relayPorts, rootlessPorts         atomic.Uint64
	dnsLocal, dnsMissing, dnsForwarded, dnsFailures, dnsDropped atomic.Uint64
	dnsRedirectAttempts, dnsRedirectErrors, dnsRedirectUS       atomic.Uint64
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
	result["sandbox_dns_redirect"] = map[string]uint64{"attempts": m.dnsRedirectAttempts.Load(), "errors": m.dnsRedirectErrors.Load(), "usec_total": m.dnsRedirectUS.Load()}
	result["published_tcp"] = map[string]uint64{"kernel_leases": m.kernelPorts.Load(), "macvlan_leases": m.directPorts.Load(), "relay_leases": m.relayPorts.Load(), "rootless_leases": m.rootlessPorts.Load()}
	for i, driver := range []string{"bridge", "macvlan", "ipvlan"} {
		result[driver] = map[string]uint64{"attach_attempts": m.attachCount[i].Load(), "attach_errors": m.attachFailures[i].Load(), "attach_usec_total": m.attachUS[i].Load()}
	}
	return result
}
