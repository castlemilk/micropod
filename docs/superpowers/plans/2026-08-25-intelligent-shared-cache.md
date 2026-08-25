# Intelligent Shared Cache Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every `npm ci` / `go mod download` warm in ~100ms on any runner, for any repo with identical lockfile, via a two-layer content-addressed cache (local `micropod-sharedfs` chunk store + GCS fallback) with intelligent auto-mounting and storage-capped LRU.

**Architecture:** Local `SharedFSDaemon` chunk store (SHA256/256 KiB, APFS `clonefile` views) fronted by `singleflight.Group` per hash; `CacheManager` does global-first lookup (local `Has` → GCS `Has` → volume create) and background promotion (`sync` volume → chunk store → `Push` with `ifGenerationMatch=0`). Well-known paths auto-detected, explicit `shared` flag overrides. Build caches via BuildKit `type=cache` + `type=gha`.

**Tech Stack:** Go 1.25 (`internal/runner`), Swift 6 (`Sources/MicropodSharedFS`, `Sources/MicropodDockerShim`), `minio-go` for GCS, `busybox`/`sha256sum` for `hashFiles`, `singleflight`, `FSEvents`/`inotify`, APFS `clonefile`/`FICLONE`.

---

## File Structure

**Cuttlefish (Go runner):**
- Modify: `cuttlefish/internal/runner/cache_manager.go:1-269` — add `shared *bool` to `CachePolicy`, global `Has` lookup, `singleflight.Group`, promotion `Sync` + `Push`
- Modify: `cuttlefish/internal/runner/cache_manager_test.go` — new cases for global hit, `shared: false` isolation, singleflight dedup
- Create: `cuttlefish/internal/runner/gcs_store.go` — `GCSStore{Has,Push,Pull}` with `ifGenerationMatch=0`, 3s timeout, `*.tmp` atomicity
- Create: `cuttlefish/internal/runner/gcs_store_test.go` — CAS, truncated download, private registry guard

**Micropod (Swift daemon):**
- Modify: `micropod/Sources/MicropodSharedFS/SharedFSDaemon.swift` — Swift `GCSStore` (GCS `Has`/`Push`/`Pull` via `minio-go` Swift port or `URLSession` + `ifGenerationMatch`, singleflight per hash)
- Modify: `micropod/Sources/MicropodSharedFS/ChunkStore.swift` — `Has` method, `atime` tracking
- Modify: `micropod/Sources/MicropodSharedFS/ChunkStore.swift` — `Has` method, `atime` tracking
- Create: `internal/runner/gcs_store_test.go` — CAS, truncated download, private registry guard
- Modify: `Sources/MicropodSharedFS/SharedFSDaemon.swift` — `GCSStore` integration, `Has`, `Push`, `Pull`, LRU `atime` + `refCount` pinning, `sharedCacheSize` via store index
- Modify: `Sources/MicropodSharedFS/ChunkStore.swift` — `Has` method, `atime` tracking
- Modify: `Sources/MicropodDockerShim/Handlers.swift:68-103` — well-known `isWellKnown(path)` with `~` → `$HOME` via `Config.User`/`Env HOME`, `hashFiles` pattern `*,?,[abc],**,{a,b}` via `gobwas/glob`, empty-match fallback
- Modify: `Sources/MicropodSharedFS/FSEventsWatcher.swift` — add Linux `inotify` fallback
- Modify: `deploy/Dockerfile.*`, `ui/Dockerfile`, `Makefile`, `deploy/digitalocean/deploy.sh` — `type=gha` already done, verify
- Test: `Tests/MicropodIntegrationTests/CacheManagerIntegrationTests.swift` — cross-repo warm test
- Docs: `docs/agent/micropod-skill.md` — already has cache section, add `RUNNER_CACHE_MAX_BYTES` flag

---

## Chunk 1: CacheManager Global Lookup + Shared Flag

### Task 1: Add `shared` field to workflow cache policy

**Files:**
- Modify: `internal/runner/cache_manager.go:20-35` (CachePolicy struct)
- Modify: `internal/runner/cache_manager_test.go`

- [ ] **Step 1: Write the failing test**

```go
// internal/runner/cache_manager_test.go
func TestCachePolicySharedFlag(t *testing.T) {
    for _, tc := range []struct{ yaml string; want *bool }{
        {`cachePolicy: {keys: ["hashFiles('package-lock.json')"], paths: ["/root/.npm"]}`, nil},
        {`cachePolicy: {keys: ["hashFiles('package-lock.json')"], paths: ["/root/.npm"], shared: true}`, boolPtr(true)},
        {`cachePolicy: {keys: ["hashFiles('package-lock.json')"], paths: ["/root/.npm"], shared: false}`, boolPtr(false)},
    } {
        policy := parseCachePolicy(tc.yaml)
        if !reflect.DeepEqual(policy.Shared, tc.want) { t.Fatalf("want %v got %v", tc.want, policy.Shared) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/runner -run TestCachePolicySharedFlag` (in cuttlefish repo) -count=1`
Expected: FAIL with "undefined field Shared"

- [ ] **Step 3: Write minimal implementation**

```go
// internal/runner/cache_manager.go
type CachePolicy struct {
    Keys         []string          `yaml:"keys"`
    Paths        []string          `yaml:"paths"`
    Shared       *bool             `yaml:"shared"`
    SharedMounts []string          `yaml:"sharedMounts"`
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/runner -run TestCachePolicySharedFlag` (in cuttlefish repo) -count=1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/runner/cache_manager.go internal/runner/cache_manager_test.go
git commit -m "feat(cache): add shared flag to cachePolicy"
```

### Task 2: Global Has lookup before per-project volume

**Files:**
- Modify: `cuttlefish/internal/runner/cache_manager.go:80-150` (ResolveCacheVolumes)

### Task 3: Promotion Volume -> ChunkStore

**Files:**
- Modify: `cuttlefish/internal/runner/cache_manager.go` — on `ResolveCacheVolumes` miss, after `create volume` and container exit, call `SharedFSDaemon.Sync(volumePath)` to snapshot volume content into `ChunkStore` keyed by `hash`, then async `GCSStore.Push` (ifGenerationMatch=0, swallow 412)

- [ ] **Step 1: Write the failing test**

```go
func TestSyncPromotesVolumeToChunkStoreAndPushes(t *testing.T) {
    // Mock GCS, create volume, run container that writes to /cache, exit
    // Expect SharedFS.Has(hash) true and GCS has object
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/runner -run TestSyncPromotesVolumeToChunkStoreAndPushes -count=1`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```go
func (m *CacheManager) onContainerExit(volumePath, hash string) {
    m.sharedFS.Sync(volumePath) // snapshots into ChunkStore
    go m.gcs.Push(hash) // background, CAS
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/runner -run TestSyncPromotesVolumeToChunkStoreAndPushes -count=1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/runner/cache_manager.go internal/runner/cache_manager_test.go
git commit -m "feat(cache): promote volume to chunk store on exit"
```

### Task 2: Global Has lookup before per-project volume

**Files:**
- Modify: `internal/runner/cache_manager.go:80-150` (ResolveCacheVolumes)

- [ ] **Step 1: Write the failing test**

```go
func TestResolveCacheVolumes_GlobalHit(t *testing.T) {
    // Mock SharedFSClient.Has("abc") -> true, GCS Has -> false
    // Expect no volume create, mount shared view via SharedFSDaemon, singleflight dedup for 10 concurrent callers
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/runner -run TestResolveCacheVolumes_GlobalHit` (in cuttlefish repo) -count=1`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```go
func (m *CacheManager) ResolveCacheVolumes(...) (map[string]string, error) {
    hash := m.hashFiles(pattern)
    if m.sharedFS != nil && m.sharedFS.Has(hash) {
        mount, _ := m.sharedFS.Mount(hash)
        return map[string]string{path: mount}, nil
    }
    if m.gcs.Has(hash) { /* pull then mount */ }
    // fallback to volume as today
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/runner -run TestResolveCacheVolumes_GlobalHit` (in cuttlefish repo) -count=1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/runner/cache_manager.go internal/runner/cache_manager_test.go
git commit -m "feat(cache): global Has lookup before per-project volume"
```

---

## Chunk 2: GCSStore + Eviction (must complete before Chunk 1 Task 2 global lookup)

### Task 3: GCSStore with CAS and timeout (Go)

**Files:**
- Create: `cuttlefish/internal/runner/gcs_store.go`
- Test: `cuttlefish/internal/runner/gcs_store_test.go`

### Task 3b: Swift Daemon GCS integration

**Files:**
- Modify: `micropod/Sources/MicropodSharedFS/SharedFSDaemon.swift` — add Swift `GCSStore` wrapper (or reuse Go `minio-go` via `URLSession`), `Has`+`Pull` singleflight, `Push` background

### Task 3: GCSStore with CAS and timeout

**Files:**
- Create: `internal/runner/gcs_store.go`
- Test: `internal/runner/gcs_store_test.go`

- [ ] **Step 1: Write the failing test**

```go
func TestGCSStorePushCAS(t *testing.T) {
    store := NewGCSStore(fakeGCSWithExistingObject) // already has "abc"
    err := store.Push("abc", []byte("data")) // should swallow 412 as dedup success
    if err != nil {
        t.Fatalf("first-write-wins CAS should swallow 412, got %v", err)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `go test ./internal/runner -run TestGCSStorePushCAS -count=1`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```go
type GCSStore struct { client *minio.Client; bucket string }
func (s *GCSStore) Push(hash string, r io.Reader) error {
    _, err := s.client.PutObject(ctx, s.bucket, hash, r, -1, minio.PutObjectOptions{IfGenerationMatch: 0})
    if isPreconditionFailed(err) { return nil } // first-write-wins, swallow 412 as dedup success
    return err
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `go test ./internal/runner -run TestGCSStorePushCAS -count=1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add internal/runner/gcs_store.go internal/runner/gcs_store_test.go
git commit -m "feat(cache): GCSStore with CAS and 3s timeout"
```

---

## Chunk 3: Shim Auto-Detect (2-5 min per sub-task; split well-known, sharedMounts, and empty-match fallback into separate commits)

### Task 4: Well-known path detection + sharedMounts

**Files:**
- Modify: `Sources/MicropodDockerShim/Handlers.swift:70-85`
- Test: `Tests/MicropodDockerShimTests/ShimServerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testWellKnownNpmAutoShared() {
    let req = DockerCreateRequest(Image: "node:22", HostConfig: .init(Binds: ["/host/.npm:/root/.npm"]))
    XCTAssertTrue(Router.isWellKnown("/root/.npm"))
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testWellKnownNpmAutoShared`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```swift
// Container-aware: ~ expands via container Config.User/HOME, not host ~
static func isWellKnown(_ containerPath: String, containerConfig: DockerCreateRequest) -> Bool {
    let home = containerConfig.Env.first { $0.hasPrefix("HOME=") }?.dropFirst(5) ?? (containerConfig.User == "" ? "/root" : "/home/\(containerConfig.User)")
    let normalized = containerPath.replacingOccurrences(of: "~", with: home)
    return wellKnown.contains(normalized)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testWellKnownNpmAutoShared`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MicropodDockerShim/Handlers.swift Tests/MicropodDockerShimTests/ShimServerTests.swift
git commit -m "feat(shim): auto-detect well-known cache paths"
```

---

## Chunk 4: Storage Cap

### Task 5a: Indexed size gate

**Files:**
- Modify: `micropod/Sources/MicropodSharedFS/SharedFSDaemon.swift` — `sharedCacheSize` via store index (sum of chunk sizes), synchronous check before next mount (no `du`)

- [ ] **Step 1: Write the failing test**

```swift
func testIndexedSizeGate() {
    // fill store to cap, assert next mount blocks
}
```

### Task 5b: LRU eviction with pinning + grace-bypass

**Files:**
- Modify: `Sources/MicropodSharedFS/SharedFSDaemon.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testEvictionRespectsPinning() {
    // mount 2 views, pin one, fill cap, assert pinned not evicted
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testEvictionRespectsPinning`
Expected: FAIL

- [ ] **Step 3: Write minimal implementation**

```swift
func gcIfNeeded() {
    while indexedSize > cap {
        let oldest = chunks.filter { $0.refCount == 0 }.min(by: { $0.atime < $1.atime })
        // bypass 5m grace if still over cap
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter testEvictionRespectsPinning`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/MicropodSharedFS/SharedFSDaemon.swift Tests/MicropodSharedFSTests/SharedFSDaemonTests.swift
git commit -m "feat(sharedfs): LRU eviction with pinning and grace-bypass"
```

---

## Chunk 5: E2E Validation

### Task 6: Cross-repo warm test

**Files:**
- Test: `Tests/MicropodIntegrationTests/CacheManagerIntegrationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
func testCrossRepoWarm() {
    // repo A cold: npm ci (miss, push)
    // repo B same lockfile: npm ci warm <2s
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter testCrossRepoWarm`
Expected: FAIL (cold)

- [ ] **Step 3: Run with implementation from Chunk 1-4, verify passes**

Run: `swift test --filter testCrossRepoWarm`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add Tests/MicropodIntegrationTests/CacheManagerIntegrationTests.swift
git commit -m "test: cross-repo warm cache e2e"
```
