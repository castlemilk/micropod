# Apple Silicon runtime and shared-cache measurements

## Same-machine runtime comparison

Gamma is a physical 18-core M5 Max with 128 GB of memory. The September 30 run interleaved native ARM workloads on macOS 26.5.1 with two CPUs and 2 GiB per workload. Launch includes command exit and teardown. The Go job was vet plus test with downloaded modules present and the build cache deliberately cleared. The four-job column is median wall time for a complete batch.

| Runtime on Gamma | Launch and exit, n=10 | One Go job, n=3 | Four Go jobs, n=3 |
|---|---:|---:|---:|
| Micropod sandbox CLI | 360 ms | 10.29 s | 15.12 s |
| Micropod sandbox via Connect | 480 ms | 10.12 s | 15.64 s |
| Apple Container CLI | 770 ms | 10.62 s | 19.18 s |
| Micropod Apple engine via Connect | 800 ms | 10.66 s | 19.33 s |
| Docker Desktop CLI | 230 ms | 12.18 s | 19.07 s |

The historical harness retried some commands and its Connect path could accept an unknown outcome. Host load also matters. The [original measurements](../../performance.md) include another series under substantially higher load. Fresh ARM64 OrbStack and Micropod persistent-kernel guest timings still require a physical Mac with both services accessible. The current Gamma work session could use the native toolchains and shared filesystem daemon directly. Its access to the container and virtualization services stopped before guest execution.

## Offline package caches on Gamma

Go 1.27.2, npm 11.19.1 and Node 24.22.2. We seeded fresh private stores with a deterministic npm tarball and a Go module on a local file-based proxy. We then removed every origin file. An independent empty store failed for each tool. Five blocks at 1, 4, 8 and 16 clients created 145 new checkouts per tool. Every checkout ran the installed module or compiled binary and verified its output. Go used `-trimpath` across different checkout paths. These measurements use native macOS processes. They exclude fixture preparation and product verification from the timed install/build.

| Workload, median batch | 1 checkout | 4 | 8 | 16 |
|---|---:|---:|---:|---:|
| Offline npm ci | 202 ms | 233 ms | 321 ms | 505 ms |
| Warm Go build | 121 ms | 158 ms | 217 ms | 302 ms |

The initial Go build took 3.43 s and invoked the compiler or assembler 106 times. All 145 warm builds together made zero such calls. Across the run, npm retained one 229-byte content blob, the module cache retained one fixture ZIP, and the Go build cache stayed at 410 files and 36,805,525 logical bytes. Both payloads kept their original inode. An independently seeded control produced its own copies. On the same Mac an additional project with a different npm lockfile root, Go module path and main source reused both dependency payloads offline. It compiled its own main package exactly once and returned its distinct output. The byte counts cover this fixture's active stores. Workspace outputs, migration backups and physical APFS block usage have separate accounting. [Raw timings, negative controls and cache sizes](package-caches-gamma-arm64.json).

## Micropod cache bind cost on Gamma

For a cache bind, the Docker shim consumes a view ID and filesystem path. Previously the daemon also enumerated the directory tree for its size on every shared acquisition. The shim now requests the ID and path directly. The comparison alternated both operations against the same three pinned production daemon views, backed by real npm, Go module and Go build stores. Every client acquired all three, every returned view was verified, and the last unmount released all views. These five-block measurements use the in-process production daemon and exclude container launch and socket transport.

| Median bind batch on Gamma | 1 client | 4 | 8 | 16 |
|---|---:|---:|---:|---:|
| Previous request with a tree-size scan | 6.18 ms | 16.49 ms | 29.90 ms | 60.63 ms |
| Bind request used by the shim | 0.065 ms | 0.168 ms | 0.299 ms | 0.550 ms |

[Raw bind measurements](cache-binds-gamma-arm64.json). For a fresh run, compile `scripts/bench_cache_bind.swift` with the production shared-filesystem sources and pass the executable to `scripts/bench_package_caches.py --bind-binary`. The default transport is the production Unix socket. The direct transport can measure the daemon in isolation.

## Raw warm Ubuntu target

The GitHub-hosted Ubuntu ARM64 runners had four vCPUs, Docker 28.0.4, a live kernel and an already-pulled native Alpine image. Each timed command was a full `docker run --rm` with one CPU, 256 MiB and networking disabled. The guest checked its kernel boot ID, emitted distinct stdout and stderr tokens and exited 23. Separate overlapping containers verified PID and mount isolation and the cgroup limits. The measurements exclude VM startup, image pulls and builds.

| Median complete container batch | 1 client | 4 | 8 | 16 |
|---|---:|---:|---:|---:|
| First two Ubuntu ARM64 allocations | 122–127 ms | 181–201 ms | 304–340 ms | 590–599 ms |
| Third kernel boot, also used for the package suite | 122 ms | 186 ms | 316 ms | 641 ms |

All 435 measured launches across three distinct kernel boots passed. The package run and the second launch reference report the same Docker daemon ID and runner name. These are three boots and two observed daemon identities. The physical rig matrix computes a ratio of Apple batch time divided by the matching Ubuntu batch time. A value of 1.00 means equal elapsed time. It checks workload identity, native image, repetitions, completion counts and per-container resource limits, and reports the engine's total resource budget. The historical Mac launch, native cache and daemon bind rows above measure different operations and have no Ubuntu parity ratio. [ARM64 run 1](live-kernel-arm64.json) · [ARM64 run 2](live-kernel-arm64-repeat.json) · [Physical rig procedure](../../development-volume.md#physical-apple-silicon-comparison).

## Warm-container target for npm and Go

The four-vCPU Ubuntu ARM64 package runner also ran fresh OCI containers with a previously seeded guest-local volume per tool. Each independent block seeded a new set of stores, proved that an offline empty store fails, and ran every warm job from a new checkout in a new network-isolated container. Each timed job includes the Docker client, container launch, Python checkout fixture, offline package operation, executing the product, auto-removal, and client return. Each package container had one CPU and 1 GiB. The fixture used Linux ARM64 Go 1.26.11, npm 11.19.1 and Node 24.22.3.

| Median complete batch, five blocks | 1 client | 4 | 8 | 16 |
|---|---:|---:|---:|---:|
| Warm offline npm ci | 0.961 s | 1.113 s | 2.206 s | 4.338 s |
| Warm Go build | 0.597 s | 0.722 s | 1.412 s | 2.795 s |

All 290 timed package containers passed. Each block retained its original shared npm tarball and Go ZIP inodes and kept the same Go build-cache footprint. All five blocks cleaned up their containers and volumes. The scaling suite is opt-in. [Raw timings and cache sizes](package-containers-ubuntu-arm64.json) · [Workflow and downloadable ARM64 image](https://github.com/castlemilk/micropod/actions/runs/44528133542) · [Pinned fixture sources](../../../scripts/bench_cache_image/Dockerfile).
