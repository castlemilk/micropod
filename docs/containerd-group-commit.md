# containerd: fewer, shared commits, and writable layers that are never synced

The engine starts every Docker container as a CRI pod and a CRI container in
containerd. containerd keeps their records in one bbolt file (`meta.db`), and
every write transaction commits on its own: bbolt writes the changed pages and
fdatasyncs, writes its meta page and fdatasyncs again, under one write lock.
On the throwaway machine a `docker run --rm alpine echo ok` cost 22.8 such
commits in `meta.db` and 4.4 in the overlay snapshotter's own file, about 54
fdatasyncs, and 16 streams of start and removal (`churn500`) ran at 64
containers a second while the guest was 70-80 % idle (profiling
`CONFIRMED.md` §6; the per-call breakdown below is bpftrace on bbolt's
`(*Tx).Commit` with user stacks, `ge/an/commits.py`).

Three changes cut that, and a fourth stops every container exit from syncing
the whole disk. This page is the argument that none of them weakens what an
answer promises.

## What one container commits, and who asks

| commits per `docker run --rm` | where |
|---|---|
| 10 meta + 1 overlay | RunPodSandbox: the sandbox record (create, 3 updates), its lease, the pause container's snapshot (2) and record, and a temporary lease around them (create, delete) |
| 5 meta + 1 overlay | CreateContainer: the workload's snapshot (2) and record, and its temporary lease (create, delete) |
| 1 meta | the engine's `containers.Update` of the OCI spec (console, tmpfs, ulimits or job parent) |
| 6 meta | RemovePodSandbox: both snapshots and records, the sandbox lease and record |
| 0.8 meta + 2.4 overlay | garbage collection of the two snapshots |

## 1. No temporary leases (engine: `runtime_lease_linux.go`)

containerd's client wraps a container it creates in a lease of its own unless
the request names one in its `containerd-lease` header. The engine names one:

- CreateContainer names its pod's own lease (CRI creates a lease with the
  sandbox's ID in RunPodSandbox and deletes it in RemovePodSandbox), so the
  workload's snapshot is held exactly as long as its pod.
- RunPodSandbox names `micropod-runtime-sandboxes`, one lease that holds the
  pause snapshots from their creation; RemovePodSandbox names it too, so each
  hold goes with its snapshot. Recovery deletes the lease once every pod is
  gone, so a hold an interrupted call left lasts one boot at most.

Durability: unchanged. Each remaining commit is synced as before. A snapshot
is held by a lease from its creation until a container record holds it, as
before; only which lease holds it changed. If a named lease is missing, the
request is repeated without it.

Saves 4 of the 22.8 `meta.db` commits per container.

## 2. Group commit (containerd patch `0002-metadata-group-commit.patch`)

`metadata.DB.Batch` lets updates that arrive while a transaction commits share
the next one. The first caller runs its transaction at once (alone if no one
else waits); callers that arrive meanwhile are run, in arrival order, in one
transaction by the next leader, which commits once.

The argument, caller by caller:

- **An answer is still durable.** `Batch` returns only after the transaction
  that holds the caller's function has committed, and bbolt's `Commit`
  fdatasyncs the pages and then the meta page before it returns, exactly as
  for `Update`. So everything a caller was told succeeded is on the disk.
- **A caller's writes are whole.** All of one caller's writes are inside one
  bbolt transaction, which is applied whole or not at all. A crash leaves
  either a whole batch or none of it, so never part of one caller's writes.
- **Order is kept.** Functions run one after another inside the transaction,
  so each sees the writes of those before it: the outcome is that of running
  them serially in arrival order. A caller whose call returned before another
  began is in an earlier transaction.
- **A failure stays the caller's own.** bbolt cannot roll back part of a
  transaction, so when a function fails, the transaction is rolled back, that
  caller is answered with its error (it ran after its predecessors, which are
  then committed, so its error is the one a serial run gives), and the
  transaction runs again without it. The functions before it run a second
  time, on the same state. So only functions whose only effect is their
  writes to the transaction are batched: container records (create, update,
  delete), sandbox records, leases and lease resources. Snapshot creation and
  removal are not: they call the snapshotter, which has its own file, inside
  the transaction. A panic in a batched function is that caller's error.
- **A disk error** fails every caller of that transaction, as it failed the
  one caller of a transaction before.

The garbage collector's exclusive lock and the mutation callbacks that
schedule it are taken and called around a batch as around `Update`.

What is not batched: snapshots (prepare, commit, remove), content, images,
and every call that brings its own transaction in its context.

## 3. Writable layers used once are volatile (patch `0001-overlay-volatile-label.patch`, engine `rootfs_volatile_linux.go`)

Every overlay unmount syncs the whole filesystem its upper directory is on
(`ovl_sync_fs`, from the shim's unmount at container exit), so each exit also
flushed every other container's writes: under 32 cold builds, 364 such syncs
summed 40-68 s, the longest 7.2 s, and a container that wrote 256 MB spent
0.16-0.62 s outside its process at exit (`CONFIRMED.md` §3). A volatile
overlay skips that sync, makes fsync inside it a no-op, and the kernel refuses
to mount its upper again.

The engine asks for it, with the annotation
`containerd.io/snapshot/overlay.volatile=true`, only for writable layers that
are mounted once and then thrown away:

- every pod's pause container (each pod is removed with its container);
- the rootfs of a container removed at exit (`--rm`) or with a read-only
  rootfs.

A container that keeps its rootfs runs on the engine's own snapshot
(`docker_rootfs_linux.go`), which carries no such label and is mounted as
before: what it wrote and synced is on the disk when its fsync returns, and
it starts again after a stop. (Setting the option for every snapshot broke
exactly that: a kept container could not start a second time.)

Durability lost, and why no one can tell: the content of an `--rm`
container's rootfs or a pause rootfs if the machine crashes while it runs.
After a crash recovery removes every pod and every AutoRemove container
before the engine answers, so nothing can read that layer again; while the
container runs, its reads see its writes as before. Volumes, binds and tmpfs
are separate mounts and keep their own durability. The records-crash gate's
`rm-burst` kind kills the machine right after eight concurrent `--rm` starts
answered and requires all eight gone after the relaunch.

A containerd without the patch ignores the annotation.

Known cost, measured (32 cold builds with `docker run --rm` probes between
them, `stall3.py`, profiling `instruments2.txt` and `fsync-burst.txt`): the
syncs a volatile exit no longer makes kept dirty data small, so it builds up,
and each of containerd's commits (an ext4 journal commit, which in
`data=ordered` writes out the data of every file in the transaction) waits
for more of it. containerd's fsync and fdatasync summed 6.9 s (longest
1.1 s) in a burst against 1.4 s (0.13 s) with every exit syncing, and the
engine's teardown histogram rose from 0.17-0.41 s to 0.43-0.66 s mean. The
probes' own runs were as fast or faster and the disk wrote 30 % less. The
next lever is to keep `meta.db`'s journal commits out of other containers'
writeback (its own filesystem, or a bound on dirty data); it is not built.

## 4. Copy-on-write cache views are volatile (engine `mountCacheOverlay`)

An untrusted (or read-only) container reads a shared cache store through a
per-container overlay whose upper directory is its own and is removed with the
view; a view a crashed start left is removed before the next mount. The view
is now mounted volatile, for the reason above.

Trust: unchanged. The store is still the view's lower layer and is never
written through it (overlayfs writes only to the upper); the upper is the
container's own and goes with it. Volatile changes only whether the upper's
bytes reach the disk, and nothing reads them after the view is gone. So no
untrusted write can reach a shared store, with or without the option.

## Gates

- records-crash: kinds `start-burst` (eight concurrent starts, then a kill
  0-3000 ms after the last answer: all present, none running, created or a
  success, and one runs again) and `rm-burst` (eight concurrent `--rm`
  starts: all gone).
- The containerd metadata package's own tests, plus
  `TestBatchSharesTransactionsAndIsolatesFailures` (64 concurrent callers,
  failing ones answered alone, the rest committed).
- e2e_hvf_caches.sh T3: an untrusted build through the views writes nothing
  into the trusted store.
