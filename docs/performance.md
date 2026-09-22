# Performance

How Micropod is measured against Docker Desktop, current numbers, and how to
reproduce or extend them.

## Methodology

Same machine, both runtimes warm, `alpine:3.20` pre-pulled on both engines.
API numbers are p50 over n=30; lifecycle over n=10; concurrency is a single
10-way wall-clock sample (noisy — treat ±30% as noise).

```sh
# Shim (the dev build must be running; the app spawns it from .build/debug)
python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim \
    --json bench/shim.json

# Docker Desktop
python3 scripts/bench_shim_vs_docker.py unix:///var/run/docker.sock docker \
    --json bench/docker.json

# Regression check vs a previous run (exit 1 if any p50 regresses >20%)
python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim \
    --baseline bench/shim.json

# Runtime footprint + cold start (cold stops both runtimes — intrusive)
bash scripts/bench_runtime.sh idle    # RSS sums + process list
bash scripts/bench_runtime.sh cold    # system-start -> first list, vs Docker.app -> docker info
```

## Live metrics

The shim serves Prometheus text at `GET /metrics` over `docker.sock`:

```sh
curl -s --unix-socket ~/.micropod/docker.sock http://localhost/metrics
```

Three families:

- `micropod_api_*` — per-route request count/errors/latency (route labels are
  normalized, `containers/{id}/json` not per-name).
- `micropod_cli_*` — per-`container`-verb spawn count/latency. This is the
  budget: every spawn costs ~15–80 ms. Status 504 = timeout kill, 499 = cancel.
- `micropod_shim_cache_{hits,misses}` — `ReadThroughCache` effectiveness.

`ContainerCLIClient.run` also emits `os_signpost` intervals
(`com.micropod.cli`, category `pointsOfInterest`) so
`xctrace record --template "os_signpost"` splits CLI spawn+XPC+run time from
caller overhead. The MicropodAPI serves its own `/metrics` on :45454.

## Results (2026-09-22, M-series, both engines warm)

### API latency p50, ms — lower is better

| op | micropod before | micropod now | docker | verdict |
|---|---|---|---|---|
| ping | 0.3 | 0.3 | 1.9 | **6× faster** |
| version | 0.4 | 0.4 | 5.4 | **13× faster** |
| containers/json?all=1 | 0.3 | 0.3 | 35.2 | **117× faster** (cached body) |
| images/json | 0.4 | 0.3 | 153.7 | **512× faster** (cached body) |
| inspect container | 15.9 | **0.5** | 1.8 | **3.6× faster** (was 8.8× slower) |
| system df | 287.3 | **3.0** | 9003.1 | **3000× faster** |
| info | 280.2 | **0.4** | 4.6 | **11× faster** (was 61× slower) |

### Lifecycle p50, ms (create→start→exec→logs→stop→rm, alpine)

| phase | micropod | docker | note |
|---|---|---|---|
| create | 39.2 | 45.2 | parity |
| start | 529.0 | 69.6 | **gap**: Apple runtime boots a per-container VM |
| exec create | 0.9 | 2.5 | faster |
| exec start | 73.1 | 19.6 | gap: CLI spawn + VM exec |
| logs | 28.3 | 4.6 | gap: CLI spawn |
| stop | 72.2 | 2083 | faster (Docker waits the full 2 s grace; shim's stop is atomic) |
| rm | 69.5 | 26.8 | gap: CLI spawn |
| FULL roundtrip | 838 | 2252 | **2.7× faster** (dominated by Docker's stop wait) |
| 10× concurrent wall | 6.5–9.0 s | 2.62 s | **gap**: per-VM start serializes under load |

### Idle footprint

| | RSS |
|---|---|
| micropod (shim + API + sharedfs + Apple daemons + 1 running container VM) | **169 MB** |
| Docker Desktop (backend + VM + UI) | **1244 MB** |

**Docker uses 7.4× the memory at idle.** The micropod figure is conservative —
it includes the shared Apple `containermanagerd`/apiserver processes and a
running alpine VM, not just Micropod-owned processes (~30 MB for the three
helpers alone).

## What the instrumentation found (and fixed)

The first `/metrics` dump after a bench run showed the cache serving HTTP
reads but **internal service calls bypassing it**: `image list --verbose`
spawned 111×, `list --all` 118×, one `container inspect` per inspect request.
`info`, `df`, inspect resolution, and `resolveID` all spawned fresh CLIs.

Fixes:

- `containerInspect` consults `cachedInspect` (populated by every list) before
  spawning; `resolveID` resolves against the cached list (read paths only —
  mutations still resolve fresh).
- `info` and `system/df` read through `cachedContainersList`/`cachedImagesList`/
  `cachedVolumesList`; `UsageService.report` accepts prefetched snapshots.
- Volumes joined the read-through cache with invalidation on create/delete/
  prune.

After the bench: **237 hits / 38 misses (86%)**, `image list` spawns 111→6,
`list --all` 118→8.

## Where the remaining gaps are

- **`start` (529 ms vs 70 ms)** — real per-container VM boot; not shim
  overhead. Options: keep-alive micro-VM pool, or measuring whether parts of
  `container run` setup can overlap.
- **`exec start`/`logs`/`rm` (~30–75 ms)** — each is ~1 CLI spawn. Structural
  floor unless a persistent apiserver session replaces per-call `Process`.
- **Concurrent lifecycle** — 10 parallel VM starts contend. Wall time varies
  6.5–9 s run to run.

## Guardrails

- `--baseline` fails the bench on >20% p50 regressions.
- Mutation paths always resolve against a *fresh* list — the cache only
  serves reads. Every shim mutation invalidates synchronously; out-of-band
  changes are caught by the EventsHub poll + 1 s TTL bound.
- `MICROPOD_SHIM_CACHE_DISABLE=1` and `MICROPOD_SHIM_CACHE_TTL_MS` control the
  cache; run the bench with it disabled to measure the cacheless floor.
