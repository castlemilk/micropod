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

On 20 November 2026, the guest fixture used upstream Docker 29.9.3 on a GitHub-hosted four-vCPU ARM64 Ubuntu 24.04.5 runner. Its native Docker 28.0.4 daemon was the control. Times below are median wall times for a whole batch. An npm or Go job creates a fresh workspace and runs offline using the warm package cache.

| Workload | 1 job | 4 jobs | 8 jobs | 16 jobs |
| --- | ---: | ---: | ---: | ---: |
| Guest launch, ms | 124 | 183 | 316 | 624 |
| Native Ubuntu launch, ms | 116 | 176 | 314 | 601 |
| Guest npm, s | 0.958 | 1.146 | 2.175 | 4.376 |
| Native Ubuntu npm, s | 0.947 | 1.080 | 2.093 | 4.243 |
| Guest Go, s | 0.586 | 0.697 | 1.340 | 2.722 |
| Native Ubuntu Go, s | 0.580 | 0.705 | 1.332 | 2.746 |

The Linux fixture ran 145 timed launches per engine and 145 fresh workspaces per package manager per engine. Both engines used the same Linux kernel. The Mac hypervisor and vsock path require separate qualification. [Raw samples](benchmarks/2026-11-20/arm64-ci-worker-guest.json) · [Executed guest job](https://github.com/castlemilk/micropod/actions/runs/44625115597/job/135916752783)

The complete Go and Node pipelines exposed a larger gap than individual container launches. On the first run, the serial Go stages and per-job image cleanup produced warm times of 17.02 s in the guest and 11.99 s in native Docker. The pipeline now overlaps the PostgreSQL integration with the service build and keeps four bounded cache tags for the exported images. On a second allocation, the warm pass took 12.44 s and 11.90 s respectively. PostgreSQL accounted for 11.49 s of the worker pass. Both versions ran the same application checks. [Before and after stage receipts](benchmarks/2026-11-20/ci-pipelines-arm64.json)

A signed probe on the standard hosted Apple Silicon runner identified an Apple M1 VirtualMac and reported `VZVirtualMachine.isSupported=false`. The native worker and OrbStack require a provisioned physical rig for comparison. [Hosted Apple capability result](https://github.com/castlemilk/micropod/actions/runs/44628671876/job/135929181800)

Run `task bench-ci-apple` locally, or pass a results directory with `task bench-ci-apple -- /tmp/micropod-apple`. The script saves a standalone OrbStack receipt before starting the paired run. The `apple-pair` workflow builds the checked-out CLI on a physical Apple Silicon runner with Apple Container and OrbStack already provisioned. It starts an independent Micropod worker in a temporary directory, matches the peer's CPU and RAM, and sends both clients the same native images. Blocks alternate engine order. The underlying `scripts/bench_live_kernel.py --engine rig-matrix --worker-cli /path/to/micropod` also accepts `--desktop-socket` and `--colima-socket` for provisioned local peers. The report records app versions, worker identity, per-engine p50s, resource budgets and matched Ubuntu references. The short PR qualification finished in 21 seconds on hosted ARM64 Linux. A separate run executed the production Go and Node pipelines, including PostgreSQL and the source-change rebuild. [PR integration](https://github.com/castlemilk/micropod/actions/runs/44626891771/job/135922978226) · [Full pipeline integration](https://github.com/castlemilk/micropod/actions/runs/44626999645/job/135923365952)
