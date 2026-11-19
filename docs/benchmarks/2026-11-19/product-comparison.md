# Micropod product measurements, 19 November 2026

## Native guest workloads

The existing matched Apple Silicon run used Mac17,6, 18 cores, 128 GB, macOS 26.5.1, Apple Container 1.3.1 and Docker Desktop Engine 29.8. The September 30 run assigned each guest workload 2 CPUs and 2 GiB. Boot includes the guest command returning and teardown. Each Go job used a cold build cache and a warm module cache. Medians are seconds. The four-job column measures whole-batch wall time.

| Execution path | Boot and exit, 10 runs | Go vet and test, 3 runs | Four Go jobs, 3 batches |
|---|---:|---:|---:|
| Micropod sandbox CLI | 0.36 | 10.29 | 15.12 |
| Micropod sandbox via Connect | 0.48 | 10.12 | 15.64 |
| Apple Container CLI | 0.77 | 10.62 | 19.18 |
| Micropod Apple engine via Connect | 0.80 | 10.66 | 19.33 |
| Docker Desktop CLI | 0.23 | 12.18 | 19.07 |
| Apple Container persistent machine | 0.14 | 9.40 | Unmeasured |

The four-job Micropod sandbox batch took 20.7% less wall time than Docker Desktop on this host. A second series with much higher host load measured 30.89 s for Micropod, 31.18 s for Docker Desktop, 30.84 s for shuru and 22.06 s for Apple Container. The historical harness retried failed commands and allowed unknown outcomes in its Connect lane. These results establish a historical baseline. [Original methodology and both series](https://github.com/castlemilk/micropod/blob/438706f8c2918e90cf15bdba4aab09c0b7c0ed0d/docs/performance.md)

The native guest matrix in this PR uses one CPU and 256 MiB, a warm Alpine image, fresh guests, shuffled engine order, an untimed guest fingerprint and 5 measured blocks at 1, 4, 8 and 16 concurrent clients. It records every attempted batch, exit 23, per-run output tokens and whether stdout and stderr arrive on the correct channels. The gzip case restores and hashes 8 MiB. The bind case verifies a 1 MiB host input and reads the guest's unique output back on the host. These workload times have different boundaries from the September Go series. Only engines sharing the same guest fingerprint may be paired. Native sandbox and Docker-compatible runs disable guest networking. Apple Container uses its default network for these offline commands. [Guest harness](../../../scripts/bench_guest_matrix.py)

On Gamma, the installed Micropod app is 0.13.3, Apple Container is 1.5.0 and Docker Desktop is 4.99.0. The work session received macOS permission errors before native guest execution. Its Micropod and Docker Desktop sockets also rejected connections. OrbStack and Colima had no live local endpoints. An admission failure supplies no guest timing. Run from a normal Terminal on a physical Mac with the selected engines running.

```sh
python3 scripts/bench_guest_matrix.py --json /tmp/micropod-guest-matrix.json
```

## Micropod Docker API shim and Docker Desktop

The September 22 warm-engine receipts include ten Alpine container lifecycles per engine. Values are median and reported p95 in milliseconds. With ten observations the stored p95 is the maximum. The final concurrency case is one batch of ten containers and had zero reported errors. It has no percentile distribution.

| Phase | Micropod p50 / p95 | Docker Desktop p50 / p95 |
|---|---:|---:|
| Create | 39.2 / 47.7 | 45.2 / 65.9 |
| Start | 529.0 / 663.1 | 69.6 / 83.1 |
| Exec start | 73.1 / 74.2 | 19.6 / 23.0 |
| Logs | 28.3 / 32.5 | 4.6 / 5.5 |
| Stop | 72.2 / 3,200.3 | 2,083.0 / 2,097.5 |
| Full lifecycle | 838.4 / 3,913.1 | 2,252.1 / 2,283.6 |
| One ten-container batch | 8,997.3 | 2,615.9 |

Docker waited for a two-second stop grace period in this fixture. Micropod's lower median full-lifecycle time coexists with higher start latency, a longer worst observed lifecycle and a longer ten-container batch. [Recorded summaries from both engines](historical-shim-desktop.json)

## Native filesystem scaling on Gamma

Fresh measurements on an M5 Max, 18 cores and 128 GB, macOS 26.5.1, APFS. Each source has 128 deterministic 4 KiB files, an 8 MiB payload, a symlink, an empty file and a directory holding a sentinel. The filtered fixture adds an ignore rule. The same source and expected manifest go to all implementations. After each batch the verifier hashes every file, compares the directory and symlink sets, verifies sentinel mode, mtime and extended attribute, and changes a view to check that the source and a sibling stay independent. Timing measures the host snapshot processes through completion. Verification happens afterward. These are host operations on a warm source tree.

| Snapshot implementation | 1 client | 4 clients | 8 clients | 16 clients |
|---|---:|---:|---:|---:|
| Master, whole tree | 6.4 ms | 11.2 ms | 20.2 ms | 31.7 ms |
| PR #216, whole tree | 6.9 ms | 10.2 ms | 19.8 ms | 33.2 ms |
| System rsync, whole tree | 61.8 ms | 98.3 ms | 174.3 ms | 271.5 ms |
| Master, filtered | Failed integrity check | — | — | — |
| PR #216, filtered | 30.2 ms | 48.3 ms | 64.7 ms | 238.6 ms |
| System rsync, filtered | 73.7 ms | 128.9 ms | 159.9 ms | 280.1 ms |

Five shuffled blocks per measured cell produced 100 batches and 725 verified views. On master the filtered output included the excluded directory and sentinel, omitted the symlink and lost the test file's mtime and extended attribute. Its warm-up failed and the harness withheld timings for that case. PR #216 and rsync passed all measured batches. The 16-client filtered results varied widely across blocks. PR #216 ranged from 114 to 623 ms and rsync from 257 to 670 ms. The full receipt includes all samples and the exact source hashes. [Raw samples](snapshot-matrix.json) · [Benchmark](../../../scripts/bench_snapshot_matrix.py) · [Candidate implementation](https://github.com/castlemilk/micropod/pull/216) · [Filesystem backlog](https://github.com/castlemilk/micropod/issues/210)

## Same-host Linux guest measurements

A second GitHub allocation used AWS us-east-1, four vCPUs and Ubuntu 24.04.5. Docker Engine 28.0.4 and rootful Podman 4.9.3 (crun, cgroup v2) ran the same local Alpine 3.20.10 amd64 image. Every job requested one CPU, 256 MiB and disabled networking. Both engines reported the same BusyBox fingerprint. Each ran the same five measured blocks at each concurrency. The measurements include guest execution, validation and cleanup. The bind case includes preparing and checking the host fixture.

| Workload | Engine | 1 client | 4 clients | 8 clients | 16 clients |
|---|---|---:|---:|---:|---:|
| Guest exit and cleanup | Docker | 0.088 s | 0.131 s | 0.246 s | 0.497 s |
| Guest exit and cleanup | Podman | 0.072 s | 0.136 s | 0.257 s | 0.632 s |
| 8 MiB gzip, restore and SHA-256 | Docker | 0.208 s | 0.304 s | 0.591 s | 1.137 s |
| 8 MiB gzip, restore and SHA-256 | Podman | 0.191 s | 0.289 s | 0.560 s | 1.131 s |
| 1 MiB bind read, SHA-256 and host-visible write | Docker | 0.087 s | 0.147 s | 0.268 s | 0.530 s |
| 1 MiB bind read, SHA-256 and host-visible write | Podman | 0.077 s | 0.139 s | 0.282 s | 0.646 s |

All 120 measured batches completed. All 870 jobs returned the expected exit 23 with the two nonce markers on the correct streams. At 16 clients Docker completed 32.2 verified lifecycles/s and Podman 25.3. Both delivered approximately 14 gzip jobs/s. The workload step took 54 s and the entire GitHub job took 67 s. The commit records the block times and the original artifact contains per-guest outcomes. [Block samples](linux-guest-batches.json) · [Original JSON artifact](https://github.com/castlemilk/micropod/actions/runs/44497992581/artifacts/14515762378) · [Job with region and timing](https://github.com/castlemilk/micropod/actions/runs/44497992581/job/135470000132)

## OrbStack and Linux engine baselines

The standalone November 19 guest used a single CPU and 64 MiB, no external network, the same amd64 executable and image configuration, a known exit code and verified output on both streams. Each engine ran five measured batches per concurrency. The OrbStack guest ran on a virtualized Intel Mac with four host vCPUs. Docker and Podman shared a four-vCPU GitHub-hosted Ubuntu 24.04.5 runner in Azure Central US. Times are within-engine median wall seconds. The host and virtualization differences preclude a native Mac product speed ratio.

| Engine and host | 1 client | 4 clients | 8 clients | 16 clients |
|---|---:|---:|---:|---:|
| OrbStack 1.5.1, Intel macOS | 1.740 | 3.486 | 7.117 | 15.775 |
| Docker 28.0.4, Ubuntu | 0.124 | 0.213 | 0.374 | 0.660 |
| Podman 4.9.3, Ubuntu | 0.104 | 0.208 | 0.401 | 1.015 |

There were 145 verified guest executions per engine. OrbStack 2.2.5 rejected the hosted Intel virtual CPU. Two Colima startup attempts on the Intel environment ended before a comparable guest batch. [Original data, versions, builds and comparison limits](https://github.com/castlemilk/micropod/blob/17059a4ccde92c4de30cc0fbe545705ec9229652/docs/benchmarks/2026-11-19/orbstack.md) · [Ubuntu runner job and region](https://github.com/castlemilk/micropod/actions/runs/44483464854/job/135421064684#step:1:8)

## Feature coverage

| Capability | Evidence |
|---|---|
| Guest start, exec, logs, stop, cleanup, compute, concurrent work | The Micropod and Docker Desktop September receipts cover these paths. The explicit first-attempt matrix allows retesting current native releases. |
| Shared directory, exclusion, symlink, xattr, timestamp, isolated write | Measured on current master, the PR #216 candidate and system rsync above. OrbStack separately read and verified a Micropod view from inside the guest. |
| Buildx multi-stage, cache invalidation, local export | Prior OrbStack runs verified output, solver execution or cache hits. A no-cache run took 16.485 s, warm 5.108 s, an edited source 7.578 s, a chmod 6.529 s and an ignored-only edit 4.754 s. One observation per build case. An equivalent native Micropod Buildx, Bake and multi-platform output series is still open. |
| Compose, DNS, bind mounts, named volumes, signals | Earlier OrbStack E2E passed these workflows. The repository has individual Micropod checks. This Linux run also verified bind writes and per-guest output on Docker and Podman. There is no complete paired current native result. |
| Root filesystem import and network attachment after creation | OrbStack completed the validated scenarios. The tested native Micropod shim returned HTTP 501 for both operations. |
| OCI/runc and Kubernetes conformance, Linux machine lifecycle, host ingress/TLS | No complete matched or upstream conformance run in this evidence. |
| CPU, memory and disk | The tables give requested workload limits or host capacities. Current matched idle footprint, energy, disk allocation and post-burst reclamation remain unmeasured. |

[OrbStack evidence](https://github.com/castlemilk/micropod/blob/17059a4ccde92c4de30cc0fbe545705ec9229652/docs/benchmarks/2026-11-19/orbstack.md) · [Micropod native shim receipt](https://github.com/castlemilk/micropod/blob/d0d0009e2c6f2f7c049a9d10a8ca0c7047007678/docs/benchmarks/2026-11-19/native-ci-summary.json) · [Core qualification gates](https://github.com/castlemilk/micropod/issues/182) · [Runtime compatibility backlog](https://github.com/castlemilk/micropod/issues/207)
