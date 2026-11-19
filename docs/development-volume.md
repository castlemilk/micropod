# Development volumes on macOS

`micropod storage dev-volume` puts a projects directory and an optional pnpm store on a sibling APFS volume. The old paths continue to work through symlinks. The volume uses the projects filesystem's case sensitivity and defaults to encryption with a passphrase entered in macOS's prompt. A source inside the projects tree, including a workspace-specific pnpm store, travels with the projects. A separate store can share hard links with the workspace on the new volume.

## Plan and migrate

Get the active store path from the workspace that uses it. Configurations can vary between projects. For a workspace with a custom pnpm store, the following commands keep its current path and configuration.

```sh
projects="$HOME/projects"
store="$(cd "$projects/micropod" && pnpm store path)"
cd "$HOME"
micropod storage dev-volume plan --projects "$projects" --pnpm-store "$store"
micropod storage dev-volume create --projects "$projects" --pnpm-store "$store"
micropod storage dev-volume migrate
micropod storage dev-volume status --json
```

Pass an existing store. Omit `--pnpm-store` to migrate only projects. If you maintain multiple pnpm store versions, select their common store directory to include them all. `plan` reads the source and writes nothing. `create` provisions the volume, records its UUID in a private journal under `~/.micropod/dev-volume`, applies the indexing policy and remounts it. An operator can explicitly choose `--container diskN` or `--unencrypted` at provisioning. After creation, commands verify both the volume UUID and its original APFS container.

Run migration outside the source directories and close editors, shells or rig jobs using them. The CLI reports open process IDs. Migration copies as the login user, verifies bytes, modes, hard links, symlinks, macOS extended attributes, flags and ACLs, then atomically switches each top-level path. A top-level path with its own mount, or an embedded filesystem detected during verification, stops the migration. Each tree has a separate commit point. Its journal and filesystem state allow the same command to continue after interruption.

Budget space for the verified destination copy and the retained source. A cross-volume copy can materialize bytes previously shared by APFS clones. The CLI prints the original backup path for each tree in JSON status. A new migration after restore starts a new generation and retains previous copies.

## Remount, repair and restore

```sh
micropod storage dev-volume status --json
micropod storage dev-volume remount
micropod storage dev-volume mount
micropod storage dev-volume repair
micropod storage dev-volume restore
```

`remount` requests an ordinary unmount and mount. Close volume users first. `mount` resolves the recorded device and prompts macOS to unlock an encrypted volume when required. `repair` reapplies the volume's ownership and indexing settings. Remount during an idle window after restoring a missing event-log marker. `restore` brings the **current** contents back to the original paths, including edits and deletions made after the move. It also retains the pre-migration backups and the volume copy. `status --json` gives the payload path, mount state, Spotlight's actual report and the observable state of the FSEvents marker.

Micropod requests Spotlight indexing off with `mdutil -i off` on this volume and creates `.metadata_never_index` and `.fseventsd/no_log` there. The latter opts the volume out of the persistent filesystem event history. Tools that rely on that history can need a rescan. Live file notifications and other volumes are outside the policy. The source ideas are [repos-volume.sh](https://github.com/elithrar/dotfiles/blob/main/repos-volume.sh), [disable-apple-tracking](https://github.com/rayhanadev/disable-apple-tracking) and [Apple's FSEvents guide](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FileSystemEventSecurity/FileSystemEventSecurity.html).

## Micropod runtime data and disk caches

Projects, pnpm's store and Micropod's VM disk store have separate owners. To move VM data as well, schedule an idle rig window and use the existing runtime storage command. Keep prepared disk images and their writable clones on the same APFS volume.

```sh
payload="$(micropod storage dev-volume status --json | jq -er 'select(.mounted and .initialized) | .payload')"
micropod storage set "$payload/runtime" --migrate
```

This operation stops and restarts the runtime during migration. Workspace `restore` handles the selected projects and pnpm directories. Manage the runtime store through `micropod storage`. [Runtime storage](storage-location.md).

## Measure a persistent Linux kernel

A Micropod sandbox requested with `rootless_docker` supplies one Linux kernel to its inner Docker containers for the lifetime of that allocation. The default Apple engine uses a VM per container. A Docker adapter pointed at another product measures that product's kernel. The persistent, shared Linux execution domain for ordinary Micropod workloads is tracked in [#202](https://github.com/castlemilk/micropod/issues/202). [Native rootless qualification](../ROOTLESS-SANDBOX-VALIDATION.md).

Use an idle, running Micropod rootless allocation. Its image needs a Docker client, a live rootless socket, delegated CPU and memory controllers, and the same pre-pulled native Alpine fixture as the controls. Use the socket path and allocation ID reported by that rig. The user executing the benchmark inside the allocation needs access to that socket. If the Connect endpoint requires an issued session credential, pass the complete Authorization header value in the local environment variable `MICROPOD_BENCH_AUTHORIZATION`. The benchmark sends it only to the specified local Micropod endpoint. The benchmark creates only its own short-lived containers and leaves the allocation running.

```sh
image='alpine:3.20@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc'
python3 scripts/bench_live_kernel.py --engine rig-pair --api http://127.0.0.1:45454 \
  --allocation "$ALLOCATION_ID" --socket /run/user/1000/docker.sock \
  --orbstack-socket "$HOME/.orbstack/run/docker.sock" --image "$image" --json rig-pair.json
python3 scripts/bench_live_kernel.py --engine micropod --api http://127.0.0.1:45454 \
  --allocation "$ALLOCATION_ID" --socket /run/user/1000/docker.sock --image "$image" --json micropod-kernel.json
python3 scripts/bench_live_kernel.py --engine orbstack --socket "$HOME/.orbstack/run/docker.sock" \
  --image "$image" --json orbstack-kernel.json
python3 scripts/bench_live_kernel.py --engine linux-docker --socket /var/run/docker.sock \
  --image "$image" --json linux-kernel.json
```

The benchmark compares two overlapping containers' Linux boot ID, requires distinct PID and mount namespaces, and verifies cgroup CPU and memory values. Each timed container has one CPU, 256 MiB and no network. It must return the expected status, stdout, stderr and boot ID. A Micropod result also requires the independent boot ID of the enclosing allocation and the same Micropod allocation before and after all batches. Linux uses the local engine host. OrbStack uses the Mac Docker client and its local Unix socket. The default Micropod clock runs on the requesting Mac and includes the Connect transport. The optional `--engine micropod --clock guest` uses Python 3.8+ inside the allocation to isolate the guest Docker latency. The paired command uses a single Mac clock, alternates both engines across blocks, verifies the same native image on distinct kernels and records each daemon's CPU and memory allocation.

The default scales are 1, 4, 8 and 16 simultaneous clients, with five blocks per scale. Batch wall times include the Docker client, launch, guest execution, auto-removal and client return. VM provisioning and image pulls happen outside the measured interval. A physical comparison should use the same idle Mac, engine budgets, image architecture and digest, and record each allocation's cold-to-ready time separately. [Measured results](benchmarks/2026-11-19/warm-kernel-and-volumes.md).
