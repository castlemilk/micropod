package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// Run from the sibling guesttx module with the compiled object and archived Image:
// GUEST_TX_TEST_OBJECT=... GUEST_TX_TEST_TARGET=... go test -v ../corecheck/*.go
func TestArchivedTarget(t *testing.T) {
	objPath, targetPath := os.Getenv("GUEST_TX_TEST_OBJECT"), os.Getenv("GUEST_TX_TEST_TARGET")
	if objPath == "" || targetPath == "" {
		t.Skip("supply the guest TX object and archived arm64 Image or raw BTF")
	}
	obj, err := os.ReadFile(objPath)
	if err != nil {
		t.Fatal(err)
	}
	target, err := os.ReadFile(targetPath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := inspect(obj, target); err != nil {
		t.Fatal(err)
	}
	blob, err := targetBTF(target)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ name, field, want string }{
		{"no queue accounting field", "num_queued", "unavailable target"},
		{"no transmit return hook", "btf_trace_net_dev_xmit", "btf_trace_net_dev_xmit"},
		{"no sender return hook", "tcp_sendmsg", "tcp_sendmsg"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			old := []byte("\x00" + tc.field + "\x00")
			if bytes.Count(blob, old) != 1 {
				t.Fatalf("fixture requires a single %q BTF string", tc.field)
			}
			replacement := []byte("\x00" + strings.Repeat("_", len(tc.field)) + "\x00")
			mutated := bytes.Replace(blob, old, replacement, 1)
			if _, err := inspect(obj, mutated); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("want %q error, got %v", tc.want, err)
			}
		})
	}
}
