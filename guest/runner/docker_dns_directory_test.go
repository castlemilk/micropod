package main

import (
	"math"
	"net/netip"
	"slices"
	"sync"
	"testing"
)

func TestServiceLookupCopiesWhileLocked(t *testing.T) {
	for _, count := range []int{1, 8, 9} {
		stored := make([]netip.Addr, count)
		for i := range stored {
			stored[i] = netip.AddrFrom4([4]byte{10, 90, 0, byte(i + 1)})
		}
		d := serviceDirectory{records: map[string][]netip.Addr{"db": stored}}
		want := slices.Clone(stored)
		var scratch [8]netip.Addr
		got, total := d.lookup("db", scratch[:], count)
		if total != count {
			t.Fatalf("wrong address count %d", total)
		}
		if count <= len(scratch) && &got[0] != &scratch[0] {
			t.Fatal("small response did not use the caller's buffer")
		}
		if truncated, n := d.lookup("db", scratch[:], count-1); len(truncated) != 0 || n != count {
			t.Fatal("copied records for truncated reply", truncated, n)
		}
		if !d.contains("db") || d.contains("missing") {
			t.Fatal("incorrect directory membership")
		}
		if ips, total := d.lookup("missing", scratch[:], count); ips != nil || total != 0 {
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
			var scratch [8]netip.Addr
			for range 1000 {
				ips, _ := d.lookup("db", scratch[:], math.MaxUint16)
				if len(ips) != 1 || ips[0] != ip || !d.contains("db") {
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
				var scratch [8]netip.Addr
				if ips, _ := d.lookup(name, scratch[:], math.MaxUint16); len(ips) > 0 {
					lastLookup = ips[len(ips)-1]
				}
			}
		})
	}
}
