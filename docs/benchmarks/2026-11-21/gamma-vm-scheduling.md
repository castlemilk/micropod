# Published-port throughput and VM scheduling on Gamma

Gamma ran 32 continuous downloads while the Mac opened 40 new HTTP connections per second. Each VM had four vCPUs and 4 GiB configured. Each container had four effective CPUs, a 400000/100000 CPU quota, 1 GiB memory and a 512-process limit. The Micropod container ran on containerd and crun with Linux 7.3.5. The OrbStack guest reported Linux 7.2.12 and Docker Engine 29.8.2. Both runtimes served the same Linux/arm64 image and marker protocol. [Measurements, fixtures and scheduler samples](gamma-vm-scheduling.json.gz)

## Matched warm workers

After each engine received the same three warm-up rounds, the selected detached supervisor with TCP-aware link checks delivered **3,296 MiB/s** and OrbStack delivered **5,062 MiB/s**. The paired throughput difference was **-33.5%** (95% paired bootstrap interval -50.1% to -20.7%). Micropod won 3 of 16 common rounds. Fresh-request p95 was 62.8 ms on Micropod and 1,004.5 ms on OrbStack.

## Installed worker and earlier qualification

The independent installed-release run measured **4,601 MiB/s on Micropod and 4,694 MiB/s on OrbStack**. The median paired difference was **-21.7%** with a 95% bootstrap interval of -47.3% to +19.2%. The preceding qualification on this Mac found −9.5% (−16.2% to +10.6%). [Previous qualification](gamma-direct-macvlan.md)

| Same-block comparison | Clean runs | Common pairs | Throughput MiB/s | Paired change (95% interval) | Wins | Fresh p95 ms |
|---|---:|---:|---:|---:|---:|---:|
| Installed Reno, default polling / OrbStack | 12/12 · 12/12 | 12 | 5,895 · 5,265 | +5.0% (-16.9% to +24.1%) | 7/12 | 33.6 · 210.0 |
| 20 µs with CUBIC / Installed Reno, default polling | 12/12 · 12/12 | 12 | 3,954 · 5,895 | -14.6% (-39.9% to +3.7%) | 3/12 | 53.3 · 33.6 |
| 20 µs with CUBIC and TCP health evidence / 20 µs with CUBIC | 12/12 · 12/12 | 12 | 5,206 · 3,954 | +4.5% (-11.7% to +51.4%) | 9/12 | 38.3 · 53.3 |
| 20 µs with CUBIC and TCP health evidence / Installed Reno, default polling | 12/12 · 12/12 | 12 | 5,206 · 5,895 | -10.3% (-29.6% to +10.4%) | 4/12 | 38.3 · 33.6 |
| 20 µs with CUBIC / OrbStack | 12/12 · 12/12 | 12 | 3,954 · 5,265 | -16.3% (-40.0% to +12.1%) | 5/12 | 53.3 · 210.0 |
| 20 µs with CUBIC and TCP health evidence / OrbStack | 12/12 · 12/12 | 12 | 5,206 · 5,265 | -0.1% (-24.8% to +15.9%) | 6/12 | 38.3 · 210.0 |
| First holdout, Installed Reno, default polling / OrbStack | 12/12 · 12/12 | 12 | 4,669 · 5,441 | -7.9% (-20.0% to +2.4%) | 3/12 | 44.5 · 416.9 |
| TCP-aware watchdog, detached / Installed Reno, default polling | 12/12 · 12/12 | 12 | 4,775 · 3,888 | +14.9% (-4.0% to +36.9%) | 7/12 | 56.0 · 83.7 |
| TCP-aware watchdog, Interactive / TCP-aware watchdog, detached | 5/12 · 12/12 | 5 | 6,314 · 4,032 | +31.8% (-3.9% to +62.5%) | 4/5 | 24.7 · 70.6 |
| TCP-aware watchdog, Interactive / Installed Reno, default polling | 5/12 · 12/12 | 5 | 6,314 · 3,905 | +61.7% (+39.6% to +72.5%) | 5/5 | 24.7 · 89.4 |
| TCP-aware watchdog, detached / OrbStack | 12/12 · 12/12 | 12 | 4,775 · 5,061 | -3.7% (-18.3% to +8.2%) | 4/12 | 56.0 · 477.1 |
| TCP-aware watchdog, Interactive / OrbStack | 5/12 · 12/12 | 5 | 6,314 · 4,997 | +24.0% (+6.7% to +59.7%) | 5/5 | 24.7 · 226.7 |
| Installed TCP-aware watchdog, detached / original | 12/12 · 12/12 | 12 | 4,601 · 5,557 | -20.9% (-32.6% to +8.7%) | 4/12 | 64.9 · 49.6 |
| Installed TCP-aware watchdog, detached / OrbStack | 12/12 · 12/12 | 12 | 4,601 · 4,694 | -21.7% (-47.3% to +19.2%) | 5/12 | 64.9 · 1003.6 |
| Equal warm-up, installed / OrbStack | 16/16 · 16/16 | 16 | 3,296 · 5,062 | -33.5% (-50.1% to -20.7%) | 3/16 | 62.8 · 1004.5 |
| Equal warm-up, installed / original | 16/16 · 16/16 | 16 | 3,296 · 3,355 | -11.9% (-17.7% to +2.2%) | 5/16 | 62.8 · 75.1 |
| Detached scheduling hints / installed | 16/16 · 16/16 | 16 | 2,820 · 3,296 | +2.8% (-15.5% to +21.1%) | 9/16 | 102.2 · 62.8 |
| Detached scheduling hints / original | 16/16 · 16/16 | 16 | 2,820 · 3,355 | -0.4% (-18.1% to +31.2%) | 8/16 | 102.2 · 75.1 |
| Detached scheduling hints / OrbStack | 16/16 · 16/16 | 16 | 2,820 · 5,062 | -42.4% (-53.6% to -30.0%) | 2/16 | 102.2 · 1004.5 |

The installed detached worker with TCP-aware link checks used the original full-preemption Linux 7.3.5 kernel and Reno. Against the original worker in the 12-block three-engine run, its paired throughput difference was -20.9% (-32.6% to +8.7%). The paired interval against OrbStack in that 12-block test crossed parity. The 20 µs/CUBIC setting won its guest screen and lost to Reno in the independent production confirmation. It remains an experimental kernel option.

Each round offered 240 fresh requests on a 25 ms schedule over six seconds. A clean round required every original stream to transfer data, exact byte accounting, 240 arrivals and zero errors or socket reopens. Fresh response time includes client dispatch delay. Rates and latencies in the table are medians over common clean pairs. The percentage is the median within-round rate ratio. The interval resamples paired rounds 10,000 times. All failed attempts are in the receipt. The four-arm confirmation used balanced crossover blocks. The first holdout alternated two engines with new containers on their running VMs. The scheduler trial restored the original Reno kernel and compared the guarded detached and Interactive supervisors. The 12-block installed-package test used all six orders of three engines twice, with newly created services and the side-by-side installed binary. Compilation, active tracers and fault injection ran outside scored rounds.

The four-engine trial with equal warm-up isolated user-initiated supervisor and VM creation priority plus a latency-critical activity on the detached worker. All arms ran 3 warm-up rounds and 16 scored rounds. The stock kernel, Reno, cgroup limits, client and direct publication were identical on the three Micropod arms. The competing Interactive agent and other experimental VMs had stopped. The installed worker was still on the same kernel boot as the preceding 12-block comparison. The scheduling treatment did not meet the promotion threshold. The decision rule and every warm-up are in the receipt.

## Where CPU time went

Gamma’s M5 Max has six Super cores and twelve Performance cores. The Mac kernel recorded thread CPU time by core level. We sampled state and effective priority roughly every 10 ms and clipped to the six-second client window. Process wait subtracts CPU time from the kernel’s runnable-time delta. Thread-group wait estimates eligibility from sampled states and subtracts measured CPU time. Host CPU use sums all threads in the helper, including device I/O, and can exceed four CPU equivalents. Anonymous dispatch threads can perform device I/O. The task-role query required elevated privileges. Both helpers reported nice 0 and had Darwin background mode off. [XNU CPU-level counters](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h) · [Scheduler accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/thread.c)

| Separate diagnostic | Clean windows ≥5 s | Host CPUs used by VM process | VM runnable wait (thread-s/s) | Estimated vCPU wait (thread-s/s) | vCPU time on Super | VM CPU in legacy QoS |
|---|---:|---:|---:|---:|---:|---:|
| Installed Reno, default polling | 4/4 | 2.43 | 1.15 | 0.84 | 21.0% | 100.0% |
| 20 µs with CUBIC and TCP health evidence | 4/4 | 1.86 | 1.63 | 1.23 | 37.8% | 100.0% |
| OrbStack | 4/4 | 5.57 | 4.35 | 0.81 | 25.2% | 100.0% |

In the Micropod switch trace, 0.883 preempted thread-seconds followed a switch to a higher-priority thread in another host process, 0.412 to the kernel and 6.9 milliseconds to the test client or Mac relay combined. This labels the thread that took the CPU at the switch. Other threads can run before the vCPU returns. The trace and per-thread CPU counters both show vCPU scheduling pressure. Neither helper was confined to one core level.

Instruments covered 0.458 s inside the offered load on OrbStack. The four vCPUs spent 1.642 thread-seconds running and 0.171 preempted. The preemption events accounted for 0.105 s higher-priority work, 0.049 s equal-priority work, 0.013 s core rebalancing, 0.004 s storage interrupt.

Instruments covered 1.116 s inside the offered load on Micropod. The four vCPUs spent 2.226 thread-seconds running and 1.577 preempted. The preemption events accounted for 1.208 s higher-priority work, 0.249 s storage interrupt, 0.096 s equal-priority work, 0.015 s core rebalancing, 0.007 s test client or relay, 0.002 s lower-priority work.

The original Micropod recorder left a recoverable Apple kernel event file. We matched the four sampled vCPU IDs and aligned its Mach clock to the Go client window. The 1.116 s overlap contained 7,146 preemptive switch-outs. The four vCPUs spent 2.258 thread-seconds running and 1.576 off CPU after a preemptive switch. Higher-priority replacements accounted for 1.472 s and equal-priority replacements for 0.102 s. We discarded intervals crossing loss markers. [XNU switch records](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/sched_prim.c)

Both vCPU groups sampled at base Mach priority 31. Micropod spent 1.262 of 1.577 preempted thread-seconds below that priority. OrbStack spent 0.000 of 0.171 below it in its separate 0.458 s trace. The short captures expose a difference in effective priority. They do not identify the policy that produced it.

Among higher-priority replacements, known executable families accounted for 0.120 s for other virtualization services, 0.004 s for network services, 0.002 s for filesystem and indexing services. The receipt groups the remaining processes by role.

Across 44 fresh requests with complete 5 ms windows on either side of the actual client dispatch, preempted vCPU time averaged 1.46 thread-seconds per second before dispatch and 1.40 after. It rose in 20 of 44 windows. Those arrivals showed no immediate average jump in preemption. The trace cannot rule out effects later in a request’s lifetime.

In the 16 equal-warm-up rounds, the installed Micropod VM process used a median 1.46 host CPU equivalents and accumulated 1.82 thread-seconds per second of runnable wait. The candidate with higher launch priority used 1.26 CPU equivalents and waited 1.99. The installed worker’s rank correlation between CPU wait and throughput was -0.97.

In the 12 untraced installed-worker attempts, median VM wait was 1.69 thread-seconds per second. The rank correlation between wait and bulk throughput was -0.99. Counters bracketed the whole client attempt, including connection setup.

The original Instruments save for Micropod did not finish. Importing its raw event file recovered the scheduling tables, and an independent decode of the same recording recovered the vCPU switches. The loss marker was at the start. The per-vCPU coverage after rejecting incomplete intervals was at least 99.86%. This diagnostic ran with active instrumentation and local compilation. All throughput scores came from separate runs with both stopped. The one-minute Mac load average ranged from 18.1 to 84.0 over the scored samples.

## Scheduling and guest tuning

| Configuration | Clean | Faster / common | Paired bulk difference | Paired p95 difference | VM runnable wait (thread-s/s) | NIC IRQs/GiB |
|---|---:|---:|---:|---:|---:|---:|
| Detached supervisor | 8/8 | — | reference | reference | 1.65 | — |
| Standard launch agent | 8/8 | 1/8 | -46.6% | +86.8% | 0.37 | — |
| Interactive launch agent | 5/8 | 5/5 | +29.8% | -71.1% | 1.15 | — |
| Interactive agent, user-initiated boot and latency activity | 6/8 | 5/6 | +23.2% | -26.8% | 1.39 | — |
| 0 µs, reno | 8/8 | — | reference | reference | 1.49 | 96 |
| 0 µs, cubic | 8/8 | 5/8 | +10.2% | -27.3% | 1.30 | 106 |
| 20 µs, reno | 7/8 | 4/7 | +2.2% | -11.7% | 1.11 | 93 |
| 20 µs, cubic | 8/8 | 6/8 | +15.3% | -30.2% | 1.02 | 134 |
| 50 µs, reno | 7/8 | 6/7 | +4.8% | -20.6% | 0.94 | 107 |
| 50 µs, cubic | 8/8 | 5/8 | +1.7% | -4.5% | 1.25 | 112 |
| 100 µs, reno | 8/8 | 6/8 | +5.7% | -20.9% | 1.24 | 109 |
| 100 µs, cubic | 8/8 | 4/8 | -5.6% | -4.9% | 1.61 | 114 |

Launchd confirmed daemon and interactive spawn types on the two stock-binary controls. The third launch agent also requested user-initiated VM creation and held a latency-critical activity while published leases existed. The existing two relay queues already use user-initiated QoS. In earlier trials utility QoS lost all seven pairs and larger read low-water marks reduced bulk throughput. [Relay experiments](gamma-mixed-scheduler.md)

All eight guest arms used the same full-preemption Linux 7.3.5 image. The kernel config added CUBIC and a distinct local release suffix. The global congestion controller stayed BBR. We verified the Reno or CUBIC selection for the direct service gateway /32 on a real accepted socket. Positive deferral set two deferred polls and a 20, 50 or 100 µs GRO flush timeout only on the published NIC. The 20 µs CUBIC arm counted more IRQs per GiB than the control. Its throughput gain does not establish fewer VM exits. [Linux NAPI configuration](https://docs.kernel.org/networking/napi.html)

## Link recovery under load

Two failing interactive-launch samples overlapped published NIC reattachments lasting 19.6 and 20.3 seconds. In a separate disposable-worker test we made the guest ARP probe report a miss while keeping ordinary TCP delivery available. The original watchdog lost its established connection (i/o timeout) and failed 2 fresh requests. During the 45-second guarded run the original connection returned 416 verified replies and all 416 fresh connections succeeded. We then took the test VM’s published interface down. A fresh request reached the correct service again after 3.1 seconds, on the same VM instance. Its repair receipt recorded guest-link-restored. The test used isolated workers and left Gamma’s other interfaces in service.

With the TCP-aware watchdog, the Interactive worker still failed seven of twelve scored rounds. A 21.1-second guest-link repair overlapped the last failed attempt. During a later unscored replay, 14 of 15 independent Mac-to-guest ICMP probes also failed in the first burst. The Mac neighbor entry kept the same address. The next burst completed and all 5 probes received replies. No new completed repair was recorded across that replay. These observations locate the interruption below the HTTP relay. They leave its initiating cause open.

During setup, one fresh worker timed out resolving the registry for its pause image. Loading the cached arm64 image through its Docker API restored container startup on the same VM. The receipt preserves that failure separately from the scored traffic windows.

## Reproduction

The helper PID should own the test worker’s `worker.ext4`. Supply the load client’s epoch window to include only complete intervals. The raw receipt includes the Go client, kernel hashes, launch policy, per-round CPU usage, interrupt counters and failures. [Worker network settings](../../ci-worker.md#direct-tcp-ports-on-a-native-mac-worker)

```sh
clang -O2 -Wall -Wextra -o /tmp/mp-vm-profile scripts/profile_vm_scheduler.c
/tmp/mp-vm-profile "$vm_pid" 950 10 > worker-scheduler.ndjson
python3 scripts/summarize_vm_scheduler.py worker-scheduler.ndjson --begin-ns "$begin" --end-ns "$end"
```

Gamma’s installed signed package is `/Users/benebsworth/.micropod/qualified/direct-38e318f9fd8d-62e29296d035`. Its recommended guest image is `/Users/benebsworth/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image`. The explicitly selected CUBIC test image is `/Users/benebsworth/.micropod/kernels/7.3.5-micropod-cc-5a3cb6b86c7b/Image`. Build that variant with `ci/build-worker-kernel.sh linux-7.3.5.tar.xz apple.config OUT full-cubic`. The normal published route uses Reno. The exact test client can be rebuilt by extracting `files["fixed.go"]` from the receipt and running `go build -trimpath`. Python performs offline analysis, outside the worker and its packet path.

The local SQLite run is `gamma-vm-scheduling-20261121`, kind `published_ports`. All qualification ran locally on Gamma. GitHub Actions remained off.
