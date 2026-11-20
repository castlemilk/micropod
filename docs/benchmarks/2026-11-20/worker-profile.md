# Warm Docker CI on Gamma

Micropod runs stock Docker Engine 29.9.3, Compose and BuildKit inside one persistent Linux 6.18.35 VM. Gamma is an 18-core Apple M5 Max with 128 GB on macOS 26.5.1. Micropod and OrbStack 2.2.5 each had four vCPUs and 4 GiB. Both used the same ARM64 image as the archived four-vCPU Ubuntu run, with Go 1.26.11, Node 24.22.3 and npm 11.19.1. Its native OCI configuration digest was `sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350`.

## Default worker versus OrbStack

The shipping build repeated the 16-client workloads in three alternating rounds. An earlier five-round series on the same kernel measured 1, 4, 8 and 16 clients. Both series used adaptive ext4 batching and timed fresh Docker containers from the Mac. Startup used one CPU and 256 MiB per container. Offline Go and npm jobs used one CPU, 1 GiB, fresh workspaces and persistent package stores. Both pipeline medians cover three warm passes after a separate first pass.

| Workload | Micropod, shipping build | OrbStack, same run | Micropod, earlier | OrbStack, earlier |
| --- | ---: | ---: | ---: | ---: |
| 16 launches | 0.958 s | 10.020 s | 0.300 s | 2.611 s |
| 16 warm Go jobs | 2.828 s | 13.862 s | 1.556 s | 3.683 s |
| 16 warm npm jobs | 4.104 s | 23.118 s | 2.127 s | 4.704 s |
| Go, npm and PostgreSQL pipeline | 13.189 s | 30.371 s | 11.939 s | 15.240 s |

OrbStack’s first qualifying pass exited during the PostgreSQL stage after 31.414 s. The stage timings are retained with its failure status. Warm medians use three subsequent completed passes on each engine. [First attempt](worker-profile/adaptive-pipeline-first-attempt.json)

The PostgreSQL Testcontainers stage took 10.995 s on the shipping worker and overlapped the Go service build. OrbStack’s absolute wall times varied widely on this shared Mac. The archived native Docker control on ARM Ubuntu measured 0.561 s for 16 launches, 2.684 s for Go, 4.183 s for npm and 12.240 s for the full pipeline. Raw Ubuntu timed prepared commands and measured 0.712 s for Go and 1.474 s for npm. That runner had different hardware and about 15.6 GiB usable RAM. [Shipping rounds](worker-profile/adaptive-paired.json) · [Pipeline stages](worker-profile/adaptive-pipelines.json) · [Earlier 1–16 client series](worker-profile/previous-paired.json.gz) · [Ubuntu reference](ubuntu-arm64-worker-reference.json)

## Why fresh Go jobs take longer

On the shipping kernel, 16 prepared Go commands finished in **0.396 s**. All 732 timed Go builds produced the expected executable using warm compiled packages. The original linker counter missed commands prefixed by a Go environment assignment. Its zero-link counts are invalid. The direct follow-up verified real linker invocations on Ubuntu and measured identical executables on Gamma. The isolated offline fixture retained one npm payload, one Go module archive and 438 compiled-cache files (33,085,592 bytes). Their payload inodes and cache sizes matched before and after the run. [Corrected Go comparison](fresh-go.md)

| Shipping worker, 16 jobs | Batch wall time | Last job’s Python setup and workspace | Last job’s Go build | Guest writes |
| --- | ---: | ---: | ---: | ---: |
| Fresh Docker container | 1.767 s | 0.860 s | 0.488 s | 107.0 MiB |
| Fresh container with tmpfs scratch | 1.952 s | 0.795 s | 0.279 s | 84.4 MiB |
| Fresh container with shared bytecode | 0.978 s | 0.143 s | 0.476 s | 64.8 MiB |
| Prepared processes in one container | 0.396 s | 0.144 s | 0.396 s | 0.4 MiB |

The last job is the client that finished last in each round. The Python phase starts at script entry. The disk samples cover guest activity during each batch. The prepared-process clock surrounds the Go commands alone. The ordinary 16-container batch recorded a median 920 ext4 sync entries and 0.0 ms of cgroup throttling during Go. At 32 clients, fresh containers took 4.452 s, containers with warm bytecode 2.028 s and prepared processes 0.790 s. Peer timings were collected separately from kernel instrumentation.

The shipping trace covers 60 batches, 564 timed Docker clients, 671 kernel samples and 7,974 timeline events and counters. Tracefs reported 0 lost events. Open the decompressed trace in Perfetto to see container creation, process setup, Go execution, removal, disk I/O, pressure stalls and filesystem activity. [Shipping kernel profile](worker-profile/adaptive-profile.json.gz) · [Perfetto trace](worker-profile/adaptive-kernel.trace.json.gz)

## File and cache settings

Adaptive synchronous write batching is the mixed-CI default. In five alternating trials of the exact 16-job package workload, Go took 3.408 s with adaptive writes and 3.730 s with immediate writes. npm took 4.295 s and 4.968 s. Two independent seven-round trials running Go directly from a shell instead saw median reductions of 24–27% with immediate writes. Dedicated workers can choose `MICROPOD_CI_EXT4_MAX_BATCH_US=0` at provisioning. Both modes retain ordered journaling and disk barriers. A fresh boot, a legacy worker and a restarted dedicated worker verified the respective settings. [Exact workload A/B](worker-profile/ext4-packages.json.gz) · [Direct-shell trials](worker-profile/ext4.json) · [Live settings](worker-profile/adaptive-setup.json) · [Complete immediate-write experiment](worker-profile/immediate-writes.md)

Python bytecode sharing and tmpfs scratch are opt-in. Across the five-round adaptive peer series, warming bytecode reduced the 16-Go median from 1.556 s to 1.134 s on Micropod. In the separate immediate-write series it went from 2.163 s to 2.511 s. The retained files and the guest phase timings identify the work saved. End-to-end timings vary with host load. [Adaptive warm-bytecode series](worker-profile/previous-warm-bytecode.json.gz) · [Immediate-write warm-bytecode series](worker-profile/paired-warm-bytecode.json)

Two live containers shared the same npm, module and compiled Go volumes. Across 16 Micropod and 20 OrbStack image builds, including images built during the failed first pass, BuildKit reported 88 cached Dockerfile steps and 0 executed on Micropod, and 110 cached and 0 executed on OrbStack. A fresh qualification exercised two executed steps, two hits on the unchanged build, and two executed steps after a source edit that retained its mutable cache. Live metrics expose bytes, active attachments, BuildKit records and cumulative uses. [Two simultaneous volume users](worker-profile/metrics.json) · [Shipping inventory](worker-profile/adaptive-metrics.json) · [Shipping step traces](worker-profile/adaptive-buildkit.json.gz) · [Cold, warm and edited builds](worker-profile/buildkit.json)

## DNS recovery

On Gamma, the Docker socket had stayed up while the route to the guest fell through to the Mac’s physical interface. The repair reconnects the worker’s network device and restores the guest route. In two physical tests that removed the Mac gateway, the running container recovered DNS and HTTPS on the same boot and daemon. Repairs took 2.063 s and 2.917 s. After removing the guest route in a running Compose service, detection and recovery took 21.727 s and 14.133 s in separate trials. The writable checkout, named volume and published HTTP port survived. The production worker recorded automatic repairs in 2.132 s and 2.494 s on the same boot. [Fault injections and recovery](worker-profile/network.json)

The shipping CLI SHA-256 was `68c53cb50b0453309cd3db97473a87e393f7bc1b2920a57ca312f98934548d69`. Its profile run ID is `b8292b0830c64e3db2a38250a78de598`. The runner keeps the receipts in `~/.micropod/benchmarks/measurements.sqlite3`. The dedicated GitHub qualification is manual. [Commands, perf traces and SQL examples](../../ci-worker.md#network-recovery-and-profiling)
