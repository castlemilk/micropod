# Concurrent sandbox disk preparation on Gamma

On 19 November 2026, 16 local processes starting against an empty Micropod disk cache prepared and verified their disks in **0.978 s** median with the per-disk lock. On master, fully successful batches took **4.113 s**. At that concurrency the older code also lost 15 of 128 workers during the APFS clone. All 128 workers succeeded with the change.

## Scaling on physical Apple Silicon

Measurements used Gamma’s Apple M5 Max, 18 cores, 128 GiB and APFS on macOS 26.5.1. The one-minute load average ranged from 27.1 to 41.6. Eight rounds at each concurrency alternated which version ran first and rotated the order of the concurrency levels. Both versions used optimized Swift 6.3.3 and Containerization 0.42.0 on the same host.

| Simultaneous workers | Before, cold | After, cold | Before, verified cold workers | After, verified cold workers | Before / after, warm |
|---:|---:|---:|---:|---:|---:|
| 1 | 0.743 s | 0.724 s | 8/8 | 8/8 | 43 / 32 ms |
| 4 | 0.923 s | 0.610 s | 32/32 | 32/32 | 43 / 35 ms |
| 8 | 1.720 s | 0.734 s | 61/64 | 64/64 | 53 / 53 ms |
| 16 | 4.113 s | 0.978 s | 113/128 | 128/128 | 102 / 84 ms |

Wall times are median seconds to finish a whole batch in which every worker passed. At 8 and 16 workers, five of eight old cold batches qualified in each case. Counting every batch, including partially failed ones, gives 2.759 s and 4.030 s respectively. All 32 new cold batches and all 64 warm batches qualified. Singleton and warm differences were small relative to the range observed on this busy machine. An earlier five-round series measured 2.785 s to 1.089 s at 16 workers. [Balanced samples, image digests and recovery results](gamma.json) · [Earlier series](initial-series.json)

At 16 workers the median total CPU consumed per cold batch fell from **8.258 to 1.042 CPU-seconds**. Master unpacked the Alpine root 128 times and the guest boot disk 113 times across the eight batches. The change unpacked each disk eight times, once per cold batch. On warm hits both versions went straight to the cached file.

## What ran

Each independent process executes the production disk-resolution, image selection, unpack and APFS clone functions from the revision being measured. Both versions read the same pre-staged arm64 OCI layers, prepare a 256 MiB Alpine 3.19.9 root and a 512 MiB vminit 0.47.0 disk, and give each worker a separate writable root clone. This is the fallback vminit version present on this Mac. The benchmark uses private temporary output directories. A cold batch begins without either realized ext4 disk. A warm batch immediately reuses the two published disks.

Timing starts when the parent releases a barrier after all worker processes have initialized their image store. It ends when they return. Each worker reads its Alpine release and the full BusyBox binary from its clone, then reads the first 4 KiB of vminitd from ext4. The parent checks the returned hashes against the OCI input. Each version also passed a complete guest-agent hash in an untimed cold run. After each measured batch, a write to one clone was checked against the base and every other successful clone. Worker startup and this final write check are outside the wall timer. Aggregate CPU includes worker process startup and exit.

Every old cold failure returned `ENOENT` while cloning a shared root disk as other workers published replacements. On two additional runs, a worker was interrupted with `SIGKILL` once partial data existed, first while writing the Alpine root and then while writing the guest boot disk. A waiting process recovered both times, verified the full BusyBox and vminitd hashes, and left zero partial files.

## How this relates to Ubuntu

GitHub’s Ubuntu Docker benchmark had a running daemon, a running Linux kernel and a pulled image. A new container reused that kernel. The AWS us-east-1 runner took 88 ms for one verified lifecycle and 497 ms for 16 together. A four-vCPU Azure West US 3 runner with the same image took 962 ms for 16. The 55.260 s Mac figure came from a different workload on a virtualized Intel Mac running OrbStack. That test used a debug Micropod Docker client, detached launches, wait, inspect, logs, removal and a final absence check. [Runtime comparison and original jobs](https://github.com/castlemilk/micropod/blob/a5b0b49dfab7a5490c0376c8aa033b32cdc72e6a/docs/benchmarks/2026-11-19/product-comparison.md)

The physical Mac measurements here stop before a VM boots. The last recorded whole-lifecycle result on Gamma was 360 ms for a cache-warm fresh Micropod sandbox. Its trace attributed about 200 ms to waiting for the guest agent and 70 ms to the Virtualization framework starting the VM. A new whole-guest run from this session was blocked before guest entry by macOS permissions. [Physical-Mac lifecycle timings and phase breakdown](../../../performance.md)

## Replay

From the candidate checkout on an Apple Silicon Mac, build the release benchmarking product and run the opt-in matrix. The worker links the same optimized SwiftPM dependency objects for both versions, compiles the revision-specific disk methods, and stages only the pinned local OCI blobs into a temporary directory. The bundled replay requires the Alpine 3.19 and Apple vminit 0.47.0 image digests recorded in the receipt and the Git objects for the baseline and candidate.

```sh
swift build -c release --product MicropodBench
python3 docs/benchmarks/2026-11-19/sandbox-disk-cache/replay.py --out /tmp/micropod-disk-samples.json
```

Use `--clients 1 4 --rounds 2` for a quick check. The standard PR suite exercises contention and retry with two small filesystem tests. The scaling benchmark runs on request.
