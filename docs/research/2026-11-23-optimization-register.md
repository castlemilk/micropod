# Micropod performance optimization register

[GitHub tracking issue #227](https://github.com/castlemilk/micropod/issues/227) · [Measured workload scorecard](../benchmarks/2026-11-23/orbstack-scorecard.md) · [Source and phase audit](2026-11-23-apple-silicon-performance-optimization.md)

The 23 November 2026 research supplied an itemized 13-experiment roadmap and an eight-layer Apple Silicon blueprint. This register covers both. It tracks 101 original directions and four follow-ons covering desktop stats, first-build caches, relay read filters and Go suite preparation, for 105 permanent IDs. The GitHub tables linked below are the working backlog. This dated snapshot includes the local receipts. Preserve each ID when updating its outcome and append new IDs for new directions. Record the build, control, hardware, workload, outcome and receipt whenever a result changes.

23 measured, 5 regressed, 26 ready for their next check, 16 open and 35 conditional. **Measured** means a result exists at the stated scope, including inconclusive comparisons. **Regressed** means the tested variant increased cost, lost throughput or failed delivery. **Ready** means a control, verifier or fixture is available for the named next check. **Open** means the hypothesis still needs implementation or a controlled measurement. **Conditional** identifies an explicit dependency such as host capability, prior profiling or a distinct backend.

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

Each shared Gamma live comparison needs an explicit isolated owner handoff, fresh fleet status and effective disk clearance. The last checked fleet snapshot on 23 November at 17:16 AEDT showed the isolated Linux worker’s only slot leased and zero of six Mac slots leased. A fresh live benchmark is pending. Historical results and local encoder or filesystem observations retain their original scopes.

## Execution order and dependencies

All 101 original directions and four follow-ons appear once below. The revised stock four-vCPU window comes first for published TCP. Guest service, storage, desktop and compiler experiments can proceed independently on suitable fixtures.

| Experiment group | Direction IDs | Next decision |
| --- | --- | --- |
| 1. Revised baseline and fixed-budget relay comparison | 230.01–04 | Next released four-vCPU window. Reuse the stock receipt across owners. After the baseline, isolate listener distribution, worker count, then callback behavior. Run an independent peer holdout only after selecting a candidate. |
| 2. Host scheduling and socket controls | 228.01–06, 230.10–13 | Use the same serving service, measure actual host and helper runnable wait and energy. Host-wide settings need their own dedicated comparison and effective readback. |
| 3. Stock transport and direct ingress | 229.01–02, 232.01–02, 233.01 | Qualify both MTU directions and service bytes on one boot. Compare the same service through the published listener and direct ingress, then exercise native forwarding semantics. |
| 4. Guest NIC, service HTTP and congestion | 231.01–08, 231.14–15 | Capture the revision and negotiated NIC features, then try one supported control. Run the quiet HTTP and DNS fixtures apart from mixed host traffic. |
| 5. Relay allocation and queue behavior | 230.06–08, 230.14 | Use realistic pending-transfer conditions. Replicate a result on the revised VM only if the bounded component trial shows a reason. |
| 6. Retain negative controls | 230.05, 230.09, 232.04, 234.01, 234.03 | Keep these implementations out of the next tuning round. Reopen a trial only for a materially different design or workload that addresses its observed failure. |
| 7. Alternate guest links and forwarders | 231.09, 233.02–04, 234.02 | Confirm kernel support and identify the actual socket/queue owner. Each link or forwarding candidate needs route, byte integrity and error evidence on the scored path. |
| 8. Guest scheduling and contention | 231.10–13, 235.10, 237.05–06 | Use a qualifying boot and compare effective quotas, scheduler attachment, fallback, sibling fairness and foreground latency at fixed workload. |
| 9. Native kernel builds | 235.01–09, 236.01–02 | Reproduce the stock compiler, config and tools. Check the resolved config after each independent change. Train and validate profile-based builds on separate work. |
| 10. Translation and per-job VM isolation | 236.03–04, 240.08 | Use the existing native request and isolated CI job paths. Measure lazy amd64 start, native cost, RAM per guest and cleanup against equivalent isolation. |
| 11. CPU scaling and headroom | 237.01–04 | After selecting relay workers, compare four and six vCPUs with identical service limits. Then measure host headroom and any broader automatic policy. |
| 12. Hot storage and edit fidelity | 238.01–02, 238.04–13, 238.19–20 | Use identified mounts, equal cache state, physical private allocation and identical bytes. Filesystem variants and file sharing each need a suitable guest image or server. |
| 13. Memory pressure and recovery | 238.14–18 | Bind the VMM identity and measure guest PSI, host footprint and rebuild cost across pressure and release. Qualify the chosen kernel features first. |
| 14. Alternate devices and image layers | 229.03–04, 232.03, 238.03, 239.01–06 | Use the specific attachment or supported SDK/OS with a same-host stock control. Qualify queue behavior, data delivery, failure recovery and physical memory independently. |
| 15. Second VMM decision | 240.01–07 | Require an attributed residual limit after the stock and custom-device trials. Measure the Linux backend, translation compatibility, file sharing and reclaim independently. |
| 16. Desktop stats polling | 237.07 | Measure full-request wall time and host CPU at representative polling cadence for small, repeated and large container lists. |

## Product outcomes

Micropod appears first in the historical comparisons. Measurements from different studies can use different builds and workloads. See the [scorecard and raw comparisons](../benchmarks/2026-11-23/orbstack-scorecard.md) and the [peer assessment](../../scripts/relaybench/peer_verdict.py).

| Workload | Available result | Next matched observation |
| --- | --- | --- |
| Edited CI / same revision rerun | 5.651 / 3.276 s vs 22.551 / 8.730 s | Recheck the same Go, npm, container and PostgreSQL pipeline on the selected build. |
| 32 parallel Go jobs / warm container launch | 5.974 vs 9.423 s for the batch. Warm launch 67 vs 236 ms. | Keep equivalent work, cache state, resource limits and startup entry point explicit. |
| Published TCP under mixed load | 2,709.8 vs 3,010.4 MiB/s clean-arm medians. Fresh p95 35.2 vs 220.3 ms. Observed CPU-s/GiB 0.956 vs 1.074. | Run the revised four-vCPU baseline, two vs four relay workers, then the independent peer holdout. |
| DNS and service HTTP | One / 32-resolver p95 118 / 711 µs vs 77 / 1,188 µs. Reused HTTP p50 54.5 vs 19.5 µs on the default bridge. | Rebuild the guest with the local DNS change and repeat both concurrencies. Profile reused HTTP separately. |
| Sibling bulk transfers | 32 streams on bridge / macvlan 11,020 / 12,767 MiB/s vs 12,205 MiB/s. Sustained 6 GiB on a separate fixture was 9,582 vs 13,496 MiB/s. | Match network mode, transfer size and offered concurrency. |
| Cold boot, first image and first build | Verified local first Go build 3.702 s with 106 compiler/assembler invocations. A partially warm counterexample took 0.175 s and compiled once. Peer comparison open. | Use verified empty caches, the same image and identical first build. Time boot-to-ready, image availability, then build completion. |
| Storage, edit propagation and recovery | 32 local cross-process file observations. A nested shared-view directory edit took 18.13 ms before subtree scanning and 1.05 ms after. Matched guest storage and restart data open. | Compare actual mount identity, both edit directions, durable I/O and correct files after restart. |
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
| 228.02 | VZ queue QoS and XPC turnstile inheritance | Open | The pinned VZ instance creates a private serial queue with only a label and passes it to VZVirtualMachine. Its SDK defaults are unspecified QoS and no explicit target. The startup helper enters it synchronously. The effective helper/vCPU QoS is unmeasured. | Trace the actual helper and supervisor in a released window, then vary only the queue policy under the same launch role. |
| 228.03 | Foundation latency-critical activity | Open | Both archived jobs were Interactive. The hinted job jointly added a user-initiated VM creation task and a latency-critical activity for published listeners. Only 3/8 blocks were clean on both arms. Hinted throughput lost all three (median paired −3.23%). | Hold VM creation priority and launch role fixed before testing the activity alone. Retain failed rounds, effective priority and fresh latency. |
| 228.04 | Mach fixed-priority relay threads | Open | Utility QoS lost the historical paired relay test. A fixed-priority policy is a different intervention. | Record the relay thread’s effective QoS, core placement, host fairness and wait. |
| 228.05 | High Power Mode | Open | The current Mac reported AC power and lowpowermode 0. High Power Mode was absent from the reported AC capabilities. | Capture the effective mode on a host that exposes it, then pair identical thermal, energy and workload measurements. |
| 228.06 | Server performance boot profile | Conditional | Reading kern.serverperfmode returned EPERM in this session. The current boot setting is unknown. | Use existing owner-provided boot evidence if available before considering a separate host-wide trial. |

[gamma-vcpu-priority.md](../benchmarks/2026-11-21/gamma-vcpu-priority.md) · [host-role-verification.json](../benchmarks/2026-11-23/host-role-verification.json) · [host-tcp-power-controls.json](../benchmarks/2026-11-23/host-tcp-power-controls.json) · [host-queue-controls.md](../benchmarks/2026-11-23/host-queue-controls.md)

## Host-only MTU and attachment

[Update directions in #229](https://github.com/castlemilk/micropod/issues/229#issuecomment-7091848763) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 229.01 | Dedicated host-only vmnet attachment at MTU 9000 | Measured | The earlier synchronized test moved from 3,449 to 3,474 MiB/s. The first nominal jumbo worker still routed at 1500. | Repeat on the actual revised service path with host/worker route identity and packet counts. |
| 229.02 | Jumbo path and shared-network MSS clamp | Ready | The two-way verifier checks the Linux reverse DF route, 8,972-byte payload and all three requests at the Mac bridge. The installed tcpdump decoded the offline 9,000-byte frames. It still rejects the archived 1,500-byte route. | Collect both directions on the released publication hop. Verify TCP MSS and complete service delivery independently. |
| 229.03 | File-handle attachment datagram buffering | Conditional | The file-handle attachment MTU setter type-checked against SDK 26.5. It applies to a separate device from Micropod’s normal vmnet path. | On that attachment, compare the proposed 4:1 buffers with received-byte hashes and actual route MTU. |
| 229.04 | Alternate vmnet-helper TSO/checksum offload | Conditional | The proposed helper is a different backend. No Micropod comparison is recorded. | Verify TSO and checksum negotiation together, cover fragments, and compare stats-only versus verbose instrumentation outside scoring. |

[gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [mtu_path.py](../../scripts/relaybench/mtu_path.py) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json)

## Mac relay and host TCP

[Update directions in #230](https://github.com/castlemilk/micropod/issues/230#issuecomment-7091849663) · 14 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 230.01 | Listener distribution on one vs many ports | Measured | The one-port and 32-port layouts can both split flows 16/16. The old host scorer accepted a 32-port sample at 11,011.66 MiB/s as one port. Its replacement rejects that mismatch and reproduces all 71 valid rates at their original settings. Staggering gained +4.7% on one port and +78.5% on 32. | Keep raw listener count, profiling and client buffers fixed for worker comparisons. The end-to-end peer scorer also requires a one-port receipt. |
| 230.02 | Two vs four kqueue workers | Ready | Host-only one-port screen gained 63.9% at 128 callback events. No VM win yet. | Use the same binary, four vCPUs and 128 events for both arms. Hold six-worker scaling for its own test. |
| 230.03 | Callback budget, filter batching and early yield | Measured | Four-worker 128 vs 24 events was inconclusive. Yielding after a short ready batch saved zero polls in six local paired blocks. Callback deliveries doubled for full reads and rose fivefold for 1 KiB fragments. | Retain the current drain loop. Test two vs four workers in the VM at a fixed callback budget. |
| 230.04 | Separate accept/fresh and established bulk lanes | Measured | Dedicated accept/data workers exist. Moving classified flows between lanes traded lower p95 for lower burst throughput. | Compare classification and migration with an identical worker count and listener policy. |
| 230.05 | Adaptive NOTE_LOWAT, 64 and 256 KiB | Regressed | The archived six-pair screens lost 6.1% and 22.3% in paired throughput. | Retain these outcomes for the tested build and threshold. |
| 230.06 | 128 KiB read watermark and idle fallback | Measured | In six local trials a promoted 128 KiB watermark preserved the 17-byte tail on FIN. An open 17-byte reply waited 64–66 ms on a background thread for a nominal 2 ms demotion. Earlier 64/256 KiB watermark arms each won 2/6 VM pairs. | Measure short open replies and timer delay at the production QoS under load before considering this policy. |
| 230.07 | Allocation-free slabs and packet pools | Measured | Archived suffix-buffer bound was zero allocations across 3,202 fresh writes and at most 12 allocations and 3 MiB copied during 8 GiB of bulk writes (0.037%). Connection allocation remains unattributed. | Profile connection-object lifetime and any forced backpressure before prototyping a pool. |
| 230.08 | Cross-worker rings and cache-line-separated counters | Ready | Opt-in profiling measures accept-to-enqueue and enqueue-to-adopt for each actual relay owner. A private queue fixture split eight handoffs 4/4. A forced 32 ms stall moved six into the >16.384 ms bucket. This tests the counters. | Measure live queue wait under churn separately from uninstrumented throughput. Investigate cross-worker rings or counter padding only if the measured cost warrants it. |
| 230.09 | Vectored readv/writev | Regressed | With identical buffers and syscall counts, two contiguous iovecs used more CPU in all eight local paired blocks. Median increase was 31.1% at 148 B and 12.0% at 256 KiB. Data, short writes and half-close passed. | Keep scalar I/O on this path. Revisit when a producer has genuinely discontiguous data that can save a copy or syscall. |
| 230.10 | Host socket caps, auto buffers and initial send/receive spaces | Open | The current normal host read returned EPERM for maxsockbuf, automatic buffer limits and sendspace/recvspace. Archived fixed per-socket caps yielded no win. | Use the owner’s effective settings on a dedicated host before changing one control. |
| 230.11 | ACK delay, window scaling and initial flight size | Open | On 26.5.1 the proposed rfc1323 and slowstart_flightsize sysctl names returned ENOENT. Reading delayed_ack returned EPERM. | Confirm a supported effective control before any trial. For window scaling, inspect the actual TCP handshake. |
| 230.12 | TIME_WAIT, ephemeral ports, listen backlog and file limits | Open | kern.maxfilesperproc returned 65,536. Reading backlog, port range and MSL returned EPERM. The historical test saw at most 80 TIME_WAIT entries in a 16,384-port range. | Use the actual offered rate and failure counters to decide if a host limit is relevant. |
| 230.13 | TCP_NOPUSH on bulk writes | Open | The relay sets TCP_NODELAY at both ends. An archived 33-accept bulk lease recorded 35,821 writes, without segment sizes or a TCP_NOPUSH control. | Capture TCP segments, first-byte latency, flush and FIN under stalls, holding NODELAY fixed. |
| 230.14 | Defer read-filter registration until the guest connection completes | Measured | Deferring read-filter registration removed two of six async kqueue submissions. Across 32,768 local asynchronous flows per arm, median paired setup CPU fell 6.68% and whole-flow relay CPU fell 2.52% (95% interval 0.90–5.64% lower). Immediate connects were inconclusive. | After the worker screen, test the opt-in candidate against stock under connection churn. Keep throughput, errors and fresh tails separate from the local CPU result. |

[gamma-relay-workers.md](../benchmarks/2026-11-22/gamma-relay-workers.md) · [gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [gamma-filter-work.md](../benchmarks/2026-11-22/gamma-filter-work.md) · [relay-short-ready-set-offline.json](../benchmarks/2026-11-23/relay-short-ready-set-offline.json) · [relay-vectored-pump-offline.json](../benchmarks/2026-11-23/relay-vectored-pump-offline.json) · [relay-watermark-tail-offline.json](../benchmarks/2026-11-23/relay-watermark-tail-offline.json) · [host-tcp-power-controls.json](../benchmarks/2026-11-23/host-tcp-power-controls.json) · [relay-handoff-profile-offline.json](../benchmarks/2026-11-23/relay-handoff-profile-offline.json) · [peer_verdict.py](../../scripts/relaybench/peer_verdict.py) · [relay-handshake-reads-confirmation.json](../benchmarks/2026-11-23/relay-handshake-reads-confirmation.json) · [test_compare.py](../../scripts/relaybench/test_compare.py)

## Guest networking, DNS and scheduler

[Update directions in #231](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125) · 15 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 231.01 | Virtio queue count and negotiated offloads | Ready | Earlier guest exposed one combined queue pair. The new reader records the publication NIC, driver and boot. | Capture channels and feature readback on the stock guest before selecting a tuning candidate. |
| 231.02 | Packed/in-order rings and virtio writable notifications | Measured | Replaying the Linux 6.18.35 eth0 feature bitmap found RING_PACKED and EVENT_IDX negotiated, IN_ORDER and MRG_RXBUF clear. This was a different interface and kernel from the revised worker. | Capture the current publication eth1 bits on the same boot, then test notification batching and readiness separately. |
| 231.03 | NAPI TX completion, deferred IRQs and GRO flushing | Measured | With two deferred polls fixed, 100 vs 20 µs GRO flushing lost 24.1% median paired throughput on CUBIC (1/8 wins) and 6.5% on Reno (3/7 wins). Timeouts used separate warm VMs. The NIC collector now reads the TX NAPI module parameter and both interface defaults. | Keep the stock control. Verify per-queue settings on one boot before timing deferred polls or TX completion independently. |
| 231.04 | Polling and busy-read CPU cost | Conditional | Persistent guest spinning would compete for vCPU time on the loaded control. | Retain non-spinning control. Measure busy_poll and busy_read separately with idle CPU and host wait. |
| 231.05 | TCP Fast Open and AccECN | Measured | Four archived guest captures contained 49,226 incoming SYN packets, all with zero payload. Of 26,806 matched SYN/SYN-ACK pairs, 19,142 showed the ECE/CWR flag pattern. The capture omitted the AE bit and TCP options. | On an isolated comparison, record SYN and reply options and the AE bit. Verify negotiation separately from payload actually delivered on SYN. |
| 231.06 | Kernel TCP socket layout and IPv6 output caching | Measured | BTF from four retained kernel Images shows established IPv4/IPv6 TCP structures of 2,304/2,432 bytes on Apple 6.18.35 and 2,432/2,560 on stock 7.3.5. The two other 7.3.5 builds match stock. The benchmark relay uses IPv4 on both legs. | Use an actual IPv6 service workload for IPv6 route-cache changes. Measure socket state counts, buffers and CPU under matched kernels for any layout claim. |
| 231.07 | Reno, CUBIC and BBR under fq pacing | Measured | Archived BBR changed the latency/bulk tradeoff. Removing service pacing lost 46.5% in one screen. | Keep Reno as the comparison path. Verify the accepted socket’s algorithm before testing other algorithms or BBRv3. |
| 231.08 | fq limits, retransmit timers and in-flight windows | Measured | Queue-depth and congestion-window sweeps traded retransmits and throughput for tails. | Retain per-flow drops, negotiated window and timer readbacks on both arms. |
| 231.09 | Guest async proxy I/O | Conditional | Zero-copy receive, 32 KiB buffers, registered plain send/recv, batched io_uring_enter and SQPOLL need a real guest proxy hop. | Qualify the hop first, then isolate buffer size, registration, batching and polling, including idle CPU. |
| 231.10 | Cgroup weight-accounting modes | Ready | The stock 7.3.5 fair scheduler supports up, smp, concur, max and tasks. Its guest-wide debugfs readout marks the selected mode. The source default is concur. All required fair-group and debugfs config options are on. | Read the actual mode on boot and compare one change at fixed quota with a competing sibling. Capture fairness and foreground tail latency. |
| 231.11 | EEVDF, LLC locality and scheduler-version effects | Ready | Stock fair scheduling includes EEVDF, an adjustable base slice and optional per-task slice requests. Stock enables SCHED_CACHE. Its enabled readout reports the user preference. Actual LLC balancing also requires multiple LLC domains. None of 14 archived run files records these controls. | Record effective slices, LLC domains and balancing. Compare one control under matched contention, with pipe round trips and foreground latency. |
| 231.12 | Scoped sched_ext sub-schedulers | Conditional | Stock image disables SCHED_CLASS_EXT. An optional full-scx profile exists. | Compare cgroup-only lavd, flash, flow or locality-oriented beerland against fair scheduling. Check migration, revocation and fallback. |
| 231.13 | Global sched_ext | Conditional | A global policy and a scoped policy are different experiments. No product benefit is qualified. | Keep ordinary fair scheduling as the control and include compilation, service tails and sibling isolation. |
| 231.14 | Single-resolver DNS, address lookup and A-reply encoding | Measured | After the multi-address change, checking directory membership and packing question-only replies reduced single-service AAAA from 277 to 120 ns and an internal A miss from 256 to 118 ns in process. Ordinary one-address A remained near 315 ns. Prior eight-address A was 1.93 to 0.66 µs. | Measure the usual A/AAAA mix over the guest socket at one and 32 resolvers. Record misses and multiple replicas separately. |
| 231.15 | Concurrent DNS and persistent service HTTP | Measured | 32-resolver p95 was 711 vs 1,188 µs. Archived default-bridge reused HTTP was 54.5 vs 19.5 µs. On a separate 14-pair series Micropod was slower in 11, median paired p50 difference +49 µs. | Use the new socket-verified quiet HTTP probe on both guests. It records redials, retries and response phases. |

[native-network.md](../benchmarks/2026-11-21/native-network.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [gamma-vm-scheduling.md](../benchmarks/2026-11-21/gamma-vm-scheduling.md) · [gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [dns-answer-encoding.txt](../benchmarks/2026-11-23/dns-answer-encoding.txt) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [dns-directory-lookup.json](../benchmarks/2026-11-23/dns-directory-lookup.json) · [quiet-service-http.md](../benchmarks/2026-11-23/quiet-service-http.md) · [guest_nic.py](../../scripts/relaybench/guest_nic.py) · [2026-11-23-guest-paths.md](2026-11-23-guest-paths.md) · [guest-gro-timeouts.md](../benchmarks/2026-11-23/guest-gro-timeouts.md) · [dns-multi-address.json](../benchmarks/2026-11-23/dns-multi-address.json) · [dns-question-lookup.md](../benchmarks/2026-11-23/dns-question-lookup.md) · [guest-handshake-replay.json](../benchmarks/2026-11-23/guest-handshake-replay.json) · [tcp-socket-layout.json](../benchmarks/2026-11-23/tcp-socket-layout.json)

## Published ingress and transport alternatives

[Update directions in #232](https://github.com/castlemilk/micropod/issues/232#issuecomment-7091852014) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 232.01 | Direct service IP and local DNS | Measured | Historical same-container direct guest ingress won four of six throughput pairs but exceeded 75 ms fresh p95 three times. | Repeat on the revised implementation with the same service, and qualify DNS, routing and ownership. |
| 232.02 | Native vmnet port-forwarding rules | Ready | The SDK 26.5 type-checked creation and removal of native forwarding rules. The creation API takes an outside port and inside address, with no outside bind-address parameter. Runtime scope and revocation remain unqualified. | Prove loopback-only visibility, collision handling, accepted-socket revocation and rebind on an isolated fixture before timing. |
| 232.03 | Raw-frame host-socket translation | Conditional | The blueprint proposes a minimal host socket translator for a future file-handle or custom NIC path. | After attribution establishes a need, test stream semantics, copy count and recovery. |
| 232.04 | Stock virtio-vsock for bulk | Regressed | The tested bulk prototype delivered 53–125 MiB/s and completed zero of four synchronized trials. | Retain the control-plane use case. Only reconsider bulk with end-to-end backpressure, credit-window and byte-integrity evidence. |

[gamma-mixed-path.md](../benchmarks/2026-11-21/gamma-mixed-path.md) · [2026-11-23-guest-paths.md](2026-11-23-guest-paths.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json)

## Container links

[Update directions in #233](https://github.com/castlemilk/micropod/issues/233#issuecomment-7091853144) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 233.01 | Bridge vs direct macvlan on one kernel | Measured | A full-preemption historical crossover favored direct by 25.2% paired. The revised relay needs a fresh comparison. | Hold kernel and service limits fixed and record both interface identities and transfer counters. |
| 233.02 | ipvlan L2 and L3 | Conditional | Both stock 7.3.5 config copies explicitly disable IPVLAN. The ordinary guest runtime accepts ipvlan L2, while the current published endpoint uses macvlan. L2 and L3 need a candidate kernel. | Build with IPVLAN and qualify each mode including parent reachability and isolation. Confirm scored traffic on the intended link. |
| 233.03 | netkit peer redirect | Open | Both stock 7.3.5 config copies enable NETKIT. A 6.18.35 setup failure does not determine current support. No current measured endpoint selects netkit. | Create a candidate fixture, verify link and egress program identity, and bind interface deltas to the timed payload. |
| 233.04 | netkit AF_XDP and io_uring zero-copy | Conditional | Stock disables XDP_SOCKETS and enables IO_URING_ZCRX. The netkit AF_XDP path additionally needs a leased capable lower RX queue. ZCRX needs an eligible DMA-backed queue. | Qualify the driver, queue and memory provider for the chosen API independently. |

[gamma-direct-macvlan.md](../benchmarks/2026-11-21/gamma-direct-macvlan.md) · [guest_link_path.py](../../scripts/relaybench/guest_link_path.py) · [guest_network_config.py](../../scripts/relaybench/guest_network_config.py) · [2026-11-23-guest-paths.md](2026-11-23-guest-paths.md)

## Guest socket splice

[Update directions in #234](https://github.com/castlemilk/micropod/issues/234#issuecomment-7091854023) · 3 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 234.01 | Userspace TCP splice in a guest forwarder | Regressed | Historical Go splice lost 22.2% paired and reached 110.3 ms fresh p95. Syscall evidence confirmed splice ran. | Preserve this negative control and distinguish the two pipe legs from application payload. |
| 234.02 | Co-located kernel socket-pair splice | Conditional | Stock 7.3.5 supports pipe splice. The kernel’s ordinary splice syscall requires a pipe on at least one end. The direct path has no forwarding process owning both TCP sockets. | Establish an actual two-socket fixture and candidate implementation before comparing an in-kernel 64 KiB ring. |
| 234.03 | SOCKMAP/SOCKHASH forwarding | Regressed | Stock 7.3.5 includes BPF_SYSCALL, BPF_STREAM_PARSER and the socket-map infrastructure. The historical SOCKHASH trial still completed zero of six clean rounds. | Require complete payloads, clean shutdown and a changed implementation before repeating the mixed workload. |

[gamma-mixed-scheduler.md](../benchmarks/2026-11-21/gamma-mixed-scheduler.md) · [guest_paths.py](../../scripts/relaybench/guest_paths.py) · [guest_network_config.py](../../scripts/relaybench/guest_network_config.py) · [2026-11-23-guest-paths.md](2026-11-23-guest-paths.md)

## Kernel compiler, features and syscall cost

[Update directions in #235](https://github.com/castlemilk/micropod/issues/235#issuecomment-7091855144) · 10 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 235.01 | GCC vs Clang and kernel size | Ready | Stock is GCC 15.2.0 with LTO disabled. The cross-target Clang control differs from stock in 52 effective settings. | Reproduce the native control toolchain first, then compare compiler alone. Measure image size, boot and CPU per unit of work. |
| 235.02 | Remove unused physical device drivers | Ready | The optional full-no-mlx5 profile resolved twice with 13 config differences, preserving 28 worker settings. It also drops NET_DEVLINK. In the stock Image, 2,057 mlx5-only text symbol groups span 577,096 bytes including padding. Final image savings are unmeasured. | Build the candidate Image, verify resulting size and boot identity, then exercise virtual devices, networking, OCI startup and CI including NET_DEVLINK compatibility. |
| 235.03 | ThinLTO, distributed ThinLTO and full LTO | Ready | With Xcode’s BSD ar, the pinned kernel silently resolved three LTO requests to no LTO. An audit option rejects this fallback. Thin/full bitcode for two real kernel math units linked as AArch64 ELF using LLD. | Use an LLVM archiver and verify the effective LTO choice before timing complete matched kernel builds. |
| 235.04 | AutoFDO and PMU profile portability | Conditional | An independent AutoFDO Kconfig control resolved on the 4 KiB Clang profile. The stock config disables ARM_SPE_PMU and CORESIGHT. No trained runtime comparison exists. | Record profile and training-workload identity on a capable host, then measure on a held-out build/workload. |
| 235.05 | Propeller code layout | Conditional | Propeller selected independently of AutoFDO in the 4 KiB Clang config. The untrained sample emitted a 62-byte basic-block address map. This only verifies tooling. | Acquire a suitable layout profile, verify the final image uses it and measure the same held-out workload. |
| 235.06 | Syscall isolation, KPTI and KASLR | Ready | The archived stock config already disables CONFIG_UNMAP_KERNEL_AT_EL0. A research estimate cannot establish a new gain. | Record boot-effective mitigations and syscall costs, holding security posture constant. |
| 235.07 | Page allocation initialization | Ready | Both stock zero-on-allocation and zero-on-free build defaults are off. The image contains the boot parameter handlers. The effective policy of the running guest remains unknown. | Capture the stock guest command line and effective init policy, then measure allocation cost, pressure and host footprint with protections fixed. |
| 235.08 | FD-anchored failfs and fchroot | Ready | Pinned 7.3.5 assigns syscall 472 to fchroot and builds failfs unconditionally. Stock image BTF contains the arm64 syscall and failfs implementation. | Qualify the FD-anchored user-space launch path, root confinement and setup time against the current path. |
| 235.09 | BPF-backed binfmt_misc for container exec | Conditional | Stock enables ordinary BINFMT_MISC and all three dependencies of BINFMT_MISC_BPF, but disables that feature. The upstream BPF implementation is present. | Use a candidate kernel and verify the registered interpreter before comparing cold and repeated container exec. |
| 235.10 | Preemption and kernel version | Measured | Historical lazy vs full preemption with Reno gave −20.4% paired throughput, with an interval spanning zero. | Isolate one preemption mode with the same compiler, release, config and service quota. |

[kernel_compiler.py](../../scripts/relaybench/kernel_compiler.py) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [gamma-direct-macvlan.md](../benchmarks/2026-11-21/gamma-direct-macvlan.md) · [kernel-compiler-qualification.md](../benchmarks/2026-11-23/kernel-compiler-qualification.md) · [kernel-driver-prune.md](../benchmarks/2026-11-23/kernel-driver-prune.md)

## Native and translated guests

[Update directions in #236](https://github.com/castlemilk/micropod/issues/236#issuecomment-7091856042) · 4 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 236.01 | 4 KiB vs 16 KiB native ARM64 guest pages | Ready | Both pinned 7.3.5 profiles passed real upstream olddefconfig twice. Each resolved 2,871 symbols, with 17 effective differences across the pair. | Build both Images on ARM64 Linux, verify hashes and page-size headers, then boot under VZ and read actual page size. |
| 236.02 | 16 KiB application and filesystem compatibility | Ready | Netbench and the saved Alpine ELFs have load offsets compatible with both page sizes. Alpine musl checks 4 KiB mmap alignment, while Linux arm64 requires native page alignment. A 16 KiB Mac rejected raw file offsets of 4, 8 and 12 KiB. The new arm64 Linux probe also checks exact bytes and private writes. | Run on 4 and 16 KiB Linux guests using the actual workload mount. Verify runtime page size, AT_PAGESZ, file offset behavior and OCI workloads. |
| 236.03 | Rosetta share and native TSO cost | Open | The Rosetta directory-share API type-checked on SDK 26.5. The native container service requests translation for explicit Rosetta or an amd64 image on ARM64, a distinct path from the warm worker. | Capture effective translation selection and compare the same native workload on two 4 KiB workers. |
| 236.04 | On-demand 4 KiB amd64 worker | Open | The proposed split has no matched first-use latency or retained-memory result. | Verify amd64 image selection, executable compatibility, first start, steady CPU, RAM and release after idle. |

[research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [kernel_candidate.py](../../scripts/relaybench/kernel_candidate.py) · [2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [elf-page-layout.json](../benchmarks/2026-11-23/elf-page-layout.json) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json) · [guest-page-mapping.json](../benchmarks/2026-11-23/guest-page-mapping.json)

## Topology and CPU sizing

[Update directions in #237](https://github.com/castlemilk/micropod/issues/237#issuecomment-7091857034) · 7 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 237.01 | Discover heterogeneous CPU tiers and shared L2 groups | Ready | The production CPU planner now reports topology on request. Local readback found 18 active CPUs, 6 Super plus 12 Performance, with 6 CPUs per L2 in each tier. Automatic allocation remains six. | Record the same fields with each released timing and measure actual thread placement. |
| 237.02 | Balanced and maximum VM policies, host reserve | Open | The normal CLI and topology output both select six locally. VZ reports a supported range of 1–64. The proposed 14-vCPU policy remains unmeasured. | Hold service quota and worker count constant, then measure host latency, power and scaling before changing any policy. |
| 237.03 | Four vs six vCPUs | Ready | The paired worker-sizing driver fixes the quota, workers and callbacks while varying vCPUs. | Run after the revised four-vCPU baseline and the separate worker-count comparison. |
| 237.04 | Scale relay workers with topology | Open | The 2–6-worker proposal changes host execution resources independently of guest vCPUs. | Test the proposed ceil(vCPUs/2) rule capped at six after the worker-only screen, with vCPUs, listener layout and callbacks fixed. |
| 237.05 | IRQ affinity, housekeeping and RPS/RFS masks | Measured | The historical receive-steering trial traded throughput for a lower tail. A static mask has different meaning at each VM size. | Resolve masks from actual online CPUs. Test the proposed vCPU 1 IRQ pin, then RPS and RFS separately. |
| 237.06 | Service quota, oversubscription and background scheduling | Ready | A quota value alone cannot show enforcement. Existing checks exercise CPU and sibling workloads. | Verify consumed CPU under contention, quota recovery and foreground latency at each size. |
| 237.07 | Desktop stats selection and timestamp formatting | Measured | In local Swift tests, 256 distinct IDs fell from 170.3 to 48.4 µs and 1,024 fell from 2,723.9 to 182.9 µs. At 16 IDs, 1.108 µs became 1.138 µs. Reusing the timestamp formatter reduced 73.0 µs to 1.03 µs. | Measure the complete desktop stats request at normal polling cadence with the same containers and XPC calls. |

[gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [gamma_pilot.py](../../scripts/relaybench/gamma_pilot.py) · [host-topology-local.json](../benchmarks/2026-11-23/host-topology-local.json) · [native-stats-selection.json](../benchmarks/2026-11-23/native-stats-selection.json)

## Storage, file sharing and reclaim

[Update directions in #238](https://github.com/castlemilk/micropod/issues/238#issuecomment-7091858072) · 20 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 238.01 | Guest-native hot volumes vs host bind mounts | Ready | The worker already uses ext4 and supports a shared workspace. The matched placement comparison is outstanding. | Move source, generated outputs or package caches one at a time. Record build time, edit visibility and product hashes. |
| 238.02 | APFS cloned raw disks | Measured | In four balanced local APFS rounds, eight 4 KiB writes added 32 KiB of private allocation when adjacent and 128 KiB when separated by 64 KiB. Rewriting the same offsets added zero. st_blocks stayed constant. | Compare allocated private bytes, first build and first private write on the actual cloned worker disk with the same write locality. |
| 238.03 | ASIF immutable base, cache and thin overlay | Conditional | The proposed shallow stack needs a compatible host. Third-party sequential rates use other workloads. | Compare cold clone, first write, hot reads and allocated bytes against raw disks on the same host and guest. |
| 238.04 | virtio-blk vs multi-queue virtual NVMe | Conditional | The NVMe controller configuration type-checked on SDK 26.5. It still needs a matched guest device and I/O control. | Compare disposable file-backed devices with the same filesystem and guest data. Verify I/O size, queue count and durable results. |
| 238.05 | ext4 fast commit and directory hashing | Conditional | Using the same cached formatter and ordered-journal settings as a new worker produced superblock flags 0x020c. FAST_COMMIT and DIR_INDEX were both clear. The archived worker readback records ordered data and barriers. Existing disks need their own readback. | Confirm actual superblock flags on each disk before timing. Use a separately formatted candidate, enough entries to exercise indexed directories, and recovery of acknowledged writes. |
| 238.06 | ext4 iomap, small direct I/O and parallel writes | Open | The archived ext4 mount reports dioread_nolock. In 7.3.5 direct I/O eligibility is per file, and extending or partial-block writes can serialize. The available receipt does not identify a scored direct-I/O file operation. | Separate aligned overwrites of allocated extents from extension and unaligned I/O. Record actual completion path, concurrency, sync policy and bytes. |
| 238.07 | btrfs no-holes and fsync | Conditional | The pinned 7.3.5 worker config disables BTRFS_FS. The existing ext4 result cannot exercise btrfs no-holes or fsync. | Qualify a separate btrfs-capable image and restart recovery before measuring an identical tree. |
| 238.08 | Per-request RWF_DONTCACHE | Ready | Pinned Linux 7.3.5 ext4 advertises FOP_DONTCACHE. OverlayFS does not advertise it, and DAX is ineligible. A container root can therefore exercise a different path from its guest-native data volume. A bounded arm64 probe now verifies the mount, return code and 4 KiB data digest. | Use a known directly mounted non-DAX ext4 file and an OverlayFS control. Verify return codes and identical contents before measuring cache impact. |
| 238.09 | VirtioFS metadata caching | Open | Attribute lifetime, negative lookup, stat and create/delete all affect developer-visible edits. | Benchmark each operation and detect stale reads, rename visibility and concurrent edits. |
| 238.10 | FUSE passthrough and io_uring zero-copy pools | Conditional | FUSE passthrough is disabled in the archived stock config. A custom server and compatible features are prerequisites for pooled I/O. | Verify both endpoints and kernel support. Measure copy cost, memory and read/write correctness under churn. |
| 238.11 | Read-only host projection of guest volumes | Open | NFSv4 over vsock is a proposed path for Finder/IDE access while writes stay on guest ext4. | Verify read-only semantics, stale file handling, restart and active build time. |
| 238.12 | File edit visibility across mounts | Measured | Subtree scans cut a nested edit from 18.13 to 1.05 ms with 256 unrelated files. Indexing exchanged paths then cut deletion from 420 to 240 µs and duplicate delete events from 241 to 62 µs with 2,048 unrelated files. Duplicate events on eight files stayed near 80 µs. Initialization footprint grew by about 192 KiB in the large fixture. | Time automatic event-to-guest propagation, reflection in both directions, deletion storms and memory on realistic workspaces. |
| 238.13 | Durable writes, restart and physical allocation | Ready | The local disposable APFS trial retained 256 write/fsync samples and verified file hashes. The historical ext4 worker captured ordered data, barriers, sectors and flushes. Restart survival of newly acknowledged writes remains open. | Perform the staged durability comparison on an owner-released disposable worker and verify bytes after restart. |
| 238.14 | zram compressed swap | Conditional | Stock config has SWAP=y and explicitly disables ZRAM and ZSWAP. There is no current zram worker arm. | Build a separate zram image, then compare compression CPU, PSI, OOM and rebuild latency under matched pressure. |
| 238.15 | MGLRU and Swap Table Phase IV | Ready | Stock builds LRU_GEN and page-table walks, with LRU_GEN_ENABLED disabled by default. Effective MGLRU state may differ on a boot. | Read the current boot’s enabled mask, then change only MGLRU policy for the pressure workload. |
| 238.16 | Guest RAM cap and touched high-water mark | Ready | The sampler now distinguishes RSS, physical footprint and lifetime peak with process birth identity. A disposable process went from 7.013 to 15.418 to 7.013 MB after touching and unmapping 8 MiB. Its peak stayed elevated. | Bind the VM helper and supervisor separately and measure build, idle and rebuild at each memory cap. |
| 238.17 | Traditional balloon under host pressure | Conditional | The VZ traditional balloon target type-checks on SDK 26.5. The new host footprint observer is qualified only on a disposable process. | Pair actual negotiated balloon and guest pressure with identified host footprint, system pressure and time to rebuild. |
| 238.18 | userfaultfd RWP working-set tracking | Conditional | The research proposes tracking cold pages before implementing a tiered reclaim policy. | Qualify the available interface and measure tracking overhead and classification error first. |
| 238.19 | Cold first build versus partially warm Go caches | Ready | With verified empty Go stores the local build took 3.702 s and ran 106 compiler/assembler commands. Changing only main on the primed cache took 0.175 s and ran one. The old cold-build check accepted that partially warm case. | Match first builds across engines with empty action caches, identical preloaded modules, no pre-existing binary and a verified output hash. Score guest boot and module fetch separately. |
| 238.20 | Batch compatible packages when preparing a Go test suite | Measured | In a six-package native fixture, prepared-suite compile time fell from 5.180 to 4.615 s cold (2 samples per arm) and 0.989 to 0.440 s warm (6 per arm). All 13 generated files matched across 16 runs and all 96 packaged tests passed. | Measure a changed revision on the actual CI worker with 2–32 eligible packages and compare matching work on OrbStack. Exact image-tag hits bypass compilation. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [volume_durability.py](../../scripts/relaybench/volume_durability.py) · [edit_visibility.py](../../scripts/relaybench/edit_visibility.py) · [gamma-worker-sizing.md](../benchmarks/2026-11-21/gamma-worker-sizing.md) · [research-kernel-capabilities.md](../benchmarks/2026-11-23/research-kernel-capabilities.md) · [edit-visibility-local.json](../benchmarks/2026-11-23/edit-visibility-local.json) · [apfs-cow-local.json](../benchmarks/2026-11-23/apfs-cow-local.json) · [dontcache-probe.json](../benchmarks/2026-11-23/dontcache-probe.json) · [process-footprint-local.json](../benchmarks/2026-11-23/process-footprint-local.json) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json) · [shared-view-directory-local.json](../benchmarks/2026-11-23/shared-view-directory-local.json) · [first-go-build-local.json](../benchmarks/2026-11-23/first-go-build-local.json) · [shared-view-index-local.json](../benchmarks/2026-11-23/shared-view-index-local.json) · [go-suite-compile-local.json](../benchmarks/2026-11-23/go-suite-compile-local.json)

## Custom virtio transport and memory reporting

[Update directions in #239](https://github.com/castlemilk/micropod/issues/239#issuecomment-7091859108) · 6 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 239.01 | Custom-device API and queue lifecycle | Conditional | The local 26.5 SDK rejects customVirtioDevices and VZGuestMemoryMapping at compile time. Nine established host APIs in the matrix type-check. | Use a macOS 27 host and matching SDK, then compare a stock device and candidate on that same host. |
| 239.02 | Multi-queue virtio-net | Conditional | The stock-device queue count and the custom-device queue count need independent observation. | Compare one queue with multiple queues, holding guest CPUs, offered traffic and host workers fixed. |
| 239.03 | Packed rings and mergeable RX buffers | Conditional | The old stock 6.18.35 guest’s eth0 already negotiated packed rings with mergeable buffers clear. Neither the revised worker nor a custom device has a matched result. | Capture both endpoints’ negotiated bits, then change one feature on a supported custom-device host. |
| 239.04 | EVENT_IDX, interrupt suppression and GSO | Conditional | The archived stock NIC negotiated EVENT_IDX. The local decoder now records it alongside packed rings and notification coalescing. | On the new guest, measure actual notifications per GiB under bulk plus fresh arrivals before changing coalescing. |
| 239.05 | Zero-copy L4 ring with guest memory mapping | Conditional | A custom ring is an alternative to the network-device path. It has no qualified Micropod throughput result. | Test bounded flow control, byte identity, half-close, revocation and recovery before mixed traffic. |
| 239.06 | Free-page reporting and host MADV_FREE | Conditional | SDK 26.5 lacks VZGuestMemoryMapping. Host physical-footprint readback now has an independent process check. There is no custom-device reclaim result. | On a supported host, verify free-page reporting and reclamation with incompressible pages, pressure and rebuild time. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [gamma-vnic.md](../benchmarks/2026-11-21/gamma-vnic.md) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json) · [process-footprint-local.json](../benchmarks/2026-11-23/process-footprint-local.json)

## Alternative VMM and isolation tier

[Update directions in #240](https://github.com/castlemilk/micropod/issues/240#issuecomment-7091860155) · 8 directions

| ID | Direction | Status | Evidence so far | Next check |
| --- | --- | --- | --- | --- |
| 240.01 | Residual ceiling and backend decision | Conditional | Current VZ networking recovery has VZ-specific code. The upstream alternate manager builds on Linux. | Locate a repeatable residual bottleneck and quantify the improvement needed after the stock and custom-device trials. |
| 240.02 | Direct HV vCPU threads | Conditional | The arm64 Hypervisor.framework hv_vcpu_run entry point type-checked with SDK 26.5. The product’s Linux worker still uses the VZ manager. | Require a measured residual ceiling, then isolate host thread scheduling on a minimal matched guest. |
| 240.03 | Virtual interrupt controller and IPI delivery | Conditional | hv_gic_create type-checked against the ARM64 SDK 26.5. Guest interrupt setup and lifecycle remain unqualified on a second backend. | Qualify guest boot, interrupt delivery, suspend and teardown before timing. |
| 240.04 | VM exits, notification batching and vectorized GSO | Conditional | Reducing exits or improving packet batching is a backend hypothesis. | Count exits and interrupts per GiB under bulk and simultaneous fresh arrivals. |
| 240.05 | VirtioFS cache and DAX control | Conditional | A custom backend could expose file-server controls unavailable through the current manager. | Compare cold/warm metadata, coherency, rename/delete visibility and host allocation. |
| 240.06 | Backend memory reclaim | Conditional | Other VMMs’ results do not establish Micropod host memory recovery. | Track host reclamation and guest rebuild under identical pressure for each qualified backend. |
| 240.07 | Retain VZ for compatible guests and qualify translation | Conditional | The proposed dual backend changes capability selection for Linux, macOS guests and Rosetta/FEX. | Define a capability matrix and compare amd64 correctness, first-use and steady-state cost. |
| 240.08 | Opt-in VM per container | Ready | The CLI already routes digest-pinned untrusted CI jobs to SandboxVM.isolatedCIJob in apple-vm mode. The shared-worker concurrency study cannot score that separate-VM path. | Use the existing per-job VM entry point to measure launch-to-ready, verified guest identity, idle/active footprint and teardown against matched shared-worker jobs. |

[2026-11-23-transport-storage-evidence.md](2026-11-23-transport-storage-evidence.md) · [gamma-throughput-gap.md](../benchmarks/2026-11-23/gamma-throughput-gap.md) · [apple-sdk-controls.json](../benchmarks/2026-11-23/apple-sdk-controls.json) · [CICommands.swift](../../Sources/MicropodCLI/CICommands.swift) · [SandboxVM.swift](../../Sources/MicropodRuntime/SandboxVM.swift) · [ci-worker.md](../ci-worker.md)
