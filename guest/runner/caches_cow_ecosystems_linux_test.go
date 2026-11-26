package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDecideCaches_NewEcosystemsAndTrustReadOnly(t *testing.T) {
	pol := defaultCachePolicy()
	facts := testFacts(
		[]string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/root"},
		map[string]pathFact{
			"/root/.m2":     dirFact,
			"/root/.gradle": dirFact,
			"/root/.bun":    dirFact,
		},
		"mvn", "gradle", "bun", "sccache", "playwright",
	)

	plan := decide(t, pol, dockerConfig{
		Labels: map[string]string{
			"io.micropod.cache.scope": "proj-x",
			"io.micropod.cache.trust": "untrusted",
		},
	}, facts)

	if !plan.ReadOnly || plan.Trust != "untrusted" {
		t.Fatalf("expected ReadOnly=true Trust=untrusted, got %+v", plan)
	}
	for _, kind := range []string{"maven", "gradle", "bun", "sccache", "playwright"} {
		st, ok := plan.Tools[kind]
		if !ok || st.Mode != "path" {
			t.Fatalf("tool %s expected mode=path, got %+v", kind, st)
		}
	}
	for _, st := range plan.Stores {
		if st.Exclusive {
			t.Fatalf("untrusted plan must not request exclusive lock for %s", st.Kind)
		}
	}

	// Invalid trust value must fail cleanly with HTTP 400.
	if _, err := decideCaches(pol, dockerConfig{
		Labels: map[string]string{"io.micropod.cache.trust": "bogus"},
	}, facts); err == nil {
		t.Fatal("expected invalid cache trust to fail")
	}
}

func TestOpenCacheMounts_UntrustedCoWOverlayAndFailClosedReadOnly(t *testing.T) {
	base := t.TempDir()
	prevRoot := cacheRoot
	prevMount := cacheOverlayMount
	cacheRoot = filepath.Join(base, "caches")
	t.Cleanup(func() {
		cacheRoot = prevRoot
		cacheOverlayMount = prevMount
	})

	pol := defaultCachePolicy()
	facts := testFacts([]string{"HOME=/root"}, nil, "node")
	plan := decide(t, pol, dockerConfig{
		Labels: map[string]string{
			"io.micropod.cache":       "gomod,yarn",
			"io.micropod.cache.trust": "untrusted",
		},
	}, facts)

	// 1. When overlay mount succeeds (simulated in unprivileged test via hook),
	//    untrusted container mounts ephemeral merged dir and never writes lower.
	overlayCalls := 0
	cacheOverlayMount = func(lowerDir, baseDir string) (string, error) {
		overlayCalls++
		merged := filepath.Join(baseDir, "merged")
		if err := os.MkdirAll(merged, 0777); err != nil {
			return "", err
		}
		return merged, nil
	}
	att := openCacheMounts(&plan, filepath.Join(base, "shim-ovl"))
	defer att.close()
	if overlayCalls < 2 {
		t.Fatalf("expected overlayfs mount for both scope and yarn unit, got %d calls", overlayCalls)
	}
	if len(att.overlays) != overlayCalls {
		t.Fatalf("expected %d tracked overlays, got %d", overlayCalls, len(att.overlays))
	}
	for _, m := range att.mounts {
		if m.Readonly {
			t.Fatalf("overlayfs mount should be writable in ephemeral upperdir: %+v", m)
		}
	}

	// 2. When overlayfs is unavailable, untrusted containers fail closed to Readonly=true!
	cacheOverlayMount = func(lowerDir, baseDir string) (string, error) {
		return "", os.ErrPermission
	}
	attRO := openCacheMounts(&plan, filepath.Join(base, "shim-ro"))
	defer attRO.close()
	if len(attRO.mounts) == 0 {
		t.Fatal("expected fail-closed readonly mounts")
	}
	for _, m := range attRO.mounts {
		if !m.Readonly {
			t.Fatalf("untrusted mount fell back to writable without overlayfs: %+v", m)
		}
	}
}

func TestOpenCacheMounts_ConcurrentYarnCoWOverlayFallback(t *testing.T) {
	base := t.TempDir()
	prevRoot := cacheRoot
	prevMount := cacheOverlayMount
	cacheRoot = filepath.Join(base, "caches")
	t.Cleanup(func() {
		cacheRoot = prevRoot
		cacheOverlayMount = prevMount
	})

	pol := defaultCachePolicy()
	facts := testFacts([]string{"HOME=/root"}, nil, "node")
	plan := decide(t, pol, dockerConfig{
		Labels: map[string]string{"io.micropod.cache": "yarn"},
	}, facts)

	// First container takes exclusive lock.
	first := openCacheMounts(&plan, filepath.Join(base, "c1"))
	defer first.close()
	if len(first.skipped) != 0 {
		t.Fatalf("first container skipped: %v", first.skipped)
	}

	// Second concurrent container gets CoW overlayfs over the warm yarn store!
	cacheOverlayMount = func(lowerDir, baseDir string) (string, error) {
		merged := filepath.Join(baseDir, "merged")
		if err := os.MkdirAll(merged, 0777); err != nil {
			return "", err
		}
		return merged, nil
	}
	second := openCacheMounts(&plan, filepath.Join(base, "c2"))
	defer second.close()
	if len(second.skipped) != 0 {
		t.Fatalf("concurrent yarn container with overlayfs should not skip, got %v", second.skipped)
	}
	if len(second.overlays) != 1 {
		t.Fatalf("expected 1 CoW overlay for concurrent yarn, got %d", len(second.overlays))
	}
}
