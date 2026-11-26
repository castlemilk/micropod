# Fresh Go containers on Gamma

Gamma is an 18-core Apple M5 Max with 128 GB. Micropod, OrbStack 2.2.5 and an independent Ubuntu 24.04.4 VM each had four vCPUs and 4 GiB. Ubuntu ran stock kernel 6.8.0-134-generic directly under Apple virtualization. Its timed jobs were ordinary Linux processes. The Go driver, compiler, linker, module archive, source and final executable matched across the three systems. This control ran locally after the primary Docker comparison.

## Same-Mac results

Each job builds the same small Go main package and imports one offline module. Each cell is the median wall time for a whole batch over five rounds. Container clocks include fresh Docker create, start, output verification and completion. Each container had one CPU, 1 GiB and networking disabled. Native Ubuntu timed concurrent Go commands in independently prepared checkouts, with verification after the clock. Its output-reuse row also received a verified current executable before the clock.

| Starting state | Jobs | Micropod | OrbStack | Raw Ubuntu |
| --- | ---: | ---: | ---: | ---: |
| Source checkout, executable must be linked | 16 | 1.029 s | 3.037 s | 0.371 s |
| Source checkout, executable must be linked | 32 | 1.685 s | 4.465 s | 0.774 s |
| Checkout with current executable | 16 | 0.690 s | 5.059 s | 0.119 s |
| Checkout with current executable | 32 | 1.189 s | 7.033 s | 0.232 s |

With a source-only checkout, Micropod still took 2.77× the native Ubuntu time at 16 and 2.18× at 32. Preparing the source layer took 0.299 s. Preparing a checkout with the linked output took 0.637 s with warm package caches. The primary and staged job series measured their batches after image preparation and before the concurrent lookup change landed. The separate preparation series measures the final helper with simultaneous callers and repeated lookups. Copying the exact images to the peer took 3.983 s outside the clocks. Across the five rounds at 32, Micropod’s source-only batch ranged from 1.58 to 2.39 s and OrbStack’s from 3.84 to 18.65 s on this shared runner. [All paired rounds](fresh-go/engines.json.gz) · [Same-Mac Ubuntu runs](fresh-go/native-ubuntu.json) · [Earlier hosted Ubuntu data](ubuntu-arm64-worker-reference.json)

## Python, Go and container startup

The current first-build fixture checks that the private Go build and module stores start empty. It fetches the fixture module from its local file proxy, verifies the module ZIP, then checks the actual build cache is still empty and the output absent before building with `GOPROXY=off`. Both store directories retain their identities across the build. In a separate Darwin arm64 run, the empty action cache produced 106 compiler or assembler invocations. Changing only the main package against the same cache produced one invocation, and an unchanged checkout produced zero. A positive tool count alone therefore cannot identify a first build. OS file-cache state, VM boot and peer performance remain unmeasured by this check. Reproduce it with `python3 -B scripts/check_first_go_build.py`. [Local first-build receipt](../2026-11-23/first-go-build-local.json)

The legacy fixture starts Python in every timed container. It imports the Go and npm fixture, writes both sets of workspace files, starts Go and verifies its output. Fresh production Go jobs and the direct measurements use a shell entrypoint and Go. Python on the Mac schedules clients and records measurements. Untimed setup also uses the existing fixture to seed and audit the guest stores. The native Ubuntu driver launches Go from a single measurement process.

| Fresh workload | Micropod, 16 | Micropod, 32 | OrbStack, 16 | OrbStack, 32 |
| --- | ---: | ---: | ---: | ---: |
| Original Python fixture | 1.848 s | 3.230 s | 4.175 s | 12.122 s |
| Shell writes Go sources per job | 1.047 s | 2.032 s | 2.229 s | 6.848 s |
| Shared source layer, fresh output | 1.029 s | 1.685 s | 3.037 s | 4.465 s |
| Shared source and executable layers | 0.690 s | 1.189 s | 5.059 s | 7.033 s |
| Start, print identity and exit | 0.580 s | 1.414 s | 5.532 s | 5.570 s |
| Prepared Go commands inside one container | 0.474 s | 0.882 s | 0.455 s | 0.949 s |

Inside an already-running Micropod container, prepared Go commands took 28% longer than native Ubuntu at 16 and 14% longer at 32. Both controls relinked every output. The launch-only batch by itself took longer than the native Go batch at each concurrency level.

In the previous instrumented 16-job run, the last-finishing job spent a median 0.860 s between Python entry and launching Go. Writing its fixture files took less than a millisecond. That kernel profile counted a median 920 ext4 sync entries per 16-job batch and zero milliseconds of cgroup throttling during Go. The old parser matched a linker only at the start of a line. Go prefixes this command with a GOROOT assignment. Its old zero-link counts for fresh outputs are invalid. The corrected counter and an independent native tool wrapper both observed one link per fresh source-only build, zero compiles and zero links for a current output, and a compile plus a link after changing source. [Previous kernel profile](worker-profile.md) · [Native tool invocation control](fresh-go/native-ubuntu.json)

| Micropod last-finishing job | Jobs | Docker create to start | Running | Exit to removal |
| --- | ---: | ---: | ---: | ---: |
| Source only | 16 | 0.499 s | 0.301 s | 0.007 s |
| Source only | 32 | 0.689 s | 0.658 s | 0.008 s |
| Current executable | 16 | 0.225 s | 0.193 s | 0.008 s |
| Current executable | 32 | 0.720 s | 0.153 s | 0.014 s |

The paired trace contains the four Docker lifecycle events for 3,140 distinct containers. Each batch has a timeline relative to its first Docker create. The intervals above are medians for the job that determined each batch’s finish. Client startup and time preceding Docker’s create event also contribute to end-to-end wall time. [Perfetto trace](fresh-go/engines.trace.json.gz)

## Concurrent checkout preparation

The Go preparation helper uses the immutable source image, build settings, output path, main package and cache scope as its lookup key. Docker holds the completed output as a tagged image. macOS coordinates a cache miss on the worker so concurrent submitters can share one build. Every caller emits a structured hit or miss and receives the immutable image ID.

| Concurrent requests for one new revision | All checkouts ready | Builds per revision | Repeated single request |
| ---: | ---: | ---: | ---: |
| 16 | 2.797 s | 1 | 0.217 s |
| 32 | 5.858 s | 1 | 0.245 s |

Each of the six cold keys used the same warmed package stores. The database holds every caller’s duration, cache outcome, image ID and the engine’s actual preparation-container ID. The binary then passed an ordinary offline Go build with zero compiler and linker invocations. Changing the build flags produced a new cache key. A job using a nested output path reused its executable. [Concurrent preparation receipts](fresh-go/preparation.json.gz)

An earlier control found that two different binaries with equal size and fixed timestamps could arrive at BuildKit under the same context path. A fresh build then relinked the previous output. The helper now names its transfer directory with the actual SHA-256 and records it on the image. The passing trials verified the checkout hash, executable hash and Go build ID before and after each build. [Earlier stale-output control](fresh-go/stale-output-control.json.gz)

## Preparing containers before dispatch

The stock Docker create API allocates the container and its private writable layer. Its first process starts only when Docker receives start. The staged experiment submits all creates, waits for them, then attaches to and starts each fresh container. The combined column charges both stages. The ordinary column is a fresh run in the same alternating series. These medians cover three rounds.

| Engine | Job | Clients | Ordinary run | Create ahead | Dispatch to completion | Combined |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| Micropod | Source only | 16 | 1.573 s | 0.296 s | 1.277 s | 1.573 s |
| Micropod | Source only | 32 | 1.749 s | 0.375 s | 1.838 s | 2.661 s |
| Micropod | Current executable | 16 | 0.942 s | 0.175 s | 0.673 s | 0.878 s |
| Micropod | Current executable | 32 | 0.979 s | 0.406 s | 0.867 s | 1.350 s |
| OrbStack | Source only | 16 | 44.845 s | 19.065 s | 21.617 s | 38.964 s |
| OrbStack | Source only | 32 | 69.376 s | 25.794 s | 51.334 s | 76.693 s |
| OrbStack | Current executable | 16 | 36.567 s | 14.778 s | 23.314 s | 38.050 s |
| OrbStack | Current executable | 32 | 69.334 s | 40.681 s | 38.336 s | 81.249 s |

At 32 with a current executable, precreation yielded 0.867 s from dispatch to completion, 1.350 s including creation, and 0.979 s for an ordinary run in the same series. For 32 source-only jobs the combined staged median was 2.661 s, compared with 1.749 s for ordinary runs. Precreation is an option when an upstream stage can absorb its creation time.

Each column gives an independently calculated median. A real precreated job had PID zero, returned exit code 41 with separate stdout and stderr when attached, and was removed on exit. Every staged create preceded that batch’s first process start. [All staged and ordinary samples](fresh-go/staged.json.gz) · [Lifecycle trace](fresh-go/staged.trace.json.gz)

## OCI runtime and supervisor trials

crun 1.31 reduced Micropod’s 32-container launch-only median from 1.414 s to 0.895 s. It took 2.181 s for 32 source-only Go jobs and 2.194 s with the prepared executable. Stock runc took 1.685 s and 1.189 s respectively. The installer registers crun for explicit per-job use. The worker keeps runc as its default. [Upstream crun release](https://github.com/containers/crun/releases/tag/1.31)

Two running containers could share a containerd supervisor while retaining distinct PID namespaces, mounts and cgroups. Removing the first preserved the second. An unanchored 32-job burst nevertheless lost the supervisor during task creation. The follow-up held a separate low-memory anchor across the bursts. [Isolation proof](fresh-go/shim-isolation.json) · [Failed unanchored burst](fresh-go/unanchored-failure.json.gz)

| Supervisor over three completed paired rounds | Micropod source, 16 | Micropod source, 32 | Micropod current output, 16 | Micropod current output, 32 |
| --- | ---: | ---: | ---: | ---: |
| Default | 0.943 s | 1.890 s | 0.634 s | 1.119 s |
| Shared with an anchor | 0.988 s | 3.728 s | 0.567 s | 1.138 s |

The optional anchored comparison was stopped after three complete paired rounds. Several later OrbStack batches took over a minute. The table uses the 72 completed batches and excludes the interrupted next round. The early stop preceded the final lifecycle-event audit. The primary five-round comparison and the independent staged series completed their audits. [All completed anchored observations](fresh-go/anchored-shims.json.gz)

## Cache identity and reproduction

The native ARM64 base OCI configuration was `sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350`. The source and output snapshots were identical on both engines. Fresh jobs verified the same executable SHA-256, `5156ed5c341595d9139485e83af8fc55b090977e02db67d9c8ea8cd1271bbf66`, as Ubuntu. An empty store failed offline. The completed paired and staged series retained the npm and Go module payload inodes and the package cache inventory. The source-edit control rebuilt in its own writable layer and the next untouched job saw the original. [Operational checks and toolchain hashes](fresh-go/operational.json)

The Ubuntu control used a plain ARM64 Lima VM on Gamma with four vCPUs, 4 GiB, no shared checkout and no container engine. Provision with `limactl start --name raw --vm-type vz --arch aarch64 --cpus 4 --memory 4 --disk 8 --plain --mount-none --containerd none template:ubuntu-24.04`. Copy the measured image’s `/usr/local/go` tree to the same path in that VM, along with `scripts/bench_fresh_go_ubuntu.py`, `bench_package_caches.py` and `ci_profile_guest.py`. Run `PATH=/usr/local/go/bin:$PATH python3 bench_fresh_go_ubuntu.py --clients 16 32 --rounds 5` inside Ubuntu. Gamma used Canonical’s 2026-07-05 Noble ARM64 cloud image. [Ubuntu image](https://cloud-images.ubuntu.com/releases/noble/release-20260705/ubuntu-24.04-server-cloudimg-arm64.img)

The local SQLite database stores per-job Docker lifecycle intervals, Go tool counts, batch timings and the native Ubuntu controls. Its views include `fresh_go_jobs`, `fresh_go_batches`, `native_go_batches` and `go_preparation_batches`. The worker qualification workflow is manual. [Commands for snapshots, caches and measurements](../../ci-worker.md#fresh-go-jobs-from-a-prepared-checkout)
