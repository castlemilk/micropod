# Linux page size under 64-container CI load on Gamma

Gamma is an Apple M5 Max running macOS 26.5.1 with 16 KiB host pages. Each worker had four Linux vCPUs and 4 GiB of configured memory. Thirty-two live services served a mix of file-backed and in-memory artifacts, while 32 ephemeral CI jobs shared eight build slots. Each healthy job ran two distinct Go revisions. Each six-second network window used 32 bulk streams and scheduled 240 fresh requests. The order of Micropod and OrbStack alternated in balanced blocks under the host’s natural load.

## Independent run with the ordinary build command

The second comparison used fresh boots, a different balanced order, and the original CI dispatch script without the Go accounting wrapper. All eight Micropod and eight OrbStack windows passed the overlap check on each boot. Across these two boots, 960 healthy jobs completed, all 32 deliberate failures and all 32 cancellations had their expected exit status, and all 7,680 fresh requests completed with zero bulk reconnects. Gamma’s pre-window CPU idle ranged from 78.85% to 92.06% during these two runs. [4 KiB dispatch and order](20261124T195855Z-link-peer-fkmgen5a/file-peer-plan.json) · [16 KiB dispatch and order](20261124T195401Z-link-peer-caqhmbif/file-peer-plan.json)

| Metric | Micropod 4 KiB | Micropod 16 KiB | OrbStack alongside 16 KiB | 16 KiB Micropod vs OrbStack, median paired change |
| --- | ---: | ---: | ---: | ---: |
| Published artifact throughput | 8,484 MiB/s | **9,254 MiB/s** | 8,023 MiB/s | **+16.2%** |
| Fresh-request p95 | 13.14 ms | **9.68 ms** | 51.84 ms | **−82.0%** |
| Last CI job finished | 13.53 s | **12.09 s** | 13.20 s | **−8.5%** |
| Provision through final cleanup | 15.75 s | **14.19 s** | 16.48 s | **−13.6%** |

Against Micropod’s 4 KiB control, 16 KiB pages improved throughput 9.2%, reduced last-job time 11.0%, and reduced cgroup kernel CPU 20.9%. Every one of the eight pairs favored the 16 KiB kernel on all three measures. The independent OrbStack throughput reference changed −0.42% across these boots. [4 KiB receipts](20261124T195855Z-link-peer-fkmgen5a/status.json) · [16 KiB receipts](20261124T195401Z-link-peer-caqhmbif/status.json) · [Scorer](published_link_results.py)

## Matched kernel builds

The two Micropod Images came from Linux 7.3.5, the same Apple config, the same arm64 Alpine compiler and package set, and the same kernel build timestamp. The rebuilt 4 KiB control’s config is byte-identical to the preserved stock config. The 16 KiB candidate has precisely the 17 previously identified Kconfig differences. Both retain full preemption, the same 48-bit virtual address width, and the same kernel release. Image headers, checksums, embedded configs and running guest config digests agreed. [Build inputs and 17 differences](20261124T194837Z-link-peer-r9ulc6lq/kernel-page-pair.json) · [Compiler and packages](20261124T194837Z-link-peer-r9ulc6lq/kernel-toolchain.txt) · [Linux arm64 Image header](https://docs.kernel.org/arch/arm64/booting.html)

| Go workload with per-command accounting | Micropod 4 KiB | Micropod 16 KiB | Median paired change |
| --- | ---: | ---: | ---: |
| Published artifact throughput | 8,367 MiB/s | 9,284 MiB/s | +10.8% |
| Fresh-request p95 | 13.85 ms | 10.11 ms | −26.9% |
| Slowest bulk stream | 210.4 MiB/s | 239.8 MiB/s | +13.5% |
| Last CI job finished | 13.97 s | 12.44 s | −10.9% |
| Provision through final cleanup | 16.16 s | 14.50 s | −10.7% |
| Healthy build cgroups, kernel CPU | 10.80 s | 8.56 s | −21.0% |

Each row gives the median of eight windows per configuration. Changes use eight within-position ratios. Throughput increased and the last build finished earlier in all eight comparisons. The lower bound on mean occupied build slots was at least 7.99 on both platforms across the two boots. OrbStack’s paired throughput changed +0.35% across the same two rounds. On the 16 KiB boot Micropod beat OrbStack in all eight throughput, last-job and lifecycle pairs. [4 KiB plan](20261124T194322Z-link-peer-gaxr23xk/plan.json) · [16 KiB plan](20261124T194837Z-link-peer-r9ulc6lq/plan.json) · [Replayed comparisons](published-link-summary.json)

## OrbStack’s anonymous page allocation policy

OrbStack exposed a 4 KiB userspace ABI and selected `always` for 16 KiB anonymous transparent huge pages. Its global policy was `madvise`, and its 2 MiB policy inherited that setting. Across each uninstrumented CI run the reference VM recorded 6,654,089 and 6,658,055 successful 16 KiB anonymous fault allocations, respectively, and zero 2 MiB anonymous fault allocations. These are guest-wide counters collected outside the timed intervals. Linux can use page-table entries to back anonymous memory with blocks larger than the application’s base page size. [4 KiB control reference counters](20261124T195855Z-link-peer-fkmgen5a/kernel-vm-B-after.json) · [16 KiB candidate reference counters](20261124T195401Z-link-peer-caqhmbif/kernel-vm-B-after.json) · [Linux multi-size THP and per-size counters](https://docs.kernel.org/admin-guide/mm/transhuge.html)

## 4 KiB applications with 16 KiB anonymous allocations

On the same 4 KiB Linux Image, two fresh boots changed only the per-size policy for 16 KiB anonymous pages. Both used global `madvise` and allowed 2 MiB pages to inherit that setting. The worker supplied the policy on its kernel command line. The OCI probes verified the effective policy and accepted 4 KiB file offsets on the container root, Linux cache volume and writable Mac bind mount. [Disabled policy](20261124T200907Z-link-peer-b2xk2jie/kernel-vm-A-before.json) · [Enabled policy](20261124T201418Z-link-peer-svycv292/kernel-vm-A-before.json) · [File mapping checks](20261124T201418Z-link-peer-svycv292/kernel-pages-A.json)

| Profiled 64-container CI load | 16 KiB allocation disabled | 16 KiB allocation enabled |
| --- | ---: | ---: |
| Go minor page faults per window | 4,195,182 | 1,917,546 |
| Healthy build cgroups, kernel CPU | 11.07 s | 10.15 s |
| Last CI job finished | 13.77 s | 13.25 s |
| Provision through final cleanup | 15.99 s | 15.44 s |
| Published artifact throughput | 8,705 MiB/s | 8,825 MiB/s |
| Per-job peak memory, p95 | 58.5 MiB | 68.0 MiB |

Linux counted 6,887,489 successful 16 KiB anonymous fault allocations on the enabled boot and zero on the disabled boot. The Go commands took 54.3% fewer minor faults. Across all eight pairs the enabled setting used less kernel CPU (median −8.5%) and finished the last job earlier (−3.3%). Published throughput gained 1.6% against a 1.1% gain on the parallel OrbStack reference. The median reference-adjusted gain was 0.7%, with four of eight pairs higher. [Disabled boot](20261124T200907Z-link-peer-b2xk2jie/status.json) · [Enabled boot](20261124T201418Z-link-peer-svycv292/status.json) · [Boot allocation counters](20261124T201418Z-link-peer-svycv292/kernel-vm-A-after.json) · [Paired comparison](published-link-summary.json)

The worker builder’s `full-mthp` profile reproduced all 23 resolved Kconfig differences from the original Apple config with the same 97 toolchain packages. The resulting 29,637,120-byte Image differs from the policy experiment’s Image at two 20-byte GNU build-ID descriptors. Every other byte matched. The packaged worker booted the rebuilt Image, restored all 32 service interfaces to MTU 9,000 with their original CPU masks, and reported the forced OOM on the one 32 MiB container. All 63 siblings survived. [Builder profile and config](20261124T202442Z-private-link-4v7kzwcv/mthp-profile.json) · [Binary comparison](20261124T202442Z-private-link-4v7kzwcv/kernel-image-comparison.json) · [Service CPU masks](20261124T202442Z-private-link-4v7kzwcv/docker-cpu-sets.json) · [OOM attribution](20261124T202442Z-private-link-4v7kzwcv/oom-fault.json) · [Worker setup](../../../ci-worker.md#direct-tcp-ports-on-a-native-mac-worker)

The independent eight-pair run used the rebuilt `full-mthp` Image and the ordinary CI dispatch command. Micropod delivered **8,830 MiB/s** versus **8,148 MiB/s** for OrbStack (+9.0% paired, eight wins). Fresh p95 was **10.28 versus 48.92 ms**, and provisioning through cleanup took **15.69 versus 16.40 s**. OrbStack reached the last build exit earlier in five of eight pairs, with medians of **13.32 s** for OrbStack and **13.44 s** for Micropod. Together the two engines completed 480 healthy jobs and all 3,840 scheduled fresh requests, with zero bulk reconnects. [Rebuilt kernel and application page size](20261124T202511Z-link-peer-0vhezcl1/mthp-profile.json) · [Independent workload order](20261124T202511Z-link-peer-0vhezcl1/file-peer-plan.json) · [Completion and cleanup](20261124T202511Z-link-peer-0vhezcl1/verification.json) · [Paired metrics](published-link-summary.json)

The builder now makes its private copy of the input config writable. A clean arm64 Linux build ran as UID 65534 with a read-only Apple config (mode 0444). Its input SHA-256 was unchanged after compilation. The resulting `full-mthp` config matched the timed Image’s config byte for byte, and the two GNU build IDs accounted for every Image difference. The regression check also exercises incorrect page shift, disabled THP and an existing control output directory. [Unprivileged build and checksums](unprivileged-kernel-build.json) · [Config guard checks](../../../../scripts/relaybench/kernel_candidate_profile_check.py)

## What the Go jobs did

Linux reported a median 4.25 million minor page faults across the 240 Go commands per Micropod window at 4 KiB and 1.43 million at 16 KiB. The largest absolute reduction was in `go test`, from 2.36 million to 785,000 faults. Kernel CPU time inside that phase fell from 4.97 to 4.08 seconds. The wrapper uses the resource usage returned when waiting for the Go command, including the subprocesses it waited for. Cgroup accounting covers the whole healthy job. [Per-command probe](build_usage_linux.go) · [Linux resource accounting](https://man7.org/linux/man-pages/man2/getrusage.2.html)

Healthy jobs used more peak memory. The 95th percentile cgroup peak across 240 jobs per engine went from **63.4 to 71.5 MiB** on Micropod. OrbStack recorded 63.1 MiB in both rounds. All 32 resident services passed their memory and identity checks on each engine. [4 KiB build sample](20261124T194322Z-link-peer-gaxr23xk/churn-0-A.json) · [16 KiB build sample](20261124T194837Z-link-peer-r9ulc6lq/churn-0-A.json) · [Service memory](20261124T194837Z-link-peer-r9ulc6lq/memory-A.json)

## Application compatibility and recovery

The Linux auxiliary vector, Go runtime and Alpine `getconf` reported the selected page size on each boot. On the container root, Linux cache volume and writable Mac bind mount, raw file offsets of 4, 8 and 12 KiB returned `EINVAL` at 16 KiB. Mappings aligned down to the OS granule returned every expected byte and preserved private writes on all three filesystems. The 4 KiB guests accepted all four test offsets directly. [Micropod 16 KiB](20261124T194837Z-link-peer-r9ulc6lq/kernel-pages-A.json) · [Micropod 4 KiB](20261124T194322Z-link-peer-gaxr23xk/kernel-pages-A.json) · [OrbStack 4 KiB](20261124T194837Z-link-peer-r9ulc6lq/kernel-pages-B.json)

Node 24.22.3 and SQLite 3.54.1 used the same offline arm64 image and the same file on a shared workspace in three successive containers. OrbStack created an 8,192-row database with 4 KiB database pages. Micropod’s 16 KiB guest verified those rows and appended 2,048. OrbStack reopened all 10,240 rows, checked every payload and verified database integrity and the final file digest. Both write phases committed and checkpointed WAL frames. All connections read back the 16 MiB SQLite mapping limit. [Cross-kernel database receipts](20261124T195334Z-private-link-xtoeaidz/node-sqlite-pages.json) · [SQLite mapping setting](https://sqlite.org/pragma.html#pragma_mmap_size)

The packaged Mac worker `fb9a3603` and Linux runner `d8ec1627` passed the 16 KiB tests through the local Docker control socket. All 32 existing service interfaces returned to MTU 9,000 after a fault, with their CPU masks intact. At 64 running containers, the deliberately limited 32 MiB container exited 137 with `OOMKilled=true`, and all 63 siblings survived. The package recorded zero failures to monitor OOM events. Published-port timing used the previously authorized signed Mac executable `be237917` with the same Linux runner. macOS Local Network permission for the new Mac executable remains outstanding. [Packaged inputs](20261124T195334Z-private-link-xtoeaidz/worker-build.json) · [CPU sets](20261124T195334Z-private-link-xtoeaidz/docker-cpu-sets.json) · [OOM attribution](20261124T195334Z-private-link-xtoeaidz/oom-fault.json) · [Timing inputs](20261124T194837Z-link-peer-r9ulc6lq/plan.json)

On a fresh 16 KiB boot the same packaged worker also attempted the published-port benchmark. All three direct TCP route controls and all 12 fragmentation-disabled UDP checks passed. Each of the 22 connections to the published service timed out before the first timed window. Two earlier same-process Network.framework diagnostics on this Mac executable had reported a Local Network denial. The 16 KiB retry collected no network timing and removed its worker. [Route controls](20261124T203020Z-link-peer-9h9mlbg9/boot-routes.json) · [Published service attempts](20261124T203020Z-link-peer-9h9mlbg9/publication-readiness.json) · [Cleanup](20261124T203020Z-link-peer-9h9mlbg9/verification.json) · [Same-process permission diagnosis](published-link-results.md#local-network-permission-on-the-rebuilt-mac-relay)

## Excluded startup delay

On the first profiled 16 KiB boot, one client invocation lasted 25.96 seconds for a six-second score. One stream completed its first 8 MiB while every other stream transferred at least 771 MiB during warm-up. The client received 35.14 GiB before the scored interval, and the last build finished at 7.73 seconds. The receipt cannot establish overlap between builds and that traffic sample. All 240 fresh requests completed, zero bulk streams reopened and the guest interface recorded zero receive errors, transmit errors, drops or transmit timeouts. The cause of the slow stream setup is unresolved. The scorer excluded the entire boot from performance comparisons. A fresh run with the same inputs verified overlap in every window. [Delayed window](20261124T193807Z-link-peer-a_tfnm5v/churn-2-A.json) · [Repeat](20261124T194837Z-link-peer-r9ulc6lq/status.json)
