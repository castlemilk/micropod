package main

import (
	"strings"
	"testing"
)

func TestOnlyCrunPodsAskForAVolatilePauseLayer(t *testing.T) {
	if got := sandboxConfig(strings.Repeat("a", 32), "/jobs/a", "crun").GetAnnotations(); got[volatileSnapshotAnnotation] != "true" || len(got) != 1 {
		t.Fatalf("crun pod annotations %v", got)
	}
	if got := sandboxConfig(strings.Repeat("b", 32), "/jobs/b", "kata").GetAnnotations(); len(got) != 0 {
		t.Fatalf("an untrusted Kata pod carries annotations %v", got)
	}
}
