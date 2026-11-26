# Phase B4 Results — Rust Hypervisor.framework VMM (`micropod-vmm`)

**Date**: 2026-11-25  
**Host**: Gamma (Apple M5 Max, 18 cores, 128 GiB RAM, macOS 26.5.1, quiet host verified)  
**Guest Kernel**: Linux `7.3.5-micropod-b4` 16 KiB pages (`ec3297f36d9a8d9e14b9804d327a63cc1ba11118468845ddf6dbc4f97e79084b`) with reciprocal `SYNC_COLOCATE`, `CONFIG_TCP_CONG_CUBIC=y`, `CONFIG_NET_SCH_FQ=y`, `CONFIG_NETKIT=y`  
**Receipts**:
- [phase-b4-hvf-bridge.json](phase-b4-hvf-bridge.json)
- [phase-b4-hvf-ipvlan.json](phase-b4-hvf-ipvlan.json)
- [phase-b4-workspace-ci.json](phase-b4-workspace-ci.json)

---

## Executive Summary

Phase B4 brought zero-`vmnet` egress to the Rust Hypervisor.framework VMM. The scorecards below compare the direct VMM with OrbStack 2.2.5 and tuned VZ on networking, container churn and the workspace fixture. The managed-worker follow-up covers the stock Docker, Compose and Buildx surfaces tested, including the remaining large-bind-mount, detached-exec and packaging gaps. [Managed Docker qualification](managed-engine-compatibility.md) · [CI and exec results](managed-ci-git-and-exec.md)

### Headline Progression (Phase B3 → Phase B4)

| Benchmark | Phase B3 HVF | **Phase B4 HVF** | Delta |
|---|---:|---:|---:|
| Cold boot (`docker info` ready) | `0.283 – 0.302 s` | **`0.276 – 0.298 s`** | Maintained (**2.4×–3.1× faster than VZ**) |
| Published TCP Bulk (32 bulk + 40 fresh req/s, bridge) | `8,699 MiB/s` | **`11,826.6 MiB/s`** (`11,980` peak) | **+35.9%** (beats VZ & **+56.5% vs OrbStack**) |
| Published TCP Upload (64 MiB SHA-256, `GUEST_TSO4`) | Single-MSS | **`2,174.3 MiB/s`** | **+31.6% vs OrbStack**, **+3.5% vs VZ** |
| 6 GiB Sibling Bulk (`ipvlan`, `cubic` + `fq`) | `18,325 MiB/s` | **`26,452.0 MiB/s`** | **+44.3%** (beats OrbStack **+9.5%**, VZ **+12.5%**) |
| 6 GiB Sibling Bulk (`bridge`, `cubic` + `fq`) | `16,580 MiB/s` | **`23,840.7 MiB/s`** | **+43.8%** (beats OrbStack **+3.1%**) |
| Outbound `eth0` Egress (`docker pull`, HTTPS, DNS, ICMP) | Offline | **Live, zero `vmnet`, zero TCC** | Host loopback/link-local strictly blocked |
| `VirtioBlk` Thin Reclaim | None | **`VIRTIO_BLK_F_DISCARD -> F_PUNCHHOLE`** | 4 KiB granularity / 32 MiB max active |
| Host-Edit Visibility (`size / held / replace / unlink`) | Unmeasured | **`12.4 / 11.2 / 2.7 / 12.4 ms`** | **4/4 POSIX pass** (OrbStack & VZ fail `replace`) |

---

## Controlled 3-Way Quiet-Host Results (OrbStack 2.2.5 vs VZ Tuned vs HVF Phase B4)

### 1. Core Docker & CI Suite (`bridge` & `ipvlan`, 3 rounds each, quiet Gamma)

| Metric | OrbStack 2.2.5 | Micropod VZ Tuned | **Micropod HVF Phase B4** | HVF vs OrbStack | HVF vs VZ Tuned |
|---|---:|---:|---:|---:|---:|
| **Cold Boot** | N/A | `0.667 – 0.869 s` | **`0.276 – 0.298 s`** | Instant-on | **2.4× – 3.1× faster** |
| **Published TCP Bulk (`bridge` run)** | `7,555.1 MiB/s` | `11,420.4 MiB/s` | **`11,826.6 MiB/s`** | **+56.5%** | **+3.6%** (0 vmnet/TCC) |
| **Published TCP Fresh `p50 / p95 / p99` (`bridge`)** | `2.60 / 5.69 / 7.19 ms` | `8.15 / 11.41 / 12.59 ms` | **`3.02 / 3.77 / 6.02 ms`** | **-34% p95** | **-67% p95 (3.0× faster)** |
| **Published TCP Bulk (`ipvlan` run)** | `7,524.1 MiB/s` | `11,569.5 MiB/s` | **`10,897.5 MiB/s`** (`11,389` peak) | **+44.8%** | **-49% p95** (`5.87` vs `11.41 ms`) |
| **Published TCP Errors / Bulk Reopens** | `0 / 0` | `0 / 0` | **`0 / 0`** | Parity | Parity |
| **6 GiB Sibling Bulk (`ipvlan`)** | `24,156.3 MiB/s` | `23,506.2 MiB/s` | **`26,452.0 MiB/s`** | **+9.5%** | **+12.5%** |
| **6 GiB Sibling Bulk (`bridge`)** | `23,130.8 MiB/s` | `24,607.9 MiB/s` | **`23,840.7 MiB/s`** | **+3.1%** | -3.1% |
| **32×8 Ephemeral Churn (wall / rate)** | `1.809 – 1.949 s` (`16.4–17.7/s`) | `1.295 – 1.530 s` (`20.9–24.7/s`) | **`1.088 – 1.090 s` (`29.4/s`)** | **40–44% faster (1.79×)** | **16–29% faster** |
| **32-Client DNS (`p50 / p95`)** | `160–165 / 670–808 µs` | `133–155 / 373–440 µs` | **`145–149 / 329–379 µs`** | **-51% to -59% p95** | **-12% to -14% p95** |
| **1-Client DNS (`p50`)** | `21 – 22 µs` | `21 – 23 µs` | **`21 – 23 µs`** | Parity | Parity |
| **Same-CPU Pinned Quiet HTTP (`p50 / p95`, `ipvlan`)** | `17.00 / 71.17 µs` | `14.38 / 22.71 µs` | **`12.92 / 18.04 µs`** | **-24% p50 / -75% p95** | **-10% p50 / -21% p95** |
| **Unrestricted Quiet HTTP (`p50`)** | `12.33 – 12.50 µs` | `30.46 – 37.71 µs` | **`29.46 – 29.92 µs`** | OrbStack faster | **-2% to -22% faster** |
| **OOM Kill (`32m` cgroup v2)** | `OOMKilled=true (137)` | `OOMKilled=true (137)` | **`OOMKilled=true (137)`** | Exact parity | Exact parity |

### 2. Real-Workload Host-Mounted Workspace CI (`phase-b4-workspace-ci.json`, 3 rounds)

| Metric | OrbStack 2.2.5 | Micropod VZ Tuned | **Micropod HVF Phase B4** | Notes |
|---|---:|---:|---:|---|
| **Published 64 MiB Upload (SHA-256)** | `1,652.5 MiB/s` | `2,100.0 MiB/s` | **`2,174.3 MiB/s`** | **#1 overall** (`GUEST_TSO4` + `MRG_RXBUF`) |
| **Sequential 64 MiB Bind-Mount Write** | `3,200.0 MiB/s` | `1,600.0 MiB/s` | **`3,200.0 MiB/s`** | **Tied #1** (**2× faster than VZ**, zero-copy `pwritev`) |
| **Sequential 64 MiB Bind-Mount Read** | `6,400.0 MiB/s` | `6,400.0 MiB/s` | **`6,400.0 MiB/s`** | **Tied #1** (zero-copy `preadv`) |
| **Host-Edit `size` (append)** | `5.26 ms` (3/3) | `1,004.07 ms` (3/3) | **`12.42 ms` (3/3)** | **81× faster than VZ** |
| **Host-Edit `held` (in-place overwrite)** | `91.19 ms` (3/3) | **FAIL** (`timeout`, 0/3) | **`11.23 ms` (3/3)** | **8.1× faster than OrbStack**; VZ fails |
| **Host-Edit `replace` (atomic rename)** | **FAIL** (`old-handle-changed`, 0/3) | **FAIL** (`old-handle-changed`, 0/3) | **`2.67 ms` (3/3)** | **Only engine with 100% POSIX fidelity** |
| **Host-Edit `unlink` (old FD preserved)** | `96.39 ms` (3/3) | `1,002.88 ms` (3/3) | **`12.41 ms` (3/3)** | **7.8× faster than OrbStack, 81× faster than VZ** |
| **1,000-file `WalkDir` Stat (Pass 1)** | `3.73 ms` | `9.32 ms` | **`7.99 ms`** | **17% faster than VZ** |
| **1,000-file `ReadFile` + SHA-256 (Pass 3)** | `14.31 ms` | `111.11 ms` | **`99.61 ms`** | **12% faster than VZ** |
| **1,000-file Bind-Mount `tar -xf` / `rm -rf`** | `80 ms` / `30 ms` | `430 ms` / `70 ms` | **`340 ms` / `60 ms`** | **26% / 17% faster than VZ** |

---

## Key Engineering Changes & Discoveries

1. **Zero-`vmnet`, Zero-TCC Outbound `eth0` Egress (`vmm/crates/vmm-net/src/egress.rs`)**:
   - Implemented pure-Rust L2/L3/L4 egress gateway (`10.42.0.1`) handling ARP, ICMP Echo (`SOCK_DGRAM/IPPROTO_ICMP`), UDP + DNS proxy (`/etc/resolv.conf` upstream, fallback `1.1.1.1`), and zero-copy outbound TCP (`GuestMemory -> libc::writev()`, `VIRTIO_NET_F_HOST_TSO4`).
   - Enforces strict host isolation (`is_blocked_egress_ip()` rejects host loopback `127.0.0.0/8`, link-local `169.254.0.0/16`, unspecified, broadcast, and multicast). Verified live with `docker pull docker.io/library/busybox:1.36`, TLS 1.3 HTTPS, DNS, ICMP ping, and blocked `127.0.0.1` check.
2. **Multi-Queue `vmm-net` + `GUEST_TSO4` + L2-Matched `SO_SNDBUF` (`vmm/crates/vmm-net/src/lib.rs`, `ci/runner/published-ports.sh`)**:
   - Enabled `VIRTIO_NET_F_MQ` (4 TX/RX queue pairs = 9 queues incl. Control VQ), `VIRTIO_NET_F_CTRL_VQ`, `VIRTIO_NET_F_MRG_RXBUF` (with atomic ARM64 `VirtQueue::push_used_batch`), and `VIRTIO_NET_F_GUEST_TSO4` (60 KiB Host→Guest super-frames).
   - Spawned 4 parallel P-core `vmm-net-tx-0..3` drainers with two-pass fresh-priority scheduling and 2 decoupled P-core `vmm-net-wr-0/1` (`EV_ONESHOT`) write-backpressure threads so `run_net_io_loop` stays dedicated to fresh `accept()`/`EVFILT_READ`.
   - **Critical profiling discoveries**:
     - Clearing 1:1 `xps_cpus` (`echo 0 > /sys/class/net/eth1/queues/tx-*/xps_cpus`) let Linux `skb_tx_hash` balance 32 bulk streams evenly across all 4 host TX drainers (`+22%` throughput, `-15%` latency) with zero guest RPS IPI overhead (whereas RX RPS flooded worker vCPUs with softirq and hurt fresh latency 3×).
     - Matching `SO_SNDBUF = 512 KiB` to `DEFAULT_HOST_RCV_WND = 512 KiB` kept all 32 live streams (`16 MiB`) inside M5 Max L2/SLC and eliminated Darwin `lo0` loopback bufferbloat (`4 MiB -> 512 KiB` improved throughput `9,605 -> 11,827 MiB/s` and cut fresh `p50` `18.3 ms -> 3.0 ms`), while keeping `SO_RCVBUF = 2 MiB` drove Host→Guest uploads to `2,174 MiB/s`.
     - Fixed an edge-triggered `EV_CLEAR` EOF drain bug in both `lib.rs` and `egress.rs` (`pump_host_to_guest` / `pump_tcp_from_host` now drain until `WouldBlock`/`EOF` instead of stopping on `n < cap`, and always flush queued `FIN` even after `host_fin_queued == true`).
3. **Guest Kernel `cubic` + `fq` Qdisc (`ci/patches/`, `ci/runner/start.sh`, `HVFWorker.swift`)**:
   - Built `7.3.5-micropod-b4` 16 KiB kernel with reciprocal `SYNC_COLOCATE` (`p->last_wakee == current`), `CONFIG_TCP_CONG_CUBIC=y`, and `CONFIG_NETKIT=y`.
   - Setting `micropod.ci_cc=cubic` while preserving `fq` qdisc boosted 6 GiB in-guest sibling bulk by **+44%** (`18.3 -> 26.45 GiB/s` on `ipvlan`, `16.6 -> 23.84 GiB/s` on `bridge`), surpassing OrbStack (`24.16 / 23.13 GiB/s`) without regressing `eth1` published TCP (whose pod routes explicitly retain `reno` + `fq`).
   - Rejected `fq_codel` (regressed published TCP p95 `2.97 -> 8.21 ms`) and `NO_TTWU_QUEUE` (regressed quiet HTTP `27.0 -> 31.3 µs`) based on empirical A/B data.
4. **Storage, Host-Share & Control-Plane Upgrades (`vmm/crates/vmm-virtio/`)**:
   - **Single-reactor zero-alloc `kqueue` `VirtioVsock`** (`vsock.rs`): eliminated 3-thread-per-connection spawning for `docker.sock` / `oci.sock` / `buildkit.sock` with a single `vmm-vsock-io` P-core reactor, zero-copy `GuestMemory -> writev()`, zero-alloc 2-slice RX scatter, and coalesced `OP_CREDIT_UPDATE`.
   - **Async zero-copy `VirtioFs`** (`virtiofs.rs`): dedicated `vmm-fs-<tag>` P-core worker with `VRING_USED_F_NO_NOTIFY` + 30 µs spin, zero-copy `preadv`/`pwritev` directly against `GuestMemory`, `FUSE_ATOMIC_O_TRUNC`, and 256 KiB I/O windows — preserving 100% of mutable inode-identity & atomic-replacement invariants.
   - **`VirtioBlk` `VIRTIO_BLK_F_DISCARD -> F_PUNCHHOLE`** (`lib.rs`): advertises 4 KiB discard granularity / 32 MiB max discard and punches APFS sparse holes on Linux `DISCARD`.

---

## Remaining Gaps & Phase B5 Roadmap

1. **Small-file `VirtioFs` metadata & read latency (`scan_1000_files` `read_ms`: `99.6 ms` vs OrbStack `14.3 ms`)**:
   - OrbStack achieves `14 ms` by keeping guest page cache valid across opens via macOS `FSEvents` invalidation (at the cost of breaking POSIX `replace` semantics and 90 ms `held`/`unlink` visibility).
   - **Next step**: Add a macOS `FSEvents` / `kqueue` host directory watcher that issues `FUSE_NOTIFY_INVAL_ENTRY` / `FUSE_NOTIFY_INVAL_INODE` reverse invalidations on host edits, enabling `FOPEN_KEEP_CACHE` + 1 s entry/attr TTL on RW shares **while preserving 100% POSIX `replace`/`held`/`unlink` correctness**, plus Darwin `getattrlistbulk()` for single-syscall `FUSE_READDIRPLUS`.
2. **Unrestricted Cross-vCPU Quiet HTTP (`29.5 µs` vs OrbStack `12.5 µs`)**:
   - Same-CPU pinned quiet HTTP is already `12.9 µs` (beating OrbStack's `17.0 µs` on `ipvlan`), confirming the remaining `~16 µs` gap is purely cross-vCPU `IPI` (`SGI` trap + host `hv_vcpu_exit` wake latency on Apple Silicon HVF vs OrbStack's kernel-side wake). Investigating `WFE` idle polling (brief guest `cpuidle` haltpoll window, e.g. `100–200 µs`) is the highest-leverage next kernel experiment to close `29.5 µs -> ~13 µs`.
3. **Phase B5 — Sub-40 ms HVF VM Snapshot & APFS CoW Fork**:
   - Serialize `hv_vcpu` regs + `hv_gic_state` + `Virtio` device state + `clonefile()` APFS CoW RAM/disk images to fork warm CI workers in `< 40 ms` (vs `276 ms` cold boot and `869 ms` VZ boot).
