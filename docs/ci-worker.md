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

For the Micropod CLI, SDK or API, start the worker under the account serving the request and enable the `ci` runtime. Use `micropod runtime enable ci` and `micropod run --runtime ci nginx`. A rig can select `MICROPOD_DEFAULT_RUNTIME=ci` for its Micropod service. The Micropod runtime selector routes container operations. Use the Docker endpoint for builds, image management, networks, volumes and Compose. Stock clients can reuse `DOCKER_HOST` throughout a pipeline. `micropod ci docker` sends the stock Docker CLI and its plugins to the worker without changing the Mac's active Docker context. For example, `micropod ci docker compose up -d`, `micropod ci docker buildx ls` and `micropod ci docker events` all use the worker endpoint.

## Storage and trust

| Setting | Default | Purpose |
| --- | --- | --- |
| `MICROPOD_CI_HOME` | `~/.micropod/ci` | Private directory for the socket, manifest and sparse disk. A directory on a Micropod development volume also works. |
| `MICROPOD_CI_CPUS` | 4 | VM vCPUs |
| `MICROPOD_CI_MEMORY_MIB` | 4096 | VM memory in MiB |
| `MICROPOD_CI_DISK_GIB` | 32 | Logical guest ext4 capacity in GiB |
| `MICROPOD_CI_EXT4_MAX_BATCH_US` | Adaptive (15,000 µs) | Maximum ext4 wait for synchronous writers to share a commit. A dedicated worker can select zero for immediate writes. |
| `MICROPOD_CI_WORKSPACE` | Unset | Optional checkout directory shared read/write at its absolute path with VirtioFS. Select it before first boot. |

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

New worker disks use ordered ext4 journaling and adaptive synchronous write batching. On Gamma, immediate writes improved two direct-shell Go trials, while adaptive batching had lower Go and npm medians in a matched mixed-package trial. To provision a dedicated worker with immediate writes, set `MICROPOD_CI_EXT4_MAX_BATCH_US=0` before first boot. Both settings retain ordered writes and flush barriers on journaled disks. [Linux ext4 mount options](https://docs.kernel.org/admin-guide/ext4.html)

Existing workers reopen their original disk and retain its filesystem format. The first cold start fetches the native Linux image and prepares the disk once. Warm launches use the socket verified for the live supervisor. The CPU and memory settings cover the whole VM, including its guest agent.

The trust boundary is the runner account and its dedicated VM. Docker clients can administer the guest, including its shared cache. Place mutually untrusted repositories in isolated sandboxes. The guest exports its own engine socket. Docker bind sources resolve inside Linux. Stream checkouts as build contexts or copy them into a container. Published ports bind inside the worker VM and its guest IP is available in the status output. For Compose projects with bind mounts, set `MICROPOD_CI_WORKSPACE` to a checkout root under `/Users`, `/Volumes` or `/private/tmp` when provisioning the worker. Linux sees that tree at the same physical path as macOS, so relative Compose binds work and edits are visible in both directions. Every Docker administrator of that worker can read and write the shared directory. Use a Docker named volume for the package stores so compiled objects and dependency archives stay on native ext4. Clients on macOS reach a published TCP port at the guest IP from `ci status`.

## Sharing a Go toolchain across parallel CI jobs

Pin one Linux Go image by digest and give related, trusted jobs a stable cache scope. Put the Go version, target and build flags in that image. A typical pure-Go profile uses `GOTOOLCHAIN=local` and `GOFLAGS=-trimpath`. Twenty containers can share the immutable toolchain layers, the module download and extraction directory, and the compiler's content-addressed object store. Each container keeps its own writable checkout. Go selects which objects are valid for each source revision, target, build tag and compiler. [Go module cache](https://go.dev/ref/mod#module-cache) · [Go build cache](https://pkg.go.dev/cmd/go#hdr-Build_and_test_caching)

For a new or evicted cache, prime a representative source snapshot before dispatching the group. The example runs in the working directory set by `ci snapshot`. Use the same scope and compatible Go settings on subsequent jobs.

```sh
source_id=$(micropod ci snapshot "$PINNED_GO_IMAGE" "$CHECKOUT")
micropod ci warm-go --cache-scope backend "$source_id"
micropod ci run --cache go --cache-scope backend --network none \
  --entrypoint sh "$source_id" -ec 'go vet ./... && go test -count=1 ./... && go build ./...'
```

The warm-up compiles tests to `/dev/null` and primes both the test-time and full vet checks. Optional package arguments select a subset. Pass `--offline` before the image ID to use a populated module store, vendored inputs or a local proxy. The default uses the image's Go proxy and checksum configuration. Pass `--trace-tools` for counts of actual compiler, vet and linker invocations. Standard output carries JSON events with the request key, worker uptime and container CPU consumption. A later invocation consults Go again after cache eviction.

With `flock` in the image, a cache scope admits one producer at a time. Overlapping requests for the same immutable input can join its successful completion. A killed producer releases its kernel lock and the next waiter checks the cache. Images without `flock` emit `uncoordinated` and still populate the same Go stores. Pinning a different source snapshot always gives the request its own identity. For repeated jobs on exactly the same snapshot, the prepared suite below also shares linked products while each job executes its own tests.

The native worker exposes `micropod ci metrics --kernel` over its control socket. Sample it twice on the same boot to calculate changes in CPU, memory and I/O pressure or OOM kills. This read works independently of Docker and the cache size scan. [Twenty-job Gamma measurements](benchmarks/2026-11-20/go-cache-fanout.md) · [Linux pressure accounting](https://docs.kernel.org/accounting/psi.html)

## Fresh Go jobs from a prepared checkout

`micropod ci snapshot BASE_IMAGE DIRECTORY` loads the checkout into the worker's image store and prints an immutable local image ID. BuildKit applies the checkout's `.dockerignore`. Prepare it once per revision. A fresh container sees its own writable layer at `/workspace`, while the lower source layer is shared. File access follows the image user's normal Linux permissions. An edit or build in one job is private to that job. [Docker build contexts](https://docs.docker.com/build/concepts/context/)

```sh
image="$(micropod ci snapshot golang:1.26 .)"
micropod ci run --cache go --cache-scope project-go "$image" go build -trimpath -buildvcs=false -o app .
```

For a fan-out that builds the same main package, `ci/prepare-go-workspace.sh BASE_IMAGE DIRECTORY RELATIVE_OUTPUT [MAIN_PACKAGE]` links the output once using the normal scoped Go stores. It adds just that executable to the checkout in a separate image layer. Each job still runs its usual `go build`. Go checks the installed build ID and relinks when an input changes. The preparation uses the Go settings exported to the script, including `CGO_ENABLED`, `GOFLAGS` and `GOEXPERIMENT`. Use the same settings in the jobs that should reuse the output.

Requests for the same immutable source image, cache scope, output path, package and build settings share a completed image. Concurrent requests for a new key elect one builder on the Mac. On a miss, the helper streams the executable through a private temporary file into BuildKit. Hits return the existing image. Each caller receives the immutable image ID on stdout and a `ci.go.prepare` JSON event on stderr with its key, binary SHA-256 and cache hit or miss. The worker stores the reusable tag as `micropod-internal/ci-go-output:KEY`. A workflow that retires a revision can remove its specific output tag with `micropod ci docker image rm "micropod-internal/ci-go-output:$key"`. The package caches live in separate named volumes.

```sh
export MICROPOD_BIN="$PWD/.build/release/micropod"
export MICROPOD_CI_GO_SCOPE=project-go
image="$(ci/prepare-go-workspace.sh golang:1.26 . app ./cmd/service)"
"$MICROPOD_BIN" ci run --cache go --cache-scope project-go "$image" sh -ec \
  'go build -trimpath -buildvcs=false -o app ./cmd/service && ./app'
```

### Lint, test and build fan-out

For jobs that test the same immutable Go revision, lint the module and compile its test executables and application once. Each job then runs every test in its package directory with its own writable checkout. The application is available at `/micropod-ci-suite/product`. The ordinary Docker endpoint and the native OCI worker can both consume the same image.

```sh
export MICROPOD_BIN="$PWD/.build/release/micropod"
scope=project-go
src=$("$MICROPOD_BIN" ci snapshot golang:1.26 ./checkout)
suite=$(ci/prepare-go-suite.sh "$src" "$scope" ./cmd/service)
handle=$(ci/oci-batch.sh prepare "$suite" "$scope")
ci/oci-batch.sh run "$handle" 16 sh /micropod-ci-suite/suite.sh test /micropod-ci-suite
ci/oci-batch.sh forget "$handle"
```

Use a Go module with vendored dependencies or warm its scoped module store first. Preparation runs offline with the image's local Go toolchain, CGO disabled and `-trimpath -p=2`. It runs `go vet ./...`, discovers internal and external test packages with `go list`, compiles their test binaries and builds the selected main package. All jobs in one trusted scope can use the same two Go cache volumes.

For a local OCI manifest the Rust guest service reads the finished suite from the stopped compiler, normalizes its file order, ownership, permissions and timestamps, and hashes the resulting layer. It appends that layer to the source manifest and registers the result in Docker's existing image store. Each image inherits the source's runtime configuration, including its user, environment, working directory and launch command. The first publication imports the gzip blob and image metadata. When the layer digest matches a recent output and the worker still holds the blob, only the new metadata crosses the guest's Docker socket. The guest holds up to 128 descriptor hints. Docker manages the blob lifetime. An older worker or a different manifest format uses the existing BuildKit exporter. Project Dockerfiles and source snapshots continue to use BuildKit.

Prepare again after changing the source, dependencies, test fixtures or toolchain image. Jobs that generate source during execution, use different build tags, or collect coverage should run their own Go commands. The Go and npm demonstration pipeline (`task ci`) uses the Docker endpoint for image builds, race-enabled Go tests, live npm tests, an HTTP service, Ryuk and PostgreSQL. Each PostgreSQL test checks a write and read over TCP before teardown.

The preparer emits a `ci.go.suite` JSON event with the cache key, image ID and hit or miss. Its v2 key covers the source image, scope, main package, fixed profile, compiler command and suite script. Concurrent requests for the same key share the build. A new source is vetted and compiled against the Go caches before the service checks the output digest. On native misses, `publication` reports the layer digest, parent layer count, compressed size, blob bytes sent, total import bytes and phase timings. A vet or compiler failure prevents publication. A failing test returns a failed job each time it runs. To retire an output after its handles are released, remove its `micropod-internal/ci-go-suite:KEY` tag. [Gamma layer measurements](benchmarks/2026-11-20/go-suite-layers.md) · [Full CI pipeline](benchmarks/2026-11-20/full-ci.md)

The original offline benchmark used Python inside each measured container to create a temporary Go and npm fixture and check its output. Direct Go jobs use the Go toolchain and their entrypoint. In the direct benchmarks, setup and measurement orchestration run on the Mac. Only the explicitly named legacy control starts Python in each timed container.

The experimental supervisor-sharing series uses one explicit anchor container on each engine. Its job group joins the same containerd shim while retaining separate PID and mount namespaces and cgroups. An unanchored 32-job burst lost the shim during task creation. Ordinary jobs use Docker's usual supervisor lifecycle. [containerd runtime grouping](https://github.com/containerd/containerd/blob/main/docs/runtime-v2.md)

`micropod ci create` takes Micropod’s cache and scratch options followed by Docker’s create flags, image and command. It creates the Docker container without starting a process. A workflow that knows the job specification while waiting for an upstream stage can prepare it then. Start it with `micropod ci docker start --attach "$id"`. Each container runs once and is removed on exit. Use `micropod ci docker rm "$id"` for a cancelled job that never started. The staged comparison charges creation and dispatch separately and reports their combined wall time.

The default OCI runtime is runc. `ci/install-crun.sh` registers a digest-checked ARM64 crun binary with the worker's live Docker daemon. The installer requires the Docker CLI, curl and jq on the Mac. Select it per job with the stock `--runtime micropod-crun` Docker option after any Micropod cache flags. The comparison records both runtimes. [Pinned crun release](https://github.com/containers/crun/releases/tag/1.31) · [Docker runtime registration](https://docs.docker.com/reference/cli/dockerd/#configure-container-runtimes)

## Direct OCI batches in the shared worker

For trusted, non-interactive jobs with networking disabled, `ci/oci-batch.sh` runs fresh OCI containers inside the existing Linux VM. The checkout image needs a shell and `sleep` for the preparation probe. Use scoped Go stores already seeded for this image. The fixed starting allocation is one CPU and 1 GiB per job.

The native worker opens a private vsock connection to a Rust service in the guest. For a source build, install the Linux ARM64 Rust standard library and build the guest tools before starting a worker. The SwiftPM CLI discovers `.build/oci-tools/guest`. The app packager also includes both guest binaries and the native Mac client when these tools are built. To use a separate installation, set `MICROPOD_CI_OCI_TOOLS` to the directory containing just `service` and `executor`, and `MICROPOD_OCI_CLIENT` to the Mac executable. An existing worker picks up the native service at its next normal boot. Its Docker endpoint remains available to running CI.

```sh
export MICROPOD_BIN="$PWD/.build/release/micropod"
rustup target add aarch64-unknown-linux-musl
ci/build-oci-service.sh
"$MICROPOD_BIN" ci start
image="$("$MICROPOD_BIN" ci snapshot "$TOOLCHAIN_IMAGE" "$CHECKOUT")"
handle="$(ci/oci-batch.sh prepare "$image" project-go)"
ci/oci-batch.sh run "$handle" 16 sh -ec 'go build -trimpath -buildvcs=false -o app . && ./app'
```

On first preparation, Docker supplies the image user, capabilities, seccomp profile, device policy, namespaces and resource limits. The service mounts a read-only containerd image view and keeps the policy on ext4. A stopped Docker container named `micropod-oci-pin-<handle>` holds references to the original image and its two named Go volumes. Keep this owner record for the lifetime of the handle. Once prepared, the handle opens sessions directly on the guest. Repeating preparation with the immutable image ID also reuses the policy and mount. A mutable image tag is resolved again. Image and cache payloads stay on the worker disk.

The service starts an executor in a private mount namespace for each connection. The executor validates the Docker policy once. Every job receives a new writable overlay, namespaces, cgroup and OCI process. Session and job launch use the private socket and runc. Docker inventory shows the owner record under `docker ps -a`. `micropod ci metrics` reports active native sessions by cache scope, session admissions and successful warm and cold preparations under `nativeOCI`. The counters reset when the service starts. A warm preparation counts reuse of a prepared OCI handle. Go and npm payload reuse have separate cache metrics.

A scheduler can open `ci/oci-batch.sh session "$handle"` once to keep the executor warm. After the JSON `ready` frame, send one newline-delimited request per batch. For example, `{"id":"build-1","clients":16,"args":["go","build","-trimpath","-buildvcs=false","-o","app","."]}` runs 16 independent builds. Read interleaved base64 `stdout` and `stderr` frames by request ID and job index. The `done` frame includes each job's OCI ID, exit code, setup, runtime and cleanup times. Send the next batch after `done`. Closing stdin cancels active jobs and releases the session. One-shot `run` returns ordinary job streams and the first nonzero status in job order.

On a four-vCPU worker the default runc policy selects Linux `SCHED_BATCH` for batches of 32 or more offline jobs. Smaller batches and other worker sizes keep the ordinary kernel scheduler. `MICROPOD_OCI_POLICY=parallel` selects the ordinary scheduler explicitly. `MICROPOD_OCI_TRACE=1` adds per-job timing to one-shot stderr. To select crun after running `ci/install-crun.sh`, set `MICROPOD_OCI_RUNTIME=crun`. Use `MICROPOD_OCI_BACKEND=docker` to prepare a handle with the earlier Docker-launched executor. Workers provisioned without the guest tools use that backend automatically.

Once sessions exit, `ci/oci-batch.sh forget "$handle"` releases the native image view, Docker references and prepared policy. The scoped cache volumes remain available for other jobs. Docker services, Compose, builds, published ports and interactive containers use the same VM through `micropod ci docker`. [Native worker measurements and Docker replay](benchmarks/2026-11-20/native-vsock.md)

### Run a published OCI bundle directly

A runner owner can provision an unpacked Linux ARM64 OCI bundle on the guest disk and use the existing private OCI socket. The service opens the bundle and two cache directories and launches the selected OCI runtime. This path needs a kernel with OverlayFS and cgroup v2, one runtime executable, and Micropod's service and executor. The native Mac client is sufficient to submit work.

Place `rootfs/`, `config.json` and `resolv.conf` under `/var/lib/micropod/oci-native/bundles/<64-hex-id>/`. The ID identifies a provisioner-owned immutable bundle. The provisioner verifies its inputs and publishes new revisions under fresh IDs. Supply the same isolated offline OCI policy that the executor validates, including namespaces, seccomp, limits and both cache mounts. Under `/var/lib/micropod/oci-native/scopes/<scope>/`, provision `gomod/` and `gobuild/`. These can be bind mounts of existing Linux stores. Jobs in a scope share those exact files and write their workspaces into individual overlay upper directories. Keep the bundle, its configuration and the top-level scope directories root-owned with write permission restricted to the owner. To retire or replace a published directory, take an exclusive flock on the directory before changing its name. A running session holds shared locks on the bundle and scope.

```sh
selector="bundle:$BUNDLE_ID:$CACHE_SCOPE"
ci/oci-batch.sh run "$selector" 16 sh -ec 'go vet ./... && go test -count=1 ./...'
```

The native service defaults to `/usr/local/bin/runc`. Select an installed crun with `MICROPOD_OCI_RUNTIME=crun` and the ARM64 binary at `/var/lib/micropod/oci/crun-1.31-arm64`. Published bundles additionally accept `MICROPOD_OCI_RUNTIME=youki` for qualification, using `/var/lib/micropod/oci/youki-0.7.0-arm64`. Youki 0.7.0 leaves loopback down on this policy. Workloads that start a local TCP service require loopback up. The published-bundle interface runs offline commands. The current public Docker API has its own object lifecycle and uses the worker's existing engine. [Runtime comparison and API migration](benchmarks/2026-11-20/raw-oci-runtimes.md)

## Network recovery and profiling

The supervisor checks for the worker's local IPv4 gateway on macOS every five seconds and periodically probes the first hop from Linux. When that link disappears, it reconnects the worker's virtual network device, restores the guest route and checks the gateway with ARP. The guest keeps its addresses, processes, Docker socket and disk. Failed repairs retry with a delay up to one minute. A runner operator can request an immediate reconnect with `micropod ci repair-network`.

`micropod ci metrics` reads the Docker inventory and reports active containers per cache volume, scope, boot ID and the latest network repair. `micropod ci metrics --usage` also asks Docker for volume bytes and BuildKit's record and use counts. Shared and private BuildKit bytes are reported separately. A mounted volume measures attachment. The offline benchmarks verify reuse by checking package output, compiler invocations and stable payload inodes.

Docker Buildx also records cache hits for individual Dockerfile steps. To inspect an existing build, use its reference from `micropod ci docker buildx history ls`. The importer retains each distinct Dockerfile step’s position, digest, timestamps and whether it ran, hit the cache, failed or is pending. Dockerfile commands, console logs, base resolution and image exports stay outside the step counts. The local Apple qualification checks a cold build, an unchanged repeat and a changed source file against actual BuildKit events. [Docker build progress formats](https://docs.docker.com/reference/cli/docker/buildx/build/#set-type-of-progress-output---progress)

```sh
micropod ci docker buildx history logs --progress rawjson "$BUILD_REF" 2>&1 | \
  python3 scripts/ci_benchmark_store.py buildkit-trace -
sqlite3 "$HOME/.micropod/benchmarks/measurements.sqlite3" \
  'SELECT run, operation, outcome, count(*) FROM build_steps GROUP BY run, operation, outcome'
```

For disposable work files, `micropod ci run --scratch-mib 256 ...` mounts a size-limited tmpfs at `/tmp`. Files use the job's memory budget and disappear on exit. A job that relies on files already in its image's `/tmp` should use the ordinary writable layer. For CI scripts driven by CPython, `--cache python --cache-scope NAME` keeps compiled imports in one guest volume using `PYTHONPYCACHEPREFIX`. Use a scope dedicated to the trusted source revision and pinned toolchain. Reusing bytecode reduces repeated import work. The measured end-to-end benefit varied across runs. The Go, npm and Python stores can be selected together. [Python bytecode configuration](https://docs.python.org/3/using/cmdline.html#envvar-PYTHONPYCACHEPREFIX)

The local profiler compares fresh OCI containers on overlayfs, tmpfs scratch, shared Python bytecode and already-prepared Go processes inside the same VM. It keeps the Go command, module and build caches fixed. The JSON records include Docker lifecycle events, guest job phases, cgroup CPU throttling, pressure stall times, page faults, disk sectors, flushes and package cache inventories. `--kernel-trace` adds a privileged observer inside the trusted VM and records aggregate tracepoints in a dedicated tracefs instance. The observer removes its instance on exit. Timed comparisons against other engines run separately from this instrumentation. [Linux pressure stall counters](https://docs.kernel.org/accounting/psi.html)

```sh
python3 scripts/profile_ci_worker.py --image "$PACKAGE_IMAGE" --clients 1 4 8 16 32 \
  --rounds 5 --kernel-trace --out "$HOME/.micropod/benchmarks/profiles"
python3 scripts/ci_benchmark_store.py apple-pair path/to/paired.json
python3 scripts/ci_benchmark_store.py go-kernel-profile path/to/profile.json.gz
micropod ci metrics --usage | python3 scripts/ci_benchmark_store.py worker-metrics -
sqlite3 "$HOME/.micropod/benchmarks/measurements.sqlite3" \
  'SELECT cache_workload, engine, workload, round(seconds,3) FROM paired_batches JOIN paired_runs USING(run) WHERE clients=16'
```

Use the native ARM64 image from the Ubuntu benchmark artifact or build `scripts/bench_cache_image` once. Each run appends a receipt to the local SQLite store and writes its raw JSON and Perfetto/Chrome trace. The database views `go_batches`, `go_phases`, `kernel_samples` and `paired_batches` retain the run ID for comparisons across revisions. `kernel_batches` reports flushes, write bytes, ext4 syncs and stall time between counter samples inside each timed batch. Batches shorter than two sample intervals can have missing deltas. `cache_stores` exposes the observed live volume sizes and attachment counts. `pipeline_stages` holds per-engine application stage times. The macOS benchmark flag `--warm-bytecode` primes the same Python cache on each engine and checks the identities and sizes of its retained files.

To repeat the filesystem trial, run the following on a physical Mac with a signed CLI. It alternates the two mount settings in its own qualification VM, runs direct-shell Go and the same offline Go/npm workload used in the OrbStack comparison, and restores the initial setting. Add `--repair-network` to exercise automatic route recovery while Docker Compose serves a named volume through a published port and writes back to a shared Mac checkout.

```sh
python3 scripts/qualify_ci_worker.py apple-worker --packages --profile-ext4 --clients 16 \
  --rounds 7 --micropod "$MICROPOD_BIN" --json /tmp/micropod-ext4.json
```

The direct Go comparison stores Docker create, start, exit and removal events for every measured container. It checks the actual products, fresh container IDs, unchanged worker boots, and the native OCI digests on both engines. The reusable-output control must recompile and relink after a source edit. The stock Ubuntu control also counts real linker process executions using Go's `-toolexec` option. Each Linux worker needs the same local package image.

```sh
ci/install-crun.sh
python3 scripts/bench_fresh_go.py --image "$PACKAGE_IMAGE" --clients 16 32 --rounds 5 --out gamma.json.gz
python3 scripts/bench_fresh_go.py --suite group --image "$PACKAGE_IMAGE" --clients 16 32 --rounds 5 --out grouped.json.gz
python3 scripts/bench_fresh_go.py --suite staged --image "$PACKAGE_IMAGE" --clients 16 32 --rounds 3 --out staged.json.gz
python3 scripts/bench_fresh_go.py --suite preparation --image "$PACKAGE_IMAGE" --clients 16 32 --rounds 3 --out preparation.json.gz
sqlite3 "$HOME/.micropod/benchmarks/measurements.sqlite3" \
  'SELECT engine,mode,clients,round,round(seconds,3) FROM fresh_go_batches JOIN fresh_go_runs USING(run) WHERE clients=32 AND passed=1'
```

## Qualification

Gamma’s qualifications cover DNS recovery with running containers, ext4 tuning, cache reuse, fresh-job startup and kernel profiling through 32 concurrent jobs. [Fresh Go, OrbStack and raw Ubuntu](benchmarks/2026-11-20/fresh-go.md) [Results and trace](benchmarks/2026-11-20/worker-profile.md) · [Earlier Apple Silicon and raw Ubuntu comparison](benchmarks/2026-11-20/gamma-ci-worker.md)

The worker qualification workflow runs only when explicitly dispatched. Local Apple comparisons and qualification runs append their receipts to the runner’s SQLite database. The full qualification runs five rounds at 1, 4, 8 and 16 clients. It verifies guest-versus-container boot IDs, distinct PID and mount namespaces, actual CPU and memory quotas, both streams and exit codes, bridge DNS, package payload inodes, and image, volume and offline BuildKit cache reuse after restart. The native Ubuntu Docker run uses the same GitHub allocation and exported package image. Manual qualifications also copy those Go, Node and npm binaries out of the image and run the offline workspaces as ordinary Ubuntu processes. The raw process clock measures the package command. Its fixture setup and product verification run outside that clock. Container timings also include the Docker client, container launch, checkout creation, output verification and teardown. The full pipeline records per-stage wall times and alternates engine order across three warm passes.

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

PostgreSQL accounted for a median 11.350 s of the guest run. Each warm pass started PostgreSQL, ran its readiness query and checked the HTTP and Node outputs. Go vet, race tests and npm tests run within image builds. Unchanged inputs can reuse those layers, including the known source edit on repeated passes. [Pipeline stages and raw process timings](benchmarks/2026-11-20/arm64-worker-native-processes.json) An independent run with the final worker source measured warm medians of 12.153 s in the guest fixture and 11.953 s on the native daemon. [Full repeat](https://github.com/castlemilk/micropod/actions/runs/44632269029/job/135941717659)

A signed probe on the standard hosted Apple Silicon runner identified an Apple M1 VirtualMac and reported `VZVirtualMachine.isSupported=false`. The physical comparisons run on a provisioned rig. [Hosted Apple capability result](https://github.com/castlemilk/micropod/actions/runs/44628671876/job/135929181800)

Run `task bench-ci-apple` locally, or pass a results directory with `task bench-ci-apple -- /tmp/micropod-apple`. The script saves a standalone OrbStack receipt before starting the paired run. If the worker build or boot fails, it also saves OrbStack’s standalone package and full-pipeline timings to `orbstack-workloads.json`. The `apple-pair` workflow builds the checked-out CLI on a physical Apple Silicon runner with Apple Container and OrbStack already provisioned. It starts an independent Micropod worker in a temporary directory, matches the peer's CPU and RAM, and sends both clients the same native images. Blocks alternate engine order. Each engine also runs the complete Go, npm and PostgreSQL pipeline once and then three more times warm. The fixture removes its own sample image tags from OrbStack after the comparison. The underlying `scripts/bench_live_kernel.py --engine rig-matrix --worker-cli /path/to/micropod` also accepts `--desktop-socket` and `--colima-socket` for provisioned local peers. The report records app versions, worker identity, per-engine p50s, resource budgets and matched Ubuntu references. The short PR qualification finished in 21 seconds on hosted ARM64 Linux. A separate run executed the production Go and Node pipelines, including PostgreSQL and the source-change rebuild. [PR integration](https://github.com/castlemilk/micropod/actions/runs/44626891771/job/135922978226) · [Full pipeline integration](https://github.com/castlemilk/micropod/actions/runs/44626999645/job/135923365952)

The tuned worker in [PR #224](https://github.com/castlemilk/micropod/pull/224) ran against OrbStack 2.2.5 on Gamma, the physical 18-core M5 Max with 128 GB. Each engine had four vCPUs and approximately 4 GiB. The complete application pipeline took 13.020 s on Micropod and 21.656 s on OrbStack, medians of three warm passes on that Mac. The five-round launch and package runs use the requesting Mac's monotonic clock.

The same Mac ran the package commands directly across 145 fresh workspaces per tool. The median batch at 1/4/8/16 checkouts took 172/199/241/400 ms for npm and 110/119/147/246 ms for Go. Its native Node 24.22.2 and Go 1.27.2 differ from the Linux toolchain. All warm Go builds reused compiled packages. The npm content store and Go module store each retained one copy of their fixture payload. [Native Mac samples](benchmarks/2026-11-20/gamma-native-package-processes.json)

Manual runs upload the exported ARM64 toolchain and native Docker measurements together as the `arm64-warm-ubuntu` artifact. The Apple job loads that image on both engines and verifies its OCI configuration digest before reporting package comparisons. To repeat it locally, download the artifact and run `task bench-ci-apple -- /tmp/micropod-apple --ubuntu-bundle /path/to/artifact`.
