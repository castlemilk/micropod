# Immediate-write CI worker experiment on Gamma

This experiment set `max_batch_time=0` inside the running Micropod worker. The mixed CI default uses adaptive batching. [Default worker results](../worker-profile.md)

Gamma ran Micropod and OrbStack 2.2.5 on the same 18-core M5 Max with 128 GB, macOS 26.5.1 and four vCPUs and 4 GiB per Linux VM. The signed Micropod build used Docker 29.9.3 and Linux 6.18.35. OrbStack used Docker 29.8.2. Both loaded the same native toolchain image from the archived Ubuntu run. Its ARM64 OCI configuration digest was `sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350`. The Mac timings include actual Docker clients, container creation and removal. [Matched raw samples](paired.json) · [Original ARM Ubuntu data](../ubuntu-arm64-worker-reference.json)

## Same-Mac results

Each cell is the median wall time in seconds for a whole batch. Five rounds alternated engine order and rotated concurrency. Each container received one CPU, a 256 MiB launch or 1 GiB package memory limit, a fresh workspace and the same warm offline packages. Both engines used Go 1.26.11, Node 24.22.3 and npm 11.19.1. The Ubuntu process rows measure only commands launched in prepared workspaces on a separate four-vCPU ARM host with about 15.6 GiB. This comparison reused the recorded Ubuntu run.

| Workload and runtime | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| Launch · Micropod | 0.115 | 0.165 | 0.327 | 0.745 |
| Launch · OrbStack | 3.859 | 7.317 | 15.003 | 29.104 |
| Launch · Docker on Ubuntu | 0.112 | 0.163 | 0.289 | 0.561 |
| Go · Micropod | 0.472 | 0.555 | 1.064 | 2.163 |
| Go · OrbStack | 4.929 | 9.012 | 19.920 | 43.534 |
| Go · Docker on Ubuntu | 0.579 | 0.704 | 1.373 | 2.684 |
| Go · prepared Ubuntu processes | 0.120 | 0.177 | 0.353 | 0.712 |
| npm · Micropod | 0.659 | 0.767 | 1.645 | 3.020 |
| npm · OrbStack | 4.642 | 11.958 | 19.001 | 60.904 |
| npm · Docker on Ubuntu | 0.960 | 1.088 | 2.137 | 4.183 |
| npm · prepared Ubuntu processes | 0.275 | 0.362 | 0.745 | 1.474 |

With the same Python bytecode cache warmed independently on both peers, the additional five-round 16-job Go median was **2.511 s on Micropod and 43.484 s on OrbStack**. npm took 3.640 s and 40.087 s. Both engines retained the original 73 bytecode files and 2,023,847 logical bytes through each round. In the earlier pair, 16 Go jobs took 1.134 s with this cache and 1.556 s with stock imports on Micropod. The full-batch improvement did not repeat in the latest pair. The option is scoped and opt-in. [Independent warm-bytecode run](paired-warm-bytecode.json)

| Full Go, npm and PostgreSQL pipeline | Warm 1 | Warm 2 | Warm 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Micropod | 12.566 s | 12.127 s | 13.591 s | 12.566 s |
| OrbStack | 89.760 s | 61.856 s | 74.464 s | 74.464 s |
| Docker on Ubuntu | 12.240 s | 12.243 s | 12.234 s | 12.240 s |

The PostgreSQL Testcontainers stage took a median 10.944 s on Micropod and 43.907 s on OrbStack. It overlaps the Go service build. Stage durations therefore do not add to full pipeline wall time.

The shared Mac showed considerable run-to-run variation. Individual 16-Go batches ranged from 1.638–2.667 s on Micropod and 37.428–78.977 s on OrbStack. With the adaptive setting, an independent five-round series on the same Mac measured 1.556 s and 3.683 s, and warm pipelines measured 11.939 s and 15.240 s. The filesystem experiment below alternated the settings on one VM to test causality. [Pipeline stages](pipelines.json) · [Earlier pair](previous-paired.json.gz) · [Earlier pipeline](previous-pipelines.json.gz) · [Earlier bytecode run](previous-warm-bytecode.json.gz)

## Where the 16-job Go time goes

In the Micropod worker, 16 prepared Go processes completed in **0.656 s**, compared with **0.712 s** in the archived raw Ubuntu run. All 1,220 Go builds in the scale profile produced the expected binary using warm compiled packages. The original counter missed environment-prefixed linker commands, so its linker counts are invalid. The harness and Docker lifecycle account for much of the remaining fresh-container wall time. The toolchain image ships Python source and the harness imports it separately for each fresh container. A cache dedicated to this source and toolchain allows the jobs to reuse compiled imports. [Corrected Go comparison](../fresh-go.md)

| 16-job profile, five-round medians | Whole batch | Last job’s Python setup and workspace | Last job’s Go build | Guest disk writes | Guest ext4 sync entries |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fresh Docker container | 4.619 s | 1.486 s | 0.488 s | 107.5 MiB | 927 |
| Fresh container with tmpfs scratch | 3.527 s | 1.439 s | 0.625 s | 90.6 MiB | 943 |
| Fresh container with warm bytecode | 2.005 s | 0.224 s | 0.736 s | 62.8 MiB | 903 |
| Prepared processes in one container | 0.656 s | 0.254 s | 0.656 s | 5.3 MiB | 42 |

The last job is the client that finished last in each round. The setup phase starts at the first timestamp inside the Python fixture and ends when it launches Go. Guest disk and sync counts cover the sample interval inside each batch, including guest activity across containers. The prepared-process row times Go alone, although the guest counters also see setup and teardown of its single wrapper. Median total cgroup throttling during the 16 ordinary Go build commands was 0.0 ms. At 32 clients, ordinary containers took 6.525 s, containers with warm bytecode 3.737 s and prepared processes 1.325 s. The traced series includes observer overhead and runs separately from the peer comparison.

The trace covers 100 batches, 940 timed Docker clients, 1,976 guest samples and 18,436 timeline events and counters. The largest reported trace-buffer loss was 0 events. It includes Docker create/start/exit/removal, guest job phases, pressure stalls, block I/O, mounts, process creation and ext4 sync activity. Decompress the trace and open it in Perfetto. [Full profile](profile.json.gz) · [Perfetto trace](kernel.trace.json.gz)

## Filesystem and cache changes

Two independent seven-round trials alternated ext4’s default 15 ms synchronous batching limit with zero on a dedicated worker. The timed command was a fresh, CPU-limited Docker container with a shell running Go directly, using the same cached module and compiled objects. Every job checked the resulting executable. Both settings kept ordered journaling and write barriers enabled. [Linux ext4 options](https://docs.kernel.org/admin-guide/ext4.html)

| 16-job Go trial | Default batching | Zero batching | Reduction in median wall time |
| --- | ---: | ---: | ---: |
| 1 | 1.794 s | 1.304 s | 27.3% |
| 2 | 1.300 s | 0.985 s | 24.2% |

Zero batching was faster in 11 of 14 paired Go rounds. A fresh worker reported `max_batch_time=0`, `data=ordered` and `barrier`. The live worker retained its boot and Docker daemon ID through this experiment and when adaptive batching was restored. [Both trials and mount verification](ext4.json)

A third trial used the exact stock offline package benchmark, five alternating rounds per setting and 16 fresh containers per batch. At 15 ms and zero batching respectively, Go took 3.408 s and 3.730 s, and npm took 4.295 s and 4.968 s. Zero batching was faster in 2/5 Go rounds and 2/5 npm rounds. The fixture checked the package identities and restored the original setting on its private VM. [Full package A/B samples](ext4-packages.json.gz)

The scale fixture retained one npm payload (221 bytes), one Go module archive and 438 build-cache files (33,085,592 bytes). Initial and final payload inodes and sizes matched. On Gamma’s persistent stores, two active containers shared all three mounts. The usage snapshot counted 35 BuildKit records and 142 accumulated uses. Package identity checks establish reuse. BuildKit record uses and volume attachments are separate counters. [Live cache snapshot](metrics.json)

Across the sixteen sample image builds on each engine, BuildKit reported 88 cached Dockerfile steps and 0 executed on Micropod, and 88 cached and 0 executed on OrbStack. A separate cold, repeat and source-edit sequence verified an executed RUN, a cache hit and an executed RUN reading the retained cache mount. [Per-step build traces](buildkit.json)

## DNS recovery with live containers

The original failure left the Docker socket reachable while macOS routed the worker subnet through the physical interface. In the physical fault test, removing both network attachments belonging to the disposable worker made its Mac gateway disappear and broke DNS and HTTPS in a running container. The supervisor detected the missing gateway and repaired it in 2.063 s. The same container read its original file, resolved the registry and fetched HTTPS on the same boot and daemon.

In a second test, removing the guest default route interrupted DNS inside a running Compose service. Automatic detection and recovery took 21.727 s, including 2.221 s for the repair. The service kept its named volume, its writable Mac checkout and its published port. The production worker independently logged a 2.132 s repair for a missing host gateway. [Physical network data](network.json) · [Production worker metrics](metrics.json)

The signed build used in this experiment repeated both physical cases. The missing host gateway repaired in 2.917 s. The route-loss Compose test recovered in 14.133 s including detection, serving the shared file over the same published port afterward. During the matched runs the persistent worker recorded a second automatic host-gateway repair in 2.494 s on the same boot. [Recovery records](network.json)

The experimental signed CLI SHA-256 was `afdf8124e2722c1083d57f20a3b275d209971bd622e7e1ecce4a414aa7e4be53`. The scale run ID was `2539ef831e87436b8e67c11df38c83c7`. Local physical qualifications, Apple pairs and kernel profiles now append to `~/.micropod/benchmarks/measurements.sqlite3`. The worker qualification on GitHub is manual. [Run the measurements and query the data](../../../ci-worker.md#network-recovery-and-profiling)
