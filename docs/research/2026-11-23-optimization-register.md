# Micropod performance optimization register

[GitHub tracking issue #227](https://github.com/castlemilk/micropod/issues/227) · [Measured workload scorecard](../benchmarks/2026-11-23/orbstack-scorecard.md) · [Source and phase audit](2026-11-23-apple-silicon-performance-optimization.md)

The 23 November 2026 research supplied an itemized 13-experiment roadmap and an eight-layer Apple Silicon blueprint. This register covers both. It assigns 101 IDs to hypotheses, closely related controls and measured experiments. The GitHub tables linked below are the working backlog. This dated snapshot includes the local receipts. Preserve each ID when updating its outcome and append new IDs for new directions. Record the build, control, hardware, workload, outcome and receipt whenever a result changes.

13 measured, 4 regressed, 13 ready for their next check, 38 open and 33 conditional. **Measured** means a result exists at the stated scope, including inconclusive comparisons. **Regressed** means the tested variant lost throughput or failed delivery. **Ready** means a control, verifier or fixture is available for the named next check. **Open** means the hypothesis still needs implementation or a controlled measurement. **Conditional** identifies an explicit dependency such as host capability, prior profiling or a distinct backend.

## Research layers and phases

| Blueprint layer | Area | Execution phase | Backlog |
| --- | --- | --- | --- |
| 1 | Host scheduling, QoS and topology | 0, 4 | [#228](https://github.com/castlemilk/micropod/issues/228#issuecomment-7091845744), [#237](https://github.com/castlemilk/micropod/issues/237#issuecomment-7091857034) |
| 2 | Host-to-guest transport and relay bypass | 1 | [#229](https://github.com/castlemilk/micropod/issues/229#issuecomment-7091848763), [#232](https://github.com/castlemilk/micropod/issues/232#issuecomment-7091852014) |
| 3 | Mac relay and host TCP | 1 | [#230](https://github.com/castlemilk/micropod/issues/230#issuecomment-7091849663) |
| 4 | Guest networking, container links and splice | 2 | [#231](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125), [#233](https://github.com/castlemilk/micropod/issues/233#issuecomment-7091853144), [#234](https://github.com/castlemilk/micropod/issues/234#issuecomment-7091854023) |
| 5 | Guest scheduling and cgroup isolation | 2 | [#231](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125), [#237](https://github.com/castlemilk/micropod/issues/237#issuecomment-7091857034) |
| 6 | ARM64 guest, compiler and architecture split | 3 | [#235](https://github.com/castlemilk/micropod/issues/235#issuecomment-7091855144), [#236](https://github.com/castlemilk/micropod/issues/236#issuecomment-7091856042) |
| 7 | Custom virtual devices, VMM and isolation tiers | 5 | [#239](https://github.com/castlemilk/micropod/issues/239#issuecomment-7091859108), [#240](https://github.com/castlemilk/micropod/issues/240#issuecomment-7091860155) |
| 8 | Storage, file sharing and dynamic reclaim | 4, 5 | [#238](https://github.com/castlemilk/micropod/issues/238#issuecomment-7091858072), [#239](https://github.com/castlemilk/micropod/issues/239#issuecomment-7091859108) |

## Decision criteria

The four-vCPU research target is 4,100–4,600 MiB/s and fresh p95 ≤75 ms. The scaled target is 6,000–8,000+ MiB/s with p95 ≤60 ms. The idle CPU target is <0.1%. These are proposed targets. The measured peer criterion uses a fresh 16-pair holdout, zero Micropod fresh losses or bulk reopens, p95 ≤75 ms in every Micropod round and a lower 95% paired throughput bound above 1. The scorer requires at least 15 common clean pairs and retains every attempted round. Track CPU/GiB and runnable wait with both engines. Check throughput, tail latency, packet integrity and host wait before advancing a candidate.

Each shared Gamma live comparison needs an explicit isolated owner handoff, fresh fleet status and effective disk clearance. The last checked fleet snapshot on 23 November at 15:37 AEDT showed the isolated Linux worker’s only slot leased and zero of six Mac slots leased. A fresh live benchmark is pending. Historical results and local encoder or filesystem observations retain their original scopes.

## Product outcomes

Micropod appears first in the historical comparisons. Measurements from different studies can use different builds and workloads. See the [scorecard and raw comparisons](../benchmarks/2026-11-23/orbstack-scorecard.md) and the [peer assessment](../../scripts/relaybench/peer_verdict.py).

| Workload | Available result | Next matched observation |
| --- | --- | --- |
| Edited CI / same revision rerun | 5.651 / 3.276 s vs 22.551 / 8.730 s | Recheck the same Go, npm, container and PostgreSQL pipeline on the selected build. |
| 32 parallel Go jobs / warm container launch | 5.974 vs 9.423 s for the batch. Warm launch 67 vs 236 ms. | Keep equivalent work, cache state, resource limits and startup entry point explicit. |
| Published TCP under mixed load | 2,709.8 vs 3,010.4 MiB/s clean-arm medians. Fresh p95 35.2 vs 220.3 ms. Observed CPU-s/GiB 0.956 vs 1.074. | Run the revised four-vCPU baseline, two vs four relay workers, then the independent peer holdout. |
| DNS and service HTTP | One / 32-resolver p95 118 / 711 µs vs 77 / 1,188 µs. Reused HTTP p50 54.5 vs 19.5 µs on the default bridge. | Rebuild the guest with the local DNS change and repeat both concurrencies. Profile reused HTTP separately. |
| Sibling bulk transfers | 32 streams on bridge / macvlan 11,020 / 12,767 MiB/s vs 12,205 MiB/s. Sustained 6 GiB on a separate fixture was 9,582 vs 13,496 MiB/s. | Match network mode, transfer size and offered concurrency. |
| Cold boot, first image and first build | Peer comparison open. | Use verified empty caches, the same image and identical first build. Time boot-to-ready, image availability, then build completion. |
| Storage, edit propagation and recovery | 32 local cross-process file observations. Matched guest storage and restart data open. | Compare actual mount identity, both edit directions, durable I/O and correct files after restart. |
| Idle CPU, memory and energy | The archived TCP CPU counters cover selected processes. Idle energy, product-wide CPU and host reclaim remain open. | Measure quiescent power and host footprint, then identical build, idle and rebuild cycles. |
| amd64 translation and isolation | Peer comparison open. | Match architecture, translated first launch, repeated build and isolation level. |
| Sleep/wake and update recovery | Peer comparison open. | Time recovery of an existing service and verify remount, route, published-port and data identity. |

## Six research guardrails

| Research caveat | What counts as evidence | Direction IDs |
| --- | --- | --- |
| Stock VZ memory balloon | Require a repeatable host physical-footprint and system-pressure change using high-entropy pages. A guest-reported decrease alone is insufficient. | 238.17, 239.06 |
| Stock vsock bulk TCP | Preserve the failed historical trials. Require backpressure and received-byte integrity in both directions before timing another bulk prototype. | 232.04 |
| Native and translated workers | Record page size, architecture, translation share and executable. Separate first-use translation and native measurements. | 236.01–04 |
| Shared-network jumbo claims | Verify both endpoints, directional DF delivery, TCP MSS and actual service bytes. A configured 9000-byte interface can still have a 1500-byte host route. | 229.01–02 |
| SOCKMAP, global sched_ext and busy polling | Carry forward failed transfers and account for sibling fairness, idle CPU and tail latency before considering another configuration. | 234.03, 231.13, 231.04 |
| ASIF for hot container data | Compare file-backed raw and ASIF on the same OS, guest and device. Record durability, write amplification and allocated host bytes. | 238.01–04 |

## Host scheduling and power

[Update directions in #228](https://github.com/castlemilk/micropod/issues/228#issuecomment-7091845744) · 6 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 228.01 | launchd Standard vs Interactive | Ready | CPU-only controls both sampled zero runnable vCPU time below base. Mixed-load role driver holds the socket window fixed. | Run the released four-vCPU role comparison. |
| 228.02 | VZ queue QoS and XPC turnstile inheritance | Open | The pinned dependency constructs the VZ queue. Whole-process wait does not identify vCPU thread priority. | Trace the disk-identified helper and supervisor with System Trace and taskinfo, then vary queue QoS alone. |
| 228.03 | Foundation latency-critical activity | Open | No isolated mixed-load result for a scoped ProcessInfo activity. | Time a bounded activity against the same launchd role and observe effective priority and energy. |
| 228.04 | Mach fixed-priority relay threads | Open | Utility QoS lost the historical paired relay test. A fixed-priority policy is a different intervention. | Record the relay thread’s effective QoS, core placement, host fairness and wait. |
| 228.05 | High Power Mode | Open | No controlled power-mode result in the cited series. | Record the power source and mode, then compare thermals, energy and workload time on a dedicated host. |
| 228.06 | Server performance boot profile | Conditional | The research proposes a host-wide boot setting. | Confirm actual OS support and obtain a dedicated boot comparison before attributing a gain. |

[gamma-vcpu-priority.md](../benchmarks/2026-11-21/gamma-vcpu-priority.md) · [host-role-verification.json](../benchmarks/2026-11-23/host-role-verification.json)

## Host-only MTU and attachment

[Update directions in #229](https://github.com/castlemilk/micropod/issues/229#issuecomment-7091848763) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 229.01 | Dedicated host-only vmnet attachment at MTU 9000 | Measured | The earlier synchronized test moved from 3,449 to 3,474 MiB/s. The first nominal jumbo worker still routed at 1500. | Repeat on the actual revised service path with host/worker route identity and packet counts. |
| 229.02 | Jumbo path and shared-network MSS clamp | Ready | The offline verifier rejects the archived false-jumbo route. Host-originated DF evidence covers the host-to-worker hop. | Check 8,972-byte DF payloads in both directions, actual TCP MSS and complete service bytes. Observe shared egress separately. |
| 229.03 | File-handle attachment datagram buffering | Conditional | A separate userspace switch would introduce send/receive datagram queues. | Compare the proposed receive/send ratio of at least 4:1, confirmed MTU, received bytes and drop counts on that attachment. |
| 229.04 | Alternate vmnet-helper TSO/checksum offload | Conditional | The proposed helper is a different backend. No Micropod comparison is recorded. | Verify TSO and checksum negotiation together, cover fragments, and compare stats-only versus verbose instrumentation outside scoring. |

[gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [mtu_path.py](../../scripts/relaybench/mtu_path.py)

## Mac relay and host TCP

[Update directions in #230](https://github.com/castlemilk/micropod/issues/230#issuecomment-7091849663) · 13 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 230.01 | Listener distribution on one vs many ports | Measured | Staggering yielded +78.5% on 32 ports and +4.7% with an interval crossing zero on one port, host-only. | Keep topology explicit and listener selection fixed during worker comparisons. |
| 230.02 | Two vs four kqueue workers | Ready | Host-only one-port screen gained 63.9% at 128 callback events. No VM win yet. | Use the same binary, four vCPUs and 128 events for both arms. Hold six-worker scaling for its own test. |
| 230.03 | Callback budget, filter batching and early yield | Measured | Four-worker 128 vs 24 events was inconclusive. Yielding after a short ready batch saved zero polls in six local paired blocks. Callback deliveries doubled for full reads and rose fivefold for 1 KiB fragments. | Retain the current drain loop. Test two vs four workers in the VM at a fixed callback budget. |
| 230.04 | Separate accept/fresh and established bulk lanes | Measured | Dedicated accept/data workers exist. Moving classified flows between lanes traded lower p95 for lower burst throughput. | Compare classification and migration with an identical worker count and listener policy. |
| 230.05 | Adaptive NOTE_LOWAT, 64 and 256 KiB | Regressed | The archived six-pair screens lost 6.1% and 22.3% in paired throughput. | Retain these outcomes for the tested build and threshold. |
| 230.06 | 128 KiB read watermark and idle fallback | Open | This threshold and the full promotion/demotion policy have no qualified result on the revised build. | Test 256 KiB of bulk history, fresh threshold 1, timer demotion and EV_EOF with a short unread tail. |
| 230.07 | Allocation-free slabs and packet pools | Open | No allocation attribution establishing a gain in this relay. | Count allocations per flow and compare reusable slabs under backpressure. |
| 230.08 | Cross-worker rings and cache-line-separated counters | Open | The research suggests SPSC/MPMC queues and padded counters. | Measure ownership transfer and contention before altering either structure. |
| 230.09 | Vectored readv/writev | Open | No paired result for scatter/gather on this path. | Verify short-write offsets, byte order and half-close before scoring syscall and CPU deltas. |
| 230.10 | Host socket caps, auto buffers and initial send/receive spaces | Open | Tested fixed per-socket caps failed to improve an earlier series. Host-wide auto-tuning is separate. | Record maxsockbuf, auto receive/send maxima, sendspace and recvspace. Vary one control on a dedicated host. |
| 230.11 | ACK delay, window scaling and initial flight size | Open | No matched host-control result on this workload. | Record delayed_ack, rfc1323 and slowstart_flightsize. Test host and guest controls separately. |
| 230.12 | TIME_WAIT, ephemeral ports, listen backlog and file limits | Open | A historical diagnostic saw at most 80 TIME_WAIT entries in a 16,384-port range. | Measure pressure at the offered rate before testing MSL, portrange, somaxconn, maxfiles or maxfilesperproc. |
| 230.13 | TCP_NOPUSH on bulk writes | Open | No tested threshold for long writes versus short replies. | Compare per-socket coalescing on established bulk transfers and measure time to first byte. |

[gamma-relay-workers.md](../benchmarks/2026-11-22/gamma-relay-workers.md) · [gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [gamma-filter-work.md](../benchmarks/2026-11-22/gamma-filter-work.md) · [relay-short-ready-set-offline.json](../benchmarks/2026-11-23/relay-short-ready-set-offline.json)

## Guest networking, DNS and scheduler

[Update directions in #231](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125) · 15 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 231.01 | Virtio queue count and negotiated offloads | Ready | Earlier guest exposed one combined queue pair. The new reader records the publication NIC, driver and boot. | Capture channels and feature readback on the stock guest before selecting a tuning candidate. |
| 231.02 | Packed/in-order rings and virtio writable notifications | Open | Availability in a kernel or SDK does not confirm negotiation of RING_PACKED, IN_ORDER or EPOLLOUT behavior. | Check the negotiated transport bits and readiness under saturation. |
| 231.03 | NAPI TX completion, deferred IRQs and GRO flushing | Open | An archived scheduling crossover explored polling. Queue coalescing and NAPI TX remain distinct controls. | Read napi_tx and sweep napi_defer_hard_irqs and gro_flush_timeout independently where supported. |
| 231.04 | Polling and busy-read CPU cost | Conditional | Persistent guest spinning would compete for vCPU time on the loaded control. | Retain non-spinning control. Measure busy_poll and busy_read separately with idle CPU and host wait. |
| 231.05 | TCP Fast Open and AccECN | Open | No evidence here that the accepted service sockets exercised either feature. | Verify the handshake and isolate one negotiated feature per pair. |
| 231.06 | Kernel TCP socket layout and IPv6 output caching | Open | These are proposed version-level effects. A kernel version change bundles many variables. | Record family-specific socket footprint, IPv6 routing and a matched kernel control. |
| 231.07 | Reno, CUBIC and BBR under fq pacing | Measured | Archived BBR changed the latency/bulk tradeoff. Removing service pacing lost 46.5% in one screen. | Keep Reno as the comparison path. Verify the accepted socket’s algorithm before testing other algorithms or BBRv3. |
| 231.08 | fq limits, retransmit timers and in-flight windows | Measured | Queue-depth and congestion-window sweeps traded retransmits and throughput for tails. | Retain per-flow drops, negotiated window and timer readbacks on both arms. |
| 231.09 | Guest async proxy I/O | Conditional | Zero-copy receive, 32 KiB buffers, registered plain send/recv, batched io_uring_enter and SQPOLL need a real guest proxy hop. | Qualify the hop first, then isolate buffer size, registration, batching and polling, including idle CPU. |
| 231.10 | Cgroup weight-accounting modes | Open | The study names up, smp, concur, max and tasks. Kernel availability and effective mode must be established on the test boot. | Compare supported modes with unchanged quota plus a competing sibling workload. |
| 231.11 | EEVDF, LLC locality and scheduler-version effects | Open | Short slices, asymmetric cores, NOHZ idle balancing, IPI completion and pipe mutex changes appear in the blueprint. | Record the effective scheduler and LLC topology. Use bounded contention and pipe tests before timing CI. |
| 231.12 | Scoped sched_ext sub-schedulers | Conditional | Stock image disables SCHED_CLASS_EXT. An optional full-scx profile exists. | Compare cgroup-only lavd, flash, flow or locality-oriented beerland against fair scheduling. Check migration, revocation and fallback. |
| 231.13 | Global sched_ext | Conditional | A global policy and a scoped policy are different experiments. No product benefit is qualified. | Keep ordinary fair scheduling as the control and include compilation, service tails and sibling isolation. |
| 231.14 | Single-resolver DNS, address lookup and A-reply encoding | Measured | One-resolver p95 was 118 µs vs 77 µs. Two local encoder series took 48–51% less time, 1,072 to 320 B/op. Six paired local directory tests reduced single-address lookup from 43.69 to 12.13 ns/op and 24 to 0 B/op. Eight-address medians were 120 vs 126 ns, with one allocation in both. | Repeat one- and 32-resolver p95 on matched guests, including service churn and multiple replicas. Both local results cover individual operations. |
| 231.15 | Concurrent DNS and persistent service HTTP | Measured | 32-resolver p95 was 711 vs 1,188 µs. Default-bridge keep-alive HTTP p50 was 54.5 vs 19.5 µs. | Protect the concurrent DNS lead and profile reused HTTP separately from fresh DNS requests. |

[native-network.md](../benchmarks/2026-11-21/native-network.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [gamma-vm-scheduling.md](../benchmarks/2026-11-21/gamma-vm-scheduling.md) · [gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [dns-answer-encoding.txt](../benchmarks/2026-11-23/dns-answer-encoding.txt) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [dns-directory-lookup.json](../benchmarks/2026-11-23/dns-directory-lookup.json)

## Published ingress and transport alternatives

[Update directions in #232](https://github.com/castlemilk/micropod/issues/232#issuecomment-7091852014) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 232.01 | Direct service IP and local DNS | Measured | Historical same-container direct guest ingress won four of six throughput pairs but exceeded 75 ms fresh p95 three times. | Repeat on the revised implementation with the same service, and qualify DNS, routing and ownership. |
| 232.02 | Native vmnet port-forwarding rules | Open | OS-specific forwarding, cross-process serialization and recreation after daemon restart remain unqualified. | Check return data on the intended OS versions, collisions, cleanup and rebinding. |
| 232.03 | Raw-frame host-socket translation | Conditional | The blueprint proposes a minimal host socket translator for a future file-handle or custom NIC path. | After attribution establishes a need, test stream semantics, copy count and recovery. |
| 232.04 | Stock virtio-vsock for bulk | Regressed | The tested bulk prototype delivered 53–125 MiB/s and completed zero of four synchronized trials. | Retain the control-plane use case. Only reconsider bulk with end-to-end backpressure, credit-window and byte-integrity evidence. |

[gamma-mixed-path.md](../benchmarks/2026-11-21/gamma-mixed-path.md) · [2026-11-23-guest-paths.md](2026-11-23-guest-paths.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md)

## Container links

[Update directions in #233](https://github.com/castlemilk/micropod/issues/233#issuecomment-7091853144) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 233.01 | Bridge vs direct macvlan on one kernel | Measured | A full-preemption historical crossover favored direct by 25.2% paired. The revised relay needs a fresh comparison. | Hold kernel and service limits fixed and record both interface identities and transfer counters. |
| 233.02 | ipvlan L2 and L3 | Open | An earlier Gamma kernel rejected ipvlan creation. Docker’s ordinary veth and dedicated macvlan have different roles. | Qualify L2 and L3 separately, including parent reachability, broadcast/ARP, MAC filters and isolation. |
| 233.03 | netkit peer redirect | Open | Setup counts cannot prove that the measured transfer used netkit; the offline checker can reject a misidentified link. | Check ingress/egress support on the selected build and record end-to-end directional byte deltas. |
| 233.04 | netkit AF_XDP and io_uring zero-copy | Conditional | These are separate optional datapaths on a qualified netkit link. | Prove support, resource ownership and forwarding correctness before a throughput test. |

[gamma-direct-macvlan.md](../benchmarks/2026-11-21/gamma-direct-macvlan.md) · [guest_link_path.py](../../scripts/relaybench/guest_link_path.py)

## Guest socket splice

[Update directions in #234](https://github.com/castlemilk/micropod/issues/234#issuecomment-7091854023) · 3 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 234.01 | Userspace TCP splice in a guest forwarder | Regressed | Historical Go splice lost 22.2% paired and reached 110.3 ms fresh p95. Syscall evidence confirmed splice ran. | Preserve this negative control and distinguish the two pipe legs from application payload. |
| 234.02 | Co-located kernel socket-pair splice | Conditional | The proposed socket-pair module is different from the Go trial. The direct macvlan route has no guest process owning both socket legs. | Verify both socket inodes and ABI, then qualify the proposed 64 KiB ring with FIN/RST, half-close and short replies. |
| 234.03 | SOCKMAP/SOCKHASH forwarding | Regressed | Historical SOCKHASH forwarding completed zero of six clean rounds. | Retain delivery failures in the record. A materially different implementation must pass the complete-body workload first. |

[gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [guest_paths.py](../../scripts/relaybench/guest_paths.py)

## Kernel compiler, features and syscall cost

[Update directions in #235](https://github.com/castlemilk/micropod/issues/235#issuecomment-7091855144) · 10 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 235.01 | GCC vs Clang and kernel size | Ready | Stock is GCC 15.2.0 with LTO disabled. The cross-target Clang control differs from stock in 52 effective settings. | Reproduce the native control toolchain first, then compare compiler alone. Measure image size, boot and CPU per unit of work. |
| 235.02 | Remove unused physical device drivers | Open | The research proposes a smaller image. The running worker still needs virtual disks, network, filesystems and OCI facilities. | Keep a driver manifest and boot the same CI fixture after each config change. |
| 235.03 | ThinLTO, distributed ThinLTO and full LTO | Open | No matched Micropod kernel build and runtime comparison. | Measure linker wall time, peak build RAM, image size and mixed workload with the same compiler. |
| 235.04 | AutoFDO and PMU profile portability | Conditional | There is no matched Micropod training profile or verified guest SPE/ETM access. | Collect a representative profile on a capable host, record workload, architecture and coverage, then test on held-out work. |
| 235.05 | Propeller code layout | Conditional | Profile-driven layout is a distinct change from training or ThinLTO. | Retain profile identity and compare layout only, including instruction-cache misses where available. |
| 235.06 | Syscall isolation, KPTI and KASLR | Ready | The archived stock config already disables CONFIG_UNMAP_KERNEL_AT_EL0. A research estimate cannot establish a new gain. | Record boot-effective mitigations and syscall costs, holding security posture constant. |
| 235.07 | Page allocation initialization | Open | Stock allocation initialization and guest high-water mark affect interpretation of memory measurements. | Record effective policy and measure allocation cost, guest pressure and host footprint with the same protections. |
| 235.08 | FD-anchored failfs and fchroot | Conditional | Feature and user-space support still need verification in the worker launch path. | Audit compatibility and measure exec/setup time plus existing isolation checks. |
| 235.09 | BPF-backed binfmt_misc for container exec | Conditional | Native startup and translation have different exec paths. | Check available kernel support and interpreter identity, then measure cold exec and repeat exec. |
| 235.10 | Preemption and kernel version | Measured | Historical lazy vs full preemption with Reno gave −20.4% paired throughput, with an interval spanning zero. | Isolate one preemption mode with the same compiler, release, config and service quota. |

[kernel_compiler.py](../../scripts/relaybench/kernel_compiler.py) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [gamma-direct-macvlan.md](../benchmarks/2026-11-21/gamma-direct-macvlan.md)

## Native and translated guests

[Update directions in #236](https://github.com/castlemilk/micropod/issues/236#issuecomment-7091856042) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 236.01 | 4 KiB vs 16 KiB native ARM64 guest pages | Ready | Both pinned 7.3.5 profiles passed real upstream olddefconfig twice. Each resolved 2,871 symbols, with 17 effective differences across the pair. | Build both Images on ARM64 Linux, verify hashes and page-size headers, then boot under VZ and read actual page size. |
| 236.02 | 16 KiB application and filesystem compatibility | Open | Resolved profiles alone have no boot, packaged binary or OCI result. | Exercise native builds, static libc binaries, allocators, toolchains, OCI images and mounts on both page sizes. |
| 236.03 | Rosetta share and native TSO cost | Open | The research proposes that enabling translation can affect native workloads. This worker has no matched TSO result. | Measure the same native workload on separately provisioned 4 KiB workers with and without translation. |
| 236.04 | On-demand 4 KiB amd64 worker | Open | The proposed split has no matched first-use latency or retained-memory result. | Verify amd64 image selection, executable compatibility, first start, steady CPU, RAM and release after idle. |

[research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [kernel_candidate.py](../../scripts/relaybench/kernel_candidate.py) · [2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md)

## Topology and CPU sizing

[Update directions in #237](https://github.com/castlemilk/micropod/issues/237#issuecomment-7091857034) · 6 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 237.01 | Discover heterogeneous CPU tiers and shared L2 groups | Ready | The sizing code reads host topology. The research also calls for per-tier names, physical counts and cpusperl2 across one-, two- and three-tier Macs. | Record all available fields, model missing data, and compare choices against observed CPU placement. |
| 237.02 | Balanced and maximum VM policies, host reserve | Open | Gamma’s current automatic policy resolves to six vCPUs. A 14-vCPU guest and 3–6 reserved host cores are research proposals. | Measure scaling, foreground host latency and thermals at fixed service quota. Include explicit overrides and fallback on incomplete topology. |
| 237.03 | Four vs six vCPUs | Ready | The paired worker-sizing driver fixes the quota, workers and callbacks while varying vCPUs. | Run after the revised four-vCPU baseline and the separate worker-count comparison. |
| 237.04 | Scale relay workers with topology | Open | The 2–6-worker proposal changes host execution resources independently of guest vCPUs. | Test the proposed ceil(vCPUs/2) rule capped at six after the worker-only screen, with vCPUs, listener layout and callbacks fixed. |
| 237.05 | IRQ affinity, housekeeping and RPS/RFS masks | Measured | The historical receive-steering trial traded throughput for a lower tail. A static mask has different meaning at each VM size. | Resolve masks from actual online CPUs. Test the proposed vCPU 1 IRQ pin, then RPS and RFS separately. |
| 237.06 | Service quota, oversubscription and background scheduling | Ready | A quota value alone cannot show enforcement. Existing checks exercise CPU and sibling workloads. | Verify consumed CPU under contention, quota recovery and foreground latency at each size. |

[gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [gamma_pilot.py](../../scripts/relaybench/gamma_pilot.py)

## Storage, file sharing and reclaim

[Update directions in #238](https://github.com/castlemilk/micropod/issues/238#issuecomment-7091858072) · 18 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 238.01 | Guest-native hot volumes vs host bind mounts | Ready | The worker already uses ext4 and supports a shared workspace. The matched placement comparison is outstanding. | Move source, generated outputs or package caches one at a time. Record build time, edit visibility and product hashes. |
| 238.02 | APFS cloned raw disks | Measured | A historical 512 MiB sparse fixture cloned in 0.189 ms median. Its first private 4 KiB write and fsync took 28.9 ms. | Measure first build, physical allocation, private-write isolation and restart on the real disposable worker. |
| 238.03 | ASIF immutable base, cache and thin overlay | Conditional | The proposed shallow stack needs a compatible host. Third-party sequential rates use other workloads. | Compare cold clone, first write, hot reads and allocated bytes against raw disks on the same host and guest. |
| 238.04 | virtio-blk vs multi-queue virtual NVMe | Conditional | The research cites external results. There is no comparable Micropod device result. | Use disposable file-backed images and one guest filesystem. Measure queue scaling, random IOPS and data integrity. |
| 238.05 | ext4 fast commit and directory hashing | Open | The earlier journal experiment varied fsync batching. It does not isolate fast commit or small-directory hashing. | Measure metadata-heavy builds and acknowledged-write recovery for each supported option. |
| 238.06 | ext4 iomap, small direct I/O and parallel writes | Open | The proposed improvements depend on actual kernel, I/O size and concurrency. | Sweep direct I/O sizes and writer counts. Keep sync policy and bytes constant. |
| 238.07 | btrfs no-holes and fsync | Open | The current ext4 worker supplies the control. Published btrfs gains are external. | Use identical file trees and verify acknowledged data after a disposable restart. |
| 238.08 | Per-request RWF_DONTCACHE | Open | There is no matched result for evicting one-shot data from the worker page cache. | Measure scan throughput, subsequent warm builds and memory pressure. |
| 238.09 | VirtioFS metadata caching | Open | Attribute lifetime, negative lookup, stat and create/delete all affect developer-visible edits. | Benchmark each operation and detect stale reads, rename visibility and concurrent edits. |
| 238.10 | FUSE passthrough and io_uring zero-copy pools | Conditional | FUSE passthrough is disabled in the archived stock config. A custom server and compatible features are prerequisites for pooled I/O. | Verify both endpoints and kernel support. Measure copy cost, memory and read/write correctness under churn. |
| 238.11 | Read-only host projection of guest volumes | Open | NFSv4 over vsock is a proposed path for Finder/IDE access while writes stay on guest ext4. | Verify read-only semantics, stale file handling, restart and active build time. |
| 238.12 | File edit visibility across mounts | Ready | An independent local reader verified create, atomic replacement, rename and delete in 32/32 operations through two path aliases. | Time both directions through the actual guest mount. Preserve wrong-byte and missed-delete failures. |
| 238.13 | Durable writes, restart and physical allocation | Ready | A local workload verifies file sync, rename, directory sync and a reopen with content checks. | Verify acknowledged and interrupted writes after worker restart, with host allocated bytes, guest writes and fsync tails. |
| 238.14 | zram compressed swap | Open | There is no matched worker pressure result. | Measure CPU spent compressing, foreground rebuild latency, PSI, OOM and peak host footprint. |
| 238.15 | MGLRU and Swap Table Phase IV | Open | The research cites external improvements under pressure. Actual feature selection matters. | Record kernel features and separate MGLRU policy tests from kernel-version changes. |
| 238.16 | Guest RAM cap and touched high-water mark | Open | Configured memory and observed host physical use are different quantities. | Sweep caps under the same build, idle and rebuild sequence, capturing PSI, peak, recovery and OOM. |
| 238.17 | Traditional balloon under host pressure | Conditional | Balloon inflation and guest free memory do not establish returned host RAM. | Measure achieved inflation, host footprint and system pressure, plus rebuild latency with high-entropy pages. |
| 238.18 | userfaultfd RWP working-set tracking | Conditional | The research proposes tracking cold pages before implementing a tiered reclaim policy. | Qualify the available interface and measure tracking overhead and classification error first. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [volume_durability.py](../../scripts/relaybench/volume_durability.py) · [edit_visibility.py](../../scripts/relaybench/edit_visibility.py) · [gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [edit-visibility-local.json](../benchmarks/2026-11-23/edit-visibility-local.json)

## Custom virtio transport and memory reporting

[Update directions in #239](https://github.com/castlemilk/micropod/issues/239#issuecomment-7091859108) · 6 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 239.01 | Custom-device API and queue lifecycle | Conditional | The existing extension point is identified. The recorded Gamma host ran macOS 26.5.1. The research targets a macOS 27 host/SDK. | On a supported disposable host, validate configuration, exhaustion, reset, disconnect and reconnect against same-host stock. |
| 239.02 | Multi-queue virtio-net | Conditional | The stock-device queue count and the custom-device queue count need independent observation. | Compare one queue with multiple queues, holding guest CPUs, offered traffic and host workers fixed. |
| 239.03 | Packed rings and mergeable RX buffers | Conditional | PACKED and MRG_RXBUF are negotiable features. Each can change accounting per packet. | Change one negotiated bit at a time. Record bytes, drops, CPU and p95. |
| 239.04 | EVENT_IDX, interrupt suppression and GSO | Conditional | These are separate batching/offload hypotheses with tail-latency risks. | Verify negotiation and effective segment sizes, then vary one option and count notifications and interrupts. |
| 239.05 | Zero-copy L4 ring with guest memory mapping | Conditional | A custom ring is an alternative to the network-device path. It has no qualified Micropod throughput result. | Test bounded flow control, byte identity, half-close, revocation and recovery before mixed traffic. |
| 239.06 | Free-page reporting and host MADV_FREE | Conditional | A drop in guest allocated memory is insufficient to establish host reclamation. | Check negotiated reporting and mapping lifecycle under host pressure with incompressible pages. Measure host footprint, system memory and recovery. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md)

## Alternative VMM and isolation tier

[Update directions in #240](https://github.com/castlemilk/micropod/issues/240#issuecomment-7091860155) · 8 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 240.01 | Residual ceiling and backend decision | Conditional | Current VZ networking recovery has VZ-specific code. The upstream alternate manager builds on Linux. | Locate a repeatable residual bottleneck and quantify the improvement needed after the stock and custom-device trials. |
| 240.02 | Direct HV vCPU threads | Conditional | A Rust Hypervisor.framework backend and direct host pthread scheduling are research designs. | Build a minimal Linux control only after the decision gate. Match kernel, resources, boot and teardown. |
| 240.03 | Virtual interrupt controller and IPI delivery | Conditional | The design proposes kernel-assisted GIC APIs. There is no matched Micropod run. | Verify supported host APIs, boot, interrupt routing and correctness through suspend and teardown before timing. |
| 240.04 | VM exits, notification batching and vectorized GSO | Conditional | Reducing exits or improving packet batching is a backend hypothesis. | Count exits and interrupts per GiB under bulk and simultaneous fresh arrivals. |
| 240.05 | VirtioFS cache and DAX control | Conditional | A custom backend could expose file-server controls unavailable through the current manager. | Compare cold/warm metadata, coherency, rename/delete visibility and host allocation. |
| 240.06 | Backend memory reclaim | Conditional | Other VMMs’ results do not establish Micropod host memory recovery. | Track host reclamation and guest rebuild under identical pressure for each qualified backend. |
| 240.07 | Retain VZ for compatible guests and qualify translation | Conditional | The proposed dual backend changes capability selection for Linux, macOS guests and Rosetta/FEX. | Define a capability matrix and compare amd64 correctness, first-use and steady-state cost. |
| 240.08 | Opt-in VM per container | Conditional | The isolation tier is a proposal. Shared-kernel worker timings do not transfer to dedicated micro-VMs. | Measure launch, memory per idle/active container, density, networking and teardown for a strict-isolation workload. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [gamma-throughput-gap.md](../benchmarks/2026-11-23/gamma-throughput-gap.md)
