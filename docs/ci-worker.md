# Persistent Linux worker for CI

## Running CI without dockerd

`micropod ci job` is the scheduler entry point. On a Mac, a trusted job uses the persistent containerd worker and crun. An untrusted job gets its own Apple Virtualization.framework VM by default. The host scheduler selects the trust class and approves the image digest before submitting a job. Only the scheduler account can open the worker socket. A process that has the socket can administer the node, so keep it out of runner workspaces, workflow environments and container mounts.

| Job | Kernel and writable state | Caches and networking |
| --- | --- | --- |
| Trusted | One warm worker kernel and containerd. A fresh crun pod and writable root per invocation. | Containerd shares immutable image layers. `MICROPOD_CI_CACHE_SCOPE` mounts Go modules, Go build objects and npm data for that trust domain. The pod has its own network namespace with egress. |
| Untrusted on macOS | A new sibling Apple VM and a copy-on-write clone of the approved image. The VM is retired at exit. | The read-only base image is reusable. Only loopback is available. The job receives no shared writable cache, host directory or runtime socket. |
| Untrusted with Kata | One Kata pod VM per allocation on a node with KVM, the Kata v2 shim and the private CNI configuration. Selection is explicit. | Containerd reuses immutable image content. Private-mode macvlan on a disconnected parent provides an isolated interface without an uplink. The job cannot request mounts or runtime annotations. |

```sh
bash ci/build-runner-tools.sh .build/oci-tools
export MICROPOD_CI_OCI_TOOLS="$PWD/.build/oci-tools/guest"
export MICROPOD_OCI_CLIENT="$PWD/.build/oci-tools/client"
micropod ci runner-start
micropod ci runner-prime 16
MICROPOD_CI_CACHE_SCOPE=repo-main-go126 MICROPOD_OCI_TRACE=1 \
  micropod ci job trusted "$CI_IMAGE" sh -ec 'go vet ./... && go test ./...'
micropod ci job untrusted "$APPROVED_IMAGE_DIGEST" /bin/sh -c 'make test'
micropod ci runner-stop
```

For a fleet that opts into Kata, provision its verified QEMU tools with `ci/install-kata-tools.sh DIRECTORY`. Use the printed path as `MICROPOD_CI_KATA_TOOLS` when provisioning a new native node. Set `MICROPOD_CI_UNTRUSTED_RUNTIME=kata` in the scheduler to require that runtime. A missing KVM device, shim or failed pod launch returns an error. Gamma's stock Micropod kernel and the Ubuntu nested-KVM node have different device support. Use the hardware qualification for the actual worker kernel. [Gamma isolation measurements](benchmarks/2026-11-20/runner-isolation.md)

An idle scheduler can call `ci runner-prime COUNT` ahead of a known trusted burst. It opens up to 32 empty crun pods. Claiming a pod atomically consumes its single-use entry and rechecks its identity, owner and runtime with containerd. Workload containers are created after dispatch. Each pod is destroyed after its job, including its network namespace and writable state. An untrusted job always gets a fresh VM. The scheduler can omit priming to avoid the idle footprint or charge it to batch time when work is already queued.

The job subprocess receives the supplied argument vector. The native service streams the job's CRI log records as they arrive to the matching stdout and stderr, and returns the process exit code. The worker caps job logs at 8 MiB, applies a 1 GiB memory limit and 1 CPU, and records image lookup, pod creation, container creation and start durations with `MICROPOD_OCI_TRACE=1`. At startup it reconciles pods against durable per-job ownership records. Shutdown refuses active work. The Apple VM path has its own VM memory and disk limits.

Keep a trusted GitHub runner controller or Cuttlefish agent on the scheduler side. Arbitrary pull requests need a private allocation containing the job, its services and its workspace. Cuttlefish's native allocation image places a rootless containerd and crun inside that allocation's Apple VM. The existing controller still owns reservations, verifies the host boundary and fences the allocation before retiring it.

In Kubernetes the corresponding control is an admission-enforced RuntimeClass assigned by namespace policy. A workload that can choose its own class or open containerd's socket could bypass that policy. [GitHub runner container hooks](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/customize-containers) · [Kubernetes RuntimeClass](https://kubernetes.io/docs/concepts/containers/runtime-class/)

## Native worker for Cuttlefish and local Docker clients

Stock `docker exec` streams stdout and stderr as the process writes them. The managed HVF and VZ workers support `-i`, `-t`, terminal resize, `-d`, environment overrides with `-e` and working-directory overrides with `-w`. The process inherits the container’s configured user. On Gamma, VZ intermittently exceeded five seconds for detached exec while a client kept event history queued. Run the stock-client qualifier against a worker with Alpine 3.23 available. [Gamma stock-client checks and current limits](benchmarks/2026-11-25/managed-ci-git-and-exec.md)

```sh
endpoint=$(micropod ci runner-docker-endpoint)
bash scripts/qualify_native_worker.sh --interactive-exec --host "$endpoint"
```

Stock `docker cp` can upload and download files, directories and tar streams through the native worker. Retained containers support copy before first start, while running and after stop. Downloads also work on read-only Alpine and layered images. The qualifier covers `-a`, `-L`, writable named volumes and host workspaces. Archive support covers uncompressed tar, ordinary files, directories and same-view links. Runtime-managed paths, tmpfs, special file entries, set-ID uploads, xattrs and recursive copies across mounts have limited or unsupported behavior. [Gamma compatibility matrix](benchmarks/2026-11-25/phase-b5-managed-checkout-and-archive.md)

The scheduler socket and the Docker-compatible socket belong to the same persistent VM. The native guest handles Docker API versions 1.44–1.47 through containerd's CRI and crun. Image layers, the Go toolchain and scoped Go/npm cache entries are shared by both entry points. Each workload gets its own writable root and network namespace. The Mac client can hold an open port, read output as it arrives, and collect process status while other clients start jobs.

The native Docker engine receives task-exit notifications from containerd and shares one Linux inotify descriptor across its running container logs. It drains any final output and reads the exit status from CRI. If a log watch or exit notification fails, the runner falls back to polling. [Gamma measurements with 64 and 112 containers](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-log-notification-results.md)

For managed HVF snapshot restore, set `MICROPOD_CI_HVF_RESTORE_FROM` to the completed capture and use a fresh `MICROPOD_CI_HOME` on the same APFS volume. Supply the workspace path from the capture, or leave it unset if the capture had none. The worker validates the snapshot and guest workspace before declaring readiness. A schema-1 restore retains the captured worker, instance and Linux boot identity. Provision separate workers for jobs that need independent identities. [Gamma snapshot checks](benchmarks/2026-11-25/managed-ci-git-and-exec.md)

Gamma’s benchmark launchers create a separate APFS volume for each native worker, including direct Hypervisor.framework workers. They verify disabled Spotlight indexing, check for FSEvents journal files and confirm the worker disk’s identity on a read-only remount at shutdown. [Protected drives, container lifecycle and dense CI measurements](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-response-handoffs-and-worker-drives.md)

Use `micropod ci runner-docker-endpoint` for stock Docker and Compose clients. The registered `ci` runtime also uses this socket for container operations. `micropod ci runner-endpoint` serves the Micropod job protocol. `micropod ci runner-status` reports the live VMM. An explicit `MICROPOD_CI_VMM=hvf` or `vz` requires the matching backend when joining a running worker. [Managed engine qualification and open Docker compatibility work](benchmarks/2026-11-25/managed-engine-compatibility.md)

```sh
# Select the rig account's private exchange directory before provisioning this disk.
export MICROPOD_CI_WORKSPACE="$HOME/.micropod/cuttle-workspace"
install -d -m 700 "$MICROPOD_CI_WORKSPACE"
micropod ci runner-start
endpoint=$(micropod ci runner-docker-endpoint)
docker --host "$endpoint" run --rm --network none alpine:3.23 echo ready
docker --host "$endpoint" volume create --label owner=cuttle cuttle-workspace
```

The stock CLI speaks to this endpoint without changing the active Docker context. The native endpoint verifies both the disk's worker identity and the live supervisor instance. To supervise this worker across logins, point `MICROPOD_CI_OCI_TOOLS` at a durably installed guest tool bundle and run `MICROPOD_CI_ENGINE=containerd micropod ci install-service` on the rig account after stopping its standalone worker. The existing launch agent supports one registered worker directory per account.

With the updated native guest tools, `docker restart`, `docker compose restart` and `micropod restart` preserve the ID of a retained container. The native runtime advertises restart after it verifies the guest capability. The endpoint accepts a bounded grace period or an explicit SIGKILL. Auto-remove containers, unlimited grace, other signal overrides and restarting a failed process through this endpoint remain unsupported. Use `docker start` after recovery of an interrupted process. [Stock-client restart qualification](../scripts/qualify_docker_restart.py)

On a kernel with CUBIC available, an internal bridge or IPvlan network can select it for sibling transfers. For example, `docker network create --internal -d ipvlan --opt com.micropod.network.tcp-congestion=cubic ci-bulk` installs the route metric for that subnet. This option only changes the selected subnet route. With the current HVF launcher and B4 kernel the guest default is also CUBIC. The measured VZ worker used BBR. [Paired Gamma measurements](benchmarks/2026-11-25/phase-b4-managed-performance.md)

| Workload | Native behavior |
| --- | --- |
| Trusted Cuttlefish attempts | Set `RUNNER_PREFER_MICROPOD=true` and `RUNNER_MICROPOD_TRANSPORT=worker`. Set `TMPDIR` and `CUTTLE_RUNNER_TMP_HOST_PREFIX` to the configured exchange directory, and `CUTTLE_DOCKER_MOUNT_WORKDIR=1`. Separate stages can use the same labeled workspace volume. The agent checks both sockets before intake and reads capacity on the VM disk. |
| Foreground and detached containers | Create, start, restart, wait, inspect, list, stop, kill, remove, logs and noninteractive exec. The image entrypoint runs as PID 1. A retained writable container keeps its filesystem across stops, restarts and worker reboots. Output preserves stdout/stderr and the process exit code. An interrupted process with an unknown exit is marked dead and can be started explicitly. |
| Local databases and servers | TCP publishing leases a fixed or dynamically assigned Mac loopback port. The native worker uses Linux kernel forwarding when its guest supplies the required netfilter features. Its TCP relay handles other supported guests. The Mac closes the lease’s connections on release. The guest retires the mapping before it recycles the pod address. Numeric users, image-default users, read-only mounts, bridge networking, offline networking, and CPU/memory/PID limits are supported. |
| Go or npm fan-out | Use a scheduler cache scope, or mount the corresponding Docker volume names `micropod-ci-scoped-SCOPE-gomod`, `-gobuild` and `-npm`. Set `GOMODCACHE`, `GOCACHE` and `npm_config_cache` to their mount points. Keep `-trimpath` in `GOFLAGS`. Removing a Docker cache reference preserves scheduler-owned cache data. |
| Testcontainers | The native guest supports Go Testcontainers' named-container reuse and a single named network with aliases. Set `DOCKER_HOST` to the worker endpoint and `TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE=/var/run/docker.sock` for the stock Ryuk sidecar. Its session-scoped socket can enumerate and remove its labeled containers, networks and volumes. Worker image layers, other sessions and both owner sockets stay private. [Stock-client qualification](benchmarks/2026-11-26/mounted-checkout-concurrency-and-native-compat.md) |
| Service networks and Compose | Create an IPv4 bridge with `docker network create`, then use container names or `--network-alias` for DNS. Internal networks, per-network subnets, MTU, scoped aliases and active-endpoint removal checks are supported. A service can join one network at creation. Gamma also supports guest-local MACVLAN L2. |
| Building and moving images | `MICROPOD_CI_ENGINE=containerd micropod ci docker buildx build --load …` selects a remote BuildKit worker over a local socket. BuildKit starts on first use and shares containerd's content store. For standalone Buildx clients, register `micropod ci runner-buildkit-endpoint` with the remote driver. Stock Docker image save/load streams OCI-compatible archives. |
| Engine events | Stock Docker and Compose can watch native container lifecycle and exec events by ID, project or service labels. Exec events carry the exec ID and a confirmed exit code on completion. The worker streams JSON records with actor attributes and nanosecond timestamps. A time-bounded query can replay up to 256 recent events retained by the current daemon. The history has an 8 MiB estimated payload limit and the daemon accepts up to 64 concurrent event subscriptions. [Gamma event qualification](benchmarks/2026-11-25/phase-b4-ci-density-and-events.md) |
| Docker API qualification | Stock clients have exercised interactive PID 1 attach, terminal exec, archive copy, Buildx and Compose health dependencies on the native socket. A second network connection before or after container start, additional Docker object events and broader API coverage remain open. [Interactive checks](benchmarks/2026-11-26/core-pid1-and-mutable-gamma.md) · [Archive copy](benchmarks/2026-11-25/phase-b5-managed-checkout-and-archive.md) · [Buildx](benchmarks/2026-11-26/workspace-queues-and-native-buildx.md) · [Compose](benchmarks/2026-11-26/workspace-completion-transport-and-image-load.md) |
| Private Cuttlefish runner allocations | Build the ARM64 allocation tools with `ci/build-runner-tools.sh --allocation DIRECTORY`. Cuttlefish's native runner image provides an allocation-only Docker API and remote Buildx builder backed by rootless containerd and crun. Physical qualification covers image pull, private workspace, named service DNS, published port cleanup, Dockerfile build, cgroup limits and fenced deletion. Production GitHub job acceptance is outstanding. |

A bind source must resolve beneath the configured exchange directory. The guest pins its opened inode during launch. The trust boundary is the worker account. Select a sibling Apple VM or qualified Kata node for untrusted job code. Trace trusted scheduler jobs with `MICROPOD_OCI_TRACE=1`. On the native Docker socket, `GET /micropod/metrics` reports boot-scoped image hits, scoped cache attachments, prepared pod use and cumulative create/start timings. Its `network` object counts attachments, failures and elapsed microseconds per driver, and local DNS answers, misses, upstream requests, failures and overload drops. `GET /micropod/storage` reads ext4 capacity in constant time. `docker stats` reads CRI CPU and memory plus kernel PID, network and block I/O counters. The Docker socket retains the container's stdout and stderr on the worker disk until removal. The default `json-file` behavior supports `docker logs`, live attach and replay across container restarts. A slow reader can finish the generation it attached to while later generations run. A spool failure exposes incomplete output and preserves the process's exit status. Explicit rotation options and other drivers currently return a create error. The standalone scheduler job API keeps its 8 MiB limit. [Gamma logging checks](benchmarks/2026-11-26/core-pid1-and-mutable-gamma.md#verbose-docker-jobs)

For a dedicated rig that repeatedly receives 32-job bursts, set `MICROPOD_CI_MAX_STARTING=8` before starting its native worker. This limits simultaneous Docker container setup through crun start. Jobs release the slot as soon as their process starts. All 32 can run at once. The default is unrestricted. The variable accepts 0–32, with zero selecting the default. An idle restart applies the setting on the same disk and preserves the caches. The metrics endpoint reports the active limit, occupied slots and cumulative queue wait. The 16-job measurements favored the default.

When a four-vCPU worker also serves published ports, budget for the build steps themselves. On Gamma, allowing four Go vet/test/build steps to run at once kept 32 job containers reachable and brought fresh-request p95 from 33.4 ms to 11.9 ms. Both policies finished the 32 revisions in about four seconds with a warm shared cache. A scheduler can apply this limit at build dispatch and keep resident services available throughout the batch. A separate test ran 32 new job containers alongside 32 published services and checked failure propagation, cancellation and port reuse. [Gamma CI concurrency measurements](benchmarks/2026-11-24/gamma-ci-concurrency/results.md)

For completed artifacts served repeatedly over a published HTTP port, pass the open regular file to the Linux HTTP server. On Gamma, Go's sendfile path delivered 5,956 MiB/s across 32 services during CI, with a 55.3 ms fresh-request p95. The memory-backed response delivered 5,046 MiB/s. All four guest CPUs performed best for the build steps, including the CPU handling the publication NIC's interrupts. [Artifact delivery, CPU placement and matched peer measurements](benchmarks/2026-11-24/gamma-ci-concurrency/low-level-results.md)

Run `scripts/qualify_native_worker.sh` to exercise stock clients. Pass `--restart` with an explicit qualification worker home to also check shutdown under load and durable state after reboot. The dated Gamma receipt includes the matched Go runs and independent Cuttlefish checks. [Gamma results](benchmarks/2026-11-21/native-worker.md)

The network benchmark compares direct netlink with standalone Netavark on the same kernel, and service traffic with OrbStack. [Gamma network measurements](benchmarks/2026-11-21/native-network.md)

The native worker publishes Mac loopback TCP ports through a host-only virtio interface. The primary interface carries internet and DNS traffic. The guest accepts kernel port mappings only from its Mac peer on the published interface. The Mac relay binds to that peer address and interface and retries a guest handshake within its ten-second setup budget. `micropod ci status` reports the egress and published addresses as `guestAddress` and `publishedAddress`. Install the host binary and the runner tools from the same build to enable the second interface. Older tool bundles continue to publish over the egress interface.

The worker tracks each link separately and checks them concurrently. It restores guest addresses and routes in place, then reconnects the affected NIC if its first hop still fails. `micropod ci repair-network` repairs egress while the published interface continues serving. `micropod ci metrics` reports the most recent egress and published-link repairs for the current boot. [Gamma mixed-load and recovery measurements](benchmarks/2026-11-21/gamma-mixed-path.md)

The default kqueue relay checks for interactive traffic after two bulk events. `MICROPOD_CI_PORT_RELAY=kqueue-throughput` gives the listener a dedicated accept queue and two data workers by default. The first connections on different ports take turns across the workers. Later connections rotate independently within each port. Each worker reads up to 24 ready events from a single kqueue and services newly connected and small streams first.

Set `MICROPOD_CI_PORT_RELAY_WORKERS` to 1 through 4 in the worker environment with `kqueue-throughput` or `kqueue-interactive`. `micropod ci status` reports the number created as `publishedRelayWorkers`. With three or four workers, each callback yields after at most 24 events so queued handoffs and revocations can run. With one or two workers the limit is 128 events. The guest VM and container CPU counts are configured separately. [Gamma relay measurements](benchmarks/2026-11-22/gamma-relay-workers.md)

On the dedicated link the throughput mode places its single virtio interrupt on the last online guest CPU and enables Linux fair queuing. For a bridge service with a published port it also enables fair queuing on the service veth and sets a Reno preference with a 20 ms minimum retransmission timeout on the directly attached gateway route. The service queue handles its outbound flows, including sibling traffic. Explicit queue configurations take precedence. Applications can select their own congestion control.

A backend TCP reset before its first response byte reaches the Mac client as a reset. An orderly FIN half-closes the opposite write side and permits the remaining reply to drain. Set `MICROPOD_CI_PORT_PROFILE=1` for per-lease timings, backpressure, route waits, handshake failures, idle guest closes, closes after a request write and forwarded resets. The lease profile reports `pending_allocations` and `pending_copy_bytes` for newly buffered write suffixes in either direction. Retrying a write from the same buffer can increase `blocked_writes` again. The two copy counters accumulate over the whole lease, including shutdown. Terminal error records include the original client port, the guest-side source port, kqueue flags, socket errors and pending bytes. `MICROPOD_CI_PORT_RELAY=kqueue` selects the default mode explicitly. `MICROPOD_CI_PORT_RELAY=nio` selects SwiftNIO. [Gamma scheduler, queue and reset measurements](benchmarks/2026-11-21/gamma-mixed-scheduler.md)

With profiling enabled, `guest_read_supply` records successful guest reads before the relay writes their bytes to the Mac client. Four counters cover up to 128 KiB, over 128 and under 256 KiB, exactly 256 KiB, and over 256 KiB. `bytes` sums those reads. `full_cap_reads` counts reads that filled `read_cap_bytes`. Among those, `full_cap_with_ready_hint_above_cap` counts read events whose queued-byte snapshot exceeded the cap. The amount available can change before the read. Uploads, retries of buffered writes and EOF contribute no samples. Counters cover the whole lease and combine its data workers. Collect these diagnostics separately from scored throughput.

Native Docker services inherit a one-CPU quota, 1 GiB of memory and 512 PIDs by default. Use `--cpus 4` to give a service four CPUs or `--cpu-quota=-1` to let it use the CPU time available to its parent. The published-port benchmark can verify these limits inside each service before timing. [Matched benchmarks and guest packet timings](benchmarks/2026-11-21/gamma-published-scheduling.md)

The updated native Docker engine accepts `--cpuset-cpus`. For example, `--cpuset-cpus 1-2 --cpus 1` lets a container run on guest vCPUs 1 and 2 with one CPU of total bandwidth. Docker inspect reports the request in `HostConfig.CpusetCpus`. Linux reports the effective CPUs in `/sys/fs/cgroup/cpuset.cpus.effective`. Omit the flag to use the worker’s allowed CPUs. On Gamma’s four-vCPU worker, assigning 16 services to `0-1` and 16 to `2-3` improved both aggregate mixed throughput and the slowest service compared with giving every service all four CPUs. Build jobs in that comparison could use all four CPUs. [CI placement measurements](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#native-docker-cpu-placement-with-files-and-memory-together) · [Docker CPU controls](https://docs.docker.com/engine/containers/resource_constraints/#configure-the-default-cfs-scheduler)

When a profiled native relay encounters a guest route failure, it checks macOS Local Network permission once during that worker session. A log entry containing `udp_path=local-network-denied` means Network.framework reported a denial for the relay process. Allow that build of Micropod in System Settings → Privacy & Security → Local Network to use its published ports. The diagnostic uses the private guest address and sends no application data. [Gamma launch-agent diagnosis](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#local-network-permission-on-the-rebuilt-mac-relay) · [Apple’s local network privacy guidance](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)

For synchronous calls between a CI client and its dependency, the two containers can share a guest vCPU. For example, start both with `--cpuset-cpus 0 --cpus 1` and put the next pair on vCPU 1. On Gamma, distributing 32 pairs this way increased internal HTTP throughput 10.4% over unrestricted placement on the four-vCPU worker. The full distribution includes busy tail latency and the corresponding OrbStack results. [CI dependency traffic and CPU placement](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-results.md)

To let Micropod choose that vCPU, give the job container and its dependencies the same Docker label, for example `--label io.micropod.ci.cpu-group=build-42`. Use a distinct value for each independent job. On the same Docker network, eligible members share one guest vCPU. A new group takes the allowed CPU with the fewest reserved groups. Docker inspect reports the selection in `HostConfig.CpusetCpus`. The default bridge and named networks have separate group namespaces.

Jobs using `--network none` can use the same CPU-group label. Give each independent compiler its own group name to distribute jobs over the worker’s allowed CPUs. The workload keeps its requested CPU quota and remains offline. [32-job placement and useful-work measurements](benchmarks/2026-11-25/phase-b4-ci-density-and-events.md)

With 32 jobs and dependencies on Gamma's four-vCPU worker, grouping raised saturated HTTP throughput by 34.3% and lowered p99 by 26.5% over unrestricted placement. Eight jobs were also building Go code. The worker used the 125 µs scheduler profile and next-buddy wakeups. [Paired measurements and build times](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-latency-and-placement-results.md#automatic-placement-for-ci-jobs)

For private service traffic inside one worker, the updated kernel builder includes IPvlan. With that kernel, `docker network create --internal --driver ipvlan ci-job` creates a private L2 network. Attach the job and its dependencies with `--network ci-job`. With 32 grouped pairs performing saturated HTTP and eight concurrent builds, Gamma delivered 180,406 requests/s on IPvlan and 169,303 on the ordinary internal bridge. Choose the network when creating the CI job. [Network-driver comparison and kernel identity](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-latency-and-placement-results.md#internal-docker-network-drivers)

An explicit CPU set, unlimited CPU quota or CPU budget above one CPU takes precedence. CPU bandwidth, memory and PID limits retain their requested values. A stopped member keeps the reservation for a restart. Removing the last member releases it. When the worker starts with fewer available CPUs, it reassigns affected groups before opening the Docker API. [Placement policy](../guest/runner/docker_config_linux.go) · [Scheduling and recovery](../guest/runner/docker_engine_linux.go) · [64-container qualification](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-latency-and-placement-results.md)

When a build and its dependency client share a container, `nice -n 5 sh ./ci/build.sh` lowers the priority of the build and its children. On Gamma with eight busy build slots and 32 same-vCPU client–service pairs, Micropod’s HTTP rate rose from 148,390 to 180,808 requests/s. Eight builds took 3.18 s versus 2.92 s at the inherited priority. [Build and request measurements](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-results.md#eight-builds-sharing-a-worker-with-32-active-dependencies)

The native CI Docker API also accepts `docker run --cpu-shares 512` to weight the whole container under CPU contention. It can be combined with `--cpus` and `--cpuset-cpus`. Read the effective weight inside the container at `/sys/fs/cgroup/cpu.weight`. Gamma mapped 512 shares to weight 59 and an ordinary sibling to weight 100. On one vCPU, the weighted container received about 37% while both were busy and used essentially the full CPU when running alone. [Effective weights and CPU time](benchmarks/2026-11-24/gamma-ci-concurrency/20261124T212137Z-sibling-h55n373c/cpu-weight-A.json) · [Linux cgroup weight semantics](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu)

For mixed CI where every dependency client needs to make progress, leave the build containers at their inherited CPU weight. In the 64-container comparison, setting 512 shares for those eight containers raised aggregate Micropod throughput 2.9% but cut the least-served client’s completed requests by 57.4%. [Builds, throughput and per-client results](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-results.md#native-docker-cpu-shares)

The native worker with the `full-16k` guest kernel accepts an opt-in high-resolution scheduler tick. In the trusted environment of the process running `micropod ci serve`, set `MICROPOD_SANDBOX_KERNEL_ARGS='micropod.ci_sched=hrtick'` before booting a worker with the matching runner tools. Append the argument if the supervisor already supplies other kernel arguments. A launchd worker reads this setting from its service environment. The guest logs its effective scheduling interval at startup. Omitting the argument selects the kernel's inherited scheduler.

On Gamma, `hrtick` delivered 186,606 requests/s with a 3.13 ms p99 while eight builds ran. To give slow requests more frequent access to a vCPU, the same argument accepts `hrtick-1ms` or `hrtick-500us`. In separate matched runs the 1 ms setting delivered 173,507 requests/s at 2.72 ms p99. The 0.5 ms setting delivered 163,424 requests/s at 2.16 ms p99. Both shorter intervals increased p95 and gave up throughput. [64-container scheduling measurements](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-scheduler-results.md)

For a worker serving many synchronous client–service pairs on shared vCPUs, the guest also accepts `micropod.ci_wakeup=next-buddy`. This preference applies to the worker's Linux fair scheduler. At the inherited 2.1 ms interval with high-resolution ticks, Gamma served 220,711 requests/s at 179 µs p95. P99 rose from 3.12 to 3.62 ms, and eight builds took 3.34 seconds. Supply both settings in the trusted worker service environment with `MICROPOD_SANDBOX_KERNEL_ARGS='micropod.ci_sched=hrtick micropod.ci_wakeup=next-buddy'`. The guest logs `NEXT_BUDDY` after checking the effective feature. [Throughput, tail and build measurements](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-scheduler-results.md#preferring-the-last-task-woken)

The final packaged worker at 2.1 ms delivered 215,997 requests/s versus OrbStack's 157,481 with p95 of 179 versus 342 µs. For a service constrained by p99, `micropod.ci_sched=hrtick-500us micropod.ci_wakeup=next-buddy` delivered 205,768 requests/s with a 2.15 ms p99. Its p95 rose to 1.08 ms. Both configurations ran 32 client–service pairs and eight simultaneous builds. [Packaged worker comparison](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-scheduler-results.md#packaged-worker-with-wakeup-preference)

For short synchronous calls on a heavily shared four-vCPU CI worker, the matching runner tools also accept `MICROPOD_SANDBOX_KERNEL_ARGS='micropod.ci_sched=hrtick-125us micropod.ci_wakeup=next-buddy'`. The packaged worker served 168,643 requests/s at 1.032 ms p99 when each client shared one guest vCPU with its dependency. Letting all containers use all four vCPUs produced 123,414 requests/s and 1.431 ms p99. Each container retained its one-vCPU bandwidth limit in both placements. [64-container interval and placement results](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-latency-and-placement-results.md)

With 32 grouped IPvlan pairs on that 125 µs profile, Gamma also ran eight Go builds at nice +5 while offering exactly 64,000 HTTP requests/s to each engine. Micropod's p95 from scheduled arrival through completion was 0.66 ms, compared with OrbStack's 2.87 ms. The eight builds finished in 3.08 and 2.84 seconds respectively. At ordinary build priority in a separate four-boot comparison under ambient load, arrival p95 was 2.00 ms for Micropod and 3.64 ms for OrbStack. The eight builds finished in 3.27 and 3.01 seconds respectively. Higher offered rates produced substantial client-side queues on both engines. [Ordinary CI build priority](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-wakeup-and-offered-load-results.md#ordinary-ci-build-priority) · [Matched arrival schedules and build overlap](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-wakeup-and-offered-load-results.md#matching-the-offered-request-rate)

The updated guest tools accept `MICROPOD_SANDBOX_KERNEL_ARGS='micropod.ci_sched=hrtick-250us micropod.ci_wakeup=next-buddy'` when starting the worker. On 32 job networks, this setting and `--scratch-mib 128` for each of eight concurrent builds cut Micropod's build time by a paired 5.7% against its 125 µs overlay configuration. At 64,000 scheduled HTTP calls/s, Micropod's p95 from scheduled arrival to completion was 1.90 ms versus OrbStack's 3.27 ms. P95 from actual dispatch to completion was 685 versus 297 µs, and the eight builds took 3.033 versus 2.976 s. Each engine had four vCPUs and 4 GiB. [Fresh holdout on the final worker](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-ci-dispatch-and-scratch-results.md#fresh-holdout-of-the-final-worker)

On the 250 µs profile, a CI job can request a 2.1 ms slice for its compiler process tree. On Gamma this brought scheduled HTTP p95 down in all eight matched windows, by a paired median of 19.8%, while the time to finish eight builds rose 0.24%. The measured Linux arm64 launcher worked as UID 65534 with zero effective capabilities. The job image’s stock `chrt` 2.38.1 rejected the custom slice. [Tested job command and hardware results](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-compiler-runtime-results.md#running-the-compiler-setting-as-an-ordinary-user)

### Direct TCP ports on a native Mac worker

A worker can deliver a published connection from the host-only virtio NIC directly to its owning container. Set the following when creating a separate worker home. Supply a signed Micropod CLI and matching guest tools from this revision. `MICROPOD_CI_KERNEL` takes an absolute path to an uncompressed ARM64 Linux `Image`. The worker records that path and the publication mode in its manifest. Keep the selected image at that path for subsequent starts.

```sh
export MICROPOD_CI_HOME="$HOME/.micropod/ci-direct"
export MICROPOD_CI_ENGINE=containerd
export MICROPOD_CI_KERNEL="$HOME/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image"
export MICROPOD_CI_PUBLISHED_PATH=macvlan
export MICROPOD_CI_PORT_RELAY=kqueue-throughput
micropod ci runner-start
export DOCKER_HOST="unix://$MICROPOD_CI_HOME/docker.sock"
unset DOCKER_CONTEXT
docker info --format '{{.KernelVersion}} {{json .Labels}}'
```

For a worker serving many concurrent macvlan publications, set `MICROPOD_CI_PORT_RELAY=kqueue-throughput` and `MICROPOD_CI_PORT_RELAY_WORKERS=4` to give four relay workers automatically sized backend receive windows. On Gamma, 32 services beat OrbStack on bulk throughput with four active build steps and either a 1,500- or 9,000-byte private link. With eight active steps on four vCPUs, Micropod finished the CI batch sooner and led on files. OrbStack led on memory-backed traffic. To select jumbo frames, set `MICROPOD_CI_PUBLISHED_MTU=9000` before first starting a new native macvlan worker. The setting accepts 1500–9000 bytes, belongs to the worker manifest and applies to the host-only vmnet network and its Linux publication interfaces. Use a separate `MICROPOD_CI_HOME` to compare MTUs. [Gamma measurements with 32 services](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md)

Memory-backed services on Gamma benefited from experimental Linux receive packet steering while eight builds shared four vCPUs. To try it, set `MICROPOD_CI_PUBLISHED_RPS=off-irq` before starting a new native macvlan worker with matching runner tools. On a single-queue private virtio NIC the guest reads the effective interrupt affinity and directs receive processing to the other online CPUs. Gamma used vCPUs 0–2 and kept the interrupt on vCPU 3. A single-vCPU worker keeps both on its only CPU. The worker logs an unsupported queue or IRQ layout. Mixed file and memory trials have reopened bulk connections with either receive policy. Leave the default in place for general CI until the mixed-load stalls are resolved. [Measured throughput, build time and reconnects](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#steering-guest-receive-work-away-from-the-virtio-interrupt)

Set `MICROPOD_CI_PUBLISHED_GSO_BYTES=40960` before creating a native macvlan worker to limit the size of IPv4 TCP batches on the private NIC and each published container. The worker accepts byte counts from the configured MTU through 65,536. Omitting the setting uses the kernel’s segmentation limit. On Gamma, the 40 KiB setting with a 9,000-byte MTU and off-IRQ receive steering beat OrbStack on memory-backed throughput by 11.7–13.4% across two eight-build trials. File throughput trailed by 3.2–7.0%, with file-request p95 at 10–11 ms. These measurements used the earlier signed host relay. [Paired Gamma results](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#40-kib-on-the-private-virtio-link)

To tune an individual service, pass `--sysctl net.ipv4.tcp_limit_output_bytes=163840` to its `docker run`. This limits how many bytes each sending TCP socket can queue in the service's Linux network namespace. The native Docker engine applies the value before starting the process, including when starting a stopped container. A container without this option uses the kernel default. Gamma’s worker default was 4 MiB. [Docker container sysctls](https://docs.docker.com/reference/cli/docker/container/run/#configure-namespaced-kernel-parameters-sysctls-at-runtime) · [Linux TCP Small Queues](https://docs.kernel.org/networking/ip-sysctl.html)

On two Gamma boots with the earlier signed Mac relay, eight concurrent builds and 32 services split evenly between 160 KiB and 192 KiB queues, Micropod led OrbStack by 4.2% in paired aggregate throughput. Both engines received the same settings. Giving the larger queues to the file services put Micropod’s file streams ahead in all eight such pairs. Giving them to the memory services produced the higher aggregate lead. [Results by service type and queue size](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#split-160-and-192-kib-queues-across-the-services)

The native Linux guest sets a minimum of 512 inotify instances per user for containerd's memory-event monitors. Gamma verified Docker's `OOMKilled` state with 64 containers running and all 63 sibling containers still healthy. [Containerd event monitoring](benchmarks/2026-11-24/gamma-ci-concurrency/published-link-results.md#containerd-out-of-memory-event-monitoring-at-64-containers)

The Mac owns each loopback listener. Linux reserves a guest TCP port and maps it to one private macvlan interface in the container’s network namespace. A worker-owned nftables table steers traffic on the dedicated NIC. Inside the namespace, a second table admits the leased TCP flow, translates it to the service’s ordinary Docker address and port, and permits replies. Multiple bindings share one interface. The interface has no IP addresses or default route. An application can bind to its Docker IP. Named bridges, DNS and internal-network policy still use its original interface. Native bridge containers use this path for IPv4 TCP. Rootless allocations and other network drivers use their existing publication mechanisms.

The guest registers its intent with the Mac before it asks the Mac to bind. On removal the Mac closes the listener and its accepted connections before acknowledging release. The guest withdraws the lease and its connection-tracking state. If a bind or release reply is lost, it holds the guest port and asks the broker whether the owner has retired. An unreadable broker keeps that port reserved. Inspect `network.published_tcp.macvlan_leases` (cumulative) and `network.macvlan_quarantined_ports` (current) in `GET /micropod/metrics`. The Docker info label `io.micropod.published-path=macvlan` confirms the running worker installed the direct policy.

Build the pinned kernel on ARM64 Linux with `ci/build-worker-kernel.sh linux-7.3.5.tar.xz apple.config OUT full`. The base config must support the Apple guest devices and filesystem. The optional `lazy` profile changes kernel preemption. Both profiles build virtio-net, macvlan, nftables ingress/egress and fair queuing into the kernel. Select a separate home to compare images on the same Mac. The standard worker uses the provisioned Apple kernel and bridge. The direct worker installs nftables at boot if needed. An offline rig can ship its matching signed Alpine APKs and dependencies in `runner/network-apks/` inside the tools bundle. Micropod runs nftables on port setup and teardown. Bulk traffic stays in the guest kernel after the Mac relay. [Gamma kernel comparison and ownership checks](benchmarks/2026-11-21/gamma-direct-macvlan.md)

For a page-size comparison, build the control with `full` and the candidate with `full-16k` from the same Apple config and compiler. Pass a new output directory for `full-16k`. The candidate uses the same release string and full-preemption settings. The builder verifies the resolved 16 KiB selection and page shift after Kconfig runs. Compare the resulting artifact directories with `python3 -B scripts/relaybench/kernel_candidate.py CONTROL_DIR CANDIDATE_DIR`, review derived Kconfig differences, then verify the booted page size and OCI behavior in separate worker homes before benchmarking. To replay the config edits offline, run `python3 -B scripts/relaybench/kernel_candidate_profile_check.py linux-7.3.5.tar.xz apple.config`.

Gamma qualified `full-16k` on an M5 Max with 32 services and 32 ephemeral Go build containers. Provision a separate worker home and point `MICROPOD_CI_KERNEL` to the absolute path of its `Image` to use that profile. This kernel exposes a 16 KiB userspace page size. Applications that map files at raw 4 KiB offsets must align the mapping to the OS page size and offset their view within it. The tested Go workload used more peak memory per job. Node and SQLite successfully reopened a 4 KiB-page database across the two Linux page sizes. [Measured performance and OCI compatibility](benchmarks/2026-11-24/gamma-ci-concurrency/kernel-page-results.md)

For CI images that require 4 KiB file-mapping offsets, the opt-in `full-mthp` profile supports larger anonymous allocations while keeping 4 KiB application pages. Build it on ARM64 Linux with `sh ci/build-worker-kernel.sh linux-7.3.5.tar.xz apple.config NEW_OUT full-mthp`. Set `MICROPOD_CI_KERNEL` to the absolute path of `NEW_OUT/Image` when provisioning a separate worker home. Set `MICROPOD_SANDBOX_KERNEL_ARGS='thp_anon=16K:always thp_anon=2M:inherit'` in the environment of the trusted `micropod ci serve` process that boots the VM. When starting an unmanaged worker, set the variable before running `micropod ci start`. For a launchd-managed worker, supply it to the service itself. In the guest, `/sys/kernel/mm/transparent_hugepage/hugepages-16kB/enabled` shows `[always]` for the measured policy. Gamma’s Go jobs used less kernel CPU and more peak memory with this setting. [Measured CI workload and memory](benchmarks/2026-11-24/gamma-ci-concurrency/kernel-page-results.md#4-kib-applications-with-16-kib-anonymous-allocations)

For a virtio-only worker, the opt-in `full-no-mlx5` kernel profile removes the ConnectX driver and needs a new output directory. The resolved profile also drops the shared devlink management interface. [Driver footprint and compatibility checks](benchmarks/2026-11-23/kernel-driver-prune.md)

Set `MICROPOD_CI_PORT_RELAY=kqueue-interactive` when generating a native worker’s launch agent to run it in its own Interactive scheduling context. The two relay workers request 512 KiB of receive space on each guest-facing TCP socket before connecting. `micropod ci launch-agent` prints the configuration and `micropod ci install-service` installs it. The matched Gamma run recorded vCPU priorities, throughput, fresh-request latency and all failed rounds. [Interactive worker results on Gamma](benchmarks/2026-11-21/gamma-vcpu-priority.md)

On a direct worker, `GET /micropod/metrics` includes `network.published_link` with bytes, drops and errors in both directions. `tx_queue_timeouts` sums the Linux watchdog counts from the published NIC’s transmit queues. Compare successive scrapes on the same worker boot. Kernels that cannot supply all queue counters omit the total. A stalled connection can occur without a kernel watchdog expiration.

The optional `full-cubic` kernel profile adds built-in CUBIC to the same full-preemption image. On Gamma, an accepted-socket and interrupt-deferral trial qualified Reno with the existing polling settings for this workload. [Matched scheduling and TCP results](benchmarks/2026-11-21/gamma-vm-scheduling.md)

The native watchdog treats TCP payload received from the guest as evidence that the published link is live. It still checks that the Mac owns the gateway. Handshake failures advance the guest probe. It first tries to restore the guest route in place. If the dedicated Mac gateway is present, repeated failed peer probes must span six seconds before it replaces the published attachment. Guest payload or a successful probe clears the timer. The replacement keeps the existing private network and checks the peer with fresh ARP before attempting full network recovery.

## Full Docker Engine worker


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
| `MICROPOD_CI_CPUS` | 4 | Fixed VM vCPUs, or `auto` to select the fastest physical core tier at each boot. |
| `MICROPOD_CI_TRUSTED_JOB_CPUS` | 1 | CPU quota for a submitted `ci job trusted`, in whole CPUs from 1 to 64. Requires the updated OCI client and runner tools. Docker containers accept their own `--cpus` value. |
| `MICROPOD_CI_MEMORY_MIB` | 4096 | VM memory in MiB |
| `MICROPOD_CI_DISK_GIB` | 32 | Logical guest ext4 capacity in GiB |
| `MICROPOD_CI_EXT4_MAX_BATCH_US` | Adaptive (15,000 µs) | Maximum ext4 wait for synchronous writers to share a commit. A dedicated worker can select zero for immediate writes. |
| `MICROPOD_CI_WORKSPACE` | Unset | Optional checkout directory shared read/write at its absolute path with VirtioFS. Select it before first boot. |

Set resources before first boot. Later starts reuse the recorded configuration. `micropod ci status` returns the boot UUID, worker and supervisor IDs, Docker daemon ID, guest IP, cgroup driver and memory. Pause runner intake and finish active builds before `micropod ci stop`. The worker checks for running containers and closes the public socket to new connections during shutdown.

`micropod ci cpu-plan` previews the next boot. To change a provisioned worker, select its engine and home, drain it, stop it, then use `micropod ci set-cpus auto` or a fixed count. This edits only the CPU field of the stopped worker's manifest. A registered launch agent that pins a conflicting count must be uninstalled while idle and registered again with the new policy. An agent with no CPU override can reuse the manifest. The CPU count is fixed for the lifetime of a VM. Status reports the boot allocation and its source.

`micropod ci cpu-plan --topology` also reports the host's active logical CPU count, Virtualization.framework CPU bounds, and each available performance tier's name, physical CPU count and CPUs per shared L2. Missing fields mean the host did not report a usable value. `levels` can be empty on a restricted host. The allocation uses the configured policy and the same rules as `cpu-plan`. The reported counts describe topology. Actual VM thread placement and runnable wait require a scheduler trace.

Set `MICROPOD_CI_POSTGRES_PATH=bridge` for the sample CI pipeline to run a PostgreSQL server and its SQL client on a per-run guest network. The default path continues to exercise Testcontainers and Ryuk. The bridge mode runs a different integration check and should be compared on both engines. [Gamma sizing, scheduler and storage qualification](benchmarks/2026-11-21/gamma-worker-sizing.md)

```sh
micropod ci run --cache npm node:26.13.1-alpine npm cache verify
micropod ci run --cache go golang:1.26-alpine go env GOMODCACHE GOCACHE
```

The shortcuts attach one guest npm volume, one Go module volume and one Go build volume per worker. Repeated jobs on the worker reuse those volumes. The shortcut paths suit images that run as root. Images using a custom UID need writable cache directories. Dockerfiles can share BuildKit cache mounts across projects, as in the Go and Node samples. BuildKit cache mounts, Docker named volumes and macOS host caches are distinct stores. Choose the same mechanism for jobs that should reuse package bytes.

Use `--cache-scope` to give a group of trusted jobs its own stores. Use the same scope across checkouts and concurrent jobs that should share dependencies. Each requested store gets one named volume on the worker disk. Docker attaches it directly at container creation and skips copying files from the image into a new scoped volume.

```sh
micropod ci run --cache npm --cache-scope frontend node:26.13.1-alpine npm config get cache
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

The supervisor checks the Mac gateway address for each worker interface every second. A transient relay handshake failure advances the next guest check. Failed repairs back off from one to thirty seconds. The guest keeps its addresses, processes, Docker socket and disk. An operator can request an immediate egress reconnect with `micropod ci repair-network`.

`micropod ci metrics` reads the Docker inventory and reports active containers per cache volume, scope, boot ID and the latest network repair. `micropod ci metrics --usage` also asks Docker for volume bytes and BuildKit's record and use counts. Shared and private BuildKit bytes are reported separately. A mounted volume measures attachment. The offline benchmarks verify reuse by checking package output, compiler invocations and stable payload inodes.

Docker Buildx also records cache hits for individual Dockerfile steps. To inspect an existing build, use its reference from `micropod ci docker buildx history ls`. The importer retains each distinct Dockerfile step’s position, digest, timestamps and whether it ran, hit the cache, failed or is pending. Dockerfile commands, console logs, base resolution and image exports stay outside the step counts. The local Apple qualification checks a cold build, an unchanged repeat and a changed source file against actual BuildKit events. [Docker build progress formats](https://docs.docker.com/reference/cli/docker/buildx/build/#set-type-of-progress-output---progress)

```sh
micropod ci docker buildx history logs --progress rawjson "$BUILD_REF" 2>&1 | \
  python3 scripts/ci_benchmark_store.py buildkit-trace -
sqlite3 "$HOME/.micropod/benchmarks/measurements.sqlite3" \
  'SELECT run, operation, outcome, count(*) FROM build_steps GROUP BY run, operation, outcome'
```

On the native containerd worker, `micropod ci run --scratch-mib 256 ...` gives a job a private, executable 256 MiB tmpfs at `/tmp`. Pages count against the container's memory limit. Restarting the same container creates an empty filesystem. The mount hides files already in the image's `/tmp` until the container stops. The native Docker endpoint also accepts `docker run --tmpfs /tmp:rw,exec,nosuid,nodev,size=256m,mode=1777 ...`. A separate named volume can keep the compiler cache across jobs. [Scratch and cache qualification](benchmarks/2026-11-24/gamma-ci-concurrency/sibling-ci-dispatch-and-scratch-results.md#native-compiler-scratch) · [Docker tmpfs mounts](https://docs.docker.com/engine/storage/tmpfs/)

For CI scripts driven by CPython, `--cache python --cache-scope NAME` keeps compiled imports in one guest volume using `PYTHONPYCACHEPREFIX`. Use a scope dedicated to the trusted source revision and pinned toolchain. Reusing bytecode reduces repeated import work. The measured end-to-end benefit varied across runs. The Go, npm and Python stores can be selected together. [Python bytecode configuration](https://docs.python.org/3/using/cmdline.html#envvar-PYTHONPYCACHEPREFIX)

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
