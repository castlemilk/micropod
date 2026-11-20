# Warm CI on Apple Silicon, OrbStack and ARM Ubuntu

Gamma ran Micropod and OrbStack on the same 18-core Apple M5 Max with 128 GB of RAM and macOS 26.5.1. The two Mac VMs each had four vCPUs and 4 GiB configured. Docker reported 4,118,708,224 usable bytes for Micropod and 4,180,480,000 for OrbStack. Both used the same macOS Docker client, version 29.7.2. Micropod ran Docker 29.9.3 and OrbStack 2.2.5 ran Docker 29.8.2. Each reused one Linux kernel. The matched Ubuntu control used Docker 28.0.4 on a separate four-vCPU GitHub-hosted ARM64 Ubuntu runner with 15.57 GiB of usable memory. Per-container limits matched across machines. [Mac samples](gamma-worker-orbstack-ubuntu.json) · [Ubuntu samples](ubuntu-arm64-worker-reference.json)

## Warm launch and exit

Median elapsed milliseconds for the entire batch over five rounds. The Mac clock starts before invoking `micropod ci run` or `docker run --rm` and stops after the clients exit. Every container ran the same pinned ARM64 Alpine image with one CPU, 256 MiB and networking disabled. The harness checked the kernel ID, both output streams, and the expected nonzero exit code. Engine order alternated and the order of concurrency levels rotated.

| Runtime | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| Micropod on Gamma | 67 | 114 | 167 | 322 |
| OrbStack on Gamma | 236 | 659 | 1878 | 2746 |
| Docker on ARM Ubuntu | 112 | 163 | 289 | 561 |

The first independent Mac series recorded 0.661 s for 16 Micropod launches and 30.408 s for OrbStack. Across the five rounds in that series, OrbStack's 16-job batches ranged from 2.74–33.02 s. In the matched Ubuntu series, they ranged from 1.96–17.08 s. Gamma was a shared runner. Each Mac series validated 145 timed launches per engine on distinct kernels and Docker daemons. [First Mac series](gamma-worker-orbstack.json) · [Matched repeat](gamma-worker-orbstack-ubuntu.json)

## Offline npm and Go

Median elapsed seconds for a whole batch. Every container received a fresh workspace, a one-CPU limit and 1 GiB of memory. Each round started with one seeded npm volume, one Go module volume and one Go build volume per engine. The empty-store controls failed offline as expected. The warm jobs verified their output, and warm Go builds invoked the compiler and assembler zero times. Each engine ran 145 timed jobs for each package manager.

| Runtime and workload | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| Micropod on Gamma · npm | 0.391 | 0.488 | 0.917 | 1.896 |
| OrbStack on Gamma · npm | 0.581 | 1.034 | 1.589 | 3.870 |
| Docker on ARM Ubuntu · npm | 0.960 | 1.088 | 2.137 | 4.183 |
| Processes on ARM Ubuntu · npm | 0.275 | 0.362 | 0.745 | 1.474 |
| Micropod on Gamma · Go | 0.291 | 0.380 | 0.688 | 1.442 |
| OrbStack on Gamma · Go | 0.552 | 0.873 | 1.463 | 3.025 |
| Docker on ARM Ubuntu · Go | 0.579 | 0.704 | 1.373 | 2.684 |
| Processes on ARM Ubuntu · Go | 0.120 | 0.177 | 0.353 | 0.712 |

All three engines loaded the package image exported from the measured Ubuntu allocation. Its ARM64 OCI configuration digest was `sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350`. Ubuntu also ran the same Go, Node and npm binaries as ordinary host processes. Those rows time the tools in prepared workspaces and omit container creation, teardown and per-container resource limits. [Ubuntu job and artifacts](https://github.com/castlemilk/micropod/actions/runs/44632524412) · [Raw process measurements](ubuntu-arm64-worker-reference.json)

## Complete CI pipeline

The Go and Node pipelines ran concurrently. They built and tested the applications, ran Go vet and race checks, started PostgreSQL through Testcontainers, checked the running Go service, and rebuilt and executed Node after a source edit. Each engine first completed a priming run. The table gives subsequent client wall times in seconds. The individual stages overlap.

| Runtime | Warm pass 1 | Warm pass 2 | Warm pass 3 | Median |
| --- | ---: | ---: | ---: | ---: |
| Micropod on Gamma | 13.48 | 12.07 | 13.02 | **13.02** |
| OrbStack on Gamma | 21.13 | 33.77 | 21.66 | **21.66** |
| Docker on ARM Ubuntu | 12.24 | 12.24 | 12.23 | **12.24** |

The PostgreSQL stage took a median of 10.79 s on Micropod. The first passes on Gamma used different existing build caches and are recorded separately in the raw results. [Mac pipeline stages](gamma-worker-pipelines.json) · [Ubuntu pipeline stages](ubuntu-arm64-worker-reference.json)

## Kernel startup and cache persistence

Sixteen simultaneous requests on Gamma prepared one new journaled worker disk and reached the same kernel in 7.80–7.82 s with the bootstrap image already present. Restarting that worker cleanly took 0.98–1.03 s for 16 callers. After the idle guest flushed its data and the supervisor was killed, ext4 replayed the journal. Sixteen callers recovered in 1.39–1.40 s. The boot ID changed and the Docker identity persisted.

Sixteen concurrent off-network jobs per package manager used `micropod ci run --cache-scope`. Both package payloads retained their inodes across fresh workspaces, clean restart and forced exit. npm retained one 221-byte payload. The Go module store retained nine files including one module archive. The Go build store stayed at 438 files and 33,085,592 logical bytes. A second scope could not satisfy either offline dependency. [Startup, recovery and cache checks](gamma-worker-recovery.json)

The first Mac series used worker revision `f20e0b1536f09e698e06212002c46774305ab438`. The matched repeat and full Mac pipeline used `fd8ebe14bc0112b31daef908417deac25d70f4e4` with signed executable SHA-256 `a0a669cf533cad3945b81df9ff58653d791d2aa669d81bde4567faa611b1f633`. Use `task bench-ci-apple` with the exported Ubuntu artifact to repeat the measurements. [Worker setup and benchmark command](../../ci-worker.md)
