# Warm crun jobs and VM-isolated runners on Gamma

On Gamma’s M5 Max, preparing one-use crun pods during idle time brought the median 16-job batch within 1% of raw warm Ubuntu. At 32 jobs the gap was 22%. Micropod beat OrbStack at both sizes. These are local runs of the same source-only Go fixture. [Machine-readable receipts, per-job phases and kernel samples](runner-isolation.json.gz)

| Median wall time on Gamma | 16 concurrent jobs | 32 concurrent jobs |
| --- | ---: | ---: |
| Raw warm Ubuntu | 2.95 s | 5.85 s |
| Micropod, empty pods prepared before dispatch | 2.97 s | 7.12 s |
| Micropod, preparation charged to the same batch | 3.43 s | 8.29 s |
| Micropod, fresh pods at dispatch | 3.57 s | 9.39 s |
| OrbStack, fresh containers | 7.74 s | 13.22 s |

The final comparison rotated the four paths over three rounds on the same Mac. Each Linux environment had four CPUs and approximately 4 GiB of RAM. The raw reference used Ubuntu kernel 6.8.0-134. The Micropod worker used 6.18.35, containerd 2.4.2 and crun 1.31. OrbStack reported Docker Engine 29.8.2. The 576 jobs in the final comparison all ran vet, passed the fixture's eight tests, linked three times, produced the same executable, and reused the same compiled dependency. The complete receipt includes 1,200 jobs across the initial comparison, serial-preparation trial and final comparison. The 20-job cache check used identical device/inode pairs for all three cache files, with 20 separate writable container roots. A different trust scope could not see the marker.

The stock OrbStack socket supplied the existing fixture once for offline import into the benchmark worker. The timed Micropod runs used the production guest tools, retained image content and fresh workload containers. OrbStack used its own warm volumes. Raw Ubuntu ran processes directly against a fresh checkout per job. Micropod and OrbStack limited each workload to 1 CPU and 1 GiB. Raw Ubuntu shares the VM’s budget across processes. The Mac client clock includes submission, teardown and result delivery. The raw clock starts in Linux. These are three-round medians on a shared physical rig. Individual samples and the cache checks are in the receipt.

## What preparation removed

At 32 concurrent arrivals, the median time to obtain a pod fell from 1,613 ms to 2 ms. Total setup through container start fell from 2,233 ms to 591 ms. Container creation still took a median 417 ms and process start 158 ms on the prepared path. All 96 prepared containers at this concurrency had distinct pod and container IDs. The worker created every workload container after dispatch.

The final preparation routine created at most four empty pods at a time. Preparing a complete wave took a median 481 ms for 16 and 1,165 ms for 32. The charged row above takes the median of each round's summed preparation and execution time. The lowest-latency row assumes that an idle interval covered preparation. On a separate idle-worker check, the median available guest RAM fell by 86 MiB with 16 standby pods and 149 MiB with 32. Each figure uses five samples from one boot. Untrusted jobs always use a fresh VM.

Kernel pressure samples in two initial 32-job crun waves recorded CPU stalls for 6.59 of 7.44 sampled seconds and 9.93 of 12.53 seconds. Neither wave recorded an OOM kill. Pressure-stall totals measure wall time with at least one stalled task. Attributing those stalls to individual processes requires scheduler tracing.

## Isolation checks

- Three warm-image Apple VM launches returned the requested exit code 17 in 0.34–0.36 s end to end. Each reported a distinct kernel boot ID, loopback as its only interface, zero effective capabilities and `NoNewPrivs=1`. The first unpack and launch in this session took 0.49 s.
- On a separate Ubuntu node with nested virtualization enabled, the identical Alpine image ran under crun on the node’s kernel and under Kata/QEMU on Linux 6.18.62. Both produced the expected stdout, stderr and exit code. The final Kata probe saw its 1 GiB limit, no runtime socket and no default route. The qualified nested launches took tens of seconds. The Ubuntu node required clearing an unsupported ARM PMU option in Kata’s pinned QEMU configuration. Gamma’s stock Micropod worker kernel rejected Kata because it did not expose a KVM device. Apple VM isolation worked directly on that Mac. The Kata job also reached a TCP listener on its own loopback while failing to reach a positively verified echo server on another private macvlan port on the same subnet.
- Trusted crun jobs retain only the capability needed to preserve existing set-ID file bits across writes. This is exercised by the Go fixture. Both trust classes set `no_new_privs`. A request for a shared writable cache in an untrusted allocation was rejected before launch.
- A busy worker declined shutdown. Cancelling the owning client released its job and the worker reported zero active jobs on the same boot. Repeating a preparation request created zero extra pods. Restarting the worker preserved the Go cache inode and worker identity, issued a new boot ID and retired the reserved pods from its previous boot.

## Reproduction

Prime the source fixture and scoped caches once on each engine. The image contains the checkout and its file-backed Go module proxy. For the native worker use the local equivalent of the `micropod-internal/go-cache-fanout:r7zsq0` fixture. The harness verifies the artifact, tool counts, dependency identity and Linux boot within each wave.

```sh
micropod ci runner-prime 32
python3 scripts/bench_go_fanout.py --runner "$(command -v micropod)" --image "$FIXTURE" \
  --scope go-pipeline --same --clients 32 --output prepared-32.json
python3 scripts/ci_benchmark_store.py runner-isolation docs/benchmarks/2026-11-20/runner-isolation.json.gz
sqlite3 "$HOME/.micropod/benchmarks/measurements.sqlite3" \
  'select series,engine,clients,round,seconds,prepare_seconds from runner_isolation_batches;'
```

The `--endpoint` and `--ubuntu` modes measure the peer engines. Python drives these measurements and imports the results into SQLite. The scheduler transport is Rust, the guest CRI client is Go, and crun runs the trusted workloads. [Runner operation and trust policy](../../ci-worker.md)
