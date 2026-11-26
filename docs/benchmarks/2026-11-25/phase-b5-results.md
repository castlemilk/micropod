# Micropod Rust HVF VMM (`micropod-vmm`) — Phase B5 Controlled Gamma Results

**Date:** 2026-11-25  
**Host:** Gamma (Apple M5 Max, 18 cores: 6 Super + 12 Performance, 128 GB RAM, macOS 26.5.1, SDK 26.5)  
**Guest Kernel:** `7.3.5-micropod-b5` (16 KiB ARM64 pages, `BOUNDED_BUDDY`, reciprocal `SYNC_COLOCATE`, `TCP_CONG_CUBIC` + `fq`, and bounded guest `idle_poll_us` in `kernel/sched/idle.c`; sha256 `5eb46b31203fe4b4d53782f4ba7b216274ad5cd63424df711fc96fd36577e52b`)  
**Competitors:** OrbStack 2.2.5 (Docker 29.8.2, 4 vCPUs) & Micropod VZ Tuned (Apple `Virtualization.framework`, 4 vCPUs, 4 GiB, same `7.3.5-micropod-b5` kernel)  
**Receipts:**
- Bridge 3-way: [phase-b5-hvf-bridge.json](./phase-b5-hvf-bridge.json)
- IPvlan 3-way: [phase-b5-hvf-ipvlan.json](./phase-b5-hvf-ipvlan.json)
- Workspace CI 3-way: [phase-b5-workspace-ci.json](./phase-b5-workspace-ci.json)
- HVF VM Snapshot & APFS CoW Fork: [phase-b5-snapshot-fork.json](./phase-b5-snapshot-fork.json)

---

## Executive Summary

Phase B5 delivered three major systems-level upgrades on top of Phase B4 while preserving 100% of zero-`vmnet`/zero-TCC isolation, `OOMKilled=true (137)`, `0` published-TCP errors/reopens, and 4/4 POSIX host-edit visibility:

1. **Sub-12 ms HVF VM Snapshot & APFS CoW Fork (`vmm-core/src/snapshot.rs`, `hvf-sys`, `vmm-virtio`, `vmm-net`, `micropod-vmm`)**:
   - Captures complete Apple Silicon HVF state (`hv_gic_state_create`/`hv_gic_set_state`, per-vCPU GPRs + SIMD `Q0..Q31` via Clang AAPCS64 shim + EL1/EL0 sysregs + writable GICv3 ICC regs + rebased `CNTVCT_EL0` vtimer offsets, PL011 UART, all Virtio-MMIO v2 queue rings & relative `VirtioFs` node tables).
   - Uses Darwin `mincore(2)` (excluding `MINCORE_ANONYMOUS`) to write only touched non-zero 16 KiB pages (`258.9 MiB` sparse out of `4,096 MiB` in `166.3 ms`), APFS `clonefile(2)` for instant writable disk forks, and `mmap(MAP_PRIVATE)` + `hv_vm_map` for zero-copy CoW DRAM sharing across forks.
   - **Serial fork (5 rounds)**: **`10.68 ms` median** (`10.07–11.53 ms` min–max, **0 timeouts**) from `micropod-vmm --restore-from` spawn to live Docker `/_ping` `200 OK` (**31× faster** than cold HVF boot, **63–94× faster** than Apple VZ), **`126.1 ms`** to first `docker run --rm alpine:3.23`, and **`124.7 MiB`** host RSS per 4 GiB worker.
   - **5-way concurrent APFS CoW fan-out**: all **5 independent 4-vCPU / 4-GiB Docker CI workers** forked and each executed an Alpine container in **`184.7 ms` total wall time** (`11.12 ms` median to Docker `/_ping`, `125.7 MiB` median RSS, 5/5 isolated CoW containerd/ext4 states verified).

2. **`VirtioFs` `dirfd`/`*at` + Darwin `getattrlistbulk(2)` + `ENOSYS` Fast-Disable (`vmm/crates/vmm-virtio/src/virtiofs.rs`)**:
   - Replaced full-path APFS walks on `FUSE_LOOKUP`/`GETATTR`/`OPEN`/`CREATE`/`MKDIR`/`UNLINK`/`RMDIR`/`RENAME`/`SYMLINK`/`READLINK` with a cached `O_DIRECTORY` `dirfd` table and `*at` syscalls.
   - Replaced N× `lstat` in `FUSE_READDIRPLUS` with single-syscall Darwin `getattrlistbulk(2)` evaluated live on `offset == 0` (preserving live post-rename `DT_LNK` & inode-identity detection).
   - Returned `-ENOSYS` on `FUSE_GETXATTR`/`FUSE_LISTXATTR`/`FUSE_FLUSH`/`FUSE_ACCESS` so Linux FUSE sets `no_getxattr`, `no_flush`, and `no_access` on the first op, eliminating thousands of redundant round-trips during `tar -xf` and workspace scans.
   - Fixed lock-free polling in `run_fs_io_loop` (atomic `paused` check, queue check before mutex lock, `150 µs` adaptive spin) and tuned mutable `cache_validity` to `20 ms`.
   - **Result vs Phase B4**: 1,000-file `stat` cut **1.5–2.0×** (`8.0–10.6 ms` → **`4.81–5.26 ms`**), 1,000-file `read` cut **1.8–2.1×** (`99.6–104.9 ms` → **`48.2–57.3 ms`**), 1,000-file `tar -xf` cut **-35.3%** (`340 ms` → **`220 ms`**), `rm -rf` cut **-16.7%** (`60 ms` → **`50 ms`**), sequential bind-mount I/O held at **`3,200 / 6,400 MiB/s`**, and **4/4 POSIX host-edit visibility** remained 100% passing in `1.5–24.2 ms` (vs OrbStack `replace` FAIL / `78–96 ms`, VZ `held`+`replace` FAIL / `1,004 ms`).

3. **Bounded Adaptive Guest Idle Poll (`idle-poll-bounded.patch` on `7.3.5-micropod-b5`)**:
   - Added runtime-tunable `core_param(idle_poll_us, ...)` in `kernel/sched/idle.c`: polls for up to `N µs` immediately after a task yields to idle before falling back to hardware `WFI` (and never re-polls on idle timer ticks).
   - Parameter sweep (`0 / 80 / 150 / 250 / 400 µs`) identified **`idle_poll_us=150`** as the optimum: only **`0.5%` idle host CPU**, while cutting unrestricted quiet HTTP p50 by **-34.8%** (`40.92 → 26.67 µs`) and p95 by **-59.9%** (`97.35 → 39.06 µs`), 1-client DNS p95 by **-58%** (`78 → 33 µs`), 32-client DNS p95 by **-30%** (`544 → 380.5 µs`), and raising 6 GiB bridge sibling bulk by **+24.3%** (`19,765 → 24,572 MiB/s`).

---

## 1. HVF VM Snapshot & APFS CoW Fork Scorecard (`phase-b5-snapshot-fork.json`)

| Metric (4 vCPUs, 4 GiB RAM, `7.3.5-micropod-b5`, `idle_poll_us=150`) | Cold Boot (Apple VZ) | Cold Boot (`micropod-vmm` HVF) | **HVF APFS CoW Fork (Serial, 5 rounds)** | **HVF APFS CoW Fork (5× Parallel Fan-Out)** |
|---|---:|---:|---:|---:|
| **Spawn → Docker `/_ping` `200 OK`** | `667.6 – 999.9 ms` | `269.1 – 328.1 ms` | **`10.68 ms` median** (`10.07–11.53 ms`) | **`11.12 ms` median** (`10.04–13.38 ms`) |
| **Spawn → First Container (`docker run --rm alpine:3.23`)** | — | — | **`126.14 ms` median** (`119.1 ms` min) | **`172.41 ms` median** (**`184.70 ms` total wall for all 5 forks**) |
| **Host RSS Footprint / Worker** | — | `~335 MiB` (source) | **`124.70 MiB` median** | **`125.67 MiB` median** |
| **Snapshot Save (`ram.bin` sparse + `disk.ext4` CoW + `vmstate.bin`)** | — | — | `166.3 ms` VMM / `178.3 ms` wall (`258.9 MiB` sparse / `4,096 MiB`, `133.8 KiB` `vmstate.bin`) | — |
| **Independent CoW Disk & Container Isolation** | — | — | Verified | **5/5 simultaneous isolated states verified (`true`)** |

---

## 2. Controlled 3-Way Network, Scheduling & Churn Scorecard (Bridge & IPvlan)

All three engines run sequentially on quiet Gamma (3 rounds/arm, identical images, `0` published TCP errors, `0` reopens, `OOMKilled=true` exit `137`).

| Workload | Driver | OrbStack 2.2.5 | Micropod VZ Tuned (`7.3.5-b5`) | **Micropod HVF Phase B5 (`7.3.5-b5`, `idle_poll_us=150`)** | HVF Position |
|---|---|---:|---:|---:|---|
| **Cold Boot (`docker info` ready)** | bridge / ipvlan | N/A | `0.695 / 0.680 s` | **`0.271 / 0.272 s`** | **2.5× faster than VZ** (and **`10.7 ms`** via CoW fork) |
| **Published TCP Bulk (32 streams, 1 port)** | bridge | `7,559.0 MiB/s` | `11,322.9 MiB/s` *(TCC `vmnet`)* | **`11,419.8 MiB/s`** *(zero `vmnet`/TCC)* | **#1 overall (+51.1% vs OrbStack, beats VZ)** |
| **Published TCP Fresh p50 / p95 / p99** | bridge | `2.73 / 5.49 / 8.01 ms` | `8.38 / 11.51 / 12.92 ms` | **`3.17 / 4.09 / 5.96 ms`** | **#1 p95/p99 (2.8× faster p95 vs VZ, -25.5% vs OrbStack)** |
| **Published TCP Bulk (32 streams, 1 port)** | ipvlan | `7,513.6 MiB/s` | `9,496.3 MiB/s` | **`9,764.4 MiB/s`** | **#1 overall (+30.0% vs OrbStack, +2.8% vs VZ)** |
| **Published TCP Fresh p50 / p95 / p99** | ipvlan | `2.81 / 6.03 / 7.30 ms` | `8.00 / 11.99 / 13.30 ms` | **`3.76 / 6.12 / 7.66 ms`** | **2.0× faster p95 vs VZ; parity w/ OrbStack** |
| **6 GiB Sibling Bulk (32 streams)** | bridge | `22,308.5 MiB/s` | `23,498.3 MiB/s` | **`24,200.5 MiB/s`** | **#1 overall (+8.5% vs OrbStack, +3.0% vs VZ)** |
| **6 GiB Sibling Bulk (32 streams)** | ipvlan | `21,376.1 MiB/s` | `23,847.6 MiB/s` | **`25,989.4 MiB/s`** | **#1 overall (+21.6% vs OrbStack, +9.0% vs VZ)** |
| **32×8 `--rm` Ephemeral Churn** | bridge | `1.795 s` (`17.83/s`) | `1.371 s` (`23.33/s`) | **`1.111 s` (`28.81/s`)** | **#1 overall (38.1% faster than OrbStack, 19.0% vs VZ)** |
| **32×8 `--rm` Ephemeral Churn** | ipvlan | `1.793 s` (`17.85/s`) | `1.128 s` (`28.37/s`) | **`1.148 s` (`27.88/s`)** | **36.0% faster than OrbStack** |
| **1-Client DNS (`p50 / p95`)** | bridge | `21 / 32 µs` | `24 / 36 µs` | **`22 / 35 µs`** | **Beats VZ; parity w/ OrbStack** |
| **1-Client DNS (`p50 / p95`)** | ipvlan | `22 / 39 µs` | `24 / 34 µs` | **`22 / 34 µs`** | **#1 overall (beats OrbStack p95 & VZ p50)** |
| **32-Client DNS (`p50 / p95`)** | bridge | `151 / 641 µs` | `136 / 406 µs` | **`140 / 348 µs`** | **#1 p95 (-45.7% vs OrbStack, -14.3% vs VZ)** |
| **32-Client DNS (`p50 / p95`)** | ipvlan | `189 / 912 µs` | `129 / 356 µs` | **`139 / 409 µs`** | **-55.2% p95 vs OrbStack** |
| **Quiet HTTP Unrestricted (`p50 / p95`)** | bridge | `13.00 / 18.58 µs` | `26.79 / 40.38 µs` | **`27.04 / 40.08 µs`** | **-34% p50 / -59% p95 vs `idle_poll_us=0`; beats VZ p95** |
| **Quiet HTTP Unrestricted (`p50 / p95`)** | ipvlan | `11.75 / 19.21 µs` | `28.71 / 40.29 µs` | **`25.92 / 37.92 µs`** | **Beats VZ Tuned by ~10%** |
| **Quiet HTTP Pinned CPU0 (`p50 / p95`)** | ipvlan | `11.63 / 16.50 µs` | `13.29 / 19.58 µs` | **`12.96 / 18.25 µs`** | **Beats VZ Tuned** |
| **OOM Kill Attribution (`32m`)** | both | `137 / true` | `137 / true` | **`137 / true`** | 100% parity |

---

## 3. Controlled 3-Way Workspace & Host-Share CI Scorecard (`phase-b5-workspace-ci.json`)

| Workload (3 rounds/arm, RW bind-mount `/mpw`) | OrbStack 2.2.5 | Micropod VZ Tuned (`7.3.5-b5`) | Micropod HVF Phase B4 | **Micropod HVF Phase B5** | HVF B5 vs B4 / VZ |
|---|---:|---:|---:|---:|---|
| **Cold Boot** | N/A | `0.682 s` | `0.276 s` | **`0.278 s`** | **2.45× faster than VZ** |
| **1,000-File `WalkDir` Stat (pass 1 / 2 / 3)** | `3.87 / 2.75 / 3.31 ms` | `7.86 / 8.00 / 9.05 ms` | `7.99 / 8.78 / 10.61 ms` | **`5.26 / 4.81 / 5.19 ms`** | **1.5×–2.0× faster vs B4; 1.5×–1.7× faster vs VZ** |
| **1,000-File Read + SHA-256 (pass 1 / 2 / 3)** | `13.21 / 12.32 / 12.04 ms` | `86.35 / 86.71 / 88.14 ms` | `104.89 / 100.29 / 99.61 ms` | **`57.34 / 48.23 / 55.90 ms`** | **1.8×–2.1× faster vs B4; 1.5×–1.8× faster vs VZ** |
| **1,000-File `tar -xf` Extract** | `80.0 ms` | `310.0 ms` | `340.0 ms` | **`220.0 ms`** | **-35.3% vs B4; -29.0% vs VZ** |
| **1,000-File `rm -rf` Delete** | `30.0 ms` | `70.0 ms` | `60.0 ms` | **`50.0 ms`** | **-16.7% vs B4; -28.6% vs VZ** |
| **Seq 64 MiB Write / Read (`dd bs=256k`)** | `3,200 / 6,400 MiB/s` | `2,133 / 6,400 MiB/s` | `3,200 / 6,400 MiB/s` | **`3,200 / 6,400 MiB/s`** | **Tied #1 overall (1.5× write vs VZ)** |
| **Published TCP Upload (64 MiB SHA-256)** | `1,806.3 MiB/s` | `2,274.7 MiB/s` | `2,174.3 MiB/s` | **`1,855.6 MiB/s`** | **Beats OrbStack** |
| **Host Edit: `size` (append)** | `OK (5.2 ms)` | `OK (1,003.6 ms)` | `OK (12.4 ms)` | **`OK (24.1 ms)`** | **42× faster than VZ** |
| **Host Edit: `held` (same-size overwrite)** | `OK (78.3 ms)` | `FAIL (timeout)` | `OK (11.2 ms)` | **`OK (24.2 ms)`** | **3.2× faster than OrbStack; VZ fails** |
| **Host Edit: `replace` (atomic rename)** | `FAIL (old-handle-changed)` | `FAIL (old-handle-changed)` | `OK (2.7 ms)` | **`OK (1.47 ms)`** | **ONLY engine preserving POSIX open-fd identity** |
| **Host Edit: `unlink` (host delete)** | `OK (96.4 ms)` | `OK (1,004.0 ms)` | `OK (12.4 ms)` | **`OK (21.6 ms)`** | **4.5× faster than OrbStack; 46× faster than VZ** |

---

## 4. `idle_poll_us` Sweep Attribution (`7.3.5-micropod-b5`, Bridge)

| `idle_poll_us` | Idle Host `%CPU` | Quiet HTTP Unr. p50 / p95 | DNS-1c p50 / p95 | DNS-32c p50 / p95 | 6 GiB Sibling Bulk |
|---:|---:|---:|---:|---:|---:|
| `0 µs` (stock WFI) | `0.0%` | `40.92 / 97.35 µs` | `27.5 / 78.0 µs` | `172.5 / 544.0 µs` | `19,764.5 MiB/s` |
| `80 µs` | `0.2%` | `33.12 / 58.96 µs` | `24.0 / 48.0 µs` | `157.5 / 429.0 µs` | `21,448.5 MiB/s` |
| **`150 µs` (selected)** | **`0.5%`** | **`26.67 / 39.06 µs`** | **`19.5 / 33.0 µs`** | **`132.5 / 380.5 µs`** | **`24,572.3 MiB/s`** |
| `250 µs` | `0.6%` | `27.79 / 41.71 µs` | `22.5 / 34.5 µs` | `118.5 / 383.0 µs` | `24,350.1 MiB/s` |
| `400 µs` | `2.2%` | `30.46 / 52.73 µs` | `24.5 / 35.0 µs` | `135.0 / 384.0 µs` | `24,259.0 MiB/s` |

## Managed checkout, Docker archives and HVF retirement

The direct fork follow-up checks every VMM exit, a five-second delayed restore against host UTC, separate workspaces and durable named-volume isolation. It recorded a VirtioFS shutdown crash on an earlier build. The corrected build retired all processes in the five- and eight-way trials. Managed checkout results and stock Docker archive tests use the worker socket. [Follow-up scorecard](phase-b5-managed-checkout-and-archive.md)
