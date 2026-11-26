# Mixed published-port traffic on Gamma

One warm four-vCPU Micropod VM served 32 simultaneous downloads while the Mac issued a new HTTP connection every 25 ms. The service configuration, executable, memory and CPU limits matched OrbStack. All runs took place on the same shared M5 Max. [Measurements, client traces and reproducible fixtures](gamma-mixed-scheduler.json.gz) · [Previous 24.5% result](gamma-mixed-path.md)

## Production comparison

The shipping configuration uses a single event queue per dedicated Mac I/O worker and a virtual NIC limit of 100 packets per flow. It qualified in 11/12 final four-CPU rounds. In 11 paired rounds with OrbStack the bandwidth difference was **-15.0%** and the median fresh-request p95 was **47.0 vs 1,004.3 ms**. Micropod was faster in 1 of the 11 paired rounds. The 95% paired percentile bootstrap interval for its rate difference is -32.1% to -9.2%, using 10,000 resamples of those blocks.

| Series and Micropod configuration | Valid, Micropod / OrbStack | Common pairs | Micropod / OrbStack MiB/s | Paired rate difference | Fresh p95, Micropod / OrbStack ms |
|---|---:|---:|---:|---:|---:|
| First series, previous release | 12/12 · 12/12 | 12 | 3,547 / 4,146 | -20.8% | 91.4 / 1,005.9 |
| First series, single queue | 12/12 · 12/12 | 12 | 4,117 / 4,146 | -11.1% | 68.7 / 1,005.9 |
| Independent repeat, final host binary, 100 packets | 11/12 · 11/12 | 10 | 4,581 / 5,138 | -0.8% | 42.5 / 1,004.6 |
| Final policy trial, 100 packets | 11/12 · 12/12 | 11 | 4,472 / 5,079 | -15.0% | 47.0 / 1,004.3 |
| Final policy trial, 256 packets | 11/12 · 12/12 | 11 | 4,385 / 5,079 | -17.0% | 41.2 / 1,004.4 |
| Uncapped service, 100 packets | 6/6 · 6/6 | 6 | 2,681 / 3,968 | -32.3% | 115.8 / 808.2 |
| Uncapped service, 256 packets | 6/6 · 5/6 | 5 | 3,931 / 4,918 | -21.9% | 69.7 / 1,005.2 |

The first production single-queue worker beat the previous Micropod build in 6/12 common rounds, with a paired change of -4.4%. An earlier detached-relay screen showed +17.6% in six pairs. A separate chunk-size screen found −2.7% for the same 256 KiB copy size in seven pairs. The single queue removes one kernel queue per data worker and the filter migration on bulk classification. The existing interactive relay uses its original scheduling policy. Lowering the dedicated workers to utility QoS lost all seven paired rounds, and the tested fixed socket buffer caps also failed to improve the result.

The final policy trial ran the same signed host executable for both Micropod workers. Raising the NIC allowance from 100 to 256 packets changed the paired rate by -1.1% across 10 common rounds with 5 wins. The higher allowance qualified in 11/12 attempts. The guest reported the requested 256-packet per-flow limit and 10,000-packet total limit at startup. The decision rule, written before this comparison, required at least ten common rounds, a win in two thirds of them, at least 3% paired throughput gain, fresh p95 within 5%, no increase in failed rounds and six uncapped passes. The worker therefore keeps the 100-packet limit.

Both final Micropod policies qualified in 11 of 12 four-CPU rounds. The failed 100-packet round recorded one reset and zero reopens. The failed 256-packet round recorded 131 resets, 32 deadlines and two reopens. OrbStack qualified in all twelve final four-CPU rounds. In the preceding series, one OrbStack round returned a fresh-request EOF. Failures count against each implementation even when its surviving sockets moved substantial data.

Rates use 240 scheduled arrivals over six seconds. Every qualifying run moved bytes on each of the 32 original sockets, verified the marker and full 8 MiB bodies, and drained without errors or reopens. Each crossover used all six engine orders twice. Times use consecutive blocks on the same shared host. The rate difference is the median of the within-block ratios. Each rate and latency in the table is a median over that row’s common blocks. The uncapped checks used the same timed load with an additional 500 ms observation window at each end. All failed attempts are in the receipt.

## CPU scheduling under fresh arrivals

Three clean 6-second arrival traces put Micropod VMM runnable off-CPU time at 1.81 thread-seconds per second in the first 10 ms after a fresh dispatch and 1.87 between dispatches. Including the fourth trace, which overlapped profiler attachment near the end, gives 1.64 and 1.66. Across the three clean runs the service used 1.53 CPUs and accumulated 1.13 runnable thread-seconds per second. Its cgroup recorded zero quota throttles. During sampled intervals where no download advanced, the Mac VMM used 0.54 CPUs and waited 3.13 thread-seconds/s, compared with 2.03 and 1.84 while bytes moved. This associates the stalls with host scheduling pressure. A dispatch-specific surge was absent in this sample.

A separate Instruments System Trace captured 0.716 seconds wholly inside a 50-second offered-load window. Across four vCPUs it recorded 2.540 CPU-seconds running, 0.179 preempted and 0.062 runnable. Higher-priority work accounted for 0.147 preempted seconds, core rebalancing 0.016, storage interrupts 0.015 and network interrupts 0.00019. Both runtimes’ vCPU threads had base priority 31. The recording perturbed traffic with 122 client resets and 259 deadlines. It establishes which tasks lost CPU in that interval. Arrival comparisons and release throughput come from separate runs. Runnable-off-CPU uses the process rusage runnable-time delta minus its CPU-time delta, converted with the Mac timebase. [Apple scheduler accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/thread.c)

## Bulk notification, guest redirection and pacing

The Mac comparison raised the read watermark after 256 KiB transferred and restored 1-byte readiness within 2 ms so short trailers could finish. All guest lanes below used the same single-queue Mac relay. The raw process and the container used byte-identical service executables. The raw process had the same CPU, memory and PID limits. Both namespace forwarders kept the inbound socket on the private guest NIC and connected to the container’s own address over its local loopback route.

| Path or setting | Valid / 6 | MiB/s | Fresh p95 ms | Paired rate vs ordinary | VMM runnable off-CPU thread-s/s | NIC per-flow drops per run |
|---|---:|---:|---:|---:|---:|---:|
| Ordinary container and both fq policies | 6 | 3,351 | 72.7 | +0.0% | 2.06 | 200 |
| Adaptive 64 KiB NOTE_LOWAT | 6 | 3,604 | 71.1 | -6.1% | 1.82 | 174 |
| Adaptive 256 KiB NOTE_LOWAT | 6 | 3,525 | 71.8 | -22.3% | 1.88 | 133 |
| NIC pacing off | 6 | 2,810 | 126.2 | -31.7% | 2.26 | 158 |
| Service pacing off | 6 | 2,289 | 122.1 | -46.5% | 2.37 | 1,408 |
| Both pacing policies off | 6 | 3,070 | 62.8 | -29.9% | 1.81 | 1,428 |
| Guest splice to the container namespace | 6 | 3,322 | 110.3 | -22.2% | 2.16 | 0 |
| Guest SOCKHASH forwarding | 0 | — | — | — | — | — |
| Raw guest process | 6 | 3,509 | 96.7 | -23.4% | 2.07 | 0 |
| OrbStack reference | 6 | 3,935 | 1,009.2 | +15.7% | — | — |

The VMM counters and interface queue counters bracket each full run, including warmup and drain. The arrival-aligned samples in the CPU section cover only the scored interval.

Linux 6.18.35 on this rig had CONFIG_NETKIT and CONFIG_NET_CLS_BPF disabled. Creating an L3 netkit link returned “Unknown device type”. The running kernel accepted a SOCKHASH and a generic SK_SKB verdict program. The program’s own byte counter recorded 147,929,536,438 bytes redirected. Across six runs the prototype produced 49 fresh-request EOFs. The relay observed guest FIN before the first response on those sampled failures. Its forwarding and close behavior needs work before it can carry published ports. A separate private macvlan experiment beat the ordinary path in five of six pairs (+23.9%). Its gate was in the disposable workload namespace and did not establish the lease and isolation guarantees needed for general Docker containers. [Linux socket-map documentation](https://docs.kernel.org/bpf/map_sockmap.html) · [Linux netkit configuration](https://github.com/torvalds/linux/blob/master/drivers/net/Kconfig)

A separate in-guest syscall trace counted 46 successful splice calls and 16,777,819 bytes across both pipe legs while transferring and hashing one 8 MiB body and checking the marker. It verifies the kernel copy path used by the prototype. [Go Linux TCP splice implementation](https://go.dev/src/net/splice_linux.go)

The prior report’s 4,986 and 2,839 MiB/s figures were medians for a direct raw guest connection and a production-published container. Here both traverse the same Mac relay. The raw process won two of six against the ordinary container. Those paths include different Mac-side work, so their 2,147 MiB/s difference depends on both topology and host conditions. The all-Linux throughput reference also omits the host relay, host TCP and VM boundary. Host scheduling and queue losses vary between blocks.

## Guest NIC queue limits

| Per-flow packets | Valid / 8 | Common with 100 | Paired gain | Wins | Fresh p95 ms | NIC per-flow drops, median | Guest retransmitted segments, median |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 100 | 7 | 7 | +0.0% | 0 | 70.6 | 124 | 49,012 |
| 256 | 7 | 6 | +11.4% | 5 | 55.6 | 0 | 33,952 |
| 512 | 8 | 7 | -0.2% | 3 | 79.4 | 0 | 23,746 |
| 1,024 | 8 | 7 | +8.2% | 4 | 84.3 | 0 | 30,452 |

The 100-packet limit dropped packets before the shared 10,000-packet limit was reached. The higher limits eliminated the median per-flow drops. Linux still counted retransmissions. The policy trial above measures the end-to-end effect of the smallest larger queue in an actual worker. Turning off service pacing increased median NIC per-flow drops from 200 to 1,408. The release keeps fq pacing at both hops. [Linux fair queue implementation](https://raw.githubusercontent.com/torvalds/linux/v6.18/net/sched/sch_fq.c)

## Uncapped EOF and reliability

An uncapped production worker using the previous teardown behavior reproduced a fresh HTTP EOF during a scheduler recording. The client wrote its request from port 52478, saw zero response bytes, and failed about 806 ms later. The relay tied that client to guest-side source port 52538. Its socket reported ECONNRESET (54) after 117 bytes sent, zero received and zero retransmitted. Closing the front socket normally concealed the reset. The guest header rings dropped 8,419 and 8,274 records during that recording, including the failed tuple. The two-sided socket evidence identifies the masking error independently of the kernel packet capture.

The lossless follow-up matched client port 65518 to backend port 49230 using the SYN sequence number. It recorded six inbound SYNs with the same initial sequence. The first RST entered the guest from the Mac-side gateway 36.88 ms after the first SYN on the guest clock. It crossed the container bridge before the service namespace sent its first RST 1.39 ms later. The only 2 outbound resets in the entire capture both belonged to that tuple. The guest TCP trace counted exactly two TCP_FLAGS sends from `tcp_v4_do_rcv`. The tracepoint omitted the remote port for those events. The frames share a TCP sequence across the NIC and bridge. Relative packet timings use only the guest clock because the VM paused during recording. The SYN and reset-only taps both recorded zero drops on both interfaces. Host capture required an administrator password, so the evidence locates the first reset at the Mac-to-VM boundary and leaves the exact host component open. The earlier historical run lacked a socket ID for retrospective attribution.

On the final implementation a backend reset before its first byte triggers an abortive close to the client. An orderly half-close preserves buffered bytes. An accepted request is never replayed after a backend write. Against actual Docker-published containers, 96/96 controlled resets reached the old client as EOFs and 96/96 reached the final client as resets. All 96 data-and-FIN replies on each build verified byte-for-byte. The relay retains retired event objects until the batch is finished and checks the event descriptor before dispatch. The alternating churn fixture saw no misdelivery.

The previous uncapped implementation completed 32 diagnostic relay runs (7,680 fresh requests) and eight in-process runs (9,920 fresh requests) on the same original bulk sockets before the recording reproduced the error. Another 2,000 fixed-rate arrivals completed without the scheduler attachment. During that latter round the host recorded at most 80 TIME_WAIT entries for its private backend against a configured 16,384-port ephemeral range. An idle-header control separately produced an orderly guest FIN after 5.01 seconds, before any upstream bytes had been sent. Both surrounding requests succeeded. This demonstrates the fixture’s five-second HTTP header deadline and distinguishes it from the observed 806 ms reset.

Set `MICROPOD_CI_PORT_PROFILE=1` to record terminal errno, kqueue flags, TCP counters, the original client port, guest source port, pending bytes and lease counters. Terminal SO_ERROR is consumed only when the connection is being retired for an error. A value of −1 on a clean close means it was not sampled. A byte-stream relay cannot infer the expected size of an arbitrary application message. The HTTP client independently validates the service response. [Darwin kqueue socket events](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/man/man2/kqueue.2)

## Reproduction

Run the fixed Go client from the preceding receipt against the published URL and expected marker. Set `MICROPOD_CI_PORT_RELAY=kqueue-throughput` on the worker. The receipt here includes the 12-block order, exact resource readbacks, failures, source hashes, client timelines, both guest interfaces’ TCP control headers and the private diagnostic fixtures. Profiling and timing ran separately. Python aggregates the saved samples and imports the local SQLite record. The workloads and published-port data path do not invoke it. [Fixed-rate client and rig setup](gamma-mixed-path.md)

The local benchmark store uses kind `published_ports` and run `gamma-mixed-scheduler-20261121`. All tests and benchmarks ran locally on Gamma. GitHub Actions stayed off.
