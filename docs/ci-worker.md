# Persistent Linux worker for CI

A trusted runner account can keep one Linux kernel running on Apple Silicon. The `micropod ci serve` process owns the Virtualization.framework VM and its writable ext4 disk. Docker Engine 29.9.3, containerd, runc and BuildKit run inside that VM. Each job gets a fresh Linux container. Layers, build cache and named volumes live on the same disk across jobs and clean worker restarts.

## Run a job

Start Apple Container once to provision its ARM64 kernel and vminit image. Install the Docker CLI and buildx plugin on the runner. For a source checkout, build `micropod` and sign it with the repository's virtualization entitlement.

```sh
swift build -c release --product micropod
codesign -f -s - --entitlements signing/micropod-cli.entitlements .build/release/micropod
export MICROPOD_BIN="$PWD/.build/release/micropod"
unset DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH BUILDX_BUILDER
export DOCKER_HOST="$("$MICROPOD_BIN" ci endpoint)"
docker info
task ci
```

On a self-hosted runner, install the signed binary at a stable path and run `micropod ci install-service` as the runner account before it accepts jobs. The macOS user launch agent owns the VM across GitHub job cleanup and starts it on login. `micropod ci uninstall-service` retires the idle service and retains its disk. Rigs using their own service manager can run `micropod ci serve` as its foreground process.

`ci endpoint` and `ci run` start the worker on demand. Concurrent callers share the supervisor's disk lock. Readiness checks match the engine to both the durable worker ID and the current supervisor instance. The host connects to a private Unix socket relayed over virtio-vsock. Job creation, build context uploads, attached streams and exits use the upstream Docker protocol.

`task ci-go` runs vet, race tests, Testcontainers with PostgreSQL and the built HTTP service. `task ci-npm` builds, tests, runs and changes a staged copy of the Node app. `task ci` runs both pipelines concurrently. `task ci-shim` runs the existing Apple shim integration.

For the Micropod CLI, SDK or API, start the worker under the account serving the request and enable the `ci` runtime. Use `micropod runtime enable ci` and `micropod run --runtime ci nginx`. A rig can select `MICROPOD_DEFAULT_RUNTIME=ci` for its Micropod service. The Micropod runtime selector routes container operations. Use the Docker endpoint for builds, image management, networks, volumes and Compose. Stock clients can reuse `DOCKER_HOST` throughout a pipeline.

## Storage and trust

| Setting | Default | Purpose |
| --- | --- | --- |
| `MICROPOD_CI_HOME` | `~/.micropod/ci` | Private directory for the socket, manifest and sparse disk. A directory on a Micropod development volume also works. |
| `MICROPOD_CI_CPUS` | 4 | VM vCPUs |
| `MICROPOD_CI_MEMORY_MIB` | 4096 | VM memory in MiB |
| `MICROPOD_CI_DISK_GIB` | 32 | Logical guest ext4 capacity in GiB |

Set resources before first boot. Later starts reuse the recorded configuration. `micropod ci status` returns the boot UUID, worker and supervisor IDs, Docker daemon ID, guest IP, cgroup driver and memory. Pause runner intake and finish active builds before `micropod ci stop`. The worker checks for running containers and closes the public socket to new connections during shutdown.

```sh
micropod ci run --cache npm node:24-alpine npm cache verify
micropod ci run --cache go golang:1.26-alpine go env GOMODCACHE GOCACHE
```

The shortcuts attach one guest npm volume, one Go module volume and one Go build volume per worker. Repeated jobs on the worker reuse those volumes. The shortcut paths suit images that run as root. Images using a custom UID need writable cache directories. Dockerfiles can share BuildKit cache mounts across projects, as in the Go and Node samples. BuildKit cache mounts, Docker named volumes and macOS host caches are distinct stores. Choose the same mechanism for jobs that should reuse package bytes.

Use `--cache-scope` to give a group of trusted jobs its own stores. Use the same scope across checkouts and concurrent jobs that should share dependencies. Each requested store gets one named volume on the worker disk. Docker attaches it directly at container creation and skips copying files from the image into a new scoped volume.

```sh
micropod ci run --cache npm --cache-scope frontend node:24-alpine npm config get cache
micropod ci run --cache go --cache-scope backend -e GOFLAGS=-trimpath golang:1.26-alpine go env GOCACHE
```

Preserve `-trimpath` alongside any other Go build flags when checkouts have different absolute paths. For an image that runs as UID 1000, initialize its new scope once with the same cache flags and run `chown 1000:1000 /cache/npm` as root. For Go, set the owner of both `/cache/gomod` and `/cache/gobuild`. Use a consistent job UID for each scope.

New worker disks use ordered ext4 journaling. Existing workers reopen their original disk and retain its filesystem format. The first cold start fetches the native Linux image and prepares the disk once. Warm launches use the socket verified for the live supervisor. The CPU and memory settings cover the whole VM, including its guest agent.

The trust boundary is the runner account and its dedicated VM. Docker clients can administer the guest, including its shared cache. Place mutually untrusted repositories in isolated sandboxes. The guest exports its own engine socket. Docker bind sources resolve inside Linux. Stream checkouts as build contexts or copy them into a container. Published ports bind inside the worker VM and its guest IP is available in the status output. Automatic macOS loopback forwarding, arbitrary host-path binds and desktop distribution management remain open parity work.

## Qualification

PRs touching the worker run one short Linux guest integration alongside the existing checks. The manual qualification runs five rounds at 1, 4, 8 and 16 clients. It verifies guest-versus-container boot IDs, distinct PID and mount namespaces, actual CPU and memory quotas, both streams and exit codes, bridge DNS, package payload inodes, and image, volume and offline BuildKit cache reuse after restart. The native Ubuntu Docker run uses the same GitHub allocation and exported package image. Manual qualifications also copy those Go, Node and npm binaries out of the image and run the offline workspaces as ordinary Ubuntu processes. The raw process clock omits container startup and teardown. The full pipeline records per-stage wall times and alternates engine order across three warm passes.

On 20 November 2026, the Micropod guest fixture ran Docker 29.9.3 on a GitHub-hosted four-vCPU ARM64 Ubuntu 24.04.5 VM with the Azure kernel. The same allocation ran native Docker 28.0.4 and bare npm and Go. Each value is the median elapsed time for a whole batch over five rounds. Every package job created a fresh workspace and used its engine's warm offline cache. All three paths used Node 24.22.3, npm 11.19.1 and Go 1.26.11 from the same ARM64 image.

| Workload | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| Guest fixture launch, ms | 123 | 178 | 310 | 582 |
| Ubuntu Docker launch, ms | 116 | 179 | 309 | 613 |
| Guest fixture npm, s | 0.946 | 1.139 | 2.125 | 4.281 |
| Ubuntu Docker npm, s | 0.957 | 1.087 | 2.120 | 4.210 |
| Bare Ubuntu npm, s | 0.275 | 0.360 | 0.730 | 1.458 |
| Guest fixture Go, s | 0.559 | 0.680 | 1.320 | 2.658 |
| Ubuntu Docker Go, s | 0.580 | 0.695 | 1.347 | 2.721 |
| Bare Ubuntu Go, s | 0.118 | 0.176 | 0.345 | 0.707 |

Each engine completed 145 timed launches and 145 fresh workspaces per package manager. Both Docker engines used the allocation's Linux kernel. The bare process timing excludes container creation, teardown and per-container resource limits. The Mac hypervisor and vsock path require the physical Mac comparison. [Raw samples and runner details](benchmarks/2026-11-20/arm64-worker-native-processes.json) · [Executed job](https://github.com/castlemilk/micropod/actions/runs/44629760090/job/135932952673) · [Independent earlier run](benchmarks/2026-11-20/arm64-ci-worker-guest.json)

The full Go, npm and PostgreSQL workflow initially took 17.02 s warm in the guest fixture and 11.99 s on the native daemon. After overlapping the service build with PostgreSQL and retaining four exported image tags, a separate allocation measured 12.44 s and 11.90 s. The latest run alternated engine order and repeated the warm workload three times. Both engines ran the same application checks. [Before and after stage receipts](benchmarks/2026-11-20/ci-pipelines-arm64.json)

| Full pipeline | First pass | Warm 1 | Warm 2 | Warm 3 | Warm median |
| --- | ---: | ---: | ---: | ---: | ---: |
| Micropod guest fixture | 73.474 s | 12.272 s | 11.978 s | 12.208 s | 12.208 s |
| Ubuntu Docker | 65.164 s | 11.972 s | 12.220 s | 11.854 s | 11.972 s |

PostgreSQL accounted for a median 11.350 s of the guest run. All three warm passes included a real PostgreSQL container and readiness query, Go race tests, npm tests, source modification, rebuild and output checks. [Pipeline stages and raw process timings](benchmarks/2026-11-20/arm64-worker-native-processes.json)

A signed probe on the standard hosted Apple Silicon runner identified an Apple M1 VirtualMac and reported `VZVirtualMachine.isSupported=false`. The native worker and OrbStack require a provisioned physical rig for comparison. [Hosted Apple capability result](https://github.com/castlemilk/micropod/actions/runs/44628671876/job/135929181800)

Run `task bench-ci-apple` locally, or pass a results directory with `task bench-ci-apple -- /tmp/micropod-apple`. The script saves a standalone OrbStack receipt before starting the paired run. If the worker build or boot fails, it also saves OrbStack’s standalone package and full-pipeline timings to `orbstack-workloads.json`. The `apple-pair` workflow builds the checked-out CLI on a physical Apple Silicon runner with Apple Container and OrbStack already provisioned. It starts an independent Micropod worker in a temporary directory, matches the peer's CPU and RAM, and sends both clients the same native images. Blocks alternate engine order. Each engine also runs the complete Go, npm and PostgreSQL pipeline once and then three more times warm. The fixture removes its own sample image tags from OrbStack after the comparison. The underlying `scripts/bench_live_kernel.py --engine rig-matrix --worker-cli /path/to/micropod` also accepts `--desktop-socket` and `--colima-socket` for provisioned local peers. The report records app versions, worker identity, per-engine p50s, resource budgets and matched Ubuntu references. The short PR qualification finished in 21 seconds on hosted ARM64 Linux. A separate run executed the production Go and Node pipelines, including PostgreSQL and the source-change rebuild. [PR integration](https://github.com/castlemilk/micropod/actions/runs/44626891771/job/135922978226) · [Full pipeline integration](https://github.com/castlemilk/micropod/actions/runs/44626999645/job/135923365952)

Manual runs upload the exported ARM64 toolchain and native Docker measurements together as the `arm64-warm-ubuntu` artifact. The Apple job loads that image on both engines and verifies its OCI configuration digest before reporting package comparisons. To repeat it locally, download the artifact and run `task bench-ci-apple -- /tmp/micropod-apple --ubuntu-bundle /path/to/artifact`.
