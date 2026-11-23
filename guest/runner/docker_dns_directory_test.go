package main

import (
	"net/netip"
	"slices"
	"sync"
	"testing"
)

func TestServiceLookupCopiesWhileLocked(t *testing.T) {
	for _, count := range []int{1, 8} {
		stored := make([]netip.Addr, count)
		for i := range stored {
			stored[i] = netip.AddrFrom4([4]byte{10, 90, 0, byte(i + 1)})
		}
		d := serviceDirectory{records: map[string][]netip.Addr{"db": stored}}
		want := slices.Clone(stored)
		var scratch [1]netip.Addr
		got := d.lookup("db", &scratch)
		if d.lookup("missing", &scratch) != nil {
			t.Fatal("missing record returned an address")
		}
		// A subsequent removal may clear or overwrite the stored backing array.
		clear(stored)
		if !slices.Equal(got, want) {
			t.Fatal("reply refers to a mutable directory record", got, want)
		}
	}
}

func TestServiceLookupConcurrentReadersAndWriter(t *testing.T) {
	ip := netip.MustParseAddr("10.90.0.4")
	d := serviceDirectory{records: map[string][]netip.Addr{"db": {ip}}}
	var workers sync.WaitGroup
	for range 3 {
		workers.Go(func() {
			var scratch [1]netip.Addr
			for range 1000 {
				ips := d.lookup("db", &scratch)
				if len(ips) != 1 || ips[0] != ip {
					t.Errorf("invalid lookup during publication: %v", ips)
					return
				}
			}
		})
	}
	for range 1000 {
		d.mu.Lock()
		d.records["db"][0] = ip
		d.mu.Unlock()
	}
	workers.Wait()
}

// The shipping lookup before this change.
func clonedLookup(d *serviceDirectory, name string) []netip.Addr {
	d.mu.RLock()
	defer d.mu.RUnlock()
	return slices.Clone(d.records[name])
}

var lastLookup netip.Addr

func BenchmarkServiceLookup(b *testing.B) {
	ip := netip.MustParseAddr("10.90.0.4")
	d := serviceDirectory{records: map[string][]netip.Addr{"single": {ip}, "replicas": {ip, ip, ip, ip, ip, ip, ip, ip}}}
	for _, name := range []string{"single", "replicas", "missing"} {
		b.Run(name+"/clone", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				if ips := clonedLookup(&d, name); len(ips) > 0 {
					lastLookup = ips[len(ips)-1]
				}
			}
		})
		b.Run(name+"/scratch", func(b *testing.B) {
			b.ReportAllocs()
			for b.Loop() {
				var scratch [1]netip.Addr
				if ips := d.lookup(name, &scratch); len(ips) > 0 {
					lastLookup = ips[len(ips)-1]
				}
			}
		})
	}
}
