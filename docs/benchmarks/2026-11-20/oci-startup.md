# Fresh Go container startup on Gamma

On Gamma, one warm Micropod launcher running runc directly finished 16 source-only Go jobs in **0.790 s** and 32 in **1.887 s**. Ordinary Micropod Docker took 1.530 s and 3.049 s. The new path won all ten paired comparisons and reduced the batch medians by **48% and 38%**. The remaining gaps to raw warm Ubuntu were **0.260 s and 0.681 s**.

## Question and measurement

> Find the largest avoidable cost between submitting 16 or 32 source-only Go jobs and running their first process on Gamma’s warm Micropod worker. Change that part of the path. If bypassing Docker helps, show which work disappears and which work moves elsewhere. Compare end-to-end time with stock Micropod, OrbStack and raw warm Ubuntu. Charge setup explicitly, require a real link in every job, and preserve fresh writable filesystems, isolation and limits.

All three VMs ran on the same 18-core Apple M5 Max with 128 GiB. Each had four vCPUs and a 4 GiB allocation. Micropod ran Linux 6.18.35, Docker 29.9.3 and containerd 2.4.2. OrbStack 2.2.5 ran Docker 29.8.2. The native reference ran stock Ubuntu 24.04.4, kernel 6.8.0-134-generic, directly under Apple virtualization. The Micropod worker was started once before sampling with its existing disk. It kept one kernel boot ID and Docker daemon ID through the timings and qualifications.

| Median batch time | 16 jobs | 32 jobs |
| --- | ---: | ---: |
| Micropod, ordinary Docker | 1.530 s | 3.049 s |
| Micropod, direct runc 1.5.2 | **0.790 s** | **1.887 s** |
| Micropod, direct crun 1.31 | 0.865 s | 2.077 s |
| OrbStack, ordinary Docker | 35.152 s | 79.930 s |
| Raw warm Ubuntu processes | **0.530 s** | **1.206 s** |

Each container entry represents five interleaved rounds. All 960 jobs had a distinct container ID, linked once, reused all compiled packages and ran the resulting program. Every engine received the same source image and Go 1.26.11 ARM64 toolchain. The checkout contained source only. Each engine's priming job and both Ubuntu controls produced the same executable SHA-256, `5156ed5c341595d9139485e83af8fc55b090977e02db67d9c8ea8cd1271bbf66`. On each engine the module archive inode, cache file counts and logical sizes were stable across the jobs. The three Micropod paths used the same Go volumes. [Paired results and cache audits](oci-startup/paired.json.gz) · [Perfetto timeline](oci-startup/paired.trace.json.gz)

The container clock starts on the Mac at submission. It includes creating the private workspace, launching the shell, linking and running the program, and returning its streams and exit status. Direct OCI also waits for private mount cleanup. Docker lifecycle events confirm each job was destroyed. The native reference times the parallel Go builds in private, prepared directories. It verifies and runs the products after the clock. Native workspace creation added a median 2.1 ms per 16-job batch and 4.3 ms at 32. Five native rounds before the engine comparison measured 0.488/1.136 s and five after measured 0.608/1.438 s. The table pools these ten rounds. Python drives the timing and the separate process sampler. Each timed container starts a shell and Go. [Ubuntu before](oci-startup/ubuntu-before.json) · [Ubuntu after](oci-startup/ubuntu-after.json)

Preparing the immutable source snapshot cost 0.374 s. Preparing the reusable Docker policy, image references and scoped cache handle cost another 2.225 s. Opening a runc session cost 0.152 s and opening a crun session cost 0.224 s. These costs are paid before the first submitted batch and can be reused across batches. At the observed median time savings, the extra runc preparation and session open pay back in four 16-job batches or three 32-job batches.

Gamma is shared. At 32 clients the five ordinary Micropod batches ranged from 2.075–6.424 s, direct runc from 1.033–3.346 s and OrbStack from 57.897–82.803 s. In the OrbStack events, the last-finishing client spent 31.8–47.6 s between Docker create and start in those five rounds. OrbStack previously measured 3.037/4.465 s on the same Mac. The difference between sessions limits what can be inferred about OrbStack performance on other hosts or at other times. [Previous comparison](fresh-go.md) · [Current engine events](oci-startup/paired.json.gz)

## Where Docker spent the time

Three separate rounds joined Docker events, containerd snapshot and task events, and the first in-job timestamp by full container ID. The process sampler identified runc commands launched directly by the containerd shim, read their birth times from Linux and watched process exit through pidfds. The columns show the median interval across all clients and the median for the **last client to finish each batch**. The latter is the relevant client for batch latency.

| Stock Micropod interval | 16, all | 16, last | 32, all | 32, last |
| --- | ---: | ---: | ---: | ---: |
| Prepare → commit the Docker init snapshot | 37 ms | 40 ms | 87 ms | 95 ms |
| Commit init → prepare writable snapshot | 59 ms | 51 ms | 166 ms | 168 ms |
| Writable snapshot → Docker create event | 10 ms | 14 ms | 12 ms | 10 ms |
| Docker create → containerd container metadata | 58 ms | 64 ms | 129 ms | 116 ms |
| Container metadata → task created | **185 ms** | **400 ms** | **327 ms** | **792 ms** |
| Task created → task started | 78 ms | 117 ms | 101 ms | 38 ms |
| First snapshot → first timestamp in the job | 568 ms | 662 ms | 1,067 ms | 1,421 ms |

The sampler saw all 48 runc creates at 16 clients and all 96 at 32. Their median process lifetimes were 116 ms and 252 ms, inside the broader task creation interval. It caught 20/48 and 36/96 starts with sampled medians of 55 ms and 100 ms. The guest clock tick was 10 ms. Sampling gaps had a 4.9 ms median and a 246 ms maximum. Short operations can escape observation and wakeup delays can extend measured lifetimes. Published events can arrive after the associated syscall or first job instruction. The table reports elapsed intervals with overlapping work, so adding column medians would give a misleading total. [Per-job events and sampler coverage](oci-startup/docker-trace.json.gz) · [Perfetto timeline with runc lifetimes](oci-startup/docker.trace.json.gz) · [containerd runtime architecture](https://containerd.io/docs/main/runtime-v2/)

## What changed in the worker

The owner opens one attached management container for the lifetime of the CI session. It holds a read-only image mount and the existing scoped Go volumes. On each request it creates a private ext4-backed overlay upper, writes the job's OCI configuration, invokes `runc run`, returns the job's streams and status, and reclaims its files. This removes per-job Docker requests, Docker init snapshots, containerd task records and separate containerd shims from this path. Each job still gets a new root filesystem, PID 1, namespaces, cgroup, capabilities and seccomp policy. The privileged launcher receives the mounts it manages and communicates over the owner's attached streams. Workloads inherit the stock unprivileged job policy and receive neither management socket. [Commands and session protocol](../../ci-worker.md#direct-oci-batches-in-the-shared-worker)

Per-job overlay and spec preparation in the paired runc series took a median 5 ms at 16 and 24 ms at 32. Cleanup took 12 ms and 10 ms. To test whether one dispatcher was the remaining bottleneck, another five interleaved rounds compared one warm runc session with the same jobs divided across two. At 32 the batch medians were 1.070 s and 1.047 s. Two launchers won two of five pairs at each concurrency. The median time until the last job's first stdout reached its launcher client went from 0.260 to 0.322 s at 16 and from 0.636 to 0.692 s at 32. The shell emits this identity before invoking Go. We kept one launcher. [Launcher comparison and first output for all 480 jobs](oci-startup/session-fanout.json.gz)

## Where the remaining time went

Five direct-runc trace rounds measured from the guest's invocation of runc to the first timestamp inside each job. The timestamp includes shell startup and one call to `date`. A separate read of each fresh job's Linux cgroup counters followed its product check. Both measurements use the guest clock. These diagnostic jobs also hash their executables, so the paired series above supplies the end-to-end comparison.

| Direct-runc measurement | 16 jobs | 32 jobs |
| --- | ---: | ---: |
| Runtime invoked → first in-job timestamp, median job | 60 ms | 235 ms |
| Same interval for the last job to finish guest cleanup | 149 ms | 312 ms |
| First job dispatched in the guest → last job's first timestamp | 194 ms | 606 ms |
| CPU time consumed per job, median | 117 ms | 133 ms |
| Per-job CPU pressure stall, median | 158 ms | 319 ms |
| Per-job I/O pressure stall, median, rounded to ms | 0 ms | 0 ms |
| Jobs reporting CPU-quota throttling | 0/80 | 0/160 |

At 32 clients a median job spent more time runnable and waiting for CPU than it spent executing on CPU. The counters cover the job's whole cgroup lifetime through the check. They identify scheduling contention on the four-vCPU guest, while leaving open how much of the pre-entry span belongs to individual runc operations. Workspace setup, disk wait and quota throttling have much smaller measured contributions in this workload. [Direct launch and cgroup counters](oci-startup/direct-trace.json.gz) · [Direct OCI timeline](oci-startup/direct.trace.json.gz)

## Replacing Docker components with a measured contract

The per-job launcher is already independent of the Docker API. Docker still supplies image resolution, scoped volumes, the reference job policy and the management container. Ordinary Docker, Compose, BuildKit, networked services and interactive commands use the normal worker endpoint. The direct interface currently supports trusted, offline batches with a fixed one-CPU, 1 GiB budget per job.

We used `rust-anything` 2.1.0 to record nine stock Docker behaviors and replay both actual OCI implementations. Each passed **9/9 with zero skips**. A deliberately incorrect candidate passed **0/9**. The qualification independently compared raw stdout, stderr and exit codes in one-shot and warm sessions. Cases cover argv, separate streams, exit 41, writable workspaces, PID 1, cgroup limits, seccomp/capabilities, loopback, the module payload and the built program. Four simultaneous jobs per implementation proved private PID, mount, net, UTS, IPC and cgroup namespaces while sharing one module archive inode. Closing a warm connection with two active 90-second jobs removed the launcher in 0.067 s with runc and 0.116 s with crun. [Recorded Docker cases](oci-startup/docker-cases.tar.gz) · [runc replay](oci-startup/replay-runc.json.gz) · [crun replay](oci-startup/replay-crun.json.gz) · [Upstream recording and replay](https://github.com/erkamyaman/rust-anything/blob/a3f40af356abc13be3baf33bfe1ddf860440d1c1/docs/whole-apps.md)

To remove Docker from session startup, the smallest next replacement is a guest-native launcher reached through the VM's control socket. It would own leases on immutable image lowers and scoped ext4 directories and would preserve the same OCI policy, cancellation and stream protocol. That gives a Rust implementation a small interface to replace and a stock Docker oracle to replay. A separate experiment could swap the OCI implementation for Rust's youki while keeping the launcher and workload identical. The current measurements establish the benefit of removing repeated daemon work. A language change needs its own matched timings and isolation checks. [Existing guest control transport](../../../Sources/MicropodRuntime/GuestAgent.swift) · [youki OCI runtime](https://github.com/youki-dev/youki)

## Reproducing the comparison

Build the pinned offline fixture once for Linux ARM64 and load the same image into the worker and OrbStack. On Gamma the fixture tag was `mp-ci-a4072736348443b6a107f7b836bb681f:packages`. The measured source image ID on both engines was `sha256:1bcd9ab8445f10decdfd1a4afde8e1be7905688e3004e99307e1c76346b6d3f4`. The harness selects each engine by its socket. Install the worker's pinned crun for the second direct arm. Run the two Ubuntu controls using the same Go tree copied from the measured image. The local harness writes complete gzip JSON receipts to the specified paths and appends the runs to `~/.micropod/benchmarks/measurements.sqlite3`. The `startup_batches`, `startup_jobs`, `direct_oci_profile` and `native_go_batches` views expose the recorded times and link counts. Timelines open in Perfetto. [Pinned fixture Dockerfile](../../../scripts/bench_cache_image/Dockerfile) · [Ubuntu provisioning](fresh-go.md#cache-identity-and-reproduction) · [Worker setup](../../ci-worker.md)

```sh
python3 scripts/bench_ci_startup.py --mode trace  --clients 16 32 --rounds 3 --image "$IMAGE" --out "$OUT/docker-trace.json.gz"
python3 scripts/bench_ci_startup.py --mode paired --clients 16 32 --rounds 5 --image "$IMAGE" --out "$OUT/paired.json.gz"
python3 scripts/bench_ci_startup.py --mode direct-trace --clients 16 32 --rounds 5 --image "$IMAGE" --out "$OUT/direct-trace.json.gz"
python3 scripts/bench_ci_startup.py --mode fanout --clients 16 32 --rounds 5 --image "$IMAGE" --out "$OUT/session-fanout.json.gz"
for runtime in runc crun; do
  python3 scripts/qualify_oci_replay.py --runtime "$runtime" --image "$IMAGE" --rust-anything "$RUST_ANYTHING" --out "$OUT/replay-$runtime.json.gz"
done
# On Ubuntu, once before and once after the paired run.
PATH="/usr/local/go/bin:$PATH" python3 bench_fresh_go_ubuntu.py --clients 16 32 --rounds 5 --modes source
```

For a future replacement, extract `docker-cases.tar.gz` into a directory and run `rust-anything app replay "$directory" --build "$candidate"`. The candidate receives a named case as its argument. The qualification script defines those adapters and the independent Linux checks. The ARM64 macOS release archive used here matched its published SHA-256, `ee0ae5766bbd51a8619c5ec2e63f7786cd86cbc12e475ed296aa303a55e241ec`. [Qualification script](../../../scripts/qualify_oci_replay.py) · [Upstream release](https://github.com/erkamyaman/rust-anything/releases/tag/v2.1.0)
