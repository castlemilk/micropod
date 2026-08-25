# Intelligent Shared Cache — Design

**Date:** 2026-08-25
**Status:** Approved (rev 2 — reviewer issues addressed)
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
- Hard cap: 10GB per runner (global LRU), 7d remote TTL. No per-type quotas (deduped chunks cannot be attributed).

**Non-Goals:**
- Cross-repo `node_modules` sharing (too variable, poorly dedupable).
- Replacing BuildKit's own `type=cache` for builds — we use it, not replace it.
- Handling private registries with per-repo auth beyond existing `DOCKER_CONFIG`. Private tarballs (detected via `~/.npmrc` containing `_authToken`) are never shared.

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
     (lifecycle 7d, 10GB)                │  builder cache  │
                                          └─────────────────┘
```

Two layers, one API (`SharedFSClient`):
- **Local:** `micropod-sharedfs` daemon at `~/micropod/share-cache`. Content-addressed chunk store (SHA256/256 KiB), APFS `clonefile` views (with fallback to `reflink`/`copy_file_range`/plain copy on Linux ext4), `FSEvents` live sync.
- **Remote:** GCS bucket `gs://cuttlefish-build-cache` (existing `minio-go` client). Lifecycle 7d via bucket retention. No soft-limit — alert at 80% via Cloud Monitoring.

## 4. Components

### 4.1 CacheManager uplift (`internal/runner/cache_manager.go`)

- Keep `hashFiles(pattern)` via `busybox` and `sanitizeCachePathKey` volume naming for backwards compat, but change lookup to **global first**:
  1. Compute `hash = hashFiles(pattern)`.
  2. Check `SharedFSClient.Has(hash)` — if hit, mount shared view, done.
  3. Check GCS `Has(hash)` — if hit, pull chunks to local store, mount, done.
  4. Miss — create `cf-cache-*` volume as today, then **promote** on container exit: `sync` snapshots volume content into chunk store keyed by `hash`, async `Push` to GCS.
- Add `shared: *bool` to `cachePolicy` (parsed from workflow YAML). `nil` = auto-detect, `true`/`false` = explicit.
- **Single-flight:** daemon per-hash `sync.Mutex` so 10 concurrent jobs computing same `hash` do one `Pull`/`Push` (CAS via GCS `ifGenerationMatch=0`, last-write-wins on collision).

### 4.2 SharedFSDaemon as cache backing (`Sources/MicropodSharedFS`)

Already does `mount`/`sync`/`gc`. Add `GCSStore`:
- `Has(hash) bool`, `Push(hashes)`: background, after `npm ci`/`go mod download` succeeds. Upload to `*.tmp` then compose/rename for atomicity. Never blocks `mount`.
- `Pull(hash)`: on local miss, before falling back to volume create. Timeout 3s, then proceed without cache (cold path). Truncated download cleaned up.
- Use existing `ChunkStore` dedup: `lodash@4.17.21` tarball fetched by repo A and B shares chunks.

**Eviction pinning:** `gc` LRU by `atime` but never evicts chunks with `refCount>0` (i.e., backing an active `sharedViews` mount). Evict only `refCount==0 && atime < now-5m`.

### 4.3 Auto-detect + explicit mount logic (shim `Handlers.containerCreate`)

At `containerCreate` time, inspect `HostConfig.Binds` and `CacheVolumes`:
- Well-known list (normalized to absolute container path, `~` expanded to `/root` on container side, `$HOME` on host side): `/go/pkg/mod`, `/root/.cache/go-build`, `/root/.npm`, `~/.cache/pip` (both `/root/.cache/pip` and `$HOME/.cache/pip`).
- If any bind's host path matches well-known **or** `cachePolicy.shared == true`, rewrite to shared view via daemon.
- If `shared == false`, force isolated view.
- Custom `sharedMounts: ["/my/cache"]` in workflow YAML → same.
- `hashFiles` pattern language: glob base dir `/workspace`, empty-match → fallback `path + ":" + langVersion` (not `hashFiles` empty).

### 4.4 BuildKit

Dockerfiles already patched with `--mount=type=cache` (done on `cuttlefish/micropod-cutover`). In CI (`GITHUB_ACTIONS=true`): `docker buildx build --cache-from type=gha --cache-to type=gha,mode=max`. No local `type=local` fallback in v1 (defer until CI-less devs need it).

## 5. Cache Key

`key = hashFiles(pattern) + ":" + langVersion` where `langVersion` dispatches per well-known path:

- `/go/pkg/mod`, `/root/.cache/go-build` → `go` from `go.mod:go` (fallback `go1.25`)
- `/root/.npm` → `node` from `package.json:engines.node` or `ui/package.json:engines.node` (fallback image digest, not tag — `latest` is mutable)
- `~/.cache/pip`, `/root/.cache/pip` → `python --version` or `requires-python` (fallback image digest)
- `go-build` (already content-addressed) → `go` version only

`hashFiles` is SHA256 of sorted `sha256sum` of matched files (existing `busybox` impl). SHA256 stated explicitly; on hit verify manifest sidecar `hash -> file list` to detect poisoning.

For well-known paths without `hashFiles` (bare `/root/.npm` mount), key is `path + ":" + langVersion` (e.g., `/root/.npm:node-22.11.0`).

Docker layer cache key is separate — BuildKit handles it.

## 6. Mount Logic (Intelligent Re-mount)

```
for each volume in cachePolicy.paths + autoDetectedWellKnown:
  if shared == false → isolated volume (today's behavior)
  else if localStore.Has(hash) → mount shared view (clonefile, ~15ms)
  else if gcs.Has(hash) → pull → mount
  else → create volume, mount, on success push to gcs (bg)
```

- **Isolation:** `node_modules` never cached; `~/.npm` is. Two repos with different `package-lock.json` get different hashes → different cache entries, even though the underlying chunks dedup.
- **Concurrency:** `mount` is per-container, but `sharedViews` in daemon is ref-counted — 10 concurrent jobs mounting same `~/.npm` share one view.

## 7. Storage & Eviction (the "don't store too much" guarantee)

- **Per-runner cap: 10GB global LRU** (`RUNNER_CACHE_MAX_BYTES`, default 10<<30). Single global cap (not per-type — deduped chunks cannot be attributed to Go vs npm). Enforced *before* next mount, not after. Metrics per type emitted for observability only.
- **Existing DiskManager (5m sweep) extended:** `sweepOrphanedVolumes` already age-gates (`cf-cache-*` 7d default, pressure 1h). Add `sharedCacheSize` check: if `du -s ~/micropod/share-cache > cap`, LRU-evict oldest `chunks` (by atime, refCount==0, 5m grace) until under cap.
- **Remote:** GCS bucket lifecycle `7d`, 10GB global. No per-runner quota. Alert at 80% via Cloud Monitoring. `Cache-Control` not set (lifecycle authoritative). Stale-while-revalidate: serve expired chunk, background refresh, with jittered re-pull to avoid thundering herd on mass expiry.
- **What we cache:** only `~/.npm`, `/go/pkg/mod`, `go-build`, `~/.cache/pip` — not `node_modules` (1-2GB, highly variable). This is ~80% smaller than naïve workspace caching.
- **Private tarballs:** if `~/.npmrc` contains `_authToken`, never `Push` to shared store/GCS (guard added to `GCSStore.Push`).

## 8. Data Flow

**Build:** `docker build` → BuildKit `type=cache` hit → no network. Miss → `go mod download` populates host cache → background push to GCS.

**Run (testcontainers / workflow task):**
1. `CacheManager.ResolveCacheVolumes` computes hash, checks local chunk store.
2. Daemon mounts shared view via `clonefile` (15ms for 10 files; directory `clonefile` fallback to per-file, respects `.dockerignore`/`.syncignore`).
3. Container runs `npm ci` — hits `~/.npm` shared view (warm).
4. On container exit, `sync` snapshots volume content into chunk store keyed by `hash`, async `Push` to GCS (atomic `*.tmp` + `ifGenerationMatch=0`).

**Promotion path made explicit:** cold-miss creates Docker volume → container writes `~/.npm` tgz files → `sync` after exit copies volume content into `ChunkStore` (hash → chunks) → `Push` to GCS. Next `Has(hash)` hits.

## 9. Error Handling

- Daemon down → fallback to plain Docker volume (today's behavior), log `shared mount failed`.
- GCS down → local hit still works; miss goes cold (no push/pull), never blocks `mount` (3s `Pull` timeout, then cold). Truncated download cleaned up.
- Corrupt chunk (`ChunkHash` mismatch) → delete chunk, re-pull from GCS or re-download (npm will re-fetch the tarball).
- ENOSPC during `clonefile` or `sync` → log, revert to isolated volume, never fail job.
- Private auth leak guard: `Push` no-ops if `~/.npmrc` has `_authToken`.
- Daemon crash mid-mount → atomic `mkdir tmp + rename` for view creation; `mount` timeout 500ms fallback to isolated volume.
- Partial push/pull → `*.tmp` + `ifGenerationMatch` ensures atomicity; no half-object visible.

## 10. Testing

- **Unit:** `UsageService.normalize`, `ChunkStore` dedup, `isIgnored` patterns (`.dockerignore` globs), eviction LRU with pinning (`sharedViews` refs never evicted), `Has` single-flight.
- **Integration (mock):** `CacheManager` global lookup before per-project, `shared: true/false` flag, `GCSStore` CAS.
- **E2E (real runtime, `MICROPOD_REAL_E2E=1`):** `npm ci` cold vs warm (assert warm < 2s), cross-repo same `package-lock.json` shares chunks (second repo warm without ever being cold), `PruneDockerResources` still respects `cuttle.kind`, private `~/.npmrc` never leaves host.

## 11. Rollout

- Branch `cuttlefish/micropod-cutover` already has BuildKit mounts + `MicropodExecutor`. Add this spec's cache manager changes behind `RUNNER_PREFER_MICROPOD=1` + `RUNNER_CACHE_MAX_BYTES` (default off, 10GB cap).
- `task e2e-real` + `bench` must stay green. No prod deploy change.
- Metrics: `shared_cache_hit_total{hit="local|remote|miss"}`, `shared_cache_bytes`, `evicted_chunks_total`, `gcs_push_errors_total`.

## 12. Open Questions (Resolved)

- **Global vs isolated:** Hybrid (global for well-known, per-repo for custom) — approved.
- **Auto-detect:** magic by default, explicit `shared: false` / `sharedMounts` override — approved.
- **Scope:** Go + Node + pip + Docker layer cache (C) — approved.
- **Storage cap:** 10GB global LRU (single, not per-type) + 7d remote + deduplicated — approved.

## 13. Revisions (rev 2)

- I1: single 10GB global LRU, per-type split removed.
- I2: promotion path `Volume → ChunkStore` on `sync` made explicit and diagrammed.
- I3: cache key extended per well-known path, fallback to image digest.
- I4: eviction pins `sharedViews` refs, `refCount==0 && atime < now-5m` only.
- I5: per-hash `sync.Mutex` single-flight + GCS `ifGenerationMatch` CAS.
- I6: error handling expanded (ENOSPC, partial, auth leak, daemon crash).
- I7: `clonefile` fallback documented (`reflink`/`copy_file_range`/plain copy on Linux ext4).
- I8: path normalization defined (container absolute, `~` → `/root`, `hashFiles` glob semantics).
- I9: BuildKit `type=local` deferred, `Cache-Control` dropped.
