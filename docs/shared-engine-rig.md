# A shared-engine rig

One hvf machine can run every job of a CI rig: Cuttlefish attempts, the containers of GitHub Actions jobs, and what those jobs build and start themselves. This page is the runbook for a rig that opts into that. Nothing here is on by default; a machine that sets none of it behaves as before.

## What the opt-in is

Two settings in the machine's policy (`machine.json` `cache`, where `defaultTrust` lives). Only the machine's owner changes them: the `micropod` CLI, or `SetCachePolicy` / `PUT /v1/caches/policy` on the owner's private API socket (`~/.micropod/api.sock`). The same call over loopback TCP is refused with `permission_denied`, and nothing is written.

```
micropod machine cache policy --docker-socket any --default-limits none
micropod machine cache policy            # shows both, and what each relaxes
micropod machine status                  # the `caches:` line names both
```

The supervisor logs the same line at every start (`logs/supervisor.log`), and a running machine applies a change at once, without a restart.

### `dockerSocket: any` (default `trusted`)

As shipped, only a trusted container may bind `/var/run/docker.sock`. With `any`, a container of any tier that binds it gets the same socket a trusted one gets: a socket of its own, on which it sees and acts on only itself and what it created there (its family: containers, networks, volumes), binds only paths inside its own binds, and reaches none of the engine's own routes (`/micropod/*` is refused). What this relaxes, plainly:

- Jobs share one kernel. There is no VM between two jobs, only namespaces and cgroups.
- Jobs share one image store. A job can pull, build, tag and remove images, and another job that runs an image by tag gets whatever the tag points at then. Refer to images by digest where that matters.
- Jobs share one BuildKit and its layer cache. A build step whose inputs are identical to another job's reuses that job's layer.

What it does not relax:

- An untrusted container, and everything it creates on its socket, still only reads the shared dependency caches, through the same copy-on-write views. A child that labels itself trusted is untrusted. A poisoned cache would break every project's builds, so no setting here lets untrusted code write one.
- Builds on an untrusted container's socket keep their `RUN --mount=type=cache` directories in a namespace apart from the trusted builds', for the same reason. This covers Dockerfile builds; a client that sends BuildKit its own LLB names its cache mounts itself.
- The machine's own directory stays masked in every bind, and the cache crash fence is unchanged.

A container made on such a socket that binds `docker.sock` in turn (a GitHub Actions runner does this for every `container:` job) is given its creator's socket, shared: the same family, never a family of its own. What it creates there is held to its own tier and cache scope and, like every member of the family, to the family owner's binds and limits. Under `dockerSocket: trusted` it is refused, as before.

### `defaultLimits: none` (default `job`)

As shipped, a container that names no limit gets one CPU, 1 GiB and 512 processes. With `none` it gets no CPU quota, the machine's memory and 65536 processes, which is what a Docker daemon gives and what a GitHub Actions runner, a compose file or Testcontainers assume (none of them names a limit). A limit a create names is always kept, and a container made on a delegated socket still gets at most its family owner's limits. The values are written into the container at create, so `docker inspect` shows them and a later policy change leaves running containers alone.

With no per-container ceiling, what protects the machine is admission: send it work by its capacity report, below.

## Admission: the capacity report

`RigService/GetMachineCapacity` (Connect, gRPC, `GET /v1/rig/capacity`, `micropod machine capacity [--json]`) answers in one request to the guest engine, from the engine's own counters and a once-a-second sample of the kernel's. No subprocess runs and nothing is listed; on a 16-CPU machine the guest route answers in about 0.2 ms (p95 0.3 ms), a new connection each time. It never boots a machine: `unavailable` while the machine does not serve.

It reports:

- capacity: CPUs, memory, `pid_max`, the container ceiling (1024), the per-family container cap (256), the relay connection cap;
- usage: busy CPUs over the last second, load, tasks, memory used and available, swap, open files, conntrack entries;
- containers: running, starting, created, exited; the CPU and memory limits of the running ones, summed; how many have no CPU limit; and the same by family;
- engine: creates and starts in flight, start latency p50 and p95 over the last 256 starts;
- pressure: the guest kernel's PSI (`some` and `full`, avg10/60/300) for CPU, memory and IO (the machine boots with `psi=1`);
- disks: free space on the OS disk and the cache disk;
- host: the Mac's memory pressure level (normal, warning, critical), available memory and load;
- headroom: how many more typical containers the machine can take now.

### The headroom formula

The unit is one typical container: what the running ones use on average now (busy CPUs / running, used memory / running), held to 0.25–2 CPUs and 256 MiB–4 GiB; 0.5 CPU and 512 MiB when nothing runs.

```
by_cpu        = (cpus × 0.90 − busy CPUs) / unit CPU
by_memory     = (memory available − max(5 % of memory, 1 GiB)) / unit memory
by_tasks      = (pid_max × 0.80 − tasks) / 64
by_containers = 1024 − containers running or starting
containers    = max(0, the smallest of the four)        → limited_by names it
```

and `containers` is 0, with `under_pressure` and the reasons, when any of these holds:

| signal | threshold |
| --- | --- |
| memory PSI | `some` avg10 ≥ 10, or `full` avg10 ≥ 2 |
| CPU PSI | `some` avg10 ≥ 80 |
| IO PSI | `full` avg10 ≥ 25 |
| memory available | below the reserve (5 % of memory, at least 1 GiB) |
| OS disk or cache disk | less than max(5 %, 2 GiB) free |
| start latency | p95 ≥ 10 s |
| the Mac | memory pressure warning or critical |

CPU and memory are counted on what is used, not on the limits containers were given. A limit is a ceiling and CI containers idle most of their time, so counting limits would leave most of the machine empty; the pressure terms are what catches a machine whose promised memory is being used after all. A scheduler should therefore ramp: admit up to the headroom, look again a second later, and stop while `under_pressure` is true.

## Families: whose containers are whose

A family is the unit the report counts by and cleanup works on.

- A container the host gives a Docker socket owns a family: itself and everything created on that socket. It is counted under the owner's `io.micropod.family` label, or its name. When the owner is removed, the engine stops and removes the rest: containers, then the networks and volumes they made. A runner that dies mid-job leaves nothing once its container is removed, and an engine start reaps any family whose owner is gone. A Linux GitHub Actions runner that runs in a container, and a Cuttlefish attempt with a Docker socket, are both this kind.
- A job that runs as a process on the Mac has no owner container. Give what it creates the label `io.micropod.family=<name>`, or send the `X-Micropod-Family: <name>` request header and the engine stamps the label on every container, network and volume the request creates. The docker CLI, compose and buildx send the `HttpHeaders` of the client's `config.json` on every request, so a per-job `DOCKER_CONFIG` attributes everything a job's docker commands make:

  ```
  mkdir -p "$RUNNER_TEMP/docker" && printf '{"HttpHeaders":{"X-Micropod-Family":"%s"}}' "gha-$GITHUB_RUN_ID-$GITHUB_JOB" > "$RUNNER_TEMP/docker/config.json"
  export DOCKER_CONFIG="$RUNNER_TEMP/docker"
  ```

  A client that builds its own HTTP requests (the Testcontainers libraries) does not read that file; Testcontainers reaps its own session through its reaper, which the engine supports. At the end of the job, or when the runner is found dead:

  ```
  curl --unix-socket ~/.micropod/hvf/run/docker.sock -X POST 'http://d/micropod/families/prune?family=<name>'
  ```

  It stops and removes the host-made containers carrying exactly that label (32 at a time), then the label's networks and volumes that nothing uses, and answers with what it removed, any errors, and whether anything remains. `&dry-run=1` only lists. It never takes an unlabelled object, another family's, or a container made on a delegated socket.

The label attributes and cleans up; it grants nothing. The header is read only on the machine's own socket.

Docker's own prunes (`docker system prune`, `docker container|image|volume|builder prune`) are scoped the same way. On a delegated socket they take only what that family created; on the machine's socket with `X-Micropod-Family`, only that family's host-made containers, networks and volumes. Images and the build cache belong to no family, so those two requests remove nothing from them and report 0. A plain request on the machine's socket, with no header, prunes only host-made objects, never a delegated socket's, but its image and build-cache prunes are machine-wide, as on any Docker daemon: `docker system prune -af` from a host job that sends no header removes every image no container uses, and every job then pulls again. A host-side Docker proxy for CI jobs should send the header on every request.

## A GitHub Actions runner on the machine

A runner that runs as a container on the machine, with `-v /var/run/docker.sock:/var/run/docker.sock`, drives `container:` jobs and `services:` through its family socket with the stock docker CLI. `scripts/gates/scale/runner-job.sh` runs the runner's command sequence for one job, command for command, and a step that uses the socket (run, build with the default builder and `cache-to`/`cache-from` `type=local` and inline, compose with health checks, `docker wait`, the Testcontainers reaper). Two things the runner's container must be given, as with any Docker daemon a runner container shares:

- its work directory (`_work`) and its `externals` directory as binds from the machine's workspace share, at the same path inside the runner container. The runner hands the job container binds of those paths, and a bind source is a path on the machine. A child may bind only paths inside its family owner's binds, so a work directory that lives in the runner container's own filesystem is refused (HTTP 403).
- `dockerSocket: any` when the runner container is untrusted, and for any `container:` job, because the runner binds the socket into the job container.

A runner that runs as a macOS process uses the machine's own socket (`DOCKER_HOST`); the runner itself supports `container:` jobs only on Linux, so on such a runner only the docker commands of its steps reach the machine. Attribute them with a per-job `DOCKER_CONFIG` as above.

`cache-to`/`cache-from` `type=gha` and `type=registry` are BuildKit's own and reach their service from the machine, not from the job's network. They are not exercised by the gate.

### linux/amd64 jobs

A job pinned to `linux/amd64`, which is how the control plane sends GitHub-compatibility Linux jobs, runs through x86-64 emulation when the payload's tool bundle ships `runner/emulators/qemu-x86_64` ([amd64-emulation.md](amd64-emulation.md)). `docker pull --platform linux/amd64` and `docker create --platform linux/amd64` then work for the job image, and its steps' own `docker` commands with no platform still get linux/arm64 images. The engine's `/version` lists `platform-linux-amd64` among `MicropodCapabilities` while emulation is on. A scheduler can gate a job kind that asks for linux/amd64 (Cuttlefish's `docker-in-vm`) on that capability. Expect such a job's CPU-bound steps to take 5 to 15 times as long as on the job's linux/arm64 form. `micropod machine install --amd64 off` turns emulation off at the next boot, and the capability goes with it.

## Limits that scale with the machine

The guest raises these at boot, since each one stops containers well before CPU or memory does:

| limit | before | now |
| --- | --- | --- |
| open files, the engine | 4096 (starts failed with "too many open files" at about 155 live containers) | 1048576 |
| open files, containerd and every container | 1024 soft, 4096 hard | 1048576, as a Docker daemon gives |
| `kernel.pid_max` | 32768 tasks in all | 4194304 |
| inotify instances per user | 512 (one per shim, plus every watcher in every container) | 8192 |
| inotify watches | kernel default | at least 1048576 |
| `vm.max_map_count` | 65530 (Elasticsearch and OpenSearch need 262144) | 262144 |
| neighbour table (`gc_thresh3`) | 1024 | 8192 |
| containers per delegated socket | 64 | 256 |
| gateway relay connections | 128 a port, 128 a family, 512 in all | 512 a port, 512 a family, 4096 in all |

## Measured

`scripts/gates/scale.sh --engine-from-tree` on a throwaway machine of 16 vCPUs and 48 GiB (OS disk flush `fsync`, as the rig), on an M-series Mac with 128 GB:

| workload | result |
| --- | --- |
| 32 `docker run --rm` at once | 0.9 s wall, p95 0.86 s |
| 64 at once | 1.4 s wall, p95 1.4 s |
| 128 / 256 at once | 2.7 s / 5.9 s wall, none failed |
| 200 alive at once | all 200 run; starts p50 0.28 s, p95 0.35 s over 16 streams |
| 500 / 1000 alive at once | all run; one more `docker run` beside 1000 takes 0.7 s; about 7 MiB of the machine's memory per idle container |
| 16 `docker build` at once | 1.9 s wall |
| compose, 20 services with health checks | up `--wait` 3.8 s |
| 500 short runs over 16 streams | 53 a second, p95 0.40 s |

Start throughput tops out near 50 a second with the guest about 20 % busy: the remaining cost is serial work inside containerd and the kernel for each pod (its metadata commits to disk, network namespace, cgroup and mounts), not the engine (0.5 s of engine CPU for 500 runs, no time waiting on its start slots). Cache views and the bridge network together are about 10 % of it.

### Sizing a rig

On a 128 GB Mac that also runs macOS jobs and GitHub runner processes: 16 vCPUs and 48 GiB for the machine. Let the scheduler's concurrency follow `headroom.containers` rather than a fixed slot count. An idle machine of that size reports a headroom of 28 (by CPU, at the 0.5-CPU unit), and the figure moves with what the running containers really use. If the scheduler needs a fixed ceiling to advertise, 32 is a sound one for this size; the engine itself has run 1000 idle containers, so the ceiling is the scheduler's choice.
