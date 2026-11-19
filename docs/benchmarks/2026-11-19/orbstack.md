# OrbStack benchmarks, 19 November 2026

OrbStack 1.5.1 (build 16857) ran a native amd64 Linux guest on four-vCPU GitHub-hosted Intel Macs. Docker Engine 25.0.5 identified its operating system as OrbStack and returned a 6.7.11-orbstack kernel. The host ran macOS 15.7.9 with 14 GiB of RAM. The measurement hosts were virtualized. The Docker server reported four vCPUs and approximately 4.47 GiB of guest memory.

## Container scaling

Median wall time per complete batch, in seconds. Each fixture requested one CPU and 64 MiB per container, disabled networking, and checked exit code 23 and the expected stdout and stderr separately. Each sample used fresh container IDs and included removal. One warm-up at each concurrency was excluded. The five-block CLI run passed all 20 measured batches (145 container executions). The direct API run passed all nine measured batches (39 executions).

| Simultaneous containers | Docker CLI, 5 blocks | CLI min–max | Direct Engine API, 3 blocks | API min–max |
|---:|---:|---:|---:|---:|
| 1 | 1.740 | 1.598–2.772 | 3.093 | 3.048–3.605 |
| 4 | 3.486 | 3.234–4.357 | 6.899 | 5.397–8.588 |
| 8 | 7.117 | 6.465–7.436 | 11.532 | 10.795–13.029 |
| 16 | 15.775 | 13.212–17.174 | unmeasured | — |

Dividing each batch size by its median completion time gives 0.57, 1.15, 1.12, 1.01 successful container lifecycles per second at 1, 4, 8 and 16 clients respectively. The highest observed rate for this workload on the four-vCPU runner occurred at four clients.

The CLI used `docker run --rm` against a selected local context. The direct API used separate requests to create, start, wait for, retrieve multiplexed logs from, and remove each container. These columns came from separate Mac allocations with different API sequences. A subtraction between them would confound host variation and workload differences.

[CLI samples](orbstack-cli-samples.json) · [Direct API samples](orbstack-api-samples.json) · [CLI run](https://github.com/castlemilk/micropod/actions/runs/44475818424) · [Direct API run](https://github.com/castlemilk/micropod/actions/runs/44477775270)

## Builds and compatibility

One observation per build case in the five-block CLI run. Timings include the Buildx invocation, image load, execution, cleanup of the verification container and inspection of the output. The fixture uses a static executable, a multi-stage Dockerfile and no registry pull.

| Build case | Seconds | Verified solver behavior |
|---|---:|---|
| solver-no-cache | 16.485 | Executed |
| warm | 5.108 | Cached |
| edited | 7.578 | Executed |
| chmod-only | 6.529 | Executed |
| ignored-only | 4.754 | Cached |

The CLI also passed multi-stage local export, process identity, read-only binds, named-volume persistence, network DNS, exec streams, signal handling, wait/logs, Compose up/exit/down and resource cleanup.

Root filesystem import and inspection completed in **0.787 s**. The post-create network attachment scenario completed in **9.444 s**, including network and container creation, start, attach, membership verification and deletion. The [native Micropod shim receipt](https://github.com/castlemilk/micropod/blob/d0d0009e2c6f2f7c049a9d10a8ca0c7047007678/docs/benchmarks/2026-11-19/native-ci-summary.json) records HTTP 501 for both requests on the version in [PR #216](https://github.com/castlemilk/micropod/pull/216).

## Reading Micropod SharedFS views from an OrbStack container

The host built and verified a filtered APFS tree with the production Micropod SharedView implementation. OrbStack read that tree through a read-only host bind and through a preseeded, read-only guest volume. Each timed run launched BusyBox, checked the symlink and absence of the ignored directory, counted every regular file, verified all SHA-256 hashes and removed the container. Image pull, view creation and volume seeding happened before timing. These figures include container lifecycle and hashing, with warm caches.

| Contents of tree | Regular files checked | Host bind median (range), s | Named volume median (range), s |
|---|---:|---:|---:|
| 512 small files + 16 MiB payload | 515 | 2.360 (2.201–2.711) | 2.068 (1.702–2.881) |
| 4,096 small files + 16 MiB payload | 4,099 | 5.030 (4.737–6.310) | 2.175 (2.005–2.229) |
| 64 small files + 256 MiB payload | 67 | 7.128 (4.938–7.580) | 7.085 (5.891–7.409) |

All 18 measured scans passed. The host reported 516, 4,100 and 68 per-file APFS clones for the three trees, with zero fallback copies. Each group had one excluded warm-up, then three measured passes with alternating mount order. Small files were 4 KiB each. The counts also include the ignore file, an empty file and the payload.

[Raw measurements and file manifests](orbstack-filesystem.json) · [Full storage receipt with manifests](https://github.com/castlemilk/micropod/actions/runs/44478828113/artifacts/14508335167) · [Measurement run](https://github.com/castlemilk/micropod/actions/runs/44478828113) · [Verified artifact digest](https://github.com/castlemilk/micropod/actions/runs/44481943176)

## Same-host comparison and incomplete attempts

Colima 0.10.3 using Apple Virtualization.framework reached SSH on the first allocation, then Lima failed to report a running VM. That setup step took 13 min 50 s. A second attempt with QEMU on the filesystem runner reached its 12-minute setup budget without publishing a verified Docker endpoint or a paired batch. Neither attempt yielded a same-host OrbStack–Colima timing. [VZ attempt](https://github.com/castlemilk/micropod/actions/runs/44475818424) · [QEMU attempt](https://github.com/castlemilk/micropod/actions/runs/44478828113)

A separate seven-block OrbStack run exceeded its 30-minute job limit during the CLI workload. GitHub marked it cancelled and uploaded no sample artifact. The timing distributions above use the independent five-block CLI run and three-block API run. [Timed-out run](https://github.com/castlemilk/micropod/actions/runs/44475267828)

## Apple Silicon reference from published raw measurements

The following medians were recalculated from all 12 timings per case in a separate published experiment on an Apple M3 with 16 GB and macOS 26.4.1, dated 20 April 2026. The author configured 4 CPUs and 4 GB per container. OrbStack reported 8 virtual CPUs. These are different fixtures and come from a third party. Apple Container is the upstream executable at version 0.11.0. Micropod did not participate in that experiment.

| End-to-end workload, seconds | OrbStack 2.0.5 | Docker Desktop (Engine 29.4.0) | Colima 0.10.1 | Apple Container 0.11.0 |
|---|---:|---:|---:|---:|
| Start Alpine, echo, remove | 0.372 | 0.3225 | 0.279 | 0.8765 |
| Write 1,000 × 4 KiB to bind mount | 0.622 | 0.716 | 0.7705 | 1.2555 |
| Write and fsync 256 MiB | 0.5325 | 0.5305 | 0.4635 | 1.1185 |
| Read 256 MiB | 0.4 | 0.4105 | 0.355 | 1.01 |
| Build Dockerfile without solver cache | 4.951 | 4.802 | 6.795 | unmeasured |

[Original raw samples](https://github.com/zot24/macos-container-benchmarks/tree/f67e6fc78dd9a2e61d7f9544b2afb41d6a4e20fc/results/tahoe) · [Upstream methodology](https://github.com/zot24/macos-container-benchmarks/blob/f67e6fc78dd9a2e61d7f9544b2afb41d6a4e20fc/README.md)

## Version and comparison limits

OrbStack 2.2.5 (build 21124) rejected the virtual CPU before the guest started on both the macOS 15 and macOS 26 Intel pools. The macOS 26 runner exposed family 6, model 58. The installer hashes were verified against the Homebrew cask records and macOS checked the app signature. The older Intel release was the version identified in the OrbStack diagnostic. On 3 fresh installations with a saved start record, the first OrbStack command to the first successful Docker `/info` response took 53.74 s, 43.95 s, 62.98 s. Installation time was outside this interval.

The Micropod repository listed no self-hosted runners, the local Apple Silicon Mac had no OrbStack installation or context, and the local Micropod and Docker Desktop sockets denied access. A same-Mac product speed ratio for Micropod and OrbStack remains unmeasured.

[2.2.5 on macOS 15](https://github.com/castlemilk/micropod/actions/runs/44473797114) · [2.2.5 on macOS 26](https://github.com/castlemilk/micropod/actions/runs/44475466720) · [First 1.5.1 engine response](https://github.com/castlemilk/micropod/actions/runs/44474582767) · [Benchmark workflow](../../../.github/workflows/orbstack-live.yml)

## Running these workloads

The full CLI qualification took 4 min 17 s, the direct API checks took 2 min 1 s, and the filesystem comparison took 3 min 11 s. These are measured workflow step durations. Installation and VM startup are additional. The final workflow only runs when dispatched. Its API, CLI and storage profiles each have a 15-minute job limit. The optional paired-engine profile has a 20-minute job limit. Pull requests add zero OrbStack benchmark jobs.

Run these commands from this revision on a Mac with a running `orbstack` Docker context, Go, Xcode command-line tools, Docker Buildx and Compose.

```sh
output=$(mktemp -d)
python3 scripts/qualification/engine.py --context orbstack --clients 1 4 8 16 --rounds 5 --json "$output/cli.json"
python3 scripts/qualification/orbstack_api.py --clients 1 4 8 --rounds 3 --json "$output/api.json"
python3 scripts/qualification/orbstack_files.py --rounds 3 --json "$output/files.json"
```

The CLI and API compile a native Linux executable locally. The filesystem lane pulls its digest-pinned BusyBox verifier once before measurement. The workloads exercise the features listed above. Kubernetes, Linux VM lifecycle, multi-platform builds and formal OCI conformance have no result in these runs.
