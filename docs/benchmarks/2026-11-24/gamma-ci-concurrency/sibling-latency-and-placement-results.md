# CPU scheduling, placement and networking with 64 CI containers on Gamma

Gamma ran 32 client–dependency pairs and eight simultaneous Go builds on each engine. Each client reused one verified HTTP/1.1 socket for a 1.5-second capacity measurement. Every build spanned that interval, changed the source twice, ran vet and eight tests per revision, built the program and executed both revisions. The two engines had four vCPUs, 4 GiB and identical container images. Each container had one vCPU of bandwidth. Only the build processes used nice +5. [Workload and raw receipt checks](sibling-results.md) · [Prior scheduler and socket-trace results](sibling-scheduler-results.md)

## Submillisecond scheduling intervals

Each client and its dependency shared one vCPU. Eight fresh Micropod boots tested four Linux fair-scheduler base intervals with high-resolution ticks and wakeup preference enabled. Each interval had two independent boots in opposite order and four matched Micropod–OrbStack load windows per boot. The guest reported its effective features, base interval and architectural clock source. Table entries are medians of the eight window statistics. Percent changes use the median of paired window ratios. [500 µs readback](20261124T223759Z-sibling-mfvkurt2/fair-scheduler.json) · [125 µs readback](20261124T224546Z-sibling-cbgpllwi/fair-scheduler.json) · [Linux fair scheduling](https://docs.kernel.org/scheduler/sched-eevdf.html)

| Micropod interval | Requests/s, Micropod / OrbStack | Request p95, µs | Request p99, ms | Eight builds, s |
| --- | ---: | ---: | ---: | ---: |
| 500 µs | 205,756 / 159,840 | 1,084 / 334 | 2.160 / 0.988 | 3.322 / 3.266 |
| 250 µs | 192,071 / 159,000 | 867 / 339 | 1.460 / 1.022 | 3.371 / 3.260 |
| 125 µs | 168,422 / 160,188 | 667 / 337 | 1.033 / 1.030 | 3.351 / 3.277 |
| 62.5 µs | 139,117 / 160,783 | 581 / 333 | 0.881 / 0.961 | 3.430 / 3.239 |

At 125 µs Micropod led throughput in all eight windows, by a paired 5.7%. P99 split four windows each, with a median paired difference of 0.1%. At 62.5 µs Micropod had the lower p99 in all eight windows and gave up 13.4% of throughput against OrbStack. Both settings took longer to finish the builds. [125 µs crossover](sibling-subms-125us-summary.json) · [62.5 µs crossover](sibling-subms-62500ns-summary.json)

## Production worker and CPU placement

The worker accepts `micropod.ci_sched=hrtick-125us` at boot. The production test combined it with `micropod.ci_wakeup=next-buddy`. The Mac executable and Linux runner matched the 500 µs control byte for byte. The new guest bootstrap begins with SHA-256 `7ca1e6cf`. The build now reuses a verified Linux runner when all its recorded source inputs match. An initial packaging attempt selected Go 1.27.0 for code previously built with 1.27.2. It was excluded before running any comparison. [Production build receipt](20261124T224822Z-sibling-teke8pf4/worker-build.json) · [Production kernel arguments](20261124T224822Z-sibling-teke8pf4/fair-scheduler/cmdline)

Two native boots reversed the order of five placements, giving eight balanced engine comparisons per layout. Both engines received the same masks. The verifier checked Docker inspect, the Linux effective CPU masks and all container quotas. The two-vCPU domains were 0–1 and 2–3. Pairs were distributed evenly across the four vCPUs or the two domains. The table includes the unrestricted placement obtained by omitting the Docker CPU-set flag. [First boot](20261124T224822Z-sibling-teke8pf4/plan.json) · [Reversed boot](20261124T225418Z-sibling-uqhihqig/plan.json) · [Placement contrasts](sibling-subms-placement-summary.json)

| Placement | Requests/s, Micropod / OrbStack | Request p95, µs | Request p99, ms | Eight builds, s |
| --- | ---: | ---: | ---: | ---: |
| Unrestricted | 123,414 / 162,011 | 860 / 446 | 1.431 / 1.257 | 3.400 / 3.400 |
| Same single vCPU per pair | 168,643 / 159,519 | 665 / 337 | 1.032 / 1.017 | 3.430 / 3.274 |
| Same two-vCPU domain per pair | 139,798 / 159,212 | 778 / 412 | 1.243 / 1.154 | 3.351 / 3.372 |
| Client can move within the domain | 151,246 / 160,063 | 749 / 415 | 1.186 / 1.194 | 3.323 / 3.370 |
| Service can move within the domain | 166,950 / 160,123 | 669 / 340 | 1.035 / 1.024 | 3.442 / 3.318 |

The CPU assignment mattered more to Micropod than to OrbStack. Micropod's throughput was 23.6% below OrbStack with unrestricted placement and 4.9% above it with same-vCPU pairs. For applications that can identify their dependencies, the assignment is available through the native Docker `--cpuset-cpus` option. These results cover saturated in-guest HTTP, with the workload and worker size specified above.

## ARM timer interrupts during CI traffic

A separate eight-boot experiment sampled the four guest vCPUs at the boundaries of the common HTTP window. The observer read the GIC architectural timer counts, Linux context switches and softirq counters. The verifier matched both snapshots to the start time recorded by all 32 clients. All 64 snapshots finished within 1.60 ms of their target boundary and each took at most 0.41 ms to read. The table shows medians over two boots and eight windows per setting. [Boundary observer](sibling_counters_linux.go) · [Counter replay](sibling_counters.py)

| Guest setting, with wakeup preference | Guest timer IRQs/s | Guest switches per HTTP completion | Micropod requests/s | Micropod p99 |
| --- | ---: | ---: | ---: | ---: |
| 125 µs, high-resolution tick | 47,601 | 3.34 | 165,346 | 1.048 ms |
| 125 µs, ordinary tick | 28,557 | 2.95 | 194,251 | 2.445 ms |
| 500 µs, high-resolution tick | 26,300 | 2.47 | 205,285 | 2.197 ms |
| 100 µs, high-resolution tick | 54,795 | 3.64 | 158,918 | 0.957 ms |

Disabling the high-resolution tick at the same 125 µs interval increased throughput and more than doubled p99. Moving from 125 to 100 µs increased timer activity again. At 100 µs Micropod had lower p99 than OrbStack in six windows and lower throughput in all eight, by a paired 0.6%. The IRQ counts include all uses of the guest architectural timer. They measure a different event from a host hypervisor exit. The context-switch counts include the eight builds and other guest work. The observer sleeps between its boundary samples and polls for the next gate outside the measured Micropod interval, including during some OrbStack windows. The capacity and placement results above use separate uninstrumented runs. [High-resolution tick comparison](sibling-timer-no-hrtick-summary.json) · [100 µs comparison](sibling-timer-100us-summary.json) · [500 µs comparison](sibling-timer-500us-summary.json)

## Automatic placement for CI jobs

The Docker client can give a job and its dependencies the same label, such as `io.micropod.ci.cpu-group=build-42`. Micropod chooses one available vCPU for that group on its network. In each trial 32 independent groups used all four CPUs, eight pairs and two builds per vCPU. Groups reserved CPUs concurrently. The first eight services were dependencies of the eight builders. On OrbStack the driver applied each actual Micropod assignment with `--cpuset-cpus`. The unrestricted control used ordinary one-CPU quotas on both engines. A second control explicitly striped pairs across the four CPUs in index order. The driver checked effective affinity on Linux threads, resource limits, and Docker inspect before admitting the cohort. [Worker configuration](../../../ci-worker.md) · [Placement qualification](sibling_group.py) · [Offline verifier](sibling_results.py)

Both independent boots with the 125 µs profile qualified. Their three layouts account for 11,263,328 validated requests, 1,584 warm connections and 384 Go jobs across the two engines. Each table entry is the median of eight windows. Startup spans come from Docker's creation and start timestamps for all 64 cached containers, with one cohort per layout and engine per boot. [Paired results and startup timestamps](sibling-job-cpu-group-summary.json) · [Production worker and Linux runner](20261124T232640Z-sibling-i70qsw9t/worker-build.json)

| Placement | Requests/s, Micropod / OrbStack | p95, µs | p99, ms | Eight builds, s | Cached 64-container startup, s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Automatic group, peer matched | 168,351 / 160,180 | 670 / 333 | 1.034 / 0.979 | 3.382 / 3.253 | 1.086 / 2.691 |
| Unrestricted | 124,905 / 161,934 | 849 / 449 | 1.410 / 1.292 | 3.386 / 3.364 | 1.143 / 2.595 |
| Manually striped pairs | 166,395 / 158,347 | 672 / 341 | 1.042 / 1.073 | 3.418 / 3.298 | 1.124 / 2.756 |

Grouping raised Micropod throughput by a paired 34.3% over unrestricted placement and reduced p99 by 26.5%. The least productive Micropod client completed 51.6% more requests. These directions held in all eight windows. Against the explicitly matched OrbStack groups, Micropod led on throughput in all eight windows by a paired 4.5% and on the least productive client's request count by 36.5%. OrbStack had lower p95 and shorter build makespans in all eight. The 125 µs result still leaves a p95 and build-time gap. [Placement contrasts](sibling-job-cpu-group-summary.json)

The 2.1 ms profile lost the original warmed socket on two boots with seed 231801. Both failures occurred under unrestricted placement. In the first boot, client 21 completed 2,143 measured requests on that socket. In the retry, client 16 completed 4,609. Each then opened one new connection. The last good requests spent 50.19 ms and 50.99 ms respectively between the first response byte and completion. The pattern is consistent with the 50 ms wait for write completion in Go's HTTP transport. The receipts establish the redial and its timing. The initiating close was unobserved. Both boots failed qualification and cleaned up. [First rejected boot](20261124T231501Z-sibling-upgseme8/status.json) · [Rejected retry](20261124T231818Z-sibling-l9_8acdi/status.json) · [Go HTTP transport](https://go.dev/src/net/http/transport.go)

All 524,107 measured responses in the two rejected waves passed HTTP status and exact-body checks. Each wave had exactly one post-first-byte wait of 49 ms or longer. The preselected reverse-order seed 231803 qualified on both the 2.1 ms and 125 µs profiles. On its sole qualified boot, grouped Micropod at 2.1 ms delivered 219,766 requests/s against 156,851 for OrbStack, with p99 of 3.668 ms against 1.061 ms. The 2.1 ms profile qualified on one of three attempts. [Raw failure audit](sibling-warm-socket-rejections.json) · [Single-seed comparison](sibling-job-coarse-single-seed-summary.json)

## Internal Docker network drivers

The original worker booted with `CONFIG_MACVLAN=y`, `CONFIG_IPVLAN` disabled and no loadable modules. Bridge and macvlan passed a four-pair smoke test on each engine. Creating an IPvlan endpoint on Micropod returned `operation not supported`. The partial worker and its owned Docker objects were removed. [Bridge smoke](20261124T231038Z-sibling-hp2fowwc/status.json) · [macvlan smoke](20261124T231051Z-sibling-agg27c18/status.json) · [Original IPvlan failure](20261124T231104Z-sibling-a6yrafbp/status.json)

The repaired worker kernel used the same Linux 7.3.5 sources, Apple configuration seed, 97 compiler packages, ARM64 compiler container, build identity and 16 KiB pages. The build script enabled and verified built-in IPvlan. Linux resolved five configuration changes, enabling IPvlan, its L3S helper and L3 master-device support and exposing two disabled dependents. The active Image's embedded configuration matched the archived file. Its SHA-256 starts with `488a83549377`. The private compiler container was removed after the build. [Kernel build receipt](20261124T233527Z-sibling-6eh87kro/ipvlan-build.json) · [Kernel builder and verifier](build_ipvlan.py)

The repaired smoke verified all 16 endpoints across both engines using Linux netlink inside the containers. Each endpoint had kind `ipvlan`, mode `l2`, MTU 1500, its assigned IPv4 address and no default route. Both networks were internal and had no explicit external parent. The six full runs used this same Micropod Image, the same signed Mac worker and the same checked Go workloads on each driver. Each used the 125 µs profile, next-buddy wakeups and four vCPUs. Seeds 231101 and 231103 reversed both network-driver order and placement order. [Repaired endpoint inventory](20261124T233527Z-sibling-6eh87kro/shared-inventory.json) · [Netlink probe](sibling_link_linux.go)

All six boots qualified. Together they verified 23,024,840 requests on 3,168 warmed sockets and completed 768 two-revision Go jobs. The table gives medians across eight paired load windows per row. Host idle sampled for one second before each boot ranged from 92% to 96%. These background readings bracket each boot and do not measure host idle during a timed window. [macvlan comparison](sibling-l2-macvlan-summary.json) · [IPvlan comparison](sibling-l2-ipvlan-summary.json) · [First host sampling receipt](20261124T233542Z-sibling-qm3ohia1/host-load-context.json)

| Internal driver and placement | Requests/s, Micropod / OrbStack | p95, µs | p99, ms | Eight builds, s |
| --- | ---: | ---: | ---: | ---: |
| Bridge, grouped | 169,303 / 157,073 | 661 / 347 | 1.023 / 1.135 | 3.388 / 3.251 |
| macvlan, grouped | 179,816 / 166,971 | 645 / 330 | 1.006 / 1.006 | 3.406 / 3.284 |
| IPvlan L2, grouped | 180,406 / 169,062 | 644 / 321 | 1.005 / 0.979 | 3.378 / 3.268 |
| Bridge, unrestricted | 124,840 / 160,419 | 846 / 443 | 1.412 / 1.301 | 3.338 / 3.356 |
| macvlan, unrestricted | 135,332 / 170,354 | 808 / 440 | 1.378 / 1.268 | 3.344 / 3.352 |
| IPvlan L2, unrestricted | 133,240 / 168,846 | 818 / 447 | 1.377 / 1.356 | 3.365 / 3.341 |

Changing grouped workloads from bridge to IPvlan improved Micropod throughput by a paired 6.3% in eight of eight windows. OrbStack gained 8.2% on the same switch. On grouped IPvlan, Micropod led throughput by a paired 7.5%, and its least-served client completed a median 7,327 requests against 5,186. OrbStack had the lower p95 and shorter build makespan in every window. On grouped bridge, Micropod had lower p99 in seven of eight windows. With unrestricted placement, OrbStack led throughput in every window on every driver. [Matched driver and workload ratios](sibling-l2-ipvlan-summary.json) · [Docker IPvlan networking](https://docs.docker.com/engine/network/drivers/ipvlan/)

Each driver has two independent boots. The two sequences placed macvlan in the middle both times. CPU numbers assigned to individual job groups could vary between boots. Both engines used the same per-job assignments within a boot, with exactly two builders per vCPU. The measurements cover guest-internal traffic on one private network per engine. [Forward CPU assignments](20261124T234101Z-sibling-31q3pjcr/grouped-inventory.json) · [Reverse CPU assignments](20261124T234344Z-sibling-g3488y2m/grouped-inventory.json)

Load level affected the result. With one active client and all 64 containers resident, grouped Micropod throughput fell a paired 9.5% on macvlan and 7.9% on IPvlan relative to bridge. Automatic grouping raised saturated throughput over unrestricted placement by 31.3% on macvlan and 34.8% on IPvlan. [Single-client and saturated windows](sibling-l2-ipvlan-summary.json) · [macvlan placement changes](sibling-l2-macvlan-summary.json)

## Provisioning 32 independent CI networks

Each fresh Micropod worker created 32 internal Docker bridges and ran one service and one client on each. Every pair used the same group label and the same DNS alias, `dependency`. Linux assigned one vCPU of bandwidth to each container and placed the two members of each job on the same vCPU. The 32 jobs split eight per vCPU. Running-state snapshots captured all 64 container IDs before and after the checks and confirmed their start times. Each client resolved its own dependency, checked the unique response body, then reused its warmed connection twice. The HTTP checks ran eight at a time while all 64 containers stayed up. [Job-network qualification and cleanup](sibling_job_network.py) · [First complete client and network inventory](20261124T235212Z-sibling-sltf15br/job-network-smoke.json)

The original Docker IP address allocator asked Linux for its IPv4 route table again for every candidate subnet. The updated runner reads one fresh table per automatic network creation, retries once after a failed read and selects the first free subnet under the worker's network lock. It checks overlapping routes and the reserved worker address space. The production build reused the same signed Mac executable, guest bootstrap and kernel, and changed three Linux source files including the regression tests. [Subnet selection](../../../../guest/runner/docker_networks_linux.go) · [Route matching](../../../../guest/runner/docker_links_linux.go) · [Linux tests and benchmark](../../../../guest/runner/docker_networks_linux_test.go)

The client-visible measurement spans the first through last of 32 sequential `docker network create` calls. A separate read-only operation queried the real kernel while the networks and their 64 endpoints were still live. With the first 32 networks occupying `10.90.0.0/24` through `10.90.31.0/24`, each implementation had to return `10.90.32.0/24` every time. Both worker versions ran the same test executable. Each boot exercised both algorithms in both orders after the create timing. [Raw guest benchmark](20261124T235212Z-sibling-sltf15br/ipam-old-first.log) · [Raw-log verifier](sibling_ipam.py)

The first two matched boot pairs split one win each on the 32 network creates. Four subsequent pairs were specified before collection with the same kernel, binaries and probe. The snapshot allocator took a median 31.8 µs at 32 resident networks against 885.8 µs for the per-candidate algorithm. Kernel route dumps fell from 33 to one, and the snapshot used less time in all 24 within-boot method comparisons. Each comparison order ran on 12 independent worker boots. The complete Docker CLI operation had medians of 476.0 ms with the original worker and 462.0 ms with the new worker. Its median paired reduction was 2.1%, with three wins in six pairs. The CLI timings give no consistent provisioning advantage at this size. [All six provisioning pairs and 24 kernel comparisons](sibling-job-ipam-summary.json) · [Offline crossover verifier](sibling_ipam_results.py)

| Independent pair | Original worker, 32 network creates in ms | Snapshot worker, ms |
| --- | ---: | ---: |
| Pilot 231201 | 436.5 | 488.9 |
| Pilot 231203 | 478.8 | 454.2 |
| Holdout 231205 | 506.3 | 469.8 |
| Holdout 231207 | 473.1 | 477.4 |
| Holdout 231209 | 487.3 | 439.8 |
| Holdout 231211 | 438.2 | 445.7 |

Every boot verified the 32 simultaneous job networks, group placements and dependency aliases, then removed all of its 64 containers and 32 networks. The same signed Mac binary and guest bootstrap served both versions. The Linux worker SHA-256 begins with `29c50a824761` in the control and `670dee15fcd7` in the candidate. The HTTP driver crossover above used the control worker, which already included automatic CPU grouping. The candidate changed network creation and ran the separate per-job checks. [Candidate build receipt](20261124T235233Z-sibling-awvwvpcn/worker-build.json) · [Final job-network check](20261124T235700Z-sibling-4fqo5owc/job-network-smoke.json)

## Verification and cleanup

The final host audit checked all 117 disposable sibling scopes. These experiments added 45 scopes, of which 42 qualified. The three rejections were the original unsupported IPvlan boot and the two 2.1 ms warm-socket failures. All 45 scope directories were removed, including the rejected scopes. The host had zero remaining owned launchd jobs, OrbStack containers, networks, volumes or kernel builders. Across the 12 separate-network boots, the verifier matched the retirement of 384 job networks and 768 job containers. All 24 original baseline files and their 24 preserved copies matched their SHA-256 manifest. [Host cleanup audit](sibling-placement-l2-ipam-cleanup.json) · [Original baseline manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)
