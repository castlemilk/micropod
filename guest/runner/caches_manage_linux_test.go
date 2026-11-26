package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestDecideCachesSharedL0AndProxyInjection(t *testing.T) {
	pol := defaultCachePolicy()
	pol.SharedL0 = true
	pol.GoProxy = "http://10.43.0.1:5555/go,direct"
	pol.NpmRegistry = "http://10.43.0.1:5555/npm"

	p := decide(t, pol, dockerConfig{Labels: map[string]string{"io.micropod.cache.scope": "proj-alpha"}}, testFacts(golangEnv, nil))
	if p.Scope != "proj-alpha" {
		t.Fatalf("plan scope = %q, want proj-alpha", p.Scope)
	}
	// L0 verified downloads route into /micropod/cache-l0 (scope "global")
	if got, _ := envOf(p, "GOMODCACHE"); got != "/micropod/cache-l0/gomod" {
		t.Fatalf("GOMODCACHE = %q, want /micropod/cache-l0/gomod", got)
	}
	if got, _ := envOf(p, "npm_config_cache"); got != "/micropod/cache-l0/npm" {
		t.Fatalf("npm_config_cache = %q, want /micropod/cache-l0/npm", got)
	}
	// L1 build artifacts stay in project scope /micropod/cache
	if got, _ := envOf(p, "GOCACHE"); got != "/micropod/cache/gobuild" {
		t.Fatalf("GOCACHE = %q, want /micropod/cache/gobuild", got)
	}
	if p.Tools["gomod"].Layer != cacheLayerL0 || p.Tools["gomod"].Scope != cacheL0GlobalScope {
		t.Fatalf("gomod tool state = %+v", p.Tools["gomod"])
	}
	if p.Tools["gobuild"].Layer != cacheLayerL1 || p.Tools["gobuild"].Scope != "proj-alpha" {
		t.Fatalf("gobuild tool state = %+v", p.Tools["gobuild"])
	}
	// Proxy env vars injected automatically when unset by user/image
	// A final direct is reached on any proxy error, not only 404 and 410.
	if got, _ := envOf(p, "GOPROXY"); got != "http://10.43.0.1:5555/go|direct" {
		t.Fatalf("GOPROXY = %q", got)
	}
	if got, _ := envOf(p, "npm_config_registry"); got != "http://10.43.0.1:5555/npm" {
		t.Fatalf("npm_config_registry = %q", got)
	}
	// Explicit user GOPROXY / npm_config_registry takes precedence
	pCustom := decide(t, pol, dockerConfig{
		Labels: map[string]string{"io.micropod.cache.scope": "proj-alpha"},
		Env:    []string{"GOPROXY=https://proxy.corp.internal", "NPM_CONFIG_REGISTRY=https://npm.corp.internal"},
	}, testFacts(golangEnv, nil))
	if _, injected := envOf(pCustom, "GOPROXY"); injected {
		t.Fatalf("expected user GOPROXY not to be overridden")
	}
	if _, injected := envOf(pCustom, "npm_config_registry"); injected {
		t.Fatalf("expected user npm_config_registry not to be overridden")
	}
}

func TestParseCachePolicyFleetFieldsAndDefaultDigestPreserved(t *testing.T) {
	// Default policy must marshal cleanly without new optional fields so digests stay stable.
	defBytes, err := json.Marshal(defaultCachePolicy())
	if err != nil {
		t.Fatalf("marshal default: %v", err)
	}
	if bytes.Contains(defBytes, []byte("sharedL0")) || bytes.Contains(defBytes, []byte("goProxy")) || bytes.Contains(defBytes, []byte("maxBytes")) {
		t.Fatalf("default policy unexpectedly contains optional keys: %s", defBytes)
	}
	raw := []byte(`{"sharedL0":true,"goProxy":"http://10.43.0.1:5555/go,direct","npmRegistry":"http://10.43.0.1:5555/npm","maxBytes":21474836480,"maxAgeDays":14,"minFreeBytes":4294967296}`)
	pol, err := parseCachePolicy(raw)
	if err != nil {
		t.Fatalf("parseCachePolicy: %v", err)
	}
	if !pol.SharedL0 || pol.GoProxy != "http://10.43.0.1:5555/go,direct" || pol.NpmRegistry != "http://10.43.0.1:5555/npm" || pol.MaxBytes != 20<<30 || pol.MaxAgeDays != 14 || pol.MinFreeBytes != 4<<30 {
		t.Fatalf("unexpected parsed policy: %+v", pol)
	}
	if _, err := parseCachePolicy([]byte(`{"goProxy":"ftp://bad"}`)); err == nil {
		t.Fatalf("expected invalid goProxy error")
	}
	if _, err := parseCachePolicy([]byte(`{"npmRegistry":"not-a-url"}`)); err == nil {
		t.Fatalf("expected invalid npmRegistry error")
	}
}

func TestCacheUsageDedupeAndLockSafePartialEviction(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("cache store layout tests require root (Linux guest)")
	}
	origRoot := cacheRoot
	cacheRoot = t.TempDir()
	defer func() { cacheRoot = origRoot }()

	// Populate two scopes: proj-a (old gomod + gobuild) and proj-b (newer gobuild sharing identical object)
	pGoModA, err := ensureStore("proj-a", "gomod", nil)
	if err != nil {
		t.Fatalf("ensureStore proj-a/gomod: %v", err)
	}
	pGoBuildA, err := ensureStore("proj-a", "gobuild", nil)
	if err != nil {
		t.Fatalf("ensureStore proj-a/gobuild: %v", err)
	}
	pGoBuildB, err := ensureStore("proj-b", "gobuild", nil)
	if err != nil {
		t.Fatalf("ensureStore proj-b/gobuild: %v", err)
	}
	pNpmA, err := ensureStore("proj-a", "npm", nil)
	if err != nil {
		t.Fatalf("ensureStore proj-a/npm: %v", err)
	}

	payload := bytes.Repeat([]byte("A"), 64*1024)
	if err := os.WriteFile(filepath.Join(pGoModA, "mod.zip"), payload, 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(pNpmA, "pkg.tgz"), payload, 0666); err != nil {
		t.Fatal(err)
	}
	// Create identical Go build object in bucket 00 of both proj-a and proj-b + a hot object in proj-a
	if err := os.MkdirAll(filepath.Join(pGoBuildA, "00"), 0777); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(pGoBuildB, "00"), 0777); err != nil {
		t.Fatal(err)
	}
	coldObjA := filepath.Join(pGoBuildA, "00", "00deadbeef-d")
	hotObjA := filepath.Join(pGoBuildA, "00", "00cafebabe-d")
	dupObjB := filepath.Join(pGoBuildB, "00", "00deadbeef-d")
	if err := os.WriteFile(coldObjA, payload, 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(hotObjA, payload, 0666); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dupObjB, payload, 0666); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().Add(-2 * time.Hour)
	if err := os.Chtimes(coldObjA, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}

	// Set deterministic LRU .used timestamps: proj-a/npm oldest (pinned!), proj-a/gobuild 2nd, proj-a/gomod 3rd, proj-b/gobuild newest
	for _, item := range []struct {
		scope, unit string
		ago         time.Duration
	}{
		{"proj-a", "npm", 4 * time.Hour},
		{"proj-a", "gobuild", 3 * time.Hour},
		{"proj-a", "gomod", 2 * time.Hour},
		{"proj-b", "gobuild", 1 * time.Hour},
	} {
		_ = touchUsed(item.scope, item.unit)
		ts := time.Now().Add(-item.ago)
		_ = os.Chtimes(filepath.Join(cacheRoot, ".meta", item.scope, item.unit+".used"), ts, ts)
	}

	// Pin proj-a/npm with a shared lock (simulating a running container)
	pin, err := unitLock("proj-a", "npm", false)
	if err != nil {
		t.Fatalf("unitLock proj-a/npm: %v", err)
	}
	defer pin.Close()

	eng := &dockerEngine{}
	// 1. Inspect usage & live inUse detection
	snap := eng.inspectCaches(true)
	if snap.Totals.ScopeCount != 2 || snap.Totals.UnitCount != 4 || snap.Totals.InUseCount != 1 {
		t.Fatalf("unexpected totals: %+v", snap.Totals)
	}
	if snap.Totals.L0Bytes == 0 || snap.Totals.L1Bytes == 0 {
		t.Fatalf("expected non-zero L0 and L1 bytes: %+v", snap.Totals)
	}

	// 2. Dedupe sampler must detect the duplicated 64 KiB Go object across proj-a and proj-b
	dedupe := sampleCacheDedupe(16)
	if dedupe.DuplicateObjects != 1 || dedupe.DuplicateBytes != uint64(len(payload)) {
		t.Fatalf("unexpected dedupe sample: %+v", dedupe)
	}

	// 3. Dry-run budget prune must skip pinned proj-a/npm and partially evict coldObjA (preserving hotObjA!)
	partial := true
	target := snap.Totals.TotalBytes - uint64(len(payload))/2
	dry, err := eng.pruneCaches(context.Background(), cachePruneRequest{
		MaxBytes:       target,
		PartialGoBuild: &partial,
		DryRun:         true,
	}, 0)
	if err != nil {
		t.Fatalf("dry prune: %v", err)
	}
	if dry.SkippedInUse != 1 || dry.FreedFiles != 1 {
		t.Fatalf("unexpected dry prune result: %+v", dry)
	}
	if _, err := os.Stat(coldObjA); err != nil {
		t.Fatalf("dry-run deleted coldObjA: %v", err)
	}

	// 4. Real budget prune must skip pinned proj-a/npm, delete coldObjA, preserve hotObjA, and record eviction telemetry!
	realRes, err := eng.pruneCaches(context.Background(), cachePruneRequest{
		MaxBytes:       target,
		PartialGoBuild: &partial,
		Reason:         "test-budget",
	}, 0)
	if err != nil {
		t.Fatalf("real prune: %v", err)
	}
	if realRes.SkippedInUse != 1 || realRes.FreedFiles != 1 || realRes.FreedBytes == 0 {
		t.Fatalf("unexpected real prune result: %+v", realRes)
	}
	if _, err := os.Stat(coldObjA); !os.IsNotExist(err) {
		t.Fatalf("expected coldObjA evicted, err=%v", err)
	}
	if _, err := os.Stat(hotObjA); err != nil {
		t.Fatalf("expected hotObjA preserved by safety cutoff, err=%v", err)
	}
	ev := eng.metrics.cache.evictionSummary()
	if ev.Evictions != 1 || ev.EvictedFiles != 1 || ev.EvictedBytes == 0 {
		t.Fatalf("unexpected eviction telemetry: %+v", ev)
	}

	// 5. Verify HTTP endpoints GET /micropod/caches, GET /micropod/caches/dedupe, POST /micropod/caches/prune
	rr := httptest.NewRecorder()
	handled, err := cacheRoutes(eng, rr, httptest.NewRequest(http.MethodGet, "/v1.47/micropod/caches", nil), "GET", "micropod/caches")
	if !handled || err != nil || rr.Code != 200 {
		t.Fatalf("GET /micropod/caches: handled=%v err=%v code=%d", handled, err, rr.Code)
	}
	var httpSnap cacheInspection
	if err := json.Unmarshal(rr.Body.Bytes(), &httpSnap); err != nil || httpSnap.Totals.UnitCount != 4 {
		t.Fatalf("decode GET /micropod/caches: err=%v snap=%+v", err, httpSnap)
	}
	rr2 := httptest.NewRecorder()
	handled, err = cacheRoutes(eng, rr2, httptest.NewRequest(http.MethodGet, "/v1.47/micropod/caches/dedupe?buckets=16", nil), "GET", "micropod/caches/dedupe")
	if !handled || err != nil || rr2.Code != 200 {
		t.Fatalf("GET /micropod/caches/dedupe: handled=%v err=%v code=%d", handled, err, rr2.Code)
	}
}
