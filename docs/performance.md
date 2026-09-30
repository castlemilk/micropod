# Performance

How Micropod is measured against Docker Desktop, current numbers, and how to
reproduce or extend them.

## Methodology

Same machine, both runtimes warm, `alpine:3.20` pre-pulled on both engines.
API numbers are p50 over n=30; lifecycle over n=10; concurrency is a single
10-way wall-clock sample (noisy — treat ±30% as noise).

```sh
# Shim (the dev build must be running; the app spawns it from .build/debug)
python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim \
    --json bench/shim.json

# Docker Desktop
python3 scripts/bench_shim_vs_docker.py unix:///var/run/docker.sock docker \
    --json bench/docker.json

# Regression check vs a previous run (exit 1 if any p50 regresses >20%)
python3 scripts/bench_shim_vs_docker.py unix:///~/.micropod/docker.sock shim \
    --baseline bench/shim.json

# Runtime footprint + cold start (cold stops both runtimes — intrusive)
bash scripts/bench_runtime.sh idle    # RSS sums + process list
bash scripts/bench_runtime.sh cold    # system-start -> first list, vs Docker.app -> docker info
```

## Live metrics

The shim serves Prometheus text at `GET /metrics` over `docker.sock`:

```sh
curl -s --unix-socket ~/.micropod/docker.sock http://localhost/metrics
```

Three families:

- `micropod_api_*` — per-route request count/errors/latency (route labels are
  normalized, `containers/{id}/json` not per-name).
- `micropod_cli_*` — per-`container`-verb spawn count/latency. This is the
  budget: every spawn costs ~15–80 ms. Status 504 = timeout kill, 499 = cancel.
- `micropod_shim_cache_{hits,misses}` — `ReadThroughCache` effectiveness.

`ContainerCLIClient.run` also emits `os_signpost` intervals
(`com.micropod.cli`, category `pointsOfInterest`) so
`xctrace record --template "os_signpost"` splits CLI spawn+XPC+run time from
caller overhead. The MicropodAPI serves its own `/metrics` on :45454.

## Execution options (2026-09-30)

`task bench-runtimes` (`scripts/bench_runtimes.py`) runs the same CI-shaped
work through each way micropod can execute it:

| option | what runs |
|---|---|
| `sandbox` | `micropod sandbox run` — in-process VZ micro-VM booted from a clonefile of a cached rootfs |
| `api:sandbox` | Connect `RunContainer(runtime: sandbox)` → `WaitContainer` → `DeleteContainer` |
| `apple` | `container run --rm` — Apple's runtime, one VM per container |
| `api:apple` | the API path with `runtime: apple` |
| `machine` | `container machine run` — a command in a warm, persistent VM |
| `docker` | `docker run --rm` on Docker Desktop (8-vCPU VM) |

Rows: boot → `true` → teardown (n=10); `go vet && go test` on
`ci/samples/go-app` with a cold `GOCACHE` and a warm module cache (n=3);
four such jobs at once (3 rounds). Every option gets a 2-CPU / 2 GiB quota
(`-c 2` gives the sandbox VM a third vCPU for the guest agent, as `container
run` does; the workload's cgroup is held to 2 CPUs, and Go sizes
`GOMAXPROCS` from it). Rounds are interleaved, so load drift lands on every
option alike. Host: Mac17,6 (18 cores, 128 GiB), macOS 26.5.1, container
1.3.1, Docker Desktop 29.8, with a CI rig holding the load average near 20.
Differences under ~3% are noise at that load.

| p50 | boot | go job | 4 jobs at once |
|---|---|---|---|
| `machine` | **0.14 s** | **9.40 s** | — (one shared VM) |
| `docker` | 0.23 s | 12.18 s | 19.07 s |
| `sandbox` | 0.36 s | 10.29 s | 15.12 s |
| `sandbox` v0.9.1 | 0.39 s | 10.02 s | **14.76 s** |
| `api:sandbox` | 0.48 s | 10.12 s | 15.64 s |
| `apple` | 0.77 s | 10.62 s | 19.18 s |
| `api:apple` | 0.80 s | 10.66 s | 19.33 s |

- `machine` never boots — the VM is already up — so it wins both
  single-run rows. Every run shares that VM's state, though: it is the
  keep-alive CI-runner pattern, not a sandbox.
- Of the options that start clean, `sandbox` boots in about half the time
  of `apple` and holds up best under concurrency: four jobs finish ~25%
  sooner than on `apple` or `docker`.
- `docker` boots fast (its VM is always on) but is the slowest on the Go
  job.
- The API adds ~0.1 s per run over the CLI: the request round trips, plus
  NAT — API containers get a network unless labelled
  `micropod.network=none`. In a controlled A/B (n=3, one 10 s job) the
  CLI took 10.24 s offline and 10.34 s with NAT; the API took 10.65 s and
  10.88 s. An earlier run against the previous API build measured 0.57 s
  for the `api:sandbox` boot.

### Sandbox boot, phase by phase

Measured with `MICROPOD_SANDBOX_TRACE=1`, temporary probes in
Containerization, and the guest's own logs (`MICROPOD_SANDBOX_BOOTLOG=path`,
`MICROPOD_SANDBOX_KERNEL_ARGS="initcall_debug ignore_loglevel"`):

| phase | ms | notes |
|---|---|---|
| resolve + clone | ~5 | image config; APFS clonefile of the base disk |
| VM object | ~10 | VZ configuration + `VZVirtualMachine` |
| VZ start | ~70 | Virtualization.framework brings the VM up |
| wait for the guest agent | ~200 | kernel ~90 ms from its first timestamp; vminitd 4 ms; Containerization's vsock poll |
| agent setup + rootfs mount | ~15 | |
| container start | ~40 | spawn → pid is 13 ms inside the guest |
| stop | ~15 | |

### Changes this round

- **Expedited RCU in the guest** (`rcupdate.rcu_expedited=1`). vminitd's
  cgroup setup and each container spawn used to wait out jiffy-scale RCU
  grace periods. Guest medians (n=6): cgroup manager 16 → 0 ms,
  init → agent serving 20 → 4 ms, spawn → pid 27.5 → 13 ms. That is ~30 ms
  off every boot, CLI and API. The Go job's IPI counts are unchanged (about
  14k function-call IPIs either way), so the workload pays nothing for it.
- **`WaitContainer` on a sandbox wakes on the engine's exit signal** instead
  of a 150 ms state poll.
- **vmnet networks are released.** Containerization's `VmnetNetwork` never
  frees its `vmnet_network_ref` (it imports as an opaque pointer, so ARC
  can't), and each networked sandbox kept its /24 reservation until the
  process exited. A long-lived API daemon then failed every networked
  sandbox after about 20 (`VMNET_FAILURE`). `SandboxNetwork` owns and
  releases them; `task e2e-runtimes` now runs 25 in one daemon.

### Where the remaining time goes

- **virtio-pci probes: 55 of the kernel's ~90 ms.** Six devices are probed
  one after another, and each waits out a `msleep(1)` for its reset (two
  jiffies at HZ=250, ~8 ms). `driver_async_probe=virtio-pci` brings root
  mount from 89 ms to 37 ms, but it reorders `vda`/`vdb`, and
  Containerization boots `root=/dev/vda`. Taking this win needs a HZ=1000
  kernel or stable root naming.
- **Agent polling.** Containerization sleeps 20 ms between vsock connect
  attempts, and during early boot a refused attempt itself takes ~20 ms.
  Worth an upstream change.
- **An unused virtio-fs device.** VZ always attaches one, even with no
  shares, which costs another ~8 ms probe. The jitterentropy self-test
  takes 7.8 ms.
- **A vmnet crash in Virtualization's VM process** (not micropod code). The
  process sometimes dies within ~0.5 s of launch with an MTE tag-check
  failure in `__vmnet_interface_start_with_network_block_invoke_3`, a
  use-after-free inside vmnet. It happened 7 times on the benchmark host on
  2026-09-30, to networked VMs only, and before this round's changes too.
  It needs an Apple Feedback report; until it's fixed, the affected run
  fails with "virtual machine stopped unexpectedly".
- **Networked sandboxes reach host services on all interfaces.** Any
  networked mode — NAT, host-only for ports or `--expose-host`, the
  `--allow-host` proxy mode — reaches services on this Mac that listen on
  `*:port`, and NAT also reaches the Mac's LAN address. That's the same as
  Docker and shuru (shuru also reached micropod's Docker shim, which ours
  blocks). vmnet has no switch for it and a host firewall needs root.

### Against shuru (2026-09-30)

shuru 0.7.0 (Homebrew), same interleaved harness, and the same Go
toolchain (1.27.1) from a `go127` checkpoint. shuru gives `--cpus 2` two
vCPUs; `sandbox -c 2` gets three with the workload held to two. The CI rig
kept the load average at 44–74 on 18 cores, so the job and fan-out rows
are dominated by contention. The earlier run at ~20 had the sandbox
fastest in fan-out.

| p50 | boot | go job | 4 jobs at once |
|---|---|---|---|
| `shuru` | 0.34 s | 14.20 s | 30.84 s |
| `sandbox` | 0.35 s | 13.57 s | 30.89 s |
| `apple` | 0.76 s | 13.69 s | 22.06 s |
| `docker` | 0.23 s | 15.49 s | 31.18 s |
| `machine` | 0.17 s | 12.42 s | — |

Boot is a tie, and the Go job is within noise.

## Results (2026-09-22, M-series, both engines warm)

### API latency p50, ms — lower is better

| op | micropod before | micropod now | docker | verdict |
|---|---|---|---|---|
| ping | 0.3 | 0.3 | 1.9 | **6× faster** |
| version | 0.4 | 0.4 | 5.4 | **13× faster** |
| containers/json?all=1 | 0.3 | 0.3 | 35.2 | **117× faster** (cached body) |
| images/json | 0.4 | 0.3 | 153.7 | **512× faster** (cached body) |
| inspect container | 15.9 | **0.5** | 1.8 | **3.6× faster** (was 8.8× slower) |
| system df | 287.3 | **3.0** | 9003.1 | **3000× faster** |
| info | 280.2 | **0.4** | 4.6 | **11× faster** (was 61× slower) |

### Lifecycle p50, ms (create→start→exec→logs→stop→rm, alpine)

| phase | micropod | docker | note |
|---|---|---|---|
| create | 39.2 | 45.2 | parity |
| start | 529.0 | 69.6 | **gap**: Apple runtime boots a per-container VM |
| exec create | 0.9 | 2.5 | faster |
| exec start | 73.1 | 19.6 | gap: CLI spawn + VM exec |
| logs | 28.3 | 4.6 | gap: CLI spawn |
| stop | 72.2 | 2083 | faster (Docker waits the full 2 s grace; shim's stop is atomic) |
| rm | 69.5 | 26.8 | gap: CLI spawn |
| FULL roundtrip | 838 | 2252 | **2.7× faster** (dominated by Docker's stop wait) |
| 10× concurrent wall | 6.5–9.0 s | 2.62 s | **gap**: per-VM start serializes under load |

### Idle footprint

| | RSS |
|---|---|
| micropod (shim + API + sharedfs + Apple daemons + 1 running container VM) | **169 MB** |
| Docker Desktop (backend + VM + UI) | **1244 MB** |

**Docker uses 7.4× the memory at idle.** The micropod figure is conservative —
it includes the shared Apple `containermanagerd`/apiserver processes and a
running alpine VM, not just Micropod-owned processes (~30 MB for the three
helpers alone).

## What the instrumentation found (and fixed)

The first `/metrics` dump after a bench run showed the cache serving HTTP
reads but **internal service calls bypassing it**: `image list --verbose`
spawned 111×, `list --all` 118×, one `container inspect` per inspect request.
`info`, `df`, inspect resolution, and `resolveID` all spawned fresh CLIs.

Fixes:

- `containerInspect` consults `cachedInspect` (populated by every list) before
  spawning; `resolveID` resolves against the cached list (read paths only —
  mutations still resolve fresh).
- `info` and `system/df` read through `cachedContainersList`/`cachedImagesList`/
  `cachedVolumesList`; `UsageService.report` accepts prefetched snapshots.
- Volumes joined the read-through cache with invalidation on create/delete/
  prune.

After the bench: **237 hits / 38 misses (86%)**, `image list` spawns 111→6,
`list --all` 118→8.

## Where the remaining gaps are

- **`start` (529 ms vs 70 ms)** — real per-container VM boot; not shim
  overhead. Options: keep-alive micro-VM pool, or measuring whether parts of
  `container run` setup can overlap.
- **`exec start`/`logs`/`rm` (~30–75 ms)** — each is ~1 CLI spawn. Structural
  floor unless a persistent apiserver session replaces per-call `Process`.
- **Concurrent lifecycle** — 10 parallel VM starts contend. Wall time varies
  6.5–9 s run to run.

## Guardrails

- `--baseline` fails the bench on >20% p50 regressions.
- Mutation paths always resolve against a *fresh* list — the cache only
  serves reads. Every shim mutation invalidates synchronously; out-of-band
  changes are caught by the EventsHub poll + 1 s TTL bound.
- `MICROPOD_SHIM_CACHE_DISABLE=1` and `MICROPOD_SHIM_CACHE_TTL_MS` control the
  cache; run the bench with it disabled to measure the cacheless floor.
