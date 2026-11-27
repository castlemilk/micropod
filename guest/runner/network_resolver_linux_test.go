package main

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A non-bridge network's resolv.conf is written out before the network's
// commit, and recovery rewrites one an earlier engine's crash left empty.
func TestNetworkResolverIsWrittenOutAndRepairedAtRecovery(t *testing.T) {
	steps := observeRecordIO(t)
	n := &workerNetwork{ID: strings.Repeat("c", 64), Subnet: netip.MustParsePrefix("10.91.0.0/24")}
	if err := os.MkdirAll(n.dir(), 0700); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(n.dir()) })
	want := "nameserver " + n.gateway().String() + "\noptions ndots:1\n"
	if err := writeNetworkResolver(n, true); err != nil {
		t.Fatal(err)
	}
	if len(*steps) != 1 || (*steps)[0] != "out resolv.conf "+want {
		t.Fatalf("steps %q, want resolv.conf written out whole", *steps)
	}
	path := filepath.Join(n.dir(), "resolv.conf")
	// What an engine before this one could leave: network.json durable, the
	// resolver's data not.
	if err := os.WriteFile(path, nil, 0600); err != nil {
		t.Fatal(err)
	}
	*steps = nil
	if err := writeNetworkResolver(n, false); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != want || st.Mode().Perm() != 0644 || len(*steps) != 1 {
		t.Fatalf("recovered resolver %q mode %v after %q, want %q 0644 written out", b, st.Mode().Perm(), *steps, want)
	}
	// A whole one is left as it is.
	*steps = nil
	if err := writeNetworkResolver(n, false); err != nil || len(*steps) != 0 {
		t.Fatalf("a whole resolver was rewritten: %q, %v", *steps, err)
	}
}
