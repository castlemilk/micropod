# End-to-end qualification

The native PR check starts the shipped Micropod CLI, SharedFS daemon and Docker shim on fresh sockets with private state. It checks mount contents, live creation and deletion in both directions, read-only write-back protection, simultaneous references, explicit sync, restart and garbage collection. The shim check verifies Docker API negotiation and records the HTTP responses for image import and post-create network attachment. HTTP 501 means the operation is unimplemented.

Storage and shim PRs run the affected Swift suites and the 32/512-file CLI mount bursts. Other product changes and pushes to master run the full Swift suite. A clone/copy/rsync and corrupt-cache smoke check runs on the existing lint Mac before the package build finishes. The Linux reference job runs when its fixture changes. Its scratch images need no registry pulls. Larger storage runs and installed-product comparisons are available through **Engine qualification → Run workflow**.

## Repeat a loop

From the repository root on an Apple Silicon Mac with the debug products already built:

```sh
python3 scripts/qualification/daemon.py --scale-rounds 3 --json /tmp/sharedfs.json
python3 scripts/qualification/shim.py --json /tmp/shim.json
python3 scripts/qualification/storage.py --json /tmp/storage.json
python3 scripts/qualification/storage.py --profile extended --rounds 3 --json /tmp/storage-extended.json
```

The host matrix uses a new destination and store for every attempt. All contenders receive the same deterministic input and rotated block order. The checker re-reads every included file, rejects extra entries and checks executable mode, timestamp, xattr and symlink. The largest fixture includes 50,000 small files, 50,000 deliberately excluded files and a 16 MiB payload. The byte-scaling fixture has a 1 GiB payload with a controlled mixture of compressible and high-entropy chunks, repeating every 8 MiB.

For distinct views, `operation_ms` ends when all contender processes return. `validated_ms` also includes independent content and metadata verification. The daemon's `cli-share-batch` measures simultaneous clients requesting the **same** shared directory, followed by content validation and final release. The chunk case ingests, reopens the store and restores to disk. It also verifies that a deliberately damaged block preserves a previous destination. Stored representation bytes, logical bytes and peak process RSS are separate measures. None is physical APFS allocation.

The versioned JSON includes raw first attempts and excluded warm-ups. A failed assertion or deadline makes the run fail. Compare paired blocks on the same host and inspect failures before quoting medians. Three or five samples do not characterize tail latency. Use `--rounds 30 --shapes mixed --serial-only` for a longer serial storage series.

## Engine coverage

```sh
python3 scripts/qualification/engine.py --name micropod --host "unix://$HOME/.micropod/docker.sock" --peer-context orbstack --peer-context desktop-linux --rounds 5 --clients 1 4 8 --json /tmp/micropod.json
python3 scripts/qualification/engine.py --context orbstack --rounds 5 --clients 1 4 8 --json /tmp/orbstack.json
python3 scripts/qualification/engine.py --context desktop-linux --rounds 5 --clients 1 4 8 --json /tmp/desktop.json
```

The product workflow expects a dedicated runner with the `micropod-qualification` label, the three local engines, Docker CLI, Buildx, Compose, Python and Go. Engines must already be running with their normal host-directory integration. The install and version of each engine are independent of the source checkout. A missing endpoint fails its lane. Compare product timings only when the receipts match native architecture, executable/config/layer digests, CPU/memory budgets, engine settings and host. The workflow runs all three suites on one Mac. Peer contexts share the primary fixture and alternate their position in each timed burst.

| Surface | Workflow validated | Remaining coverage for a general replacement claim |
|---|---|---|
| Buildx | Multi-stage offline build, solver cache on a repeat, source edit, chmod-only edit, ignored edit, load-to-runnable and local exporter | Bake, remote/named contexts, sessions, secrets/SSH, external caches, multi-platform push, attestations, job cancellation |
| Docker and Compose | Image load/inspect, UID/GID, cwd, environment, hostname, read-only bind, persistent volume, network DNS, separate exec streams, SIGTERM, wait/inspect/logs, Compose up/exit/down | Full versioned Engine API, all Compose features, cgroup enforcement and managed VM lifecycle |
| OCI | Upstream Linux runc create/state/start/exec/kill/stopped/delete on the reference runner | Upstream conformance suite, Micropod bundle execution, containerd Runtime v2 task/events, namespace and cgroup matrices |
| Filesystem and cache | Host SharedFS and chunk semantics, same-volume and non-APFS coverage in the native suites | Guest VirtioFS notifications, durability and recovery, cross-process leases, physical I/O and power |
| Other OrbStack product features | Separate qualification lanes | Linux machine management, Kubernetes, published-port networking, DNS/TLS, x86 translation, idle density and energy |

Docker and Podman burst samples use the same static Linux executable, imported from the same docker-archive on one Ubuntu runner, with one CPU and 64 MiB requested per container. A container must return exit 23 with its exact stdout and stderr before its completion counts. One observation represents a whole burst. Docker and Podman alternate order between blocks. Scale controls are concurrency, not sample count. The native runc lifecycle is a separate workload.

The full parity gates remain in [benchmark qualification #182](https://github.com/castlemilk/micropod/issues/182), [Buildx #149](https://github.com/castlemilk/micropod/issues/149) and [OCI/containerd #146](https://github.com/castlemilk/micropod/issues/146).
