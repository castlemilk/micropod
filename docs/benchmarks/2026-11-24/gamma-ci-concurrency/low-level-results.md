# Artifact delivery and guest exits under concurrent CI on Gamma

Gamma ran the signed Standard worker with two relay workers, four guest vCPUs, 4 GiB of memory and 32 separately published ports. The artifact trials kept 32 services resident while releasing 32 additional job containers, with four CPU-intensive build steps active. Each batch included 30 successful jobs, an intentional test failure, a cancellation, 32 bulk streams and 240 fresh connections. The trials admitted the host at its current load. [Worker and networking configuration](20261124T115609Z-kernel-de4uwit3/fixtures-before.json) · [Workload and evidence](low-level-summary.json)

## Static artifacts on the stock Linux worker

The file-backed case allowed Go to pass an open regular file to Linux. The copy control wrapped the **same file** to expose only reads and seeks. The memory control served the same 8 MiB of bytes as the original benchmark. All 32 tenant endpoints returned the expected full SHA-256 and a nonaligned byte range before timing. On one traced request the file case recorded 16 sendfile syscall returns and 8,388,096 transferred bytes. Each control recorded zero returns. The syscall trace was disabled for scored traffic. [Tenant implementation](artifact.go) · [Trace and validation driver](kernel_ci.py) · [Syscall receipts](20261124T115609Z-kernel-de4uwit3/sendfile-proof.json) · [Linux sendfile](https://man7.org/linux/man-pages/man2/sendfile.2.html)

| Median of four windows | Bulk MiB/s | Fresh p95, ms | Last job, s | Service CPU-s/GiB | VMM CPU-s/GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| Memory, builds on all four CPUs | 5,033 | 57.8 | 14.88 | 0.258 | 0.836 |
| File with userspace copy, all four CPUs | 5,000 | 61.2 | 15.26 | 0.300 | 0.857 |
| File with sendfile, all four CPUs | 5,864 | 60.9 | 14.34 | 0.146 | 0.727 |
| File with sendfile, builds on CPUs 0–2 | 5,533 | 67.0 | 14.60 | 0.148 | 0.774 |

Relative to copying the same file, sendfile improved bulk throughput in **four of four blocks**, by **17.2%** at the paired median. Service CPU per GiB fell **52.0%**, measured across the 32 service cgroups. The four-block paired reduction in VMM CPU per GiB was **13.5%**. Host work includes the concurrent CI activity, and CPU costs use all payload bytes from the same client invocation, including warm-up and drain. This measures repeated hot reads of a container-local file. The real job output endpoint already uses Go’s file server. Applications that serve completed artifacts can preserve that path by passing the regular file to their HTTP server. [One timed window and both counter snapshots](20261124T115609Z-kernel-de4uwit3/churn-0-A.json) · [CI output handler](tenant.go) · [Go HTTP server source](https://go.dev/src/net/http/server.go)

The published virtio NIC reported a median **1,213 transmit kicks per delivered GiB** with sendfile and **2,213** with the same-file copy. All 2,467 preflight interrupts and all 769,629 interrupts observed during client invocations landed on guest CPU 3. Restricting build processes to CPUs 0–2 reduced throughput in all four blocks, by **6.2%** at the paired median, and lengthened the time to the last job in all four. Every job recorded its effective CPU list. The experiment used the existing guest IRQ routing. There were zero NIC error or drop increments across the measured invocations. [Preflight CPU and device counters](20261124T115609Z-kernel-de4uwit3/kernel-plan.json) · [Linux IRQ affinity](https://docs.kernel.org/core-api/irq/irq-affinity.html)

### Independent comparison with OrbStack

A fresh private Micropod VM and fresh per-engine caches repeated the original memory and fast-file conditions. Each engine used the same image, artifacts, 32 published ports, six-second client, four build slots and effective CPU list 0–3. The order balanced position and first-order carryover. Host pre-window idle ranged from 78.11% to 91.06%. Each engine returned 1,920 correct fresh responses, completed 240 healthy jobs and produced the same 480 distinct build outputs. Both passed the failure, cancellation, listener retirement and port-reuse checks. [Confirmation plan](20261124T120649Z-file-peer-oxnf4_xc/file-peer-plan.json) · [Workload replay](low-level-summary.json)

| Engine and artifact source | Bulk MiB/s | Fresh p95, ms | Fresh p99, ms | Last job, s |
| --- | ---: | ---: | ---: | ---: |
| Micropod, memory | 5,046 | 57.8 | 85.8 | 14.53 |
| Micropod, file | 5,956 | 55.3 | 99.9 | 14.24 |
| OrbStack, memory | 7,104 | 42.4 | 75.2 | 13.54 |
| OrbStack, file | 7,798 | 52.7 | 73.3 | 13.30 |

At the paired median, file delivery raised Micropod throughput **18.7%** and OrbStack throughput **10.1%**. Both improved in every block. Micropod delivered **77.4% of OrbStack’s file throughput**, up from 71.5% for memory. Its file p95 stayed below 75 ms in every window. The higher median p99 on Micropod limits the latency claim to p95. [Micropod file window](20261124T120649Z-file-peer-oxnf4_xc/churn-1-A.json) · [Matched OrbStack file window](20261124T120649Z-file-peer-oxnf4_xc/churn-1-B.json)

## Hypervisor.framework producer

A separate signed one-vCPU producer filled guest pages and delivered them through real TCP connections to 32 Linux CI containers. Each receiver checked its tenant cookie, frame sequence and every payload byte. Each transfer delivered 256 MiB during a wave of real Go builds. Per-flow outstanding guest memory was capped at 512 KiB. This is an upload experiment. The stock Linux worker used Virtualization.framework for every trial. [EL1 assembly](../../../../scripts/relaybench/hvf_notify/flows.S) · [Signed producer and socket accounting](../../../../scripts/relaybench/hvf_notify/flows.c) · [Experiment order and inputs](20261124T120138Z-grants-juej_gda/bridge-plan.json)

The host submitted descriptors for up to eight currently writable tenants in one vCPU entry. The guest published completions with release ordering. The host checked each result against the original socket owner before exposing the slot to TCP. A scalar and a NEON loop wrote the same tagged bytes in 64-byte strides. Ten counterbalanced blocks separated the effect of the descriptor table, grouping and instruction choice.

| Producer, 512 KiB socket buffers | Verified MiB/s | Sender CPU-s/GiB | Guest ms/GiB | Data exits per 256 MiB |
| --- | ---: | ---: | ---: | ---: |
| Original, one tenant per exit | 2,462 | 0.174 | 29.54 | 512 |
| Descriptor table, one tenant, scalar | 2,426 | 0.178 | 28.74 | 512 |
| Descriptor table, up to eight, scalar | 2,404 | 0.165 | 27.68 | 302 |
| Descriptor table, one tenant, NEON | 2,453 | 0.169 | 22.82 | 512 |
| Descriptor table, up to eight, NEON | 2,483 | 0.172 | 22.99 | 311.5 |

The combined change cut median paired **data exits by 39.2%** and **vCPU execution time per GiB by 21.2%** relative to the original producer. There were still 512 separately owned grants in every 256 MiB transfer. With the same grouping, NEON used less guest execution time than scalar stores in all ten blocks. End-to-end throughput rose in six of ten comparisons with the original. Its paired median was +5.1%, with a 95% block-bootstrap interval of −2.6% to +11.3%. Socket sends rose 26.2% at the paired median. The measurements distinguish guest time from sender-thread CPU and the elapsed time until the final verified HTTP response. [Receiver and sender receipts](20261124T120138Z-grants-juej_gda/transfer-hv49.json) · [Offline calculation](replay.py)

In the fault window, 30 siblings finished before the held connection was released at 102.9 ms. The held receiver verified at 106.8 ms, and a separate receiver reset after one verified frame. Across 51 waves, all 1,632 builds and 8,642 fresh probes succeeded. [Fault window](20261124T120138Z-grants-juej_gda/transfer-hv50.json) · [Concurrent builds](20261124T120138Z-grants-juej_gda/wave-hv50-A.json)

### Darwin socket write readiness

An independent eight-block experiment crossed the original and grouped NEON producers with two per-socket write thresholds. Gamma reported a default `SO_SNDLOWAT` of 2 KiB. Each of the 32 sockets confirmed the requested 128 KiB in the alternative. All used the same 512 KiB send buffer. The host counted successful short writes, would-block returns and interrupted system calls independently for each connection. [Socket configuration](bridge.py) · [Darwin socket options](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/setsockopt.2.html)

| Producer and write threshold | Verified MiB/s | Sender CPU-s/GiB | Send calls per 256 MiB | Short writes per 256 MiB |
| --- | ---: | ---: | ---: | ---: |
| Original, 2 KiB | 2,284 | 0.176 | 756.5 | 244.5 |
| Original, 128 KiB | 2,273 | 0.180 | 760.5 | 248.5 |
| Grouped NEON, 2 KiB | 2,373 | 0.175 | 930 | 418 |
| Grouped NEON, 128 KiB | 2,185 | 0.179 | 843 | 331 |

On the grouped producer, the higher threshold reduced send calls by **10.7%** and poll calls by **22.1%** at the paired median. Throughput fell **4.5%** at the paired median, with a 95% interval of −15.8% to +7.1%. Only three of eight blocks improved throughput. Gamma’s default write threshold is the choice for this producer. The fault window again completed all 30 siblings before releasing the held reader and verified the reset after exactly one frame. Across 33 waves, all 1,056 builds and 5,619 fresh probes succeeded. [Socket readbacks and individual outcomes](20261124T121154Z-low-water-557dz3y2/transfer-hv32.json) · [Paired results and uncertainty](low-level-summary.json)

## Reproduction and cleanup

From this directory on Gamma, run `python3 -B qualify.py --profile kernel` for the file and interrupt experiment. The independent engine comparison uses `--profile file-peer`. The descriptor and socket experiments use `--profile grants` and `--profile low-water`. Run the profiles sequentially. Each captures its source files, fixed client and worker identities, the run order, per-window results and teardown. To recompute one study offline, use `python3 -B replay.py RUN_DIRECTORY`. [Driver](qualify.py) · [Verifier](replay.py)

The first trace preflight detected the collector’s own nine-byte sendfile call while it read a control message. Switching that read to the shell builtin removed the event, and the corrected run attributed all sendfile events to the tenant. The failed preflight reached cleanup before any scored windows. All four completed studies retired their private scopes and cache volumes. Across every attempt, all 24 original baseline files and their sealed copies matched the original manifest. The separate 6,573.34 MiB/s baseline is preserved. [Preflight diagnostic](20261124T115450Z-kernel-jgstw9ds/status.json) · [Final cleanup](20261124T121154Z-low-water-557dz3y2/cleanup.json) · [Preserved manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)
