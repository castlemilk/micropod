# Phase B7 — Real CI Workloads, Multi-Layer Caching, Live OTLP/Prometheus Observability & On-Demand Tracing

**Date:** 2026-11-26  
**Host:** Gamma (Apple M5 Max, 18 cores, 128 GB RAM, macOS 26.5.1)  
**Artifact Under Test:** Signed `dist/Micropod.app` (`0.1.0-b7`, `codesign --verify --deep --strict` valid) + zero-config `dist/micropod` CLI  
**Raw E2E Receipt:** [phase-b7-real-ci-and-caching.json](phase-b7-real-ci-and-caching.json)  
**E2E Harness:** [run_real_ci_and_cache_suite.py](../../../scripts/run_real_ci_and_cache_suite.py)

---

## Executive Summary

Phase B7 validated Micropod's signed native Apple Silicon HVF runtime (`micropod-vmm` + `containerd v2.4.2` + `crun` + `overlayfs`) across **six end-to-end real-world CI & multi-layer caching stages**, while shipping a clean declarative observability architecture:

- **Zero metric files on disk** (`metric_files_on_disk: 0`): all hypervisor, guest kernel, guest runtime-engine, storage, cache-store, and per-container cgroup v2 metrics are exposed live over Prometheus (`GET /metrics` on `0600` `telemetry.sock` + optional TCP listener) and OpenTelemetry OTLP/HTTP (`/v1/metrics`, `/v1/traces`), configured via declarative YAML (`micropod telemetry` / `micropod config`).
- **On-demand distributed tracing with zero hot-path overhead when off**: toggled live at runtime without restarting the VM (`micropod telemetry trace enable|disable|dump|clear`), emitting bottleneck spans across Rust `micropod-vmm` and Swift CLI into a live OTLP/HTTP collector (`28` metric batches and `27` trace batches captured end-to-end).
- **Rich per-container cgroup v2 & runtime-engine visibility without `conmon`**: `guest/runner/docker_stats_linux.go` reads cgroup v2 `cpu.stat`, `memory.peak`, `memory.events`, `pids.max`, `io.stat`, per-container PSI (`cpu`/`memory`/`io`), and `/proc/<pid>/net/dev` directly alongside containerd shim supervision.
- **Multi-layer CI caching verified end-to-end**: BuildKit `--mount=type=cache` achieved a **7.91× warm speedup** (`8.030 s` cold → `1.015 s` warm, `6 CACHED` steps); scoped npm/python volumes, native OCI Go cache, and Virtio-FS incremental `make -j4` all verified; all four cache tiers survived graceful `runner-stop` / `runner-start` and inherited cleanly across **3 parallel APFS CoW warm snapshot forks** (`90.6–91.9 ms` managed `runner-start` each, `~4.15 ms` VMM restore, 100% write isolation).

---

## 1. Architecture & CLI Surface

### Declarative YAML Configuration & Clean CLI
- **Schema v1 YAML**: [observability.example.yaml](../../../config/observability.example.yaml) & [ObservabilityConfig.swift](../../../Sources/MicropodCore/ObservabilityConfig.swift) — manages `service_name`, `prometheus`, `otlp`, `tracing` (`enabled`, `endpoint`, `sample_rate`, `slow_op_threshold_ms`), and `health`, with dot-path `set`, `validate`, and atomic `save`.
- **Top-level CLI commands**: [TelemetryCommands.swift](../../../Sources/MicropodCLI/TelemetryCommands.swift) & [MicropodCLI.swift](../../../Sources/MicropodCLI/MicropodCLI.swift):
  - `micropod telemetry init|show|validate|set|enable|disable|health|metrics|trace` (with `micropod config` alias).
  - `micropod telemetry trace status|enable|disable|dump [--summary]|clear` for live runtime tracing without restarting the VM.
  - Organized `micropod ci` help sections and automatic per-worker `BUILDX_CONFIG` isolation (`$MICROPOD_CI_HOME/buildx`).
- **HTTP API endpoints**: [APIHandlers.swift](../../../Sources/MicropodAPI/APIHandlers.swift) adds `GET /v1/ci/traces`, `GET /v1/ci/tracing`, and `POST /v1/ci/tracing/enable|disable`.

### Per-Container & Guest Runtime Engine Metrics (No `conmon` Required)
Micropod's guest stack runs `containerd` + `containerd-shim-runc-v2` + `crun`, which already handles OCI lifecycle, stdio pipes, exit status, and OOM monitoring without adding a `conmon` daemon per container. [docker_stats_linux.go](../../../guest/runner/docker_stats_linux.go) and [docker_stats_parse.go](../../../guest/runner/docker_stats_parse.go) enrich `/containers/{id}/stats` directly from cgroup v2 (`cpu.stat` user/kernel/throttling, `memory.peak`, `memory.events`, `pids.max`, `io.stat` bytes + IOPS, and per-container `cpu`/`memory`/`io` PSI), while [CIWorkerHealth.swift](../../../Sources/MicropodRuntime/CIWorkerHealth.swift) combines guest `/micropod/metrics`, `/micropod/storage`, `/containers/{id}/stats`, guest `/proc` PSI/meminfo, and `micropod-vmm` `telemetry.sock` into unified Prometheus + OTLP feeds.

---

## 2. Live E2E CI & Multi-Layer Caching Results (6 Stages)

All six stages ran sequentially and in parallel against the signed zero-config `dist/micropod` binary (no `MICROPOD_HVF_VMM` or `MICROPOD_HVF_INITRD` overrides set).

| Stage / Workload | Measured Result | Verified Invariant |
|---|---|---|
| **Stage 0 — Zero-Config Signed Bundle Boot & Live Observability** | `1,352.4 ms` cold worker start (`verdict=healthy`, `260.88 MiB` host phys footprint, `metric_files_on_disk=0`) | Live TCP Prometheus scrape, unified CLI Prometheus & OTLP export, live tracing toggle `OFF -> ON -> dump --summary -> OFF` without restart |
| **Stage 0b — Base Image Load (`alpine:3.23`, `node:24-alpine`, `postgres:16-alpine`, `pause`)** | `2,046.7 ms` | All 4 images loaded into `containerd` + `overlayfs` |
| **Stage 1 — BuildKit Multi-Stage C Build (`--mount=type=cache,target=/var/cache/apk`)** | Cold **`8.030 s`** → Warm **`1.015 s`** (**7.91× speedup**, `6 CACHED` steps); 1-header partial edit **`1.020 s`** (apk cache hit); post-reboot rebuild **`2.833 s`** (`6 CACHED` steps) | Deterministic output binary verified across cold, warm, partial, and post-reboot builds |
| **Stage 1b — `micropod ci snapshot`** | Cold **`2.174 s`** → Warm **`1.028 s`** | Identical `sha256:` image ID returned on warm snapshot |
| **Stage 2 — Node 24 Tests, Scoped Volume Caches, Native OCI & Virtio-FS Incremental `make -j4`** | `node --test` PASS; Virtio-FS 17-file C project cold **`211.4 ms`** → no-op **`75.9 ms`** → host `os.replace` 1-file edit **`125.7 ms`** (only `mod_05.c` recompiled, `SUM=236`) | `npm` `scope-alpha` hit & `scope-beta` isolated; `python` `scope-py` hit; `runner-prime 4` + native OCI `job trusted` Go cache hit |
| **Stage 3 — Docker Compose (`postgres:16-alpine` + Node 24 API + Published Port)** | **`2,269.7 ms`** wall (`HTTP 200`, 2 SQL rows verified) | Live `telemetry health` surfaced both containers with full cgroup v2 stats, runtime counters, and ext4 usage (see Section 3) |
| **Stage 4 — Deliberate 32 MiB OOM Fault Injection** | `verdict=degraded`, `kernel.oomKills=1`, warning `"Guest kernel recorded 1 OOM kill(s) since boot"` | Recovered cleanly to `verdict=healthy` (`oomKills=0`) after worker restart |
| **Stage 5 — Graceful Restart Persistence** | `runner-stop` **`327.1 ms`**, `runner-start` + warm snapshot capture **`402.3 ms`** | All 4 cache layers (images, BuildKit layers, scoped npm/python volumes, native OCI Go cache) persisted across clean shutdown |
| **Stage 6 — 3× Parallel Managed APFS CoW Warm Snapshot Pool** | Managed `runner-start`: **`91.9 / 90.6 / 90.6 ms`**; total 3-way parallel wall (boot + `demo-app:v2` run + scoped write + full cached BuildKit rebuild `6 CACHED` steps each): **`3,551.0 ms`** | `verdict=healthy` on all 3 forks, `344.8–353.9 MiB` phys footprint, `clockSyncCount=1`, **100% APFS CoW cache/write isolation** |

---

## 3. Live Per-Container Cgroup v2 & Guest Runtime Snapshot (During Active Compose)

Captured live by `micropod telemetry health` during Stage 3 (`compose_active` in [phase-b7-real-ci-and-caching.json](phase-b7-real-ci-and-caching.json)):

| Container | CPU (Total / User / Kernel) | CPU Throttling | Memory (Usage / Peak / Working Set / Limit) | PIDs | Net RX / TX | Container PSI (`cpu` / `io` / `mem`) | Ports |
|---|---|---|---|---:|---:|---|---|
| `repo-compose-pg-db-1` (`postgres:16-alpine`) | `273.1 ms` (`182.1` / `91.0 ms`) | `1` period (`4.04 ms`) | `74.8 / 89.5 / 31.4 MiB` (`1 GiB` limit) | `6 / 512` | `1,682 / 856 B` | `2,610 / 6,819 / 0 µs` | `5432/tcp` |
| `repo-compose-pg-api-1` (`node:24-alpine`) | `36.2 ms` (`29.6` / `6.6 ms`) | `0` periods (`0 ms`) | `19.2 / 20.3 / 19.2 MiB` (`1 GiB` limit) | `11 / 512` | `1,123 / 1,492 B` | `679 / 14 / 0 µs` | `127.0.0.1:58075->8080/tcp` |

At the same instant, the unified health payload reported:
- **Guest Runtime Engine**: `containersCreated=11`, `runsFinished=9`, `imageCacheHits=9`, `preparedPodsUsed=2`, `sharedCacheAttachments=3`, `dnsLocalAnswers=2`, `macvlanLeases=1`, `runtimeFailures=0`.
- **Guest Storage (`ext4`)**: `33.82 GB` total, `1.61 GB` used, `32.19 GB` available.
- **Hypervisor (`micropod-vmm`)**: `vcpusOnline=4/4`, `ipaGranule=16KiB`, `wfiExits=0`, `balloonReclaimedMib=3616`, `publishedBinds=1`, `publishedConns=1`, `guestCtrlConnected=true`.

---

## 4. Measured Bottleneck Trace Spans (Live OTLP/HTTP Collector)

During the E2E run, the local OTLP/HTTP collector received **`28` `resourceMetrics` batches** and **`27` `resourceSpans` batches** across services `micropod-b7-e2e` and `micropod-b7-pool`:

| Layer | Span Name | Count | Min (ms) | Avg (ms) | Max (ms) | Bottleneck Takeaway |
|---|---|---:|---:|---:|---:|---|
| **VMM Cold Boot** | `vmm.boot.setup` | 1 | 4.625 | 4.625 | 4.625 | Sub-5 ms host VM setup (`read_images` `2.102`, `kernel_load` `1.458`, `virtio_attach` `0.214`, `ram_alloc` `0.082`) |
| **VMM Cold Boot** | `vmm.boot.to_first_uart` | 4 | 73.376 | 88.067 | 93.099 | Guest Linux kernel decompression + early init |
| **VMM Cold Boot** | `vmm.boot.to_init_ready` | 1 | 78.225 | 78.225 | 78.225 | Guest `/init` userspace handoff |
| **VMM Snapshot Save** | `vmm.snapshot.save` | 1 | 92.088 | 92.088 | 92.088 | **96.4%** in `sparse_ram_write` (`88.806 ms`); `gic_save` `2.212`, `vmstate_write` `0.856`, `cow_disk_clone` `0.075`, `virtio_pause` `0.041` |
| **VMM APFS CoW Restore** | `vmm.restore.setup` | 3 | 2.495 | 2.517 | 2.554 | `validate` `0.812`, `cow_ram_map` `0.672`, `virtio_attach` `0.225`, `cow_disk_clone` `0.110` |
| **VMM APFS CoW Restore** | `vmm.restore.gic_and_virtio` | 3 | 1.611 | 1.631 | 1.642 | Total VMM restore ≈ **`4.15 ms`** before guest resumes |
| **Swift CLI** | `ci.worker.start` | 4 | 66.528 | 145.555 | 379.434 | Fork starts `~66–92 ms`; cold restart + snapshot `~379–402 ms` |
| **Swift CLI** | `ci.worker.stop` | 4 | 107.872 | 213.309 | 318.017 | Clean guest drain + `POWEROFF` flush |
| **Swift CLI** | `telemetry.health` | 4 | 11.038 | 20.649 | 27.833 | Full multi-layer health aggregation across VMM + guest |

---

## 5. Production Issues Caught & Fixed During E2E

1. **Docker Desktop `com.docker.build` hijacking `buildkit.sock` during `runner-stop`**:
   - *Symptom*: `micropod ci runner-stop` failed with `"The CI worker received more work while draining"` after running `docker buildx build`.
   - *Root cause*: Registering a remote Buildx builder under the default `~/.docker/buildx/instances/` caused Docker Desktop's background `com.docker.build` daemon to open persistent gRPC connections to Micropod's `buildkit.sock`, holding `buildkit_linux.go`'s `/run/micropod-oci/engine.lock`.
   - *Fix*: Isolated `BUILDX_CONFIG` to `$MICROPOD_CI_HOME/buildx` inside [CICommands.swift](../../../Sources/MicropodCLI/CICommands.swift) (preserving `~/.docker/config.json` registry auth), and hardened full-close vsock teardown across all three hops ([vsock.rs](../../../vmm/crates/vmm-virtio/src/vsock.rs), [guest-init/main.go](../../../vmm/guest-init/main.go), [buildkit_linux.go](../../../guest/runner/buildkit_linux.go)) so half-closed vs fully-closed clients release leases immediately.
2. **Swift `String(format: "%-34s", swiftString)` crash in `telemetry trace dump --summary`**:
   - Replaced unsafe C `%s` format specifier with pure-Swift right-padding in [TelemetryCommands.swift](../../../Sources/MicropodCLI/TelemetryCommands.swift).

---

## 6. Verification Battery

All cross-language unit/integration suites and packaging checks passed with zero failures:

- **Rust `cargo test --workspace` (`vmm/`)**: **101 passed, 0 failed** (`23` `vmm-core`, `53` `vmm-virtio` incl. `vsock_distinguishes_half_close_from_full_close`, `16` `vmm-net`, `4` `micropod-vmm` unit, `4` `parent_pid`, `1` `vmm-fdt`; `1` hardware-entitled `simd_hardware` ignored; 0 warnings).
- **Go `vmm/guest-init` & `bench/phase0-host-scheduling/guest/runner`**: `GOOS=linux GOARCH=arm64 go vet ./...` and `go test ./...` — **PASS**.
- **Swift tests (`bench/phase0-host-scheduling`)**: **66 passed, 0 failed** (`18` `CIWorkerTests`, `16` `NativePublishedPortsTests`, `6` `SandboxVMTests`, `26` Swift Testing `HVFWorkerTests`).
- **Python & Shell checks**: `test_bench_engine_tuning_drive.py` (**19/19 passed**), `py_compile` on all scripts, `sh -n scripts/package_app.sh` — **PASS**.
- **Signed Release Bundle**: `codesign --verify --deep --strict --verbose=2 dist/Micropod.app` — **valid on disk; satisfies its Designated Requirement**.
- **Host Hygiene**: `0` leftover `mp-b7`/`mp-drain` processes.
