# Intelligent Shared Cache — Design

**Date:** 2026-08-25
**Status:** Approved (rev 3 — reviewer issues addressed)
**Authors:** cuttlefish + micropod team
**Scope:** Cross-repo, cross-job, cross-runner package cache sharing with intelligent re-mounting

## 1. Overview

Cuttlefish runners currently create per-project, per-node, per-hash volumes (`cf-cache-*`) for workflow `cachePolicy` paths. This isolates correctly but re-downloads identical `package-lock.json` / `go.mod` contents for every repo. Local `docker build` has no cache mounts, so every build re-downloads Go modules and npm tarballs.

We add a **two-layer cache**: a local content-addressed store on each runner (the existing `micropod-sharedfs` daemon) and a remote GCS bucket as fallback. Well-known package-manager paths are auto-detected and mounted as shared views; explicit `shared: true/false` overrides. Storage is capped and LRU-evicted — the system must not grow unbounded. Promotion from Docker volume to chunk store happens explicitly on `sync` after container exit.

## 2. Goals / Non-Goals

**Goals:**
- `npm ci` / `go mod download` warm in ~100ms on second run, on any runner, for any repo with identical lockfile.
- No code changes in workflows to get the benefit (auto-detect `/go/pkg/mod`, `/root/.cache/go-build`, `/root/.npm`, `~/.cache/pip`).
- Explicit `cachePolicy.shared` and `sharedMounts` for custom paths.
- Never store `node_modules` (output); store `~/.npm` (input tarballs) — 80% smaller, dedupable.
- Hard cap: 10GB per runner (global LRU), 7d remote TTL.

**Non-Goals:**
- Cross-repo `node_modules` sharing (too variable, poorly dedupable).
- Replacing BuildKit's own `type=cache` for builds — we use it, not replace it.
- Handling private registries with per-repo auth beyond existing `DOCKER_CONFIG`. Private tarballs (detected via `NPM_TOKEN` env or any `.npmrc` containing `_auth` or `//registry.*/:_authToken`) are never shared.

## 3. Architecture

```
Host (runner)                          Container
┌─────────────────────┐                ┌─────────────────┐
│ micropod-sharedfs   │◄──FSEvents──►│  /go/pkg/mod    │  auto-mounted
│  chunk store        │   clonefile   │  /root/.npm     │  via shim
│  viewsBySrc         │◄──live sync──►│  /cache         │
│  GCS sync (bg)      │                └─────────────────┘
│  Docker volume      │◄──sync on exit─►│  cf-cache-*   │  fallback
└─────────────────────┘                         ▲
        ▲                                       │
        │ pull/push on miss/put                 │ BuildKit
        ▼                                       │ --mount=type=cache
   gs://cuttlefish-build-cache/<hash>     ┌─────────────────┐
     (lifecycle 7d, alert at 80%)        │  builder cache  │
                                          └─────────────────┘
```

Two layers, one API (`SharedFSClient`):
- **Local:** `micropod-sharedfs` daemon at `~/micropod/share-cache`. Content-addressed chunk store (SHA256/256 KiB), APFS `clonefile` views (with fallback to `FICLONE` on XFS/btrfs, `copy_file_range --reflink` where available, plain copy on ext4 which has no reflink), `FSEvents` on macOS / `inotify` on Linux live sync.
- **Remote:** GCS bucket `gs://cuttlefish-build-cache` (existing `minio-go` client). Lifecycle 7d, alert at 80% via Cloud Monitoring (no hard 10GB remote cap — lifecycle is the enforcement; local 10GB is hard).

## 4. Components

### 4.1 CacheManager uplift (`internal/runner/cache_manager.go`)

- Keep `hashFiles(pattern)` via `busybox` (with fallback to host `sha256sum` if `busybox` not in image) and `sanitizeCachePathKey` volume naming for backwards compat, but change lookup to **global first**:
  1. Compute `hash = hashFiles(pattern)`.
  2. Check `SharedFSClient.Has(hash)` — if hit, mount shared view, done. Uses `singleflight.Group` per hash so 10 concurrent jobs do one `Has`/`Pull`.
  3. Check GCS `Has(hash)` — if hit, pull chunks to local store, mount, done. `Pull` has 3s timeout, then cold.
  4. Miss — create `cf-cache-*` volume as today.
  5. **Promotion:** on container exit, `CacheManager` calls `SharedFSDaemon.Sync(volumePath)` which snapshots volume content into `ChunkStore` keyed by `hash`, then async `GCSStore.Push` (upload to `*.tmp` then `ifGenerationMatch=0` CAS — first-write-wins, second gets `412 PreconditionFailed` and is swallowed as dedup success).
- Add `shared: *bool` to `cachePolicy` (parsed from workflow YAML). `nil` = auto-detect, `true`/`false` = explicit.

### 4.2 SharedFSDaemon as cache backing (`Sources/MicropodSharedFS`)

Already does `mount`/`sync`/`gc`. Add `GCSStore`:
- `Has(hash) bool`, `Push(hashes)`, `Pull(hash)` — `Push` background, after `npm ci`/`go mod download` succeeds. Never blocks `mount`. `Push` is idempotent via `ifGenerationMatch=0`.
- `Pull` single-flight per hash, `Has` checks local `ChunkStore` first.
- Use existing `ChunkStore` dedup: `lodash@4.17.21` tarball fetched by repo A and B shares chunks.
- **Eviction pinning:** `gc` LRU by `atime` but skips `refCount>0` (backing active `sharedViews` mount) and respects 5m grace. If cache still over cap and all remaining chunks are `<5m` old or pinned, bypass grace and evict oldest `refCount==0` anyway (prevents unbounded growth under pressure). Enforced *before* next mount (synchronous check) and via async 5m sweep.

### 4.3 Auto-detect + explicit mount logic (shim `Handlers.containerCreate`)

At `containerCreate` time, inspect `HostConfig.Binds` and `CacheVolumes`:
- Well-known list (normalized to absolute container path): `/go/pkg/mod`, `/root/.cache/go-build`, `/root/.npm`, `~/.cache/pip` (expanded via container `USER`/`HOME` inspection — `~` → `$HOME` from `Config.Env HOME` or `Config.User` home, fallback `/root`).
- If any bind's host path matches well-known (container absolute, `~` expanded) **or** `cachePolicy.shared == true`, rewrite to shared view via daemon.
- If `shared == false`, force isolated view.
- Custom `sharedMounts: ["/my/cache"]` in workflow YAML → same.
- `hashFiles` pattern language: glob base dir `/workspace`, supports `*`, `?`, `[abc]`, `**`; empty-match → fallback `path + ":" + langVersion`.

### 4.4 BuildKit

Dockerfiles already patched with `--mount=type=cache` (done on `cuttlefish/micropod-cutover`). In CI (`GITHUB_ACTIONS=true`): `docker buildx build --cache-from type=gha --cache-to type=gha,mode=max`. No local `type=local` fallback in v1 (defer until CI-less devs need it — local devs get sharedFS, not BuildKit remote).

## 5. Cache Key

`key = hashFiles(pattern) + ":" + langVersion` where `langVersion` dispatches per well-known path:

| Well-known path | `hashFiles` glob | `langVersion` source | Fallback |
|---|---|---|---|
| `/go/pkg/mod`, `/root/.cache/go-build` | `go.mod` (`**/go.mod`) | `go` from `go.mod:go` | `go1.25` or image digest (not tag — `latest` mutable) |
| `/root/.npm` | `package-lock.json` (`**/package-lock.json`) | `node` from `package.json:engines.node` or `ui/package.json:engines.node` (search up to 3 parents) | image digest |
| `~/.cache/pip`, `/root/.cache/pip` | `requirements.txt` / `poetry.lock` / `pyproject.toml` (`**/{requirements.txt,poetry.lock,pyproject.toml}`) | `python --version` or `requires-python` | image digest |
| `go-build` (already content-addressed) | `go.mod` | `go` version + `GOOS`/`GOARCH`/`GOFLAGS` (prevents cross-arch poisoning) | `go` version |

`hashFiles` is SHA256 of sorted `sha256sum` of matched files (existing `busybox` impl, fallback to host `sha256sum` if `busybox` not in image). SHA256 stated explicitly; on hit verify manifest sidecar `hash -> file list` (stored atomically with chunks as `chunks/<hash>.manifest`) to detect poisoning.

For well-known paths without `hashFiles` (bare `/root/.npm` mount), key is `path + ":" + langVersion` (e.g., `/root/.npm:node-22.11.0`).

Docker layer cache key is separate — BuildKit handles it.

## 6. Mount Logic (Intelligent Re-mount)

```
for each volume in cachePolicy.paths + autoDetectedWellKnown:
  if shared == false → isolated volume (today's behavior)
  else if localStore.Has(hash) → mount shared view (clonefile, ~15ms) [singleflight]
  else if gcs.Has(hash) → pull (singleflight, 3s timeout) → mount
  else → create volume, mount, on success push to gcs (bg, *.tmp + ifGenerationMatch=0)
```

- **Isolation:** `node_modules` never cached; `~/.npm` is. Two repos with different `package-lock.json` get different hashes → different cache entries, even though the underlying chunks dedup.
- **Concurrency:** `mount` is per-container, but `sharedViews` in daemon is ref-counted — 10 concurrent jobs mounting same `~/.npm` share one view. `singleflight.Group` per hash prevents thundering herd on `Pull`/`Push`.
- **Normalization:** container absolute path, `~` expanded via container `USER`/`HOME` (fallback `/root`), glob base `/workspace`.

## 7. Storage & Eviction (the "don't store too much" guarantee)

- **Per-runner cap: 10GB global LRU** (`RUNNER_CACHE_MAX_BYTES`, default 10<<30). Single global cap (not per-type — deduped chunks cannot be attributed to Go vs npm; per-type metrics emitted for observability only). Enforced *before* next mount (synchronous `du -s` check) and via async sweep. If over cap, LRU-evict oldest `chunks` (by atime, `refCount==0`, 5m grace) until under cap; if still over and all candidates are `<5m` or pinned, bypass grace and evict oldest `refCount==0` anyway.
- **Existing DiskManager (5m sweep) extended:** `sweepOrphanedVolumes` already age-gates (`cf-cache-*` 7d default, pressure 1h). Add `sharedCacheSize` check: same 10GB cap, same pinning.
- **Remote:** GCS bucket lifecycle `7d`, alert at 80% via Cloud Monitoring (no hard remote cap). `Cache-Control` not set (lifecycle authoritative). Stale-while-revalidate: serve expired chunk, background refresh with jittered delay `100ms * rand(1, 10)` to avoid herd on mass 7d expiry.
- **What we cache:** only `~/.npm`, `/go/pkg/mod`, `go-build`, `~/.cache/pip` — not `node_modules` (1-2GB, highly variable). This is ~80% smaller than naïve workspace caching.
- **Private tarballs:** `GCSStore.Push` no-ops if `~/.npmrc` contains `_authToken` or `//registry.*/:_authToken`, or env `NPM_TOKEN` is set, or pip `~/.netrc`/`PIP_EXTRA_INDEX_URL` contains private host. Guard covers non-root `$HOME` `.npmrc` as well.

## 8. Data Flow

**Build:** `docker build` → BuildKit `type=cache` hit → no network. Miss → `go mod download` populates host cache → background push to GCS (atomic `*.tmp` + `ifGenerationMatch=0`).

**Run (testcontainers / workflow task):**
1. `CacheManager.ResolveCacheVolumes` computes hash, checks local chunk store (singleflight).
2. Daemon mounts shared view via `clonefile` (15ms for 10 files; directory `clonefile` fallback to per-file, respects `.dockerignore`/`.syncignore`).
3. Container runs `npm ci` — hits `~/.npm` shared view (warm).
4. On container exit, `CacheManager` calls `SharedFSDaemon.Sync(volumePath)` which snapshots volume content into `ChunkStore` keyed by `hash` (hash-checked, `reflink`/`copy_file_range` on XFS/btrfs, plain copy on ext4), then async `Push` to GCS.

**Promotion path made explicit:** cold-miss creates Docker volume (`cf-cache-*`) → container writes `~/.npm` tgz files → `sync` after exit copies volume content into `ChunkStore` (chunked, content-addressed) → `Push` to GCS. Next `Has(hash)` hits.

## 9. Error Handling

- Daemon down → fallback to plain Docker volume (today's behavior), log `shared mount failed` (500ms mount timeout, then isolated).
- GCS down → local hit still works; miss goes cold (no push/pull), never blocks `mount` (3s `Pull` timeout, truncated download cleaned up, `ChunkHash` verify on Pull).
- Corrupt chunk (`ChunkHash` mismatch on `Pull`) → delete chunk, re-pull from GCS or re-download (npm will re-fetch the tarball).
- ENOSPC during `clonefile` or `sync` → log, delete `*.tmp`, revert to isolated volume, never fail job.
- Private auth leak guard: `Push` no-ops if `~/.npmrc`/`NPM_TOKEN`/`~/.netrc` indicates private registry.
- Daemon crash mid-mount → atomic `mkdir tmp + rename` for view creation; `mount` timeout 500ms fallback to isolated volume. Crash after mount but before `sync` → data loss for that container's `~/.npm` writes (acceptable: next `npm ci` re-downloads; `sync` is best-effort).
- Partial push/pull → `*.tmp` + `ifGenerationMatch=0` ensures atomicity; no half-object visible. Truncated `Pull` detected via `ChunkHash` and cleaned.
- `busybox` missing → fallback to host `sha256sum` binary.

## 10. Testing

- **Unit:** `UsageService.normalize`, `ChunkStore` dedup, `isIgnored` patterns (`.dockerignore` globs), eviction LRU with pinning (`sharedViews` refs never evicted, `refCount==0 && atime < now-5m` only, grace-bypass under pressure), `Has` singleflight.
- **Integration (mock):** `CacheManager` global lookup before per-project, `shared: true/false` flag, `GCSStore` CAS (`412 PreconditionFailed` swallowed as dedup success), `FindDockerBinary` with `DOCKER_HOST` override.
- **E2E (real runtime, `MICROPOD_REAL_E2E=1`):** `npm ci` cold vs warm (assert warm < 2s), cross-repo same `package-lock.json` shares chunks (second repo warm without ever being cold, verified via `sharedCacheSize` and `GCSStore` metrics), `PruneDockerResources` still respects `cuttle.kind` (cache volumes never pruned incorrectly), private `~/.npmrc` never leaves host (assert no `Push`).

## 11. Rollout

- Branch `cuttlefish/micropod-cutover` already has BuildKit mounts + `MicropodExecutor`. Add this spec's cache manager changes behind `RUNNER_PREFER_MICROPOD=1` + `RUNNER_CACHE_MAX_BYTES=10737418240` (default 10GB, default *off* until `RUNNER_PREFER_MICROPOD=1` is set — single default statement, no "off" vs "10GB" contradiction).
- `task e2e-real` + `bench` must stay green. No prod deploy change.
- Metrics: `shared_cache_hit_total{hit="local|remote|miss"}`, `shared_cache_bytes`, `evicted_chunks_total`, `gcs_push_errors_total`, `shared_views_pinned`.

## 12. Open Questions (Resolved)

- **Global vs isolated:** Hybrid (global for well-known, per-repo for custom) — approved.
- **Auto-detect:** magic by default, explicit `shared: false` / `sharedMounts` override — approved.
- **Scope:** Go + Node + pip + Docker layer cache (C) — approved.
- **Storage cap:** 10GB global LRU (single, not per-type) + 7d remote + deduplicated — approved.

## 13. Revisions

- **rev 2:** I1 single global LRU, I2 promotion path, I3 per-path keys, I4 pinned eviction, I5 CAS, I6 error handling, I7 clonefile fallback, I8 path normalization, I9 deferred local fallback.
- **rev 3:** I1 remote alert-only (no hard 10GB), I2 diagram + Docker volume node, I3 table well-known→glob→langVersion, I4 grace-bypass, I5 `singleflight.Group` + first-write-wins, I6 ENOSPC/partial/auth/crash, I7 `FICLONE` vs ext4, I8 non-root `~`, I9 already pass, plus N1 single default, N2 sidecar, N3 file-level vs chunk, N4 GOOS/GOARCH, N5 jitter, N6 busybox fallback.
