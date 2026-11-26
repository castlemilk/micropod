# Linux guest scheduling with 64 CI containers on Gamma

Gamma's Apple M5 Max ran 32 HTTP client–service pairs on each engine. Eight clients shared their container with a two-revision Go build. Each build ran vet, eight tests per revision and the resulting ARM64 binary. All eight jobs had to span the common 1.5-second HTTP window. Each worker had four vCPUs and 4 GiB. Pairs rotated across all four CPUs, each pair shared a vCPU, and only the build processes ran at nice +5. Requests used the same checked HTTP executables and image, one warmed socket per pair and a guest-internal Docker bridge. [Workload and CPU limits](sibling-results.md) · [Raw receipt verifier](sibling_results.py)

## High-resolution scheduler ticks

The 16 KiB Linux 7.3.5 guest booted with a 250 Hz periodic tick, a 2.1 ms fair-scheduler base slice, run-to-parity enabled and the high-resolution scheduler tick disabled. The experiment changed one live setting per boot. The worker reported the complete scheduler feature set before and after each change and the ARM architectural timer as its clock source. Two boot orders supplied eight matched load windows per setting. Throughput is completed, validated HTTP requests per second. Build time is the interval from the first job starting to the last one finishing. [Kernel readback](20261124T213609Z-sibling-cjpm8urd/fair-scheduler.json) · [Paired high-resolution tick results](sibling-hrtick-summary.json) · [Run-to-parity results](sibling-run-to-parity-summary.json)

| Guest setting | Micropod requests/s | Micropod p95 | Micropod p99 | Eight builds | OrbStack requests/s | OrbStack p99 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Inherited | 181,984 | 752 µs | 3.38 ms | 3.17 s | 160,286 | 1.04 ms |
| High-resolution tick | 186,606 | 732 µs | 3.13 ms | 3.23 s | 161,573 | 1.00 ms |
| Disable run-to-parity | 182,059 | 720 µs | 3.51 ms | 3.22 s | 161,454 | 1.02 ms |

High-resolution ticks improved Micropod p99 in all eight comparisons, a median paired reduction of 8.0%. Throughput increased 2.0% in all eight, and the builds took 1.9% longer. The paired gain in throughput over OrbStack was 15.2%. The two engines finished their eight builds in 3.23 and 3.25 seconds respectively. Disabling run-to-parity increased Micropod p99 by a paired 3.6%. [Per-engine and paired results](sibling-hrtick-summary.json) · [Run-to-parity comparison](sibling-run-to-parity-summary.json)

## Guest-wide scheduling interval

Six fresh boots kept high-resolution ticks enabled. Two reversed boot orders compared the measured 2.1 ms interval to 1 ms and 0.5 ms. Shortening the interval reduced p99 in all eight comparisons at each setting. It also reduced throughput and increased p95 in every comparison. The 0.5 ms setting reduced the slowest client's p95 by a paired 12.1%. Across the two independent scheduler studies, both engines completed 24,421,292 requests and 768 two-revision builds with 12,288 passing workload tests. [1 ms receipts](sibling-hrtick-1000us-summary.json) · [0.5 ms receipts](sibling-hrtick-500us-summary.json)

| Base slice | Micropod / OrbStack requests/s | Micropod / OrbStack p99 | Micropod p95 | Micropod / OrbStack eight builds |
| --- | ---: | ---: | ---: | ---: |
| 2.1 ms | 184,649 / 162,560 | 3.14 / 0.95 ms | 735 µs | 3.25 / 3.27 s |
| 1 ms | 173,507 / 160,860 | 2.72 / 1.04 ms | 851 µs | 3.27 / 3.27 s |
| 0.5 ms | 163,424 / 159,426 | 2.16 / 1.07 ms | 819 µs | 3.31 / 3.26 s |

The comparisons use medians of matched per-wave ratios for percentages. The tables show medians in the original units. OrbStack ran in each block and used its own guest scheduler throughout.

## Time spent waiting for a vCPU

A separate four-wave run traced one building client and one HTTP-only client per wave, with their corresponding services. The pairs rotated across the guest vCPUs. The worker located each warmed socket by its IP endpoints, inode and descriptor. Byte-identical client and service executables had distinct short process names for the diagnostic. The kernel scheduler supplied their global thread IDs. The verifier matched both TCP byte streams to the request sequence, checked every syscall chain against application timing and checked the per-CPU buffers for lost events. It correlated 55,624 complete requests across 1,093,312 events. The performance tables above use runs with tracing disabled. [Trace replay](sibling_trace_results.py) · [Trace and waveform totals](sibling-socket-trace-summary.json) · [Linux event tracing](https://docs.kernel.org/trace/events.html)

| Traced client | Requests in the wave's slowest 1% | Mean time for those requests | Request leg with server reader runnable, off CPU | Return leg with client reader runnable, off CPU | Between server read and write |
| --- | ---: | ---: | ---: | ---: | ---: |
| Sharing a build | 408 | 6.06 ms | 29.4% | 67.6% | 0.5% |
| HTTP only | 291 | 6.04 ms | 32.2% | 63.2% | 0.6% |

The percentages use the sum of elapsed time in that cohort's tail requests. For each leg, the verifier counted only the time when the thread that eventually completed the socket read was runnable and off CPU. It counted both wakeups and involuntary switches away from a still-runnable thread. The two legs occupy disjoint intervals. The slow exchanges therefore spent 97.1% and 95.4% of elapsed time overlapping a receiving thread's wait for a guest vCPU. The guest clock includes any host-side interruption during those intervals. [Per-pair phase receipts](20261124T215845Z-sibling-jl2f8pnw/same-0-all-A-phases.json) · [Per-vCPU buffer accounting](20261124T215845Z-sibling-jl2f8pnw/same-0-all-A-trace-stats.json)

The eight build containers' CPU controllers recorded just two throttled periods out of 2,531 across the two uninstrumented high-resolution-tick boots. They accumulated 2.47 ms of throttling and 76.59 seconds of CPU use. This puts a separate bound on how often those containers exhausted their CPU quota. [Cgroup counters and per-client results](sibling-hrtick-summary.json)

An initial trace paired outer-container process numbers with guest-global thread IDs and recorded unrelated switches. Its stream failed the socket-event coverage check and contributed zero requests to the attribution. The corrected trace resolves global IDs through scheduler events for the named endpoints. [Initial diagnostic](20261124T214233Z-sibling-cdvkc5lu/same-0-all-A-trace-stats.json) · [Corrected actor identities](20261124T215845Z-sibling-jl2f8pnw/same-0-all-A-actors.json)

## Production worker and fairness under load

The native worker bootstrap accepts `micropod.ci_sched` on the trusted supervisor's kernel command line. It sets the requested guest scheduler state before launching containerd and checks the kernel's readback. The packaged tools were booted alongside signed Mac executable `fb9a3603`, Linux job runner `b4b4bdb7` and the same 16 KiB kernel. A read-only observation of the boot argument, scheduler feature set and base interval confirmed the product setting. [Worker configuration](../../../ci-worker.md) · [Packaged source and identity](20261124T215845Z-sibling-jl2f8pnw/worker-build.json) · [Boot argument](20261124T215845Z-sibling-jl2f8pnw/fair-scheduler/cmdline) · [Effective 0.5 ms interval](20261124T215757Z-sibling-46_fa3wf/fair-scheduler.json)

One preliminary worker timed out at engine readiness. A diagnostic boot traced the guest shell to its write to `sched/features`. The feature took effect, but the command returned a failure and the strict startup script exited. Sending the feature name in a single write fixed startup. The replacement worker reached readiness in about two seconds. [Startup failure](20261124T215405Z-sibling-ae08v9bv/a/service.stderr) · [Guest shell trace](20261124T215644Z-sibling-c0z3__wm/scheduler-start.trace) · [Corrected worker launch](20261124T215757Z-sibling-46_fa3wf/a/launch-state.jsonl)

Fresh workers using the default, 1 ms and 0.5 ms selections each completed the full 64-container workload with eight verified builds per engine. Booting without the argument selected `NO_HRTICK` and a 2.1 ms base slice. Each explicit interval matched the kernel's readback. [Inherited startup](20261124T220838Z-sibling-qnopdad8/fair-scheduler.json) · [1 ms startup](20261124T220749Z-sibling-g7adc1ji/fair-scheduler.json) · [0.5 ms startup](20261124T215757Z-sibling-46_fa3wf/fair-scheduler.json)

With production high-resolution ticks enabled, disabling Linux's delayed dequeue for ineligible tasks changed paired p99 by −0.7% and throughput by −0.6%. Disabling lag preservation across sleep and wakeup produced a much larger effect. Aggregate p99 fell from 3.12 to 2.41 ms, but throughput fell 24.0%, the least-served client's request count fell 60.6%, and the slowest client's p95 rose 91.6%. All three costs appeared in every matched comparison. The production profiles keep lag preservation enabled. [Delayed-dequeue comparison](sibling-hrtick-no-delay-dequeue-summary.json) · [Sleep and wakeup placement comparison](sibling-hrtick-no-place-lag-summary.json)

## A shorter slice for clients sharing build containers

Linux's fair scheduler uses a task's requested time slice to calculate its virtual deadline. The benchmark requested 250 µs only for the HTTP process in each of the eight build containers. Their compiler processes, all 32 services and the other 24 HTTP clients kept their inherited slices. Each engine ran the same ordinary-priority request through `sched_setattr`. The harness used `sched_getattr` to verify the HTTP threads on both engines. All 64 holders and the untargeted HTTP clients kept their inherited interval. [Linux EEVDF scheduler](https://docs.kernel.org/scheduler/sched-eevdf.html) · [Task-level setting and readback](sibling_slice_linux.go) · [Paired controls and per-client cohorts](sibling-build-client-slice-250-summary.json)

| Metric | Micropod inherited | Micropod 250 µs on eight clients | OrbStack inherited | OrbStack 250 µs on eight clients |
| --- | ---: | ---: | ---: | ---: |
| All clients, requests/s | 184,807 | 175,246 | 161,864 | 159,352 |
| All clients, request p99 | 3.08 ms | 3.02 ms | 0.98 ms | 1.10 ms |
| Build-sharing clients, request p99 | 4.55 ms | 2.36 ms | 2.25 ms | 3.93 ms |
| HTTP-only clients, request p99 | 2.67 ms | 3.32 ms | 0.85 ms | 0.95 ms |
| Requests by the least-served client | 6,001 | 7,209.5 | 5,048 | 4,932.5 |
| Eight builds finished | 3.23 s | 3.26 s | 3.26 s | 3.26 s |

The least-served Micropod client completed a paired 19.8% more requests. The slowest client's p95 fell 31.9%. Both improved in eight of eight windows. Aggregate throughput fell 5.4% and the eight builds took 1.4% longer. The short slice benefited the build-sharing clients most and shifted some delay to the 24 HTTP-only clients. OrbStack's build-sharing clients recorded their lower p99 at the inherited setting. [Detailed slice comparison](sibling-build-client-slice-250-summary.json)

A separate four-boot crossover applied the same 250 µs request to all 32 HTTP clients. Services and compilers retained the inherited interval. Micropod p99 fell from 4.48 to 2.37 ms for build-sharing clients and from 2.71 to 2.18 ms for HTTP-only clients. Across all clients, p99 fell from 3.13 to 2.21 ms and p95 from 728 to 531 µs. The least-served client completed 9.1% more requests. Throughput fell from 184,817 to 171,173 requests/s and eight builds took 3.32 seconds. OrbStack at the same setting recorded 168,165 requests/s, 1.15 ms p99 and a 3.29-second build batch. Every matched Micropod window showed the lower p99 and the lower throughput. [All-client time-slice results](sibling-all-client-slice-250-summary.json)

## Preferring the last task woken

The 7.3.5 guest exposes the Linux `NEXT_BUDDY` scheduler feature. With `PICK_BUDDY` enabled, it lets the scheduler prefer an eligible task that another task just woke. A client and its service frequently wake each other on their shared guest vCPU. The four-boot comparison enabled this preference on Micropod while keeping high-resolution ticks, the 2.1 ms base interval and all 64 CPU quotas fixed. [Control feature set](20261124T221443Z-sibling-8ubqp5g0/fair-scheduler.json) · [Changed feature set](20261124T221600Z-sibling-q3otu6rz/fair-scheduler.json) · [Matched measurements](sibling-hrtick-next-buddy-summary.json)

| Metric | Micropod, ordinary wakeups | Micropod, prefer last woken | OrbStack in the preference trial |
| --- | ---: | ---: | ---: |
| Requests/s | 185,944 | 220,711 | 159,810 |
| Request p95 | 728 µs | 179 µs | 337 µs |
| Request p99 | 3.12 ms | 3.62 ms | 1.05 ms |
| Slowest client's p95 | 1,294 µs | 292 µs | 402 µs |
| Least-served client's requests | 6,042.5 | 8,756.5 | 5,000 |
| Eight builds finished | 3.24 s | 3.34 s | 3.29 s |

Micropod gained a paired 19.8% in throughput and reduced p95 by 75.5% against its own control. The least-served client completed 44.2% more requests. P99 increased 16.4%, and build completion time increased 3.5%. Each change had the same direction in all eight comparisons. Against the matched OrbStack windows, Micropod led throughput by 39.4% and reduced p95 by 47.5%. OrbStack had the lower p99, and Micropod's builds took a paired 2.0% longer. [Per-window engine comparisons and client distributions](sibling-hrtick-next-buddy-summary.json)

## Packaged worker with wakeup preference

The final guest bootstrap `3281b15a` sets and verifies both features before starting containerd. The host executable, Linux job runner and kernel image retained their verified hashes. Six fresh boots used the production command-line settings and a read-only guest scheduler observer. Two reversed boot orders supplied eight matched Micropod–OrbStack load windows for each interval. [Packaged worker](20261124T222517Z-sibling-1d9wcai7/worker-build.json) · [Supervisor arguments received by the kernel](20261124T222517Z-sibling-1d9wcai7/fair-scheduler/cmdline) · [Readback on the reversed 0.5 ms boot](20261124T222911Z-sibling-n3_1qpcv/fair-scheduler.json)

| Micropod base slice | Requests/s, Micropod / OrbStack | Request p95, µs | Request p99, ms | Eight builds, s |
| --- | ---: | ---: | ---: | ---: |
| 2.1 ms | 215,997 / 157,481 | 178.5 / 342.3 | 3.66 / 1.06 | 3.34 / 3.29 |
| 1 ms | 216,004 / 160,191 | 709.1 / 335.5 | 3.09 / 0.98 | 3.34 / 3.29 |
| 0.5 ms | 205,768 / 156,010 | 1,082.3 / 353.3 | 2.15 / 1.16 | 3.34 / 3.29 |

At 2.1 ms the packaged Micropod worker served a paired 39.8% more requests than OrbStack and reduced p95 by 47.4%. The least-served Micropod client completed a paired 78.4% more requests. Moving from 2.1 to 0.5 ms lowered Micropod p99 by a paired 41.4% and cost 5.0% in throughput. The shorter interval still delivered 31.9% more requests/s than its matched OrbStack peer, while OrbStack retained the lower p95 and p99. In this workload the 2.1 ms profile favors throughput and p95, and the 0.5 ms profile favors Micropod's slowest requests. [1 ms crossover](sibling-wakeup-base-hrtick-1ms-summary.json) · [0.5 ms crossover](sibling-wakeup-base-hrtick-500us-summary.json)

Across the 36 uninstrumented boots in this report, the verifier replayed 74,764,684 requests, 2,304 two-revision build jobs and 36,864 passing workload tests across the two engines. Each request used the warmed private connection. The consumer checked its service marker, and the two engines produced identical executable hashes for each corresponding build revision. [Verifier](sibling_results.py) · [Build receipts](20261124T222911Z-sibling-n3_1qpcv/same-3-all-A-go.json)

Three additional boots of the final package verified the inherited scheduler, high-resolution ticks alone and wakeup preference alone. The final cleanup audit covered all 48 scopes created for this investigation and all 72 scopes in the sibling benchmark series. It found zero remaining owned launchd jobs, temporary worker directories, OrbStack containers, networks or volumes. The 24 original baseline files and their 24 preserved copies matched their SHA-256 manifest. [Inherited boot](20261124T223303Z-sibling-huwvni7l/fair-scheduler.json) · [Tick-only boot](20261124T223316Z-sibling-ofp4n13u/fair-scheduler.json) · [Wakeup-only boot](20261124T223328Z-sibling-eoe_nqkv/fair-scheduler.json) · [Final cleanup](20261124T223328Z-sibling-eoe_nqkv/cleanup.json) · [Baseline manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)

## Replaying the measurements

From this directory, these commands recompute the high-resolution tick comparison and the syscall attribution from the archived receipts and compare the results byte for byte.

```sh
python3 -B sibling_results.py \
  --pool 20261124T213609Z-sibling-cjpm8urd 20261124T213959Z-sibling-cnbmsobp \
  --compare-to 20261124T213454Z-sibling-6aorlvdi 20261124T214116Z-sibling-dwc83o_v \
  | cmp - sibling-hrtick-summary.json
python3 -B sibling_trace_results.py 20261124T215845Z-sibling-jl2f8pnw \
  | cmp - sibling-socket-trace-summary.json
```
