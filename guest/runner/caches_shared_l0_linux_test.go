package main

import (
	"strings"
	"testing"
)

// What sharedL0 shares across projects, and the image facts the newer tool
// rows need.

// Only stores their tool verifies on every read move to scope "global" under
// sharedL0; maven, gradle, bun, playwright and every other row stay in the
// container's scope, so two projects never share them.
func TestCacheSharedL0KeepsUnverifiedStoresPerScope(t *testing.T) {
	pol := defaultCachePolicy()
	pol.SharedL0 = true
	facts := testFacts([]string{"PATH=/usr/local/bin:/usr/bin:/bin", "HOME=/root"}, map[string]pathFact{
		"/root/.m2": dirFact, "/root/.gradle": dirFact, "/root/.bun": dirFact, "/usr/local/cargo": dirFact,
	}, "mvn", "gradle", "bun", "sccache", "playwright", "node")
	facts.Env = append(facts.Env, "CARGO_HOME=/usr/local/cargo")
	global := map[string]bool{"gomod": true, "npm": true, "pnpm": true}
	for _, scope := range []string{"proj-a", "proj-b"} {
		p := decide(t, pol, dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": scope}}, facts)
		seen := map[string]bool{}
		for _, st := range p.Stores {
			seen[st.Kind] = true
			want := ""
			if global[st.Kind] {
				want = cacheL0GlobalScope
			}
			if st.Scope != want {
				t.Fatalf("%s: %s store in scope %q, want %q", scope, st.Kind, st.Scope, want)
			}
			if got := p.Tools[st.Kind].Scope; global[st.Kind] && got != cacheL0GlobalScope || !global[st.Kind] && got != scope {
				t.Fatalf("%s: %s reported in scope %q", scope, st.Kind, got)
			}
		}
		for _, kind := range []string{"maven", "gradle", "bun", "playwright", "yarn", "pip", "cargo", "gomod", "npm"} {
			if !seen[kind] {
				t.Fatalf("%s: no %s store in %+v", scope, kind, p.Tools)
			}
		}
	}
	for _, row := range cacheTable {
		if row.Global != global[row.Kind] {
			t.Fatalf("%s: Global=%v", row.Kind, row.Global)
		}
	}
	if !cacheToolByKind("maven").Exclusive {
		t.Fatal("maven's local repository is not single-writer")
	}
}

// Facts an older probe cached (version 1, before the mvn/gradle/bun/
// playwright binaries and npmrc registries) are probed again.
func TestImageFactsFromAnOlderProbeAreProbedAgain(t *testing.T) {
	old := imageFactsDir
	imageFactsDir = t.TempDir()
	t.Cleanup(func() { imageFactsDir = old })
	id := "sha256:" + strings.Repeat("ab", 32)
	stale := imageFacts{Version: 1, ImageID: id, OK: true}
	if err := writeCachedFacts(stale); err != nil {
		t.Fatal(err)
	}
	if _, ok := readCachedFacts(id); ok {
		t.Fatal("facts cached by version 1 are used")
	}
	stale.Version = factsVersion
	if err := writeCachedFacts(stale); err != nil {
		t.Fatal(err)
	}
	if _, ok := readCachedFacts(id); !ok || factsVersion < 2 {
		t.Fatal("current facts are not used")
	}
}
