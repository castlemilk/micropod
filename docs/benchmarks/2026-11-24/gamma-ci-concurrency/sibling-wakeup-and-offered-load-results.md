# Scheduling and offered request load on Gamma

With eight ordinary-priority Go builds running at 64,000 offered HTTP requests/s, Micropod's scheduled-arrival p95 was 2.00 ms to OrbStack's 3.64 ms. Micropod led in all eight windows. OrbStack finished the builds sooner in every window and had the lower p95 after dispatch. [Ordinary CI build priority](#ordinary-ci-build-priority)

Each engine ran 32 HTTP client containers paired with 32 service containers on four vCPUs and 4 GiB. Eight of the clients also built two distinct Go revisions, ran vet, passed eight tests per revision and executed the resulting binaries. The 32 pairs shared one internal IPvlan L2 network per engine during timing. Micropod assigned each job and its dependency to the same vCPU using the native CPU group label. OrbStack received the observed per-job CPU sets. These runs used the signed worker and the guest IP address allocation change measured in the preceding stage. [Worker and network placement measurements](sibling-latency-and-placement-results.md)

## Matching the offered request rate

The saturation trials let each client send its next request as soon as its previous response completed. The fixed-demand trials gave both engines the same staggered schedule across 32 warmed HTTP/1.1 connections. Each 1.5 s window prescribed 96,000 requests at 64,000/s, 192,000 at 128,000/s, or 240,000 at 160,000/s. A late client kept every scheduled request and drained them in order. Each engine ran the same client executable. Two fresh Micropod boots supplied four windows each at every rate. The two seeds reversed the order of the three rates. [Client source used for these runs](20261125T003342Z-sibling-fsukzq2b/quiet-http.go) · [First measured plan](20261125T003342Z-sibling-fsukzq2b/plan.json)

Arrival-to-completion latency starts at the prescribed due time. Call latency starts when the client dispatches its HTTP request. The client recorded both times and the response completion on a monotonic clock, plus the issuing thread's Linux timer slack. The replay checks every ordinal and stable socket, accounts for requests past the deadline, and compares actual completion times with the first of eight builds to finish. The serialized clients use a high-resolution timer as part of this workload. The saturation trials in the following sections used continuously busy sockets. [Live scoring](sibling_paced.py) · [Independent raw replay](sibling_paced_results.py)

| Offered requests/s | Arrival p95, Micropod / OrbStack | Arrival p99, Micropod / OrbStack | Call p95, Micropod / OrbStack | Drain after 1.5 s, Micropod / OrbStack | Eight builds, Micropod / OrbStack |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 64,000 | 0.664 / 2.871 ms | 3.237 / 5.781 ms | 401 / 265 µs | 0.365 / 3.713 ms | 3.075 / 2.840 s |
| 128,000 | 142.983 / 160.651 ms | 206.303 / 220.738 ms | 848 / 321 µs | 121.256 / 65.885 ms | 3.513 / 3.277 s |
| 160,000 | 536.152 / 669.384 ms | 622.265 / 776.045 ms | 870 / 352 µs | 513.034 / 354.653 ms | 3.905 / 3.532 s |

At 64,000/s Micropod had lower arrival p95 in all eight windows and lower arrival p99 in seven. The directly measured dispatch-lateness p95 was 233 µs on Micropod and 2,549 µs on OrbStack. At 160,000/s, 24.0% of Micropod requests and 20.0% of OrbStack requests finished after the nominal offer interval in the median window. Both engines retained and completed those calls. At 160,000/s, Micropod had lower arrival p99 in all eight windows, while OrbStack had lower median arrival latency and finished draining sooner in all eight. At 128,000/s, arrival p99 favored each engine in four windows. The median within-window Micropod/OrbStack p99 ratio was 1.060. The table reports the median of each engine’s per-window percentiles. [Fixed-demand replay by rate and boot](sibling-fixed-demand-summary.json)

Each engine completed all 4,224,000 prescribed requests across the three rates. The last response in every one of the 48 engine-windows finished while all eight builds were still active. The smallest margin to the first build exit was 1.222 s. Every issuing thread reported 50 µs of timer slack on both engines. OrbStack stayed on one boot across the six Micropod boots. [Build overlap and timer readbacks for each window](sibling-fixed-demand-summary.json)

## Ordinary CI build priority

At 64,000 requests/s, four fresh Micropod boots ran nice +5, 0, 0 and +5, with both settings tested on each of two seeds. Each boot contributed four paired windows using the same frozen client and build scripts. Each engine’s eight build dispatchers read their absolute nice value before invoking the compiler. The HTTP clients and services used their ordinary priority. The Micropod guest used high-resolution scheduler ticks, next-buddy wakeups and a 125 µs base slice throughout. Host idle sampled before the four boots was 88%, 84%, 89% and 86%. The OrbStack guest stayed warm. [Control plan](20261125T005910Z-sibling-h7rpq0r9/plan.json) · [Ordinary-priority plan](20261125T010034Z-sibling-jo5uu2_x/plan.json) · [Dispatcher receipts](20261125T010034Z-sibling-jo5uu2_x/grouped-0-all-A-go.json)

| Median of eight windows per priority | Micropod nice +5 | OrbStack nice +5 | Micropod nice 0 | OrbStack nice 0 |
| --- | ---: | ---: | ---: | ---: |
| Scheduled arrival to completion, p95 | 1.522 ms | 3.634 ms | 2.001 ms | 3.644 ms |
| Scheduled arrival to completion, p99 | 7.405 ms | 9.531 ms | 7.087 ms | 8.199 ms |
| Dispatch to response, p95 | 534 µs | 346 µs | 773 µs | 323 µs |
| Dispatch lateness, p95 | 1.033 ms | 3.233 ms | 1.508 ms | 3.302 ms |
| Drain after 1.5 s | 0.534 ms | 3.637 ms | 1.334 ms | 6.800 ms |
| All eight builds finished | 3.373 s | 3.049 s | 3.269 s | 3.014 s |

At ordinary priority Micropod had lower arrival p95 in eight of eight engine comparisons and lower arrival p99 in five. OrbStack finished the eight builds sooner in every comparison and had the lower dispatch-to-response p95 in all eight. On Micropod, raising the builders from +5 to 0 reduced the build makespan by a median paired 1.8% and raised arrival p95 by 37.9%. Five of eight paired windows moved in each of those directions. All 3,072,000 prescribed requests completed across these four boots. The smallest margin between the final response and the first build exit was 1.367 s. [Matched priorities, raw replay and build overlap](sibling-fixed-demand-build-priority-summary.json)

Both engines had the same per-job placement in each boot, with eight pairs and two builders per vCPU. The allocator changed the numeric vCPU of 15 of 32 pairs between priorities in the first seed and 13 in the second. This also changed which paced arrivals shared a vCPU. The evidence for the priority tradeoff comes from two independent boot pairs on this worker profile. [First-seed placement at nice +5](20261125T005910Z-sibling-h7rpq0r9/grouped-inventory.json) · [First-seed placement at nice 0](20261125T010034Z-sibling-jo5uu2_x/grouped-inventory.json) · [Second-seed placement at nice 0](20261125T010158Z-sibling-c2d5gd5u/grouped-inventory.json) · [Second-seed placement at nice +5](20261125T010323Z-sibling-unhrs0sx/grouped-inventory.json)

## macOS launch role

The Standard and Interactive roles each ran on two independent worker boots, in reversed order on the second seed. Each boot contained four balanced Micropod and OrbStack windows. The OrbStack VM stayed warm across worker boots. The measurements checked the launchd spawn type, eight builders, 32 warmed connections, completion timestamps, output hashes, container resource limits and teardown. The 125 µs high-resolution scheduler and next-buddy wakeups were active on every boot. Before-boot host idle was 94–95%. [Standard role readback](20261125T000229Z-sibling-rjwji1a6/launch-role.json) · [Interactive role readback](20261125T000355Z-sibling-s72ahjrt/launch-role.json)

| Median across eight windows per role | Micropod Standard | OrbStack alongside Standard | Micropod Interactive | OrbStack alongside Interactive |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 181,241 | 167,736 | 181,168 | 168,771 |
| Request p50 | 21 µs | 146 µs | 21 µs | 147 µs |
| Request p95 | 642 µs | 327 µs | 642 µs | 318 µs |
| Request p99 | 1.002 ms | 1.057 ms | 1.011 ms | 0.982 ms |
| Requests finished by the least-served client | 7,369 | 5,048 | 7,414 | 5,279 |
| All eight builds finished | 3.376 s | 3.244 s | 3.369 s | 3.253 s |

Micropod won saturated throughput in all 16 windows. Interactive left Micropod p95 and throughput essentially unchanged. The recorded role belongs to the launched worker supervisor. The scheduling classes of its individual vCPU threads remain unmeasured. [Raw replay and paired comparisons](sibling-group-host-role-summary.json)

## A deadline bound in the Linux guest scheduler

Linux EEVDF normally chooses a runnable task that is owed CPU time and has the earliest virtual deadline. With next-buddy enabled, Linux can give the CPU directly to an eligible task that has just been nominated. That shortcut often helps the two ends of a TCP exchange run back to back. The experimental switch made the picker consult the eligible-deadline tree first. It accepted a nominated task within one-quarter base slice of the earliest eligible deadline, weighted for that competing task. A rejected nomination returned the ordinary earliest eligible task, including a delayed task that Linux would dequeue before choosing again. [Linux EEVDF documentation](https://docs.kernel.org/scheduler/sched-eevdf.html) · [Exact kernel patch](bounded-buddy.patch)

Both settings used the same Linux 7.3.5 arm64 Image with a 2.1 ms base slice, high-resolution ticks and next-buddy enabled. All 97 compiler-package versions, the source archive, build timestamp, embedded config and 16 KiB ABI matched the IPvlan parent. The verifier also rejected the unpatched Image when substituted for the experiment. Guest readback confirmed a single feature change. [Build receipt](20261125T001531Z-sibling-z1blr0bg/bounded-kernel.json) · [Switch off](20261125T001531Z-sibling-z1blr0bg/fair-scheduler.json) · [Switch on](20261125T001659Z-sibling-9e5br_bt/fair-scheduler.json)

| Eight-window median | Micropod, off | OrbStack reference | Micropod, on | OrbStack reference |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 238,176 | 168,216 | 224,606 | 166,611 |
| Request p95 | 114 µs | 324 µs | 576 µs | 329 µs |
| Request p99 | 3.431 ms | 1.019 ms | 3.243 ms | 0.998 ms |
| All eight builds finished | 3.323 s | 3.273 s | 3.313 s | 3.281 s |

The bound reduced p99 in all eight matched windows, with a median paired reduction of 5.8%. It also raised p95 in all eight, lowered throughput in seven and reduced the completion count of the least-served client in seven. The switch remains confined to the experimental Image. [Matched replay](sibling-group-bounded-buddy-summary.json)

## Scheduling only the build processes

This crossover used the 125 µs worker profile and compared Linux `SCHED_NORMAL` and `SCHED_BATCH` at nice +5. Both engines ran the same launcher. Each build archived scheduling readbacks from its dispatcher and an ordinary child. The warmed HTTP processes and the 64 resident HTTP listeners retained ordinary scheduling, their CPU masks and nice zero. Micropod's build processes inherited a 125 µs slice, and OrbStack's inherited 2.1 ms. Each engine kept its own slice through the policy change. [Linux launcher](sibling_build_policy_linux.go) · [Normal build receipts](20261125T002118Z-sibling-i1vd5w7d/grouped-0-all-A-go.json) · [Batch build receipts](20261125T002314Z-sibling-8jcsfxf0/grouped-0-all-A-go.json)

| Eight-window median | Micropod, normal | OrbStack, normal | Micropod, batch | OrbStack, batch |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 180,163 | 168,110 | 180,521 | 168,096 |
| Request p95 | 643 µs | 326 µs | 646 µs | 327 µs |
| Request p99 | 1.010 ms | 0.987 ms | 1.012 ms | 1.125 ms |
| All eight builds finished | 3.400 s | 3.240 s | 3.382 s | 3.339 s |

The median paired Micropod changes were +0.38% in throughput, +0.18% in p95, −0.05% in p99 and −0.63% in build time. Four of eight paired builds finished sooner. OrbStack's p99 rose under batch, accounting for most of the change in the peer-relative tail comparison. [Matched replay](sibling-group-build-policy-summary.json)

### Shortening the compiler's CPU slice

Both engines used a 2.1 ms inherited slice on the build processes in this crossover. The launcher verified that the control retained it and that the candidate's actual dispatcher and forked child received 250 µs. The HTTP threads in each engine kept their observed 2.1 ms slices. Both build settings used ordinary scheduling at nice +5. [Inherited slices](20261125T004834Z-sibling-820qn2rq/grouped-0-all-A-go.json) · [250 µs child readbacks](20261125T005009Z-sibling-_0arv0mc/grouped-0-all-A-go.json)

| Eight-window median | Micropod, inherited | OrbStack, inherited | Micropod, 250 µs | OrbStack, 250 µs |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 202,148 | 145,350 | 191,607 | 147,443 |
| Request p95 | 186 µs | 425 µs | 208 µs | 420 µs |
| Request p99 | 4.001 ms | 1.320 ms | 4.453 ms | 1.332 ms |
| All eight builds finished | 3.824 s | 3.686 s | 3.832 s | 3.562 s |

Shortening the compiler slice increased Micropod p99 in all eight matched windows, by a median paired 11.0%. At 250 µs, throughput fell by a median paired 6.6%. Build makespan improved in five of eight windows, by a median paired 1.47%. The inherited 2.1 ms build slice gave Micropod better saturated HTTP throughput and p99. The peer throughput and build times also varied from the earlier guest-kernel crossover, so the comparisons above use their own contemporaneous controls. [Matched replay](sibling-group-build-slice-summary.json)

## 64 KiB anonymous memory allocations on a 16 KiB ABI

Both policies booted the same 16 KiB Image with transparent huge page support. All 22 resolved Kconfig changes matched the reviewed IPvlan parent delta. Only the 64 KiB anonymous policy changed between measured boots. Linux reported every other anonymous order, including the 32 MiB PMD size, disabled. The observer sampled VM-wide allocations, fallbacks, the count of resident 64 KiB folios and host VMM RSS outside the measured windows. The dispatchers also read their own and their waited-for children's page faults and CPU time around the unmodified Go commands. [Image build and config comparison](20261125T004238Z-sibling-sk92xu6e/mthp64-build.json) · [Memory observer](sibling_mthp.py) · [Linux per-size THP counters](https://docs.kernel.org/admin-guide/mm/transhuge.html)

The first config check rejected the correct settings. The Python verifier sorted symbol names and the shell sorted complete assignment lines, which reordered 37 lines including `CONFIG_ARCH_THUNDER` and `CONFIG_ARCH_THUNDER2`. The corrected full-line hash matched the rejected build's resolved config and the retry independently embedded that config in the Image. The regression test also rejects a real extra setting. [First resolver output](../../../../.build/local-kernel-pages/20261125T002733Z-mthp64-jnk65hns/full-16k.log) · [Regression test](test_build_mthp16.py)

| Eight-window Micropod median | 64 KiB never | 64 KiB always |
| --- | ---: | ---: |
| Minor faults summed across the eight build process trees | 394,560 | 237,264 |
| System CPU summed across the build process trees | 1.16 s | 1.04 s |
| Successful 64 KiB anonymous fault allocations per observer interval | 0 | 62,949 |
| Guest memory available after a window | 1,961 MiB | 1,096 MiB |
| Host VMM RSS after a window | 5,611 MiB | 5,971 MiB |
| Resident anonymous 64 KiB folios after a window, converted to MiB | 0 | 1,547 MiB |
| Requests/s | 176,751 | 178,007 |
| Request p95 | 653 µs | 648 µs |
| Request p99 | 1.022 ms | 1.024 ms |
| All eight builds finished | 3.552 s | 3.489 s |

Five of eight matched windows finished their builds sooner, with a median paired improvement of 0.82%. OrbStack's median build times alongside the two policies were 3.324 and 3.362 s. The median available guest memory after the window was 865 MiB lower with the 64 KiB policy. The median paired gap was already 803 MiB before the window and reached 845 MiB afterward. VM-wide allocation counters span 4.55–4.85 s of setup, requests and builds around each 1.5 s HTTP window. [Matched replay](sibling-group-mthp64-summary.json)

## Admission and cleanup

One 64,000/s nice +5 boot stopped during setup. The admission monitor recorded a successful host inspection followed by a timeout before its next OrbStack inventory record. The previous successful inventory contained 34 fixture containers. The boot produced zero measured windows, and cleanup removed its private worker directory without errors. The comparison restarted at the first seed. [Admission log](20261125T005452Z-sibling-igkj13mm/admission.jsonl) · [OrbStack inventory](20261125T005452Z-sibling-igkj13mm/orb-inventory.jsonl) · [Status](20261125T005452Z-sibling-igkj13mm/status.json) · [Cleanup](20261125T005452Z-sibling-igkj13mm/cleanup.json)

Thirty qualified boots completed 1,920 two-revision builds across the two engines. Independent raw replay checked the paced schedules against all 11,520,000 expected responses across the ten fixed-demand boots. During review, the verifier rejected a 1 ns shift in a due time, a missing completion, a replaced warm socket and a comparison between different priority seeds. The original wave replayed successfully afterward. [Paced replay](sibling_paced_results.py) · [Replay regression tests](test_sibling_paced_results.py)

The final audit checked 148 worker scopes, including all 31 from this stage, and the three kernel build attempts. It found zero owned worker directories, launchd jobs, OrbStack containers, networks, volumes or kernel-builder containers. All 24 original baseline files and all 24 preserved copies matched the original SHA-256 manifest. [Cleanup and baseline receipt](sibling-wakeup-offered-cleanup.json) · [Published TCP QoS and relay-worker results](../gamma-qos-and-workers/results.md)
