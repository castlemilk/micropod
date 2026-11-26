# Testcontainers + Ryuk Benchmarks & End-to-End Engine Observability (`0.1.0-b9`)

**Date**: 2026-11-26  
**Host**: Gamma (Apple M5 Max, 18 cores, 128 GB RAM, macOS 26.5.1)  
**Micropod**: Signed `0.1.0-b9` (`dist/Micropod.0.1.0-b9.tgz` / `dist/Micropod.app`, Rust HVF `micropod-vmm`, kernel `7.3.5-micropod-b8`, 4 vCPUs / 4 GiB RAM)  
**Baseline Competitor**: OrbStack 2.2.5 (Docker Engine 29.8.2, 4 vCPUs)  
**Client Stack**: Unmodified `testcontainers-go v0.40.0`, Docker Go SDK `v28.5.1`, real `testcontainers/ryuk:0.13.0`, `alpine:3.23`, `postgres:16-alpine`  
**Authoritative Receipt**: [testcontainers-ryuk-and-observability.json](testcontainers-ryuk-and-observability.json)

---

## Executive Summary

Micropod `0.1.0-b9` passes **100% (5/5)** of the stock `testcontainers-go v0.40.0` + real `testcontainers/ryuk:0.13.0` qualification matrix (including multi-network alias routing and automatic Ryuk reaping of abandoned containers, networks, and volumes while preserving unrelated sessions) and **outperforms OrbStack 2.2.5 in every paired alternating benchmark round**:

| Workload (Paired Alternating Runs) | Micropod `0.1.0-b9` (Median) | OrbStack 2.2.5 (Median) | Delta / Speedup |
|---|---:|---:|---:|
| **8-Client Sibling Testcontainers + Shared Ryuk** (4 pairs): Start → Last HTTP Ready | **956.74 ms** *(range 810.1–1,189.6)* | 1,502.27 ms *(range 1,308.9–1,592.7)* | **-36.3% faster (1.57×)** |
| **8-Client Sibling + Shared Ryuk**: Ryuk Reap Window *(10 s grace + actual reap)* | **10,870.83 ms** *(+871 ms past grace)* | 11,513.19 ms *(+1,513 ms past grace)* | **1.74× faster actual reap** |
| **8-Client Sibling + Shared Ryuk**: Total Lifecycle to All 9 HTTP 404s | **11,823.88 ms** | 13,015.47 ms | **-1.19 s faster** |
| **Real-World `postgres:16-alpine` + Virtio-FS SQL Init + Ryuk** (3 pairs): Ready (`initdb` + SQL + TCP 5432) | **862.85 ms** *(range 853.2–975.2)* | 2,782.49 ms *(range 2,640.8–2,969.3)* | **3.22× faster (-69.0%)** |
| **Real-World `postgres:16-alpine`**: Live `psql` `INSERT` + `SELECT` (`docker exec`) | **9.07 ms** *(range 8.55–9.09)* | 40.25 ms *(range 36.73–45.48)* | **4.44× faster (-77.5%)** |
| **Real-World `postgres:16-alpine`**: Ryuk Automatic Cleanup to Both 404s | **10,237.33 ms** *(+237 ms past grace)* | 10,478.44 ms *(+478 ms past grace)* | **2.02× faster actual reap** |
| **Real-World `postgres:16-alpine`**: Total End-to-End Lifecycle | **11,105.20 ms** | 13,451.77 ms | **-2.35 s faster** |

> [!NOTE]
> Under quiet host conditions (prior clean run before ambient host load), Micropod reached **`807.43 ms`** median (`741.3–860.8 ms`) vs OrbStack **`1,253.10 ms`** on the 8-service wave (-35.6%), and **`756.10 ms`** ready / **`6.79 ms`** SQL exec vs OrbStack **`2,795.51 ms`** / **`36.95 ms`** on PostgreSQL 16 (3.70× / 5.44× faster). Both runs are consistent across every paired metric; all figures in the tables below come directly from the complete 4-suite authoritative receipt [testcontainers-ryuk-and-observability.json](testcontainers-ryuk-and-observability.json).

---

## 1. Suite 1 — Stock Testcontainers-Go v0.40.0 + Ryuk Qualification Matrix

Every mode compiles and runs the stock Go client against identical preloaded `alpine:3.23` and `testcontainers/ryuk:0.13.0` images:

| Qualification Mode | Micropod `0.1.0-b9` | OrbStack 2.2.5 | Notes |
|---|---:|---:|---|
| `core` *(create, HTTP ready, prefix decoy, running & stopped reuse w/ retained rootfs, stop/terminate)* | **PASS** (`4,319.5 ms`) | PASS (`1,768.0 ms`) | Live trace pinpointed single `2,778.35 ms` initial `start` span (see §5) |
| `name-filters` *(exact & anchored container name regex filtering)* | **PASS** (`87.1 ms`) | PASS (`455.0 ms`) | **5.22× faster** |
| `single-network` *(owned bridge + alias DNS resolution + published HTTP)* | **PASS** (`1,594.4 ms`) | PASS (`2,076.5 ms`) | **-23.2% faster** |
| `multi-network` *(dual owned bridges + per-network aliases + peer `wget`)* | **PASS** (`2,787.5 ms`) | PASS (`3,595.5 ms`) | **-22.5% faster** |
| `ryuk-abandon --abandon-resources` *(real Ryuk auto-reap of container + network + volume; control session preserved)* | **PASS** (`10,799.0 ms`) | PASS (`11,234.1 ms`) | `fixture=404`, `ryuk=404`, active `net/vol=404`, control `net/vol=200`, `manual_cleanup=false` |

---

## 2. Suite 2 — 8-Client Sibling Testcontainers + Shared Ryuk (4 Alternating Pairs)

Eight independent Go Testcontainers client processes launch concurrently, race on `reaper_<session>` creation/discovery, start 8 distinct published HTTP services, verify loopback HTTP content from macOS, exit simultaneously, and wait for real `testcontainers/ryuk:0.13.0` to automatically reap all 8 services plus itself (`0` manual cleanups permitted).

| Pair | First Engine | Micropod Ready | OrbStack Ready | Micropod Reap Window | OrbStack Reap Window | Micropod Total | OrbStack Total |
|---:|---|---:|---:|---:|---:|---:|---:|
| 1 | Micropod | **810.11 ms** | 1,308.91 ms | **10,874.32 ms** | 11,403.16 ms | **11,684.43 ms** | 12,712.07 ms |
| 2 | OrbStack | **1,021.04 ms** | 1,561.61 ms | **10,867.35 ms** | 11,496.89 ms | **11,888.39 ms** | 13,058.50 ms |
| 3 | Micropod | **892.44 ms** | 1,442.93 ms | **10,866.94 ms** | 11,529.50 ms | **11,759.38 ms** | 12,972.43 ms |
| 4 | OrbStack | **1,189.57 ms** | 1,592.71 ms | **10,934.92 ms** | 11,966.31 ms | **12,124.49 ms** | 13,559.02 ms |
| **Median** | **Alternating** | **956.74 ms** | **1,502.27 ms** | **10,870.83 ms** | **11,513.19 ms** | **11,823.88 ms** | **13,015.47 ms** |

- **Win rate**: Micropod won **4/4 pairs** on start-to-ready latency (**-36.3%**), reap window (**-642 ms**), and total lifecycle (**-1.19 s**).
- **Cleanup integrity**: **0 manual cleanups**, 36/36 containers automatically reaped cleanly with 0 leaked Ryuk sessions.

---

## 3. Suite 3 — Real-World `postgres:16-alpine` + Virtio-FS SQL Migrations + Ryuk (3 Alternating Pairs)

Each iteration starts a real `postgres:16-alpine` container via stock `testcontainers-go v0.40.0` with:
- A host-mounted `/docker-entrypoint-initdb.d/01-init.sql` migration file served over Phase B8 Virtio-FS,
- Dual wait strategy (`wait.ForLog("database system is ready to accept connections").WithOccurrence(2)` + `wait.ForListeningPort("5432/tcp")`),
- Direct macOS TCP dial to the published `5432/tcp` host port,
- Live `psql` `INSERT` + `SELECT count(*)` confirming both the Virtio-FS init row and live write (`2` rows),
- Automatic Ryuk teardown upon client exit verified by HTTP `404` on both PostgreSQL and Ryuk.

| Pair | First Engine | Micropod Ready | OrbStack Ready | Micropod SQL | OrbStack SQL | Micropod Reap | OrbStack Reap | Micropod Total | OrbStack Total |
|---:|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | Micropod | **975.19 ms** | 2,782.49 ms | **8.55 ms** | 45.48 ms | **10,237.33 ms** | 10,657.22 ms | **11,214.01 ms** | 13,451.77 ms |
| 2 | OrbStack | **862.85 ms** | 2,969.26 ms | **9.09 ms** | 40.25 ms | **10,239.47 ms** | 10,478.44 ms | **11,105.20 ms** | 13,457.86 ms |
| 3 | Micropod | **853.18 ms** | 2,640.81 ms | **9.07 ms** | 36.73 ms | **10,203.76 ms** | 10,416.94 ms | **11,063.52 ms** | 13,067.00 ms |
| **Median** | **Alternating** | **862.85 ms** | **2,782.49 ms** | **9.07 ms** | **40.25 ms** | **10,237.33 ms** | **10,478.44 ms** | **11,105.20 ms** | **13,451.77 ms** |

- **Win rate**: Micropod won **3/3 pairs** across every phase: **3.22× faster** Postgres 16 init+ready, **4.44× faster** `psql` exec round-trip, and **2.02× faster** post-grace Ryuk deletion.

---

## 4. End-to-End Instrumentation & Live Observability (Zero Metric Files)

To make engine, Docker API, Ryuk reaper, and Virtio-FS issues immediately visible without metric files on disk, `0.1.0-b9` adds live, low-overhead instrumentation across all three layers:

1. **Guest Docker Engine & Ryuk Reaper (Go)** — [docker_observability_linux.go](../../../guest/runner/docker_observability_linux.go), [docker_http_linux.go](../../../guest/runner/docker_http_linux.go), [docker_reaper_linux.go](../../../guest/runner/docker_reaper_linux.go), [docker_metrics_linux.go](../../../guest/runner/docker_metrics_linux.go):
   - Bounded-cardinality route normalization (`normalizeDockerRoute`: `/v1.47/containers/<id>/start` → `/containers/{id}/start`) tracking per-route `count`, `errors`, `duration_usec_total`, `max_duration_usec`.
   - Status-class counters (`requests_total`, `errors_4xx`, `errors_5xx`, `conflicts_409`, `not_implemented_501`, `slow_requests_total` > 50 ms excluding streaming routes like `logs`/`events`/`wait`/`attach`/`exec/start`).
   - Bounded 64-entry `recent_issues` ring capturing 5xx, 409 conflicts, 501 unsupported ops, non-polling 4xx (filtering out routine `GET` 404 cleanup polling), slow requests (>50 ms), and reaper failures.
   - Native guest OTLP/JSON trace ring exposed on `GET /micropod/traces` (scope `micropod.docker.api`) and `POST /micropod/traces/clear`, preserving `http.Flusher` and `http.Hijacker` on streaming/upgraded connections.
   - Dedicated Ryuk reaper telemetry: `active_sessions`, `sessions_started`, `sessions_closed`, `requests_total`, `containers_reaped`, `networks_reaped`, `volumes_reaped`, `reap_errors`, `reap_denied`, `reap_duration_usec_total`, `max_reap_duration_usec`.
2. **Host HVF VMM (Rust)** — [virtiofs.rs](../../../vmm/crates/vmm-virtio/src/virtiofs.rs), [telemetry.rs](../../../vmm/crates/vmm-core/src/telemetry.rs):
   - Six relaxed-atomic Phase B8 Virtio-FS counters (`keep_cache_hits`, `ro_cache_hits`, `ro_cache_misses`, `notify_events_pushed`, `notify_epoch_resets`, `fuse_errors` excluding expected `ENOENT`/`ENOSYS`/`ENODATA`) exported over Prometheus `/metrics`, OTLP/JSON `/v1/metrics`, and `/healthz`.
3. **Host Swift Runtime & CLI** — [CIWorkerHealth.swift](../../../Sources/MicropodRuntime/CIWorkerHealth.swift), [TelemetryCommands.swift](../../../Sources/MicropodCLI/TelemetryCommands.swift):
   - **`micropod telemetry issues [--json]`**: live human-readable & JSON issue diagnostics showing overall verdict, Docker API / Ryuk Reaper / Virtio-FS summaries, and newest-first actionable issues.
   - **`micropod telemetry health`**: auto-warns on `runtimeFailures > 0`, `api.errors5xx > 0`, `reaper.reapErrors > 0`, `hv.fsErrors > 0`, `hv.fsNotifyEpochResets > 0`, `macvlanQuarantinedPorts > 0`, and `dnsOverloadDrops > 0`.
   - **`micropod telemetry metrics --format prometheus|otlp`**: unified export covering VMM + Phase B8 Virtio-FS + Docker API + per-route counters + Ryuk Reaper + cgroup container metrics.
   - **`micropod telemetry trace enable|disable|dump [--summary]`**: merges live VMM (`micropod.vmm`) and guest Docker API (`micropod.docker.api`) OTLP/JSON spans over Unix sockets with HTTP/1.1 chunked decoding.

### Suite 4 Live Validation Output (Captured Directly After Suites 1–3)

Fault injection (`POST /containers/create?platform=linux/amd64` → `400`, duplicate container name → `409` with winning ID, `DELETE /containers/000...` → `404`) plus full run audit verified:

```text
VERDICT: HEALTHY (warnings=0, recent_issues=64)
DOCKER API: reqs=6664 4xx=250 5xx=0 409=1 501=0 slow(>50ms)=43 max=2778.4ms
RYUK REAPER: active=0 started=8 closed=8 reaped(c=36 n=1 v=1) errors=0 denied=0 max=116.1ms
VIRTIO-FS: reqs=2416 keep_cache_hits=0 ro_cache=0/3 notify_events=54 epoch_resets=0 errors=0

RECENT ISSUES (newest first):
  [error       ] docker_api  DELETE /containers/{id}           HTTP 404    0.0ms — no such container: 0000...
  [conflict    ] docker_api  POST   /containers/create         HTTP 409    0.3ms — Conflict. The container name "/mp-obs-dup-..." is already in use...
  [error       ] docker_api  POST   /containers/create         HTTP 400    0.0ms — only linux/arm64 images are supported
  [slow        ] ryuk_reaper DELETE /containers/{id}           HTTP 204   85.7ms
  ...
```

And `micropod telemetry trace dump --summary` merged both `micropod.vmm` and `micropod.docker.api` scopes and ranked slowest spans immediately:

```text
SPAN (slowest first)                    DURATION   STAT  ATTRIBUTES
docker_api.POST /containers/{id}/start  2778.35 ms OK    http.route=/containers/{id}/start http.status_code=204 ...
docker_api.POST /images/load            1337.22 ms OK    http.route=/images/load http.status_code=200 ...
docker_api.POST /containers/{id}/stop   1066.60 ms OK    http.route=/containers/{id}/stop http.status_code=204 ...
docker_api.POST /containers/{id}/start   126.90 ms OK    http.route=/containers/{id}/start http.status_code=204 ...
```

---

## 5. Issues Caught & Fixed During Benchmarking

1. **Docker API v1.47 `"starting"` Status Leak During Concurrent Ryuk Races** — [docker_engine_linux.go](../../../guest/runner/docker_engine_linux.go#L1148-L1156), [docker_http_linux.go](../../../guest/runner/docker_http_linux.go#L284-L296):
   - *Symptom*: Under 8-client simultaneous Ryuk startup, a sibling client calling `GET /containers/{id}/json` while the winner was launching observed `"Status": "starting"`, which is not a valid Docker Engine API v1.47 container state and caused `testcontainers-go` to abort with `unexpected container status "starting"`.
   - *Fix*: Added `c.dockerStatus()` mapping internal `"starting"` → `"created"` (initial start) or `"exited"` (restart), matching Moby semantics, covered by Linux unit test `TestStartingPhaseMapsToValidDockerStatus`.
2. **Upstream `testcontainers-go v0.40.0` `fromContainer` Race Under Extreme Host Saturation**:
   - *Observation*: During a contended run when an external 8-vCPU VM drove Gamma's host load average above `90`, `testcontainers-go`'s `fromContainer` (`wait.ForExposedPort().WithPollInterval(100ms)`) observed the winner's `reaper_<session>` container still in `"created"` after a single `100 ms` poll and treated `unexpected container status "created"` as a permanent non-retryable error in `reaper.go:retryError`. Live probing of OrbStack confirmed Moby/OrbStack emits identical `State.Status="created"` / `NetworkSettings.Ports={}` prior to start completion; on a non-saturated host, Micropod starts Ryuk well under 100 ms (`0` failures across 4/4 pairs).
3. **Swift JSON Snake-Case Decoder with Digit-Prefixed Keys & Chunked HTTP Trace Responses** — [CIWorkerHealth.swift](../../../Sources/MicropodRuntime/CIWorkerHealth.swift):
   - *Fix*: Replaced generic `.convertFromSnakeCase` on runtime engine metrics with `makeRuntimeMetricsDecoder()` (preserving map keys like `"GET /_ping"` and mapping `errors_4xx`/`conflicts_409`/`not_implemented_501` cleanly) and added HTTP/1.1 `Transfer-Encoding: chunked` decoding (`decodeChunkedHTTPBody`) to `queryUnixHTTP` so guest `/micropod/traces` merges cleanly with VMM `/v1/traces`.
4. **Actionable Bottleneck Surfaced by Live Tracing**:
   - Across 51 `POST /containers/{id}/start` calls (`6,096.8 ms` total), `telemetry trace dump --summary` immediately isolated a single **`2,778.35 ms`** outlier during `qualify core` while the remaining 50 starts averaged **`66.37 ms`** each (explaining the entire `2.55 s` delta on `core` vs OrbStack and giving a direct target for first-start / stopped-container rootfs-rebind tuning next).
