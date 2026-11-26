# CI dependency traffic inside a 64-container worker on Gamma

The complete signed Micropod worker `fb9a3603` and Linux runner `d8ec1627` served 32 client–dependency pairs on a user-defined internal Docker bridge. Each request traveled between two private container IPs in one Linux guest. Each engine had four vCPUs, 4 GiB and the same arm64 service image. Every container had one CPU of quota, 128 MiB of memory and a 64-PID limit. The Micropod worker booted the 16 KiB Linux 7.3.5 Image, and OrbStack exposed 4 KiB pages. [Signed worker](20261124T204539Z-sibling-kf5k_ct1/worker-build.json) · [Image verification](20261124T204539Z-sibling-kf5k_ct1/images.json) · [Live CPU masks and limits](20261124T204539Z-sibling-kf5k_ct1/same-inventory.json)

Later 64-container runs compared guest scheduler ticks, wakeup preference and receiving-thread time slices with eight simultaneous builds. They include socket-to-scheduler timing for individual requests, ARM timer interrupt counts, and automatic vCPU placement for each CI job and its dependencies. [Linux guest scheduling under CI load](sibling-scheduler-results.md) · [Scheduler intervals and automatic placement](sibling-latency-and-placement-results.md)

## CPU placement

Each comparison kept all 64 containers running. In the quiet case, one client made 200 successive HTTP calls. In the busy case each of the 32 clients made 200 calls to its own service. All clients warmed and verified one private socket, then waited for a common guest deadline. The probe verified the marker, peer IP, socket reuse and zero redials on every request. The measured intervals for all 32 clients overlapped in every busy wave. The shortest common interval covered 24% of its full wave. These are finite bursts of 6,400 requests. [Socket probe](../../../../scripts/netbench/quiet/main.go) · [Fixture](sibling_ci.py) · [Raw receipt verifier](sibling_results.py)

The default placement let both members use guest CPUs 0–3. In the same-CPU placement, the client and its service shared one CPU and successive pairs rotated through all four CPUs. The split placement moved each client to the next CPU while keeping its service pinned. Both engines accepted the same ordinary Docker CPU-set controls. The two independent boots reversed layout order. Each layout had eight within-wave engine comparisons per load, with balanced engine order. [First boot](20261124T204539Z-sibling-kf5k_ct1/plan.json) · [Second boot](20261124T204646Z-sibling-hiv3hvjw/plan.json) · [Replayed results](sibling-placement-summary.json)

| Active pairs | Placement | Median request, Micropod / OrbStack | Request p95, Micropod / OrbStack | Requests/s, Micropod / OrbStack |
| --- | --- | ---: | ---: | ---: |
| 1 | Unrestricted | 72.6 / 38.1 µs | 125.3 / 75.0 µs | 11,682 / 22,093 |
| 1 | Same CPU | 46.7 / 50.2 µs | 77.5 / 79.2 µs | 19,491 / 18,198 |
| 1 | Split CPUs | 77.5 / 71.6 µs | 149.6 / 157.8 µs | 10,207 / 11,561 |
| 32 | Unrestricted | 41.3 / 241.8 µs | 1,418 / 975 µs | 77,178 / 75,417 |
| 32 | Same CPU | 37.1 / 269.5 µs | 1,337 / 783 µs | 83,699 / 84,960 |
| 32 | Split CPUs | 119.0 / 329.2 µs | 1,674 / 940 µs | 65,337 / 70,477 |

The cells show medians of the eight wave statistics. On Micropod, same-CPU placement reduced quiet p50 by a median paired 36.2% and quiet p95 by 35.6%. Both improved in all eight comparisons. With 32 active pairs, throughput rose 10.4% in the paired median and improved in all eight comparisons. Splitting communicating processes across CPUs reduced busy throughput 15.7%, with eight losses. OrbStack’s unrestricted quiet median was lower than Micropod’s same-CPU median. OrbStack also delivered the shorter busy p95 in all eight same-CPU comparisons. [Paired layout and engine results](sibling-placement-summary.json)

The 316,800 timed requests used 1,584 verified warm connections. All run-owned Docker networks, containers and Micropod workers were retired. The original 24 baseline files and their preserved copies matched. [First cleanup](20261124T204539Z-sibling-kf5k_ct1/verification.json) · [Second cleanup](20261124T204646Z-sibling-hiv3hvjw/verification.json)

## Kernel timer frequency

The 250 Hz kernel has a four-millisecond scheduler tick. Some busy p99 measurements fell near that interval. A second 16 KiB Image tested timer frequency directly using the same upstream Linux source, builder, Apple seed, arm64 compiler, 97 packages and build environment. Only the three resolved `CONFIG_HZ` selections differed. Both uncompressed Images had the same length and embedded their verified configs. [Build and config differences](20261124T205549Z-sibling-wmxmqu7b/tick-build.json) · [Reproducible build](build_tick.py)

Four fresh boots alternated kernel order across two seeds. All 422,400 requests completed. With unrestricted placement, raising the tick to 1,000 Hz reduced busy p95 by a paired 9.0%, but the change relative to the OrbStack reference was +0.7%. Quiet unrestricted p99 increased from 161 to 219 µs (+40.3% paired). With same-CPU placement, busy p99 was 4.19 versus 4.20 ms and median throughput was 84,613 versus 81,728 requests/s (−3.9% paired). Median idle VMM CPU during short two-second samples with 64 resident containers was 0.268 versus 0.287 CPU-seconds per second. The 250 Hz kernel remains the benchmark control. [Matched tick trials and peer drift](sibling-tick-summary.json) · [Idle host counters](20261124T205549Z-sibling-wmxmqu7b/same-idle.json)

## Ordinary Linux scheduling slices

Linux lets an ordinary task request a scheduling slice with `sched_setattr`. The probe read back the policy, nice value, real-time priority and effective slice on every observed Go thread. Both engines inherited 2.1 ms and accepted 250 µs under `SCHED_OTHER` at nice 0. The service and client received the same setting. Each of four boots ran two CPU placements, balanced engine order and a 500 ms common deadline for the 32 busy clients. All clients completed the measured requests before encoding their receipts. Across 5,266,074 calls and 2,112 established sockets, the shortest interval shared by all busy clients covered 95% of its wave. [Linux scheduling interface](https://man7.org/linux/man-pages/man1/chrt.1.html) · [Thread probe](sibling_slice_linux.go) · [Peer readbacks](sibling-slice-peer-check.json) · [Full comparison](sibling-slice-summary.json)

| Same-CPU placement, 32 active pairs | Micropod, inherited | Micropod, 250 µs | OrbStack, inherited | OrbStack, 250 µs |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | 190,420 | 153,209 | 163,492 | 161,566 |
| Median request | 18.4 µs | 100.1 µs | 165.3 µs | 167.0 µs |
| Request p95 | 838 µs | 713 µs | 334 µs | 336 µs |
| Request p99 | 2.52 ms | 1.52 ms | 0.65 ms | 0.66 ms |
| Slowest client’s p95 | 1,019 µs | 784 µs | 350 µs | 347 µs |
| Requests completed by least-served client per wave | 2,519 | 2,324 | 2,476 | 2,474 |

With the inherited slice, Micropod delivered 16.6% more requests/s than OrbStack in the paired median and won all eight same-CPU waves. OrbStack had the lower p95 and p99 in all eight. Shortening the slice reduced Micropod p99 by a paired 39.2% and reduced throughput by 18.9%, both in eight of eight comparisons. The least-served Micropod client completed fewer requests in every comparison. Unrestricted placement showed a similar tradeoff, with p99 down 41.6% and throughput down 21.0%. The worker retains the inherited scheduler policy. [Per-wave engine, layout and scheduling comparisons](sibling-slice-summary.json)

## Eight builds sharing a worker with 32 active dependencies

Eight of the 32 HTTP client containers also ran a two-revision Go CI job. The eight builders shared a primed guest cache volume. Each had a one-vCPU quota, 512 MiB and a 192-PID limit. The other 56 containers retained the service limits. Each revision changed a source file, ran vet and eight tests, built an arm64 executable and ran the resulting binary to check its revision. The scorer required compiler, vet and linker invocations, distinct outputs and identical binary hashes across the engines for the same source. These jobs ran through the ordinary Docker API on the signed worker. [Go workload](../../../../scripts/bench_go_fanout.py) · [Concurrent dispatch and verification](sibling_build.py) · [Image receipts](20261124T211213Z-sibling-e6rlp2ji/go-image.json)

The 32 clients warmed their own connections before the builds started. Each build recorded its actual start and its completion on the guest clock. All eight had to run through the entire timed HTTP interval, and every client had to share at least 90% of the planned 1.5 seconds with the others. Clients waited until the last build finished before encoding their per-request logs. The eight-job completion time runs from the first job’s start to the last job’s exit. It excludes warming the cache and starting the containers. An initial 500 ms trial recorded a client starting 79 ms after release and ended at the overlap check. Its completed requests are available separately from the scored series. [Initial 500 ms trial](20261124T210956Z-sibling-32_lqotw/status.json) · [Full 1.5 s run plan](20261124T211213Z-sibling-e6rlp2ji/plan.json)

The priority comparison changed the nice level only on the eight build dispatchers and their children. Each dispatcher read its actual nice value from the Linux process table before release. Two independently ordered boots at each setting supplied eight matched waves per layout. [Linux scheduler nice levels](https://docs.kernel.org/scheduler/sched-nice-design.html) · [First priority control](20261124T211213Z-sibling-e6rlp2ji/plan.json) · [Reversed-order control](20261124T211916Z-sibling-3fdrqxgh/plan.json)

| CPU placement | Build nice | Requests/s, Micropod / OrbStack | Request p99, Micropod / OrbStack | Eight builds finished, Micropod / OrbStack |
| --- | ---: | ---: | ---: | ---: |
| Unrestricted | 0 | 126,024 / 155,622 | 5.41 / 1.51 ms | 2.89 / 3.28 s |
| Unrestricted | +5 | 150,178 / 162,332 | 4.40 / 1.27 ms | 3.08 / 3.34 s |
| Same CPU per pair | 0 | 148,390 / 156,968 | 4.62 / 1.29 ms | 2.92 / 3.21 s |
| Same CPU per pair | +5 | **180,808 / 159,988** | **3.38 / 1.08 ms** | **3.18 / 3.26 s** |

Within same-CPU Micropod, nice +5 improved throughput by a paired 20.8%, cut request p99 by 26.5%, and increased the number of requests the least-served client finished by 87.3%. The eight builds took a paired 9.1% longer. Against OrbStack at the same settings, Micropod led throughput by a paired 12.9% across eight wins and finished the builds first in six of eight comparisons. OrbStack had the lower request p99 in all eight. [Matched build-priority results](sibling-build-priority-summary.json)

The four boots completed 14,939,524 requests and 512 two-revision jobs. At nice +5, Micropod p99 was 4.54 ms for the eight clients also running builds and 2.94 ms for the 24 HTTP-only clients. For requests in each wave’s slowest one percent, the median share of elapsed time between the request-write callback and the first response byte was 99.85%. That interval includes guest scheduling, the service and both TCP stacks. The trace locates the delay within the exchange. Separating those contributors requires server or scheduler timestamps. [Per-client and phase results](sibling-build-priority-summary.json)

## Native Docker CPU shares

The signed Mac worker `fb9a3603` booted the new Linux runner `b4b4bdb7`. The native Docker API accepts `HostConfig.CpuShares`, passes it to containerd through CRI, and advertises support when the Linux CPU controller is delegated. The requested value remained visible through Docker inspect and the kernel weight survived a container restart. On both engines an inherited container had weight 100 and a container with 512 shares had weight 59. On one pinned vCPU under contention Micropod delivered 37.16% of measured CPU time to the lower-weight container and OrbStack delivered 37.14%. Each weighted container used over 99.9% of that vCPU when running alone. Two ordinary containers split the busy vCPU approximately equally. [Runner implementation](../../../../guest/runner/docker_config_linux.go) · [Release identity](20261124T212137Z-sibling-h55n373c/worker-build.json) · [Micropod CPU times](20261124T212137Z-sibling-h55n373c/cpu-weight-A.json) · [OrbStack CPU times](20261124T212137Z-sibling-h55n373c/cpu-weight-B.json) · [Docker CPU shares](https://docs.docker.com/engine/containers/resource_constraints/#cpu)

Four more boots crossed the weight setting at two matched seeds. Both engines used same-vCPU pairs and nice +5 for the eight build processes. The 512-share setting applied to the eight containers running both a build and an HTTP client. Each of the other 56 containers kept its inherited weight. All 8,436,962 requests and 256 two-revision builds completed.

| Same-CPU pairs, eight builds | Micropod, inherited | OrbStack, inherited | Micropod, 512 shares | OrbStack, 512 shares |
| --- | ---: | ---: | ---: | ---: |
| Requests/s | **183,214** | 161,438 | 189,141 | 168,232 |
| Eight builds finished | **3.15 s** | 3.26 s | 3.23 s | 3.30 s |
| Request p95 | 753 µs | 332 µs | 627 µs | 347 µs |
| Request p99 | 3.39 ms | **1.00 ms** | 3.39 ms | 1.07 ms |
| Requests by least-served client per wave | 5,926 | 4,998 | 2,538 | 2,614 |
| Slowest client’s p95 | 1.34 ms | 0.38 ms | 3.79 ms | 1.41 ms |

With inherited weights, the new runner delivered a paired 13.6% more requests/s and finished the builds a paired 3.5% sooner than OrbStack. It led on both in all eight comparisons. Reducing the build containers to 512 shares gave Micropod a further paired 2.9% in aggregate throughput, with six wins in eight. It also cut the least-served client’s request count by 57.4% and increased the slowest client’s p95 by 188.7%. Those two costs appeared in all eight comparisons. For CI with clients that need to make progress alongside their builds, the measured configuration is inherited container weights and nice +5 on the build processes. [CPU allocation, paired performance and client distribution](sibling-cpu-shares-summary.json) · [Worker configuration](../../../ci-worker.md)

Across the two build studies, the scorer replayed 23,376,486 timed requests, 768 jobs, 1,536 built revisions and 12,288 passing workload tests. All 24 disposable fixture scopes from the placement, timer, scheduling and build studies were removed, including four preliminary attempts that stopped at verification. The 24 original baseline files and their preserved copies matched. The guest runner’s main package also passed 36 tests in a fresh arm64 Linux container. The optional standalone Netavark benchmark skipped for lack of its separate test tools. [Guest test output](sibling-cpu-share-tests.txt) · [Final worker cleanup](20261124T212556Z-sibling-p8695rwf/cleanup.json) · [Baseline verification](20261124T212556Z-sibling-p8695rwf/verification.json)

The traffic above used internal guest addresses. The current signed Mac relay’s separate host-published TCP check on Gamma still needs macOS Local Network access. The earlier 16 KiB published-artifact measurements identify the Mac executable used for that path. [Published-path result and permission status](kernel-page-results.md)

To replay the CPU-share comparison from this report’s directory, run

```sh
python3 -B sibling_results.py \
  --pool 20261124T212137Z-sibling-h55n373c 20261124T212556Z-sibling-p8695rwf \
  --compare-to 20261124T212304Z-sibling-vw9cqdjl 20261124T212430Z-sibling-s60ojub6 \
  | cmp - sibling-cpu-shares-summary.json
```
