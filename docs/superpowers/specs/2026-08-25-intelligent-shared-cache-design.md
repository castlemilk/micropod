# Intelligent Shared Cache — Design

**Date:** 2026-08-25
**Status:** Approved
**Authors:** cuttlefish + micropod team
**Scope:** Cross-repo, cross-job, cross-runner package cache sharing with intelligent re-mounting

## 1. Overview

Cuttlefish runners currently create per-project, per-node, per-hash volumes (`cf-cache-*`) for workflow `cachePolicy` paths. This isolates correctly but re-downloads identical `package-lock.json` / `go.mod` contents for every repo. Local `docker build` has no cache mounts, so every build re-downloads Go modules and npm tarballs.

We add a **two-layer cache**: a local content-addressed store on each runner (the existing `micropod-sharedfs` daemon) and a remote GCS bucket as fallback. Well-known package-manager paths are auto-detected and mounted as shared views; explicit `shared: true/false` overrides. Storage is capped and LRU-evicted — the system must not grow unbounded.

## 2. Goals / Non-Goals

**Goals:**
- `npm ci` / `go mod download` warm in ~100ms on second run, on any runner, for any repo with identical lockfile.
- No code changes in workflows to get the benefit (auto-detect `/go/pkg/mod`, `/root/.cache/go-build`, `/root/.npm`, `~/.cache/pip`).
- Explicit `cachePolicy.shared` and `sharedMounts` for custom paths.
- Never store `node_modules` (output); store `~/.npm` (input tarballs) — 80% smaller, dedupable.
- Hard cap: 10GB per runner, 7d remote TTL.

**Non-Goals:**
- Cross-repo `node_modules` sharing (too variable, poorly dedupable).
- Replacing BuildKit's own `type=cache` for builds — we use it, not replace it.
- Handling private registries with per-repo auth beyond existing `DOCKER_CONFIG`.

## 3. Architecture

```
Host (runner)                          Container
┌─────────────────────┐                ┌─────────────────┐
│ micropod-sharedfs   │◄──FSEvents──►│  /go/pkg/mod    │  auto-mounted
│  chunk store        │   clonefile   │  /root/.npm     │  via shim
│  viewsBySrc         │◄──live sync──►│  /cache         │
│  GCS sync (bg)      │                └─────────────────┘
└─────────────────────┘                         ▲
        ▲                                       │
        │ pull/push on miss/put                 │ BuildKit
        ▼                                       │ --mount=type=cache
   gs://cuttlefish-build-cache/<hash>     ┌─────────────────┐
                                          │  builder cache  │
                                          └─────────────────┘
```

Two layers, one API (`SharedFSClient`):
- **Local:** `micropod-sharedfs` daemon at `~/micropod/share-cache`. Content-addressed chunk store (SHA256/256 KiB), APFS `clonefile` views, `FSEvents` live sync.
- **Remote:** GCS bucket `gs://cuttlefish-build-cache` (existing `minio-go` client). Lifecycle 7d, 10GB quota.

## 4. Components

### 4.1 CacheManager uplift (`internal/runner/cache_manager.go`)

- Keep `hashFiles(pattern)` via `busybox` and `sanitizeCachePathKey` volume naming for backwards compat, but change lookup to **global first**:
  1. Compute `hash = hashFiles(pattern)`.
  2. Check `SharedFSClient` chunk store for `hash` — if hit, mount shared view, done.
  3. Check GCS for `hash` — if hit, pull chunks to local store, mount, done.
  4. Miss — create `cf-cache-*` volume as today.
- Add `shared: *bool` to `cachePolicy` (parsed from workflow YAML). `nil` = auto-detect, `true`/`false` = explicit.

### 4.2 SharedFSDaemon as cache backing (`Sources/MicropodSharedFS`)

Already does `mount`/`sync`/`gc`. Add `GCSStore`:
- `Push(hashes)`: background, after `npm ci`/`go mod download` succeeds. Never blocks `mount`.
- `Pull(hash)`: on local miss, before falling back to volume create. Timeout 3s, then proceed without cache (cold path).
- Use existing `ChunkStore` dedup: `lodash@4.17.21` tarball fetched by repo A and B shares chunks.

### 4.3 Auto-detect + explicit mount logic (shim `Handlers.containerCreate`)

At `containerCreate` time, inspect `HostConfig.Binds` and `CacheVolumes`:
- Well-known list: `/go/pkg/mod`, `/root/.cache/go-build`, `/root/.npm`, `/usr/local/share/.cache`, `~/.cache/pip`, `/root/.cache/pip`.
- If any bind's host path matches well-known **or** `cachePolicy.shared == true`, rewrite to shared view via daemon.
- If `shared == false`, force isolated view.
- Custom `sharedMounts: ["/my/cache"]` in workflow YAML → same.

### 4.4 BuildKit

Dockerfiles already patched with `--mount=type=cache` (done on `cuttlefish/micropod-cutover`). Add in `Makefile`/`deploy/digitalocean/deploy.sh`:
```make
docker buildx build --cache-from type=gha --cache-to type=gha,mode=max  # CI
docker build --cache-from type=local,src=/tmp/buildkit-cache              # local fallback
```
No daemon involvement for builds — BuildKit handles it.

## 5. Cache Key

`key = hashFiles(pattern) + ":" + goVersion + ":" + nodeVersion` where `goVersion`/`nodeVersion` are taken from `go.mod:go` and `package.json:engines.node` (fallback to image tag). This prevents Go 1.24 mods poisoning Go 1.25 cache.

For well-known paths without `hashFiles` (e.g., bare `/root/.npm` mount), key is `path + ":" + nodeVersion`.

## 6. Mount Logic (Intelligent Re-mount)

```
for each volume in cachePolicy.paths + autoDetectedWellKnown:
  if shared == false → isolated volume (today's behavior)
  else if localStore.has(hash) → mount shared view (clonefile, ~15ms)
  else if gcs.has(hash) → pull → mount
  else → create volume, mount, on success push to gcs (bg)
```

- **Isolation:** `node_modules` never cached; `~/.npm` is. Two repos with different `package-lock.json` get different hashes → different cache entries, even though the underlying chunks dedup.
- **Concurrency:** `mount` is per-container, but `sharedViews` in daemon is ref-counted (already) — 10 concurrent jobs mounting same `~/.npm` share one view.

## 7. Storage & Eviction (the "don't store too much" guarantee)

- **Per-runner cap: 10GB** (`RUNNER_CACHE_MAX_BYTES`, default 10<<30). Split: 5GB Go, 3GB npm, 2GB other. Enforced *before* next mount, not after.
- **Existing DiskManager (5m sweep) extended:** `sweepOrphanedVolumes` already age-gates (`cf-cache-*` 7d default, pressure 1h). Add `sharedCacheSize` check: if `du -s ~/micropod/share-cache > cap`, LRU-evict oldest `chunks` (by atime) until under cap.
- **Remote:** GCS lifecycle `7d`, bucket quota 10GB (GCS `set-soft-limit` + Cloud Monitoring alert at 80%). `Cache-Control: public, max-age=604800`.
- **What we cache:** only `~/.npm`, `/go/pkg/mod`, `go-build`, `~/.cache/pip` — not `node_modules` (1-2GB, highly variable). This is ~80% smaller than naïve workspace caching.

## 8. Data Flow

**Build:** `docker build` → BuildKit `type=cache` hit → no network. Miss → `go mod download` populates host cache → background push to GCS.

**Run (testcontainers / workflow task):**
1. `CacheManager.ResolveCacheVolumes` computes hash, checks local chunk store.
2. Daemon mounts shared view via `clonefile` (15ms for 10 files).
3. Container runs `npm ci` — hits `~/.npm` shared view (warm).
4. On container exit, `sync` flushes new tarballs to chunk store, background push to GCS.

## 9. Error Handling

- Daemon down → fallback to plain Docker volume (today's behavior), log `shared mount failed`.
- GCS down → local hit still works; miss goes cold (no push/pull), never blocks `mount`.
- Corrupt chunk → `ChunkHash` mismatch → re-pull from GCS or re-download (npm will re-fetch the tarball).

## 10. Testing

- **Unit:** `UsageService.normalize`, `ChunkStore` dedup, `isIgnored` patterns, eviction LRU.
- **Integration (mock):** `CacheManager` global lookup before per-project, `shared: true/false` flag.
- **E2E (real runtime, `MICROPOD_REAL_E2E=1`):** `npm ci` cold vs warm (assert warm < 2s), cross-repo same `package-lock.json` shares chunks, `PruneDockerResources` still respects `cuttle.kind`.

## 11. Rollout

- Branch `cuttlefish/micropod-cutover` already has BuildKit mounts + `MicropodExecutor`. Add this spec's cache manager changes behind `RUNNER_PREFER_MICROPOD=1` + `RUNNER_CACHE_MAX_BYTES` (default off).
- `task e2e-real` + `bench` must stay green. No prod deploy change.

## 12. Open Questions (Resolved)

- **Global vs isolated:** Hybrid (global for well-known, per-repo for custom) — approved.
- **Auto-detect:** magic by default, explicit `shared: false` / `sharedMounts` override — approved.
- **Scope:** Go + Node + pip + Docker layer cache (C) — approved.
- **Storage cap:** 10GB + LRU + 7d remote — approved.
