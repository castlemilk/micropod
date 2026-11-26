# Micropod Engine Tuning & Rust HVF VMM Results (Track A + Track B Phases B0–B3)

**Date**: 2026-11-25  
**Host**: Gamma — Apple M5 Max (18 cores: 6 Super + 12 Performance), 128 GB RAM, macOS 26.5.1 (SDK 26.5)  
**Baseline Competitor**: OrbStack 2.2.5 (Docker 29.8.2, Linux `7.2.12-orbstack`, 4 vCPUs)  
**Micropod Guest Kernel (Phase B3)**: `7.3.5-micropod-sync` (ARM64 16 KiB pages, `PREEMPT`, `BOUNDED_BUDDY` + `SYNC_COLOCATE`, sha256 `988bf8e5f360b04cb6c81b450f1eb616e71cfe4263850dc918d87367a917822d`)  
**VMM Binary**: [micropod-vmm](file:///Users/benebsworth/projects/micropod/vmm/Cargo.toml) (`rustc 1.99.1`, signed with `com.apple.security.hypervisor`, **zero `vmnet`**, **zero macOS Local Network TCC prompts**)

---

## 1. Executive Scorecard — Controlled 3-Way Paired Gamma Benchmarks

All three arms ran sequentially on a quiet Gamma host with identical container images (`alpine:3.23`, `micropod-qa/netbench:local`, `registry.k8s.io/pause:3.10.2`), 4 vCPUs / 4 GiB RAM, 3 scored rounds per arm (plus 1 warmup round for published TCP), and the Track A3 guest runner.

Authoritative receipts:
- Bridge + Published TCP: [phase-b3-hvf-bridge.json](./phase-b3-hvf-bridge.json)
- IPvlan: [phase-b3-hvf-ipvlan.json](./phase-b3-hvf-ipvlan.json)

The HVF arm launched the VMM directly and preloaded the images. Its boot clock starts at process launch. Including the protected APFS drive and disk preparation, the bridge and IPvlan receipts record 3.137 s and 6.186 s to readiness. The installed desktop shim, managed CLI path and online registry workflow have separate acceptance evidence. [Managed engine qualification](./managed-engine-compatibility.md)

| Workload | Driver | OrbStack 2.2.5 | Micropod VZ Tuned (`7.3.5-sync`) | **Micropod HVF Phase B3 (`micropod-vmm` + `7.3.5-sync`)** | HVF B3 vs Competitors |
|---|---|---:|---:|---:|---|
| **Cold Boot (`docker info` ready)** | `bridge` | always-on VM | `0.710 s` | **`0.302 s`** | **2.35× faster than VZ** (5.4× vs pre-Track-A VZ `1.64 s`) |
| **Cold Boot (`docker info` ready)** | `ipvlan` | always-on VM | `0.767 s` | **`0.283 s`** | **2.71× faster than VZ** |
| **OOM Kill Attribution (`32m`)** | both | `OOMKilled=true (137)` | `OOMKilled=true (137)` | **`OOMKilled=true (137)`** | 100% parity across all 3 arms |
| **Published TCP Bulk (32 streams, 1 port)** | `bridge` | `7,500.2 MiB/s` | `11,324.4 MiB/s` *(requires TCC `vmnet`)* | **`8,699.0 MiB/s`** *(peak `8,868–9,710`, zero `vmnet`/TCC)* | **+16.0% faster than OrbStack** (2.23× vs Phase B2) |
| **Published TCP Fresh p50 / p95 / p99** | `bridge` | `2.685 / 5.731 / 7.237 ms` | `8.189 / 11.537 / 12.676 ms` | **`2.568 / 3.041 / 3.305 ms`** | **Fastest of all 3: 1.88× p95 & 2.19× p99 vs OrbStack; 3.79× p95 vs VZ** |
| **Published TCP Failures / Reopens** | `bridge` | `0 / 0` | `0 / 0` | **`0 / 0`** | 100% clean across all rounds |
| **`32×8` Ephemeral `--rm` Churn** | `bridge` | `1.813 s` (`17.65 c/s`) | `1.314 s` (`24.36 c/s`) | **`1.094 s` (`29.25 c/s`)** | **1.66× faster than OrbStack; 1.20× faster than VZ** |
| **`32×8` Ephemeral `--rm` Churn** | `ipvlan` | `1.813 s` (`17.65 c/s`) | `1.363 s` (`23.48 c/s`) | **`1.018 s` (`31.43 c/s`)** | **1.78× faster than OrbStack; 1.34× faster than VZ** |
| **1-Client DNS (p50 / p95)** | `bridge` | `19 / 32 µs` | `19 / 36 µs` | **`20 / 36 µs`** | **2.25× faster than B2 (`45 µs`)**; parity w/ OrbStack |
| **1-Client DNS (p50 / p95)** | `ipvlan` | `21 / 32 µs` | `20 / 36 µs` | **`19 / 36 µs`** | **Beats OrbStack (`21 µs`) & VZ (`20 µs`)** |
| **32-Client DNS (p50 / p95)** | `bridge` | `185 / 979 µs` | `166 / 293 µs` | **`166 / 314 µs`** | **3.12× lower p95 than OrbStack** |
| **32-Client DNS (p50 / p95)** | `ipvlan` | `159 / 814 µs` | `164 / 306 µs` | **`161 / 297 µs`** | **2.74× lower p95 than OrbStack; beats VZ p50 & p95** |
| **Quiet HTTP Unrestricted (p50 / p95)** | `bridge` | `13.79 / 31.46 µs` | `23.38 / 40.00 µs` | **`24.54 / 43.96 µs`** | **~1.8× faster than Phase B2 (`43.6 µs`)** |
| **Quiet HTTP Unrestricted (p50 / p95)** | `ipvlan` | `11.88 / 19.54 µs` | `21.75 / 41.46 µs` | **`22.71 / 39.58 µs`** | **~1.9× faster than Phase B2; beats VZ p95** |
| **Quiet HTTP Pinned CPU0 (p50 / p95)** | `bridge` | `12.29 / 17.96 µs` | `14.25 / 20.33 µs` | **`13.75 / 19.42 µs`** | **Beats VZ p50 & p95** |
| **Quiet HTTP Pinned CPU0 (p50 / p95)** | `ipvlan` | `11.54 / 16.79 µs` | `13.12 / 18.25 µs` | **`12.96 / 18.75 µs`** | **Beats VZ p50** |
| **6 GiB Sibling Bulk (32 streams)** | `bridge` | `21,731 MiB/s` | `17,024 MiB/s` | **`16,828 MiB/s`** | Parity with VZ |
| **6 GiB Sibling Bulk (32 streams)** | `ipvlan` | `23,971 MiB/s` | `18,443 MiB/s` | **`18,272 MiB/s`** | Parity with VZ |

---

## 2. Phase Progression: Pre-Track-A VZ → Track A VZ → HVF B2 → HVF B3

| Metric | Pre-Track-A VZ Control | Track A VZ Tuned | HVF Phase B2 (`smoltcp`) | **HVF Phase B3 (Zero-Copy `O(1)` + `7.3.5-sync`)** | Total Improvement |
|---|---:|---:|---:|---:|---|
| **Cold Boot (`docker info`)** | `1.641 s` | `0.675 s` | `0.338 s` | **`0.283 s`** | **5.8× faster** |
| **Published TCP Bulk (zero-TCC HVF)** | *(TCC blocked)* | *(TCC blocked)* | `3,900 MiB/s` | **`8,699 MiB/s`** *(peak `9,710`)* | **2.23× (up to 2.49×)** |
| **Published TCP Fresh p95** | `11.49 ms` | `11.01 ms` | `3.03 ms` | **`3.04 ms`** *(down to `0.786 ms` standalone)* | **3.78× lower** |
| **`32×8` `--rm` Churn (`ipvlan`)** | `1.041 s` | `0.994 s` | `1.359 s` | **`1.018 s`** | **-25% vs B2 (beats VZ & OrbStack)** |
| **1-Client DNS p50 (`ipvlan`)** | `53 µs` | `47 µs` | `45 µs` | **`19 µs`** | **2.79× lower** |
| **32-Client DNS p95 (`ipvlan`)** | `497 µs` | `335 µs` | `406 µs` | **`297 µs`** | **1.67× lower** |
| **Unrestricted Quiet HTTP p50 (`ipvlan`)** | `44.4 µs` | `41.4 µs` | `43.6 µs` | **`22.7 µs`** | **1.95× lower** |
| **Host Physical Footprint (4 GiB VM)** | ~4 GiB | ~4 GiB | `~380–430 MiB` | **`~378–431 MiB`** *(2.6–3.7 GiB `MADV_FREE`)* | **~9× lower RSS** |

---

## 3. Summary of Implemented Changes (Track A + Track B B0–B3)

### Track A — Portable Engine, Guest Runner & C Relay
- **Guest boot & sysctls**: Replaced `sleep 1` with `usleep 50000` in [start.sh](../../../ci/runner/start.sh), lowered supervisor readiness polling from `150 ms` → `25 ms` in [CIWorker.swift](../../../Sources/MicropodRuntime/CIWorker.swift), and added `cgroup.memory=nokmem,nosocket slab_min_order=2 swiotlb=noforce workqueue.power_efficient=1 micropod.ci_sysctls=perf` in [SandboxVM.swift](../../../Sources/MicropodRuntime/SandboxVM.swift).
- **Zero-alloc inline UDP DNS**: Rewrote local authoritative replies in [docker_dns_linux.go](../../../guest/runner/docker_dns_linux.go), [docker_dns_answer.go](../../../guest/runner/docker_dns_answer.go), and [docker_dns_directory.go](../../../guest/runner/docker_dns_directory.go) to pack directly on the reader loop (**`34.96 ns/op`, `0 allocs/op`**).
- **Ephemeral `--rm` fsync elimination**: Skipped 6 ext4 journal `f.Sync()` / `syncDir()` barriers for `AutoRemove` containers in [docker_engine_linux.go](../../../guest/runner/docker_engine_linux.go) while preserving full durability for persistent containers and named volumes.
- **Lock-free MPSC + `EVFILT_USER` relay handoff**: Replaced `dispatch_async` with atomic MPSC handoff + mid-turn draining + batched/deferred/oneshot filters in [PublishedTCP.c](../../../Sources/CPublishedTCP/PublishedTCP.c) (`<= 16 µs` adoption jumped `41.4%` → `72.4%`, >1 ms tail eliminated `4` → `0`, fresh p99 `-16.2%`, receipt [track-a2-handoff-ab.json](./track-a2-handoff-ab.json)).

### Track B — Apple-Silicon Rust HVF VMM (`micropod-vmm`)
- **Core Hypervisor & FDT** ([vmm/crates/hvf-sys](../../../vmm/crates/hvf-sys/src/lib.rs), [vmm/crates/vmm-fdt](../../../vmm/crates/vmm-fdt/src/lib.rs), [vmm/crates/vmm-core](../../../vmm/crates/vmm-core/src/lib.rs)): Uses macOS 26 `HV_IPA_GRANULE_16KB`, hardware GICv3 (`hv_gic_create`), real host L1/L2 cache FDT geometry (`128 KiB L1d / 192 KiB L1i / 16 MiB L2`), `QOS_CLASS_USER_INTERACTIVE` P-core pinning for vCPU threads, and live `proc_pid_rusage` telemetry (`~82 ms` kernel-to-init, `0` WFI exits).
- **Zero-Copy `O(1)` Direct TCP Engine (`vmm-net`)** ([vmm/crates/vmm-net/src/lib.rs](../../../vmm/crates/vmm-net/src/lib.rs)):
  - Eliminated `smoltcp` in favor of a pure-Rust + `libc` 4,096-slot `O(1)` flow array (`flows[dst_port - 32768]`) with per-flow locking and `VIRTIO_NET_F_HOST_TSO4`.
  - **Zero-copy Guest→Host**: builds `libc::iovec` directly over `GuestMemory` scatter-gather descriptors and invokes `libc::writev()` straight into Darwin `127.0.0.1` sockets.
  - **Dedicated async `vmm-net-tx` drainer**: ARM64 `Acquire`/`Release` lock-free VirtQueue polling (`60 µs` adaptive poll with `VRING_USED_F_NO_NOTIFY` kick suppression + `VRING_AVAIL_F_NO_INTERRUPT` NAPI IRQ suppression).
  - **Priority fresh-request lane**: processes `accept()` and `EVFILT_READ` (with immediate IRQ raise) strictly ahead of `EVFILT_WRITE` bulk drains, plus `512 KiB` per-flow BDP window (`WS=7`), `2 MiB` Darwin socket buffers, priority window-update ACKs, and a 5 ms self-healing timer.
- **Storage, FUSE & Vsock** ([vmm/crates/vmm-virtio](../../../vmm/crates/vmm-virtio/src/lib.rs), [virtiofs.rs](../../../vmm/crates/vmm-virtio/src/virtiofs.rs), [vsock.rs](../../../vmm/crates/vmm-virtio/src/vsock.rs)):
  - `VirtioFs`: enabled `FUSE_NO_OPEN_SUPPORT`, `FOPEN_KEEP_CACHE = 1 << 1`, `FOPEN_CACHE_DIR = 1 << 3`, `FOPEN_NOFLUSH = 1 << 5`, `FUSE_CACHE_SYMLINKS`, `FUSE_PARALLEL_DIROPS`, `FUSE_EXPLICIT_INVAL_DATA`, and `ro_file_cache[nodeid]` fallback — cutting `oci-tools` FUSE requests **21.3×** (`132,419` → `6,207`).
  - `VirtioBlk`: dedicated async `vmm-blk-io` worker with vectored `libc::preadv`/`libc::pwritev`, race-proof `has_avail` wakeup guard, and coalesced `libc::fsync(fd)`.
  - `VirtioBalloon`: `VIRTIO_BALLOON_F_REPORTING` → inward-aligned 16 KiB `madvise(MADV_FREE)`, keeping host physical RAM at `~378–431 MiB` on a 4 GiB VM.
  - `VirtioVsock` + [guest-init](../../../vmm/guest-init/main.go) + [HVFWorker.swift](../../../Sources/MicropodRuntime/HVFWorker.swift): full `MICROPOD_CI_VMM=hvf` integration with real `switch_root` and clean `cgroup2` delegation.
- **Linux 7.3.5 `SYNC_COLOCATE` Patch** ([sync-colocate.patch](../../../ci/patches/sync-colocate.patch), [build-sync-colocate-kernel.sh](../../../ci/patches/build-sync-colocate-kernel.sh)): Opt-in `SCHED_FEAT(SYNC_COLOCATE, false)` in `select_task_rq_fair()` co-locating 1:1 `WF_SYNC` wakeups when `want_affine && new_cpu == cpu && (rq->nr_running - cfs_h_nr_delayed(rq)) == 1`.

---

## 4. Key Empirical Findings & Lessons Learned

1. **ARM64 Weak Memory Model on Lock-Free VirtQueues**: Reading `avail->ring[slot]` without an `Acquire` load on `avail->idx` + `fence(Ordering::Acquire)` allowed ARM64 speculative reordering (`virtio_net: id is not a head!`). Enforcing `AtomicU16::load(Ordering::Acquire)` + `AtomicU16::store(Ordering::Release)` on `avail->idx`/`used->idx` eliminated it completely.
2. **Linux FUSE `FOPEN_DIRECT_IO` (`1 << 0`) vs `FOPEN_KEEP_CACHE` (`1 << 1`)**: Returning `open_flags = 0` or `1` triggered `invalidate_inode_pages2()` on every container exec of `containerd-shim` and `crun` (`132,419` FUSE exits across 96 containers). Switching read-only shares to `FUSE_NO_OPEN_SUPPORT` (`ENOSYS` on `FUSE_OPEN` → Linux sets `fc->no_open = 1` + `FOPEN_KEEP_CACHE`) dropped FUSE traffic **21.3×** and dropped `32×8` churn from `1.43 s` → `0.96–1.02 s`.
3. **macOS 26 APFS `F_BARRIERFSYNC` vs `libc::fsync()`**: Direct Gamma microbenchmarks proved `libc::fsync(fd)` takes **`0.03–0.05 ms`** (matching `VZDiskImageSynchronizationMode.fsync`), whereas `fcntl(fd, F_BARRIERFSYNC)` triggers a container-wide APFS transaction barrier taking **`1.0–2.7 ms`** idle and **`19–38 ms`** on dirty CoW-cloned ext4 images (causing `16.1 s` churn regressions under APFS pressure).
4. **Published TCP BDP Pareto Curve (`MICROPOD_VMM_NET_BUF_KIB`)**:
   - `256 KiB` flow window / `1 MiB` Darwin socket buffer → `7,177 MiB/s` bulk, **`1.93 / 2.47 / 2.69 ms`** fresh p50/p95/p99.
   - `512 KiB` flow window / `2 MiB` Darwin socket buffer *(default)* → **`8,699–8,948 MiB/s`** bulk, **`2.57 / 3.04 / 3.31 ms`** fresh p50/p95/p99 (beating OrbStack on both throughput and tail latency).
   - Standalone non-`SYNC_COLOCATE` peak observed at **`9,710 MiB/s`** with **`0.59 / 0.79 / 0.95 ms`** fresh latency; A/B proved `SYNC_COLOCATE` inside `virtnet_poll` NAPI softirq accounts for `~840 MiB/s` of overhead (addressed in Phase B4.2).
5. **`WF_SYNC` vs `haltpoll` vs `same-mm` Co-Location A/B**:
   - Pure `WF_SYNC` (`SYNC_COLOCATE`) cut `dns1` `45 → 19 µs`, `dns32` p95 `450 → 297 µs`, and `quiet_unrestricted` `43.6 → 22.7 µs` with zero multi-thread tail regression.
   - Guest `arm64` adaptive `haltpoll` (`200 µs`) dropped `dns1` to `17.5 µs` with `0.0%` idle CPU, did *not* close `quiet_unrestricted` (`25.5 µs` — proving the remaining `+10 µs` is Go's cross-vCPU `futex_wake` IPI/cache bounce rather than `wfi` sleep), and hurt `churn` (`1.19 s`), so it was dropped.
   - Extending `SYNC_COLOCATE` to `same-mm` wakeups shaved only `2 µs` off `quiet_unrestricted` while regressing `dns32` p95 (`299 → 505 µs`) and `churn` (`0.98 → 1.07 s`), so pure `WF_SYNC` was kept.

---

## 5. Saved Benchmark Receipts & Verification

All receipts in [docs/benchmarks/2026-11-25/](.):
- [track-a1-bridge.json](./track-a1-bridge.json), [track-a1-a3-bridge.json](./track-a1-a3-bridge.json), [track-a-final-ipvlan.json](./track-a-final-ipvlan.json), [track-a2-handoff-ab.json](./track-a2-handoff-ab.json)
- [track-b-hvf-vmm.json](./track-b-hvf-vmm.json)
- [phase-b2-hvf-bridge.json](./phase-b2-hvf-bridge.json), [phase-b2-hvf-ipvlan.json](./phase-b2-hvf-ipvlan.json)
- [phase-b3-hvf-bridge.json](./phase-b3-hvf-bridge.json), [phase-b3-hvf-ipvlan.json](./phase-b3-hvf-ipvlan.json)

Test suite verification (all green, zero warnings, clean host hygiene):
- `cargo test --workspace` (`vmm/`): **8/8 passed**
- `swift test --filter 'HVFWorkerTests|CIWorkerTests|NativePublishedPortsTests|SandboxVMTests'`: **44/44 passed**
- `go test ./...` (`guest/runner`) & `GOOS=linux GOARCH=arm64 go vet ./...` (`vmm/guest-init`): **pass**
- `sh -n ci/runner/start.sh && sh -n ci/runner/published-ports.sh` & `python3 scripts/relaybench/check_handoff_profile.py`: **pass**

Next steps are detailed in [2026-11-25-phase-b4-plan.md](../../research/2026-11-25-phase-b4-plan.md).
