package main

import (
	"math"
	"strings"
	"testing"
)

// A crun pod's sandbox asks for the boost's shares while the boost is on and
// for the kernel's default weight otherwise; a Kata pod asks for nothing.
func TestSandboxCPUShares(t *testing.T) {
	// crun 1.23+ (the bundle's is 1.31): libcrun's convert_shares_to_weight.
	crunWeight := func(shares uint64) uint64 {
		if shares >= 262144 {
			return 10000
		}
		l := math.Log2(float64(shares))
		return uint64(math.Ceil(math.Pow(10, (l*l+125*l)/612-7.0/34)))
	}
	if got := crunWeight(sandboxCPUShares(false)); got != 100 {
		t.Fatalf("shares %d are weight %d, not the default 100", sandboxCPUShares(false), got)
	}
	if got := crunWeight(sandboxCPUShares(true)); got != 10000 {
		t.Fatalf("boosted shares are weight %d", got)
	}
	got := sandboxConfig(strings.Repeat("a", 32), "/jobs/a", "crun").GetAnnotations()[sandboxCPUSharesAnnotation]
	if want := map[bool]string{true: "262144", false: "1024"}[startBoostWindow > 0]; got != want {
		t.Fatalf("crun pod annotation %q, want %q", got, want)
	}
	if got := withSandboxCPUShares(nil, false)[sandboxCPUSharesAnnotation]; got != "1024" {
		t.Fatalf("unboosted annotation %q", got)
	}
	if _, ok := sandboxConfig(strings.Repeat("b", 32), "/jobs/b", "kata").GetAnnotations()[sandboxCPUSharesAnnotation]; ok {
		t.Fatal("a Kata pod names sandbox shares")
	}
}
