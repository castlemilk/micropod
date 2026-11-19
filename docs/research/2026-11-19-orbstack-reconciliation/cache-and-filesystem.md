# Cache and filesystem implementation plan

**Core product work, ahead of Kubernetes expansion.** Source snapshot: 19 November 2026, Micropod `54980012eb47b458a7f7e1def616d3fa95c970a2`; master was rechecked and unchanged. This document is a deeper source audit and implementation specification. No native Mac benchmark, fault injection, runtime change or tool installation was performed.

The product needs fast, correct builds and container filesystems across repeated local development and disposable CI. That requires several cooperating caches, a precise filesystem contract, durable ownership and measurable eviction. A content hash or a VirtioFS mount alone does not establish that result. Existing caches should become the starting point, with fixes and adapters around their actual owners.

## Separate the cache tiers

| Tier | What it caches | Current Micropod evidence | Required contract |
|---|---|---|---|
| Uploaded/extracted build contexts | A source tree presented to a builder | `BuildContextCache`: tar tree hash, APFS clone checkout, 5 GiB default cap and in-process pins | Canonical filesystem identity, complete/atomic publication, actual byte basis and concurrent build leases |
| BuildKit solver/results | Build graph results, immutable refs and dependency relationships | Builds delegate through the existing Apple build path; Micropod's context cache is not the LLB cache | Upstream worker/service ownership, cache hit reason, supported import/export and GC interfaces |
| Build cache mounts | Mutable compiler/package directories used by `RUN --mount=type=cache` | Existing package caches and volume clones are potential backing components, not proof of BuildKit mount semantics | Cache ID, namespace, sharing/locking, UID/mode, version compatibility and separate transfer policy |
| OCI distribution content | Compressed layer blobs, manifests, indexes and config | Apple image-store XPC client already reads content and resolves platforms | Digest/size verification, platform-complete availability, leases, provenance and bounded transfer |
| Unpacked immutable roots | Filesystem snapshots prepared from an image | Sandbox creates cached ext4 roots, keyed by image identity and capacity, then clones them | Exact realization key, single-flight unpack, parent graph and validated publication |
| Writable roots and named volumes | Execution changes and persistent workload data | APFS clones, staged volume promotion, locks, disk checkpoints | These are owned data; explicit disposable-cache policy is required before eviction |
| SharedFS chunks and views | File blocks and host-side trees exported into a VM | SHA-256 chunks, optional LZ4 representation, views, watchers and retained-data controls | Verified blocks, snapshot consistency, metadata/empty-file semantics and safe owner recovery |
| Filesystem metadata and page cache | `stat`/directory results and file pages on host/guest | Apple VirtioFS plus user-space SharedFS synchronization | Coherence/invalidation, memory-pressure response and cache-policy capability reporting |

BuildKit's exported solver cache and mutable cache-mount contents are separate. Docker's current Dockerfile reference explicitly says cache mounts remain builder-local and are not included in `--cache-to` or restored by `--cache-from`. A successful remote layer-cache hit therefore does not prove package-cache continuity across disposable builders. [Dockerfile cache mounts](https://docs.docker.com/reference/dockerfile/), [external cache backends](https://docs.docker.com/build/cache/backends/).

## Source findings that need implementation

### 1. Preserve successful APFS clones in the per-file path

`SharedView.cloneOrCopy` calls `clonefile` inside nested filesystem-representation closures. Its success `return` exits the inner closure, then execution continues into `Data(contentsOf:)` and an atomic write. The per-file path therefore still reads and rewrites a file even after a successful clone. The whole-directory path returns a Boolean to its caller correctly, so the distinction matters: ignore rules or a failed directory clone take the affected path.

Fix the success propagation, use a bounded streaming copy only when cloning fails, and preserve the declared metadata. Add an injected file-operation seam proving that a successful clone performs no fallback read/write. On APFS, then measure bytes read/written, peak memory, allocation and elapsed time. Do not assume all clone operations are O(1) regardless of directory size or filesystem. [SharedView implementation](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedView.swift).

### 2. Make chunk ingestion an all-or-error operation

`ChunkStore.ingestFile` catches a block-store error inside its loop and returns `false`, then computes the original file digest separately and returns the accumulated chunk list. A failed write can therefore produce a partial list paired with a digest from the whole source. Independently, a file changed between the chunk pass and digest pass may produce inconsistent identities. This is a source-level control-flow finding; no live data loss is asserted.

Produce chunks, whole-file digest and byte length from one stable logical input; propagate errors and publish a file manifest only when complete. Use a stable snapshot or detect concurrent mutation and retry under a bounded policy. Orphaned blocks from an unsuccessful attempt may be collected later under their own lease; they must not form a successful file manifest. [ChunkStore lines 275–319](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/ChunkStore.swift#L275-L319).

### 3. Verify content after reading or importing it

`readBlock` decodes stored bytes but does not compare the decoded digest with the requested content-addressed filename. Decompression success alone does not prove integrity. The representation marker also interprets a raw payload of at least eight bytes beginning with `MCZ1` as a frame; a legitimate identity block can begin with those bytes. The declared decoded-size bound is much larger than the default 256 KiB chunk size.

Define a versioned stored representation that can unambiguously represent raw and compressed bytes, validate lengths and digest, and bound decode allocation by the declared object/chunk policy. Qualify existing-file migration and corruption quarantine. Hashing cost should be measured and amortized using an explicitly trusted verified-object state, not eliminated by assuming a pathname proves content. [ChunkStore representation and read path](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/ChunkStore.swift#L121-L201), [existing transcode tests](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Tests/MicropodSharedFSTests/TranscodeTests.swift).

### 4. Separate empty files from deletion

An empty ingest produces no chunks, and `materialise([])` deletes the destination. This behavior is explicitly asserted by `testMaterialiseEmptyHashesRemovesFile`; it is an existing contract, not an untested accidental regression. Before using this API as a general filesystem/content interface, introduce explicit entry type, byte length and deletion/tombstone state. A zero-byte regular file and an absent path must be distinguishable without silently changing legacy callers. [ChunkStore](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/ChunkStore.swift#L251-L272), [contract test](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Tests/MicropodSharedFSTests/ChunkStoreTests.swift).

### 5. Fix retained-context accounting before setting global budgets

`BuildContextCache.store` adds the sum of regular-file lengths to its index. `entryBytes` prefers `BuildManifest.contentBytes`, which deduplicates equal digests within a context. Two independent paths with identical 1 KiB contents contribute 2 KiB on insertion but 1 KiB on eviction under those definitions. Startup scans the whole root, including sidecars, while normal insertion excludes them. Eviction also decrements accounting after `try? removeItem`, even when deletion fails.

Choose one documented cap basis and use it consistently for insertion, replacement, eviction, restart and reconciliation. Keep separate counters for path-logical bytes, distinct content bytes, stored representation bytes and host allocation. The current `sharedBytes` metric detects overlapping digests; it does not prove that two extracted context trees physically share those bytes. [Context accounting](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodDockerShim/BuildContextCache.swift#L271-L388), [manifest accounting](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/BuildCache.swift).

### 6. Preserve existing retention protections, then make ownership durable

The daemon already protects retained caches, refuses manual purge with active mounts, checks reviewed cleanup tokens, and fails closed when retained view directories outlive its in-memory registry. These are valuable safeguards. Build-context pins and chunk reference counts remain process-local, and restart reconciliation cannot yet turn unknown retained ownership into a complete reusable reference graph.

Add durable operation/owner generations and object leases around the present owners. Reconcile before eviction; unknown ownership stays protected. A lease expiry alone must not prove that a VM or build has stopped. Route GC through the owning BuildKit/image/SharedFS/volume service instead of deleting its backing files from another process. [Daemon cap and cleanup](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedFSDaemon.swift#L108-L213), [reviewed cleanup and unknown views](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedFSDaemon.swift#L394-L519), [retention model](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/CacheManagement.swift).

### 7. Avoid repeated full-tree work on the critical path

The current cap loop rebuilds and sorts the candidate set for each victim. It first reads/hashes active view contents to compute live pins. Shared-view synchronization also has directory-rescan and content-only identity limitations described in #93/#161. These algorithms are costs to profile; their presence is not a measured bottleneck result.

Build one bounded eviction plan per generation and replace recurring whole-tree proof with durable object references where possible. Use a metadata index and changed-subtree invalidation for supported live shares, with a full recovery scan when an event gap invalidates the index. Keep uncertainty visible instead of treating a stale index as complete. [GC loop](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedFSDaemon.swift#L134-L198), [pin reconstruction](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedFSDaemon.swift#L607-L638), [SharedViewSync](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodSharedFS/SharedViewSync.swift).

### 8. Coordinate image roots and volume work already in progress

The image client already checks that a selected platform's manifest/config blobs exist; it does not simply treat an OCI index as proof of all platforms being local. Preserve that distinction. Sandbox base preparation uses staged unpack and rename, but concurrent first requests may each unpack the same root. Its current capacity suffix uses integer GiB for exact-GiB sizes and truncated MiB otherwise; different requested byte capacities within one MiB can therefore share a key. Use exact-byte capacity in the versioned realization identity, with collision fixtures and explicit migration. Add a shared in-flight promise/operation record and an immutable realization manifest rather than merely another cache directory.

The realization identity should include resolved platform manifest, filesystem format/version, relevant unpacker configuration and exact capacity. Blob digest, uncompressed layer DiffID and the chain/root realization identity are different values. Preserve image whiteouts, opaque directories, ownership, modes, links and xattrs when realizing layers; a directory copy is not an OCI layer applicator. [Image resolution](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/ImagesServiceClient.swift), [sandbox root preparation](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/SandboxVM.swift#L591-L621), [containerd content flow](https://github.com/containerd/containerd/blob/main/docs/content-flow.md), [OCI layer semantics](https://github.com/opencontainers/image-spec/blob/main/layer.md).

PRs [#135](https://github.com/castlemilk/micropod/pull/135) and [#177](https://github.com/castlemilk/micropod/pull/177) already own image deletion lock relief and preformatted volume templates. Their source and author-reported measurements remain open work at this audit snapshot. Preserve first-template versus warm-clone timing, shared ext4 UUID considerations and requested-versus-CLI-reported size semantics. Extend these owners rather than introduce a competing template/reclaimer implementation.

## Cache control architecture

The initial design should be a common inventory and ownership contract over existing stores. It does not require replacing every store with a new global CAS or running another always-on daemon.

Each adapter exposes object identity, trust namespace, representation/version, parent/dependency references, immutable versus mutable status, active owners, byte basis, last validated use, and supported operations. Use explicit unknown values where upstream APIs cannot supply a property. A name/tag is a mutable reference, not an immutable cache key.

### Publication and lifetime invariants

1. Acquire an operation lease before creating or importing an object. Stage content privately and validate its complete identity.
2. Publish its immutable manifest/reference graph atomically. Transfer ownership to the build, image, snapshot or retained cache that will use it.
3. Release only the initiating operation's lease after the authoritative handoff. Cancellation reconciles unknown outcomes instead of assuming no side effect occurred.
4. GC selects only unreferenced objects inside the requesting authority's namespace. Revalidate the owner generation before retirement; detach metadata and reclaim storage through the actual owner.
5. Recovery distinguishes staged, committed, leased, retired and quarantined states. An unknown running task, incomplete inventory or failed delete cannot be counted as reclaimed capacity.

This follows the ownership requirement exposed by containerd's lease-based GC: resources need a live reference or a lease while they may still be needed. Micropod must adapt that contract to Apple's store as well as any future containerd worker; a containerd lease cannot protect an unrelated APFS path by itself. [containerd garbage collection](https://github.com/containerd/containerd/blob/main/docs/garbage-collection.md).

### Budgets, eviction and trust

Set per-store and per-trust-domain retention plus a host free-space floor. Preserve active references regardless of age; under pressure reject or queue new work with an actionable reason if safe reclaim is insufficient. Use cost/recency/size information where measured, and keep rebuild-cost estimates labelled estimates. Apply bounded asynchronous retirement so deleting a large image cannot monopolize a lifecycle lock.

Deduplication and authorization are separate. A digest may identify bytes shared physically, while authorization and provenance determine which workload may retrieve, promote or export them. Untrusted PR builds must not replace a trusted branch's mutable compiler cache or poison its name-to-result mapping. Remote caches require authenticated namespace access, verified payloads and explicit export eligibility. The engine must exclude secret, SSH and transient session mounts from automatic snapshots and exports. This does not guarantee secret-free artifacts if a Dockerfile explicitly copies secret material into an ordinary output or cache directory.

Mutable package caches need their own contract: logical cache ID, toolchain/platform compatibility, creator UID/mode and `shared`/`private`/`locked` behavior. Preserve upstream mutable-cache semantics: writes may persist after failed or cancelled builds; do not impose blanket rollback. Existing golden-volume promotion is a useful primitive for a separate snapshot/export generation. Concurrent writers must retain the selected sharing mode, with supported locking or isolated clones where that mode requires them. Incomplete remote exports or golden generations must not replace a verified published reference. Copying the entire mounted directory during active package-manager writes is not a coherent remote-cache export. [Volume owner guards](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodRuntime/NativeVolumeService.swift), [APFS clone/promotion primitives](https://github.com/castlemilk/micropod/blob/54980012eb47b458a7f7e1def616d3fa95c970a2/Sources/MicropodCore/Services/VolumeClone.swift), [BuildKit GC policy](https://docs.docker.com/build/cache/garbage-collection/).

## VirtioFS and shared-file performance: implement at the layer we control

Apple's documented VZ interface configures a directory share and tag. It does not document the queue/cache-timeout/DAX/server-thread controls assumed by a generic Linux virtiofsd tuning recipe. Linux's virtiofs client uses FUSE requests over virtqueues, but that protocol description is not proof that Apple's host server exposes identical tuning controls. Record actual framework/kernel capability by supported version. [Apple VZ filesystem configuration](https://developer.apple.com/documentation/virtualization/vzvirtiofilesystemdeviceconfiguration/), [Linux virtiofs](https://docs.kernel.org/filesystems/virtiofs.html).

Define three supported storage behaviors rather than one ambiguous fast mode:

| Mode | Appropriate workload | Required behavior |
|---|---|---|
| Direct host share | Interactive source editing and ordinary bind mounts | Visible host changes, supported POSIX metadata, explicit macOS case/permission differences, correct guest notifications or documented supported mechanism |
| Immutable build input | A particular build's source snapshot | Stable complete tree identity, reproducible bytes and metadata, no source mutation leaking into an already accepted snapshot |
| Guest-native writable cache/volume | Package caches, compiler intermediates, databases and high-churn temporary work | Linux filesystem semantics, deliberate persistence/commit/backup policy, no automatic copying into a live host project |

Build a versioned metadata index for the controlled SharedFS mode: path bytes and normalization policy, entry kind, inode/link relation where meaningful, mode/UID/GID, xattr/ACL policy, size, timestamps, content digest, generation and authoritative root identity. Metadata-only edits must invalidate metadata even when the file's bytes hash identically. Preserve empty directories and explicit deletion. A directory rename should remap a subtree or invalidate it; it should not require a fresh hash of every unrelated file.

The event pipeline keeps FSEvents IDs/flags, coalesces redundant paths within bounded windows, handles overflow/root replacement, and uses versioned dirty generations to avoid stale asynchronous work winning. Guest-originated and host-originated changes need separate conflict/order rules. #93 remains the live-notification repair owner; #161 owns the correctness matrix. New indexing should consume qualified events, with a recovery scan on gaps. Never claim that a host-side FSEvent necessarily becomes a guest inotify event through every backend.

For data paths, measure small-file latency separately from large sequential I/O. Candidate changes include bounded streaming, batched metadata reads, retaining valid file descriptors, avoiding repeated stat/hash work and appropriate read-ahead. Preserve cancellation, resource limits and open/rename/unlink behavior. A bulk-transfer optimization must not delay small control requests indefinitely.

For writes, specify acknowledgement versus persistence: which operation makes bytes visible, which makes them durable, how `fsync` and directory rename behave, and what survives host/guest/service failure. Dirty writeback and batching are optional policy decisions with bounded memory and error propagation. Report their cost under the same durability requirement as the comparator.

DAX is a research capability only until the selected host/guest path proves it. Linux documents that virtiofs DAX eligibility depends on the server and may require checking `STATX_ATTR_DAX`; setting a guest flag alone is insufficient. Do not promise zero-copy or elimination of the page cache from an unsupported mount option. Memory reclamation work in #142 must consider host and guest page caches, dirty-page pressure and IO amplification, not only idle RSS. [Linux DAX semantics](https://docs.kernel.org/filesystems/dax.html).

## Qualification and performance matrix

| Fixture | Correctness evidence | Performance evidence |
|---|---|---|
| No-change rebuild; one source edit; lockfile edit; chmod-only edit | Expected invalidation, output identity, correct permissions; old cache cannot mask the edit | Context upload/hash/stage, solver hits, execution and export spans separately |
| 50k and larger trees with dotfiles, links and xattrs | Stable metadata/tree digest, rename/delete and notification checks | Cold versus indexed traversal, CPU, bytes read, peak memory and queue depth |
| APFS clone success, forced clone failure and different-volume copy | Equivalent supported contents/metadata; source unchanged | Physical IO and allocation, successful-clone fallback count, full workflow latency |
| Interrupted/failed chunk write; corrupt plain/compressed block | No partial manifest publication; digest verification; bounded decoder; explicit empty-file/tombstone behavior | Error completion time, orphan reconciliation and bounded memory |
| Concurrent cache hit/miss and same-image first unpack | Exactly one authoritative realization; no foreign lease cleanup | Duplicate unpack count, lock wait, throughput and p95, contention under load |
| Daemon crash with build/container active; low disk | Active data protected; unknown owners retained; restart reconciliation | Recovery time, safe reclaimed bytes, admission delay and GC work budget |
| Two projects and untrusted/trusted jobs sharing content | Authorization and mutable-cache isolation; remote corruption rejected | Dedup opportunity, actual stored/allocation measurements and useful reuse |
| File and database durable writes on bind and Linux-native volume | Declared fsync/rename/crash guarantee; no stale successful read | Throughput, flush latency, host/guest pressure, post-burst reclaim and energy |

Record separate states for context warm, solver cache warm, package cache warm, image downloaded, image unpacked, guest page cache warm and host page cache warm. A single warm/cold flag is insufficient. Measure fresh-builder remote reuse separately from an existing local builder, and retain first-attempt failures and all cleanup outcomes. Use #182's run manifest and #191's resource identity/accounting work; no new benchmark framework is required.

## Ticket ownership and ordering

Seven bounded cache/filesystem implementation slices accompany this document: verified chunk publication, clone fast-path repair, consistent cache accounting, durable cache leases, content/snapshot realization adapters, mutable package-cache semantics, and incremental filesystem metadata/invalidation. They are children of existing owners, not replacements for #93 or the #160–172 filesystem/storage plan.

Build-context semantic hashing and tar ingestion remain under the build-platform work. BuildKit cache import/export and DiskUsage/Prune protocol belong to the build service; this plan supplies safe owner operations and accounting behind those routes. Image-store integration extends #150, native sharing/indexing extends #160/#161/#163/#166/#167, and durable volume guarantees stay with #168–172. Preserve active #135/#177 ownership.

Start with the source-level correctness and clone/accounting fixes. Then establish leases and immutable realization identity while the build service integrates its worker. Implement the metadata index against the correctness matrix and profile the resulting end-to-end builds. Adopt alternative snapshotters or a custom VirtioFS host implementation only after a supported integration path and measured bottleneck justify them. A Linux overlayfs, blockfile or remote snapshotter is an adapter/design choice, not a format that can be attached directly to Apple's VZ server. [containerd snapshotter catalogue](https://github.com/containerd/containerd/blob/main/docs/snapshotters/README.md).

## Verification boundary

All implementation findings are pinned source observations. Existing test files were inspected, not run. The empty-materialization behavior is explicitly tested legacy behavior and needs deliberate versioning. New performance effects are hypotheses until native measurement. No current cache contents, host identifiers, runtime diagnostics or private workload data are published in this document.

## Filed implementation issues

| Issue | Work package | Priority |
|---|---|---|
| [#209](https://github.com/castlemilk/micropod/issues/209) | [Cache] Make chunk ingestion and materialization complete, verified and atomic | P0 |
| [#210](https://github.com/castlemilk/micropod/issues/210) | [Filesystem] Preserve the successful clone fast path and fallback metadata | P0 |
| [#211](https://github.com/castlemilk/micropod/issues/211) | [Cache] Unify byte accounting across insertion, eviction and restart | P0 |
| [#212](https://github.com/castlemilk/micropod/issues/212) | [Cache] Persist ownership and coordinate safe garbage collection across stores | P1 |
| [#213](https://github.com/castlemilk/micropod/issues/213) | [Images] Reuse verified content and immutable root realizations across build and run | P1 |
| [#214](https://github.com/castlemilk/micropod/issues/214) | [Build cache] Define mutable package-cache sharing, promotion and transfer semantics | P1 |
| [#215](https://github.com/castlemilk/micropod/issues/215) | [Filesystem] Add a versioned metadata index and bounded invalidation for shared views | P1 |

These issues are part of the [core platform program](core-container-platform.md) and [tracker #180](https://github.com/castlemilk/micropod/issues/180). Required compatibility remains a release gate; source findings are not executed qualification results.
