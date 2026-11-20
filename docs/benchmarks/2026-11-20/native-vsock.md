# Fresh CI containers over vsock on Gamma

On Gamma, Micropod's Rust guest service finished 16 fresh source-only Go jobs in **0.934 s** and 32 in **1.840 s**. It beat OrbStack and ordinary Micropod Docker in all ten paired batches. Raw warm Ubuntu finished in **0.650 s** and **1.263 s**, leaving gaps of about 0.28 s and 0.58 s. Replacing the Docker bootstrap had its largest effect on opening a session. Once open, the two direct-runc executors had similar batch times. [Matched engine receipts](native-vsock/paired.json.gz) · [Ubuntu before](native-vsock/ubuntu-before.json) · [Ubuntu after](native-vsock/ubuntu-after.json)

## Benchmark prompt

> On Gamma, reduce the time from submitting 16 or 32 source-only Go jobs to receiving all verified results. Give every job a fresh isolated filesystem and its original CPU, memory and security policy. Move session startup into a Rust service over vsock and preserve the shared Go stores. Replay the archived Docker cases. Trace admission wait, OCI entry, kernel CPU pressure and cleanup. Select tuning by whole-batch wall time. Compare the result with the previous launcher, ordinary Docker, OrbStack and raw warm Ubuntu at the same VM budget. Report setup separately, archive the raw receipts and keep GitHub tests off.

## Comparison

| Execution path | 16 jobs, median | 32 jobs, median |
| --- | ---: | ---: |
| Raw Ubuntu processes | 0.650 s | 1.263 s |
| Micropod, Rust service and runc, default policy | 0.934 s | 1.840 s |
| Micropod, Rust service and runc, ordinary scheduler | 0.960 s | 1.878 s |
| Micropod, earlier Docker-launched runc executor | 0.923 s | 1.856 s |
| Micropod, ordinary Docker | 1.685 s | 3.239 s |
| OrbStack 2.2.5, ordinary Docker | 6.649 s | 11.554 s |

Gamma is a shared 18-core Apple M5 Max with 128 GiB running macOS 26.5.1. Each Linux VM was configured with four vCPUs and 4 GiB. Micropod used Linux 6.18.35 and Docker 29.9.3. The native reference used Ubuntu 24.04.4, kernel 6.8.0-134-generic and the ARM64 Go 1.26.11 toolchain copied from the measured image. The engine order rotated over five rounds at each concurrency. At 32 jobs, the native-service default ranged from 1.701–1.949 s and OrbStack from 10.546–44.421 s. Ubuntu ran five rounds immediately before and five after. Its before/after medians were 0.638/0.732 s at 16 and 1.242/1.285 s at 32. The table pools the ten native rounds. [Rig and recovery record](native-vsock/rig.json) · [Engine timeline](native-vsock/paired.trace.json.gz)

All 1,200 timed containers had unique IDs. Each started with source only, invoked the linker once, reused all compiled packages and ran the expected program. The checksum from the priming jobs matched both native controls. The container clock includes private filesystem setup, launch, link, execution and stream return. The direct paths also finish private filesystem cleanup before replying. The Ubuntu clock covers parallel builds in prepared directories. Creating those directories took another 2.3 ms at 16 and 4.6 ms at 32. Native product verification follows the clock. Python drives the experiments and audits the fixture. The production launch path is Rust, the Go executor and runc, and timed jobs invoke a shell and Go. [Workload and clocks](../../../scripts/bench_ci_startup.py) · [Native control](../../../scripts/bench_fresh_go_ubuntu.py)

## What moved out of startup

The native service starts once at worker boot. The Mac client opens a private socket bridged over vsock. A session starts one executor in its own mount namespace. Jobs share a prepared read-only lower filesystem and the original scoped cache volumes. Each receives its own ext4 overlay upper, six namespaces, cgroup and stock OCI security policy. Docker still supplies the image and reference policy during cold preparation. A stopped Docker owner record references the image and volumes. No Docker management container starts when a native session opens. The stock Docker endpoint remains in the same VM for general workloads. [Worker interface](../../ci-worker.md#direct-oci-batches-in-the-shared-worker)

| Step outside the timed Go batch | Earlier launcher | Native service |
| --- | ---: | ---: |
| First preparation of a handle | 5.481 s | 1.257 s |
| Open a warm session, median of seven | 189 ms | 59 ms |

Creating the common source snapshot took 0.499 s. Reusing the native handle by immutable image ID took **70 ms** for one caller and **101 ms wall time for eight concurrent callers**. Resolving the equivalent mutable tag took 157 ms and 451 ms on the same worker. The service recorded 26 warm preparations, three cold preparations and zero active sessions at the end of qualification. All three Micropod paths used the same named volumes. Across the timed rounds the Go build cache held 441 files and 33,086,136 logical bytes, while the module archive inode and cache sizes stayed stable. [Preparation samples and cache audits](native-vsock/paired.json.gz) · [Worker counters](native-vsock/worker-metrics.json)

Each native session also validates and decodes the stock OCI policy once. Only the per-job fields are copied for subsequent launches. Using the measured Docker policy, generating byte-identical job configurations fell from a median **142 to 26 µs** and from **601 to 15 allocations per job**. This saves allocation work and accounts for a small part of the batch time. [Linux policy benchmark and tests](native-vsock/policy-benchmark.txt)

## CPU wait at 32 jobs

Three experiments kept the four-vCPU budget, the one-CPU/1-GiB limits per job and the Go command fixed.

1. Limiting runc to four simultaneous starts using its init pid-file reduced median in-job CPU stall from 505 to 477 ms. It also added 385 ms of admission wait. Batch time increased from 2.129 to 2.750 s. Adding a queue hid some contention from each job's cgroup counter. [Admission windows and per-job queue time](native-vsock/admission.json.gz)
2. Pinning jobs round-robin to individual CPUs raised median CPU stall from 411 to 992 ms. Linux `SCHED_BATCH` with all four CPUs available won four of five 32-job diagnostic pairs and four of five pairs in a separate source-only selection run. We enabled that scheduling class for native runc batches of at least 32 on four-vCPU workers. Smaller batches keep ordinary scheduling. All jobs start concurrently. [Placement and scheduler counters](native-vsock/placement.json.gz) · [Policy selection run](native-vsock/policy-selection.json.gz)
3. The release-build trace recorded the requested scheduling class in all 160 jobs per 32-client arm. Median time from invoking runc to the first in-job timestamp went from **449 to 298 ms**, per-job CPU stall from **492 to 468 ms**, and traced batch time from **1.851 to 1.558 s**. Median I/O stall rounded to zero and no job reported CPU quota throttling. The lighter final source-only comparison showed a smaller effect, **1.878 to 1.840 s**, with the default winning three of five pairs. CPU pressure covers the job cgroup through verification and overlaps its runtime. Adding the counters across concurrent jobs would overstate wall time. [Release trace and cgroup samples](native-vsock/cpu-trace.json.gz) · [Perfetto timeline](native-vsock/cpu.trace.json.gz) · [Linux pressure accounting](https://docs.kernel.org/accounting/psi.html)

## Behavior and recovery

The pinned rust-anything recorder replayed the [original nine Docker cases](oci-startup/docker-cases.tar.gz). The release passed nine with zero skips. A deliberately incorrect candidate passed zero. Independent checks compared raw streams and exit codes, including exit 41. A barrier held all 32 jobs live together on each implementation. All six namespace IDs were private per job and a single module inode was shared across Docker and native jobs. The service rejected a drain during active work and reclaimed two 90-second jobs in 109 ms when the client closed its input. Killing the Mac client separately reclaimed both jobs in 166 ms. A binary stream probe preserved NUL and non-UTF-8 bytes on both output channels. [Replay and namespace evidence](native-vsock/docker-replay.json.gz) · [Disconnect and binary stream record](native-vsock/rig.json)

After a clean restart of the qualification VM, the original handle reopened with the same cache inode and contents on its persistent disk. A second handle could also be forgotten before reopening it. The CLI in the PR checkout then found its guest tools with no explicit path overrides. The qualification worker was stopped after verification. Gamma's original CI worker retained its prior boot ID. [Worker identities and recovery](native-vsock/rig.json)

## Reproduce

Build the worker and native tools as described in the worker guide, then load the same offline fixture into both engines. Select the OrbStack socket explicitly when it differs from `~/.orbstack/run/docker.sock`. On a four-vCPU Ubuntu VM, run the native reference once before and once after the paired comparison using the same Go toolchain. All raw jobs, CPU counters and prep samples are available locally in `~/.micropod/benchmarks/measurements.sqlite3` using `startup_batches`, `native_oci_jobs`, `native_oci_cache` and `native_go_batches`. Generic jobs submitted through the stock Docker endpoint use the ordinary Docker row in the table. [Worker setup](../../ci-worker.md) · [Database schema](../../../scripts/ci_benchmark_store.py)

```sh
ci/build-oci-service.sh
python3 scripts/qualify_oci_replay.py --image "$IMAGE" --rust-anything "$RUST_ANYTHING" \
  --corpus docs/benchmarks/2026-11-20/oci-startup/docker-cases.tar.gz --isolation-clients 32 --out "$OUT/replay.json.gz"
python3 scripts/bench_ci_startup.py --mode native-tune --policies parallel default --clients 16 32 \
  --rounds 5 --image "$IMAGE" --out "$OUT/trace.json.gz"
python3 scripts/bench_ci_startup.py --mode native-paired --policies default parallel --clients 16 32 \
  --rounds 5 --image "$IMAGE" --out "$OUT/paired.json.gz"
```
