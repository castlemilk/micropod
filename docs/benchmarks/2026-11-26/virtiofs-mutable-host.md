# Mutable VirtioFS interrupts and live reads

## Workspace interrupt experiment

The writable workspace backend publishes each used split-ring descriptor before raising the interrupt at the end of the pass. The experiment raises one early interrupt when the first ordinary reply has been published and the ring still has work. It checks the available-ring suppression flag, coalesces an already asserted interrupt, and checks suppression again at the end of the pass. A successful early signal limits that pass to 32 ordinary replies so the high-priority queue and pause or shutdown checks can run. The writable workspace is the only instrumented share. [Virtio split-ring notification suppression](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html#x1-510007)

Both measured modes used the same signed VMM and Linux 7.3.5 B5 Image. The 1,058-file mounted fixture ran four paired rounds against OrbStack in each mode. Each reported guest time sums Git status, Go build and three uncached Go test subprocesses. The APFS fixture and worker volumes had Spotlight indexing disabled and zero FSEvents journal files. [Source, compiler logs and paired receipts](virtiofs-mutable-host-replay.tar.gz)

| VMM mode | Warm HVF / OrbStack median | Edited HVF / OrbStack median | Warm median paired HVF/OrbStack ratio | Host CPU idle |
|---|---:|---:|---:|---:|
| Control | 890.709 / 653.722 ms | 2,060.479 / 1,955.755 ms | 1.375 | 76.72% |
| Early | 1,132.476 / 769.691 ms | 2,360.296 / 2,201.801 ms | 1.468 | 56.62% |

Over the early worker's lifetime, Linux acknowledged all 14,697 early assertions. Of the 14,704 attempts, seven found the interrupt already asserted. The IRQ setter reported zero failures, and no pass reached the 32-reply cap. All 16 standard workspace edit observations passed in each mode. HVF recorded zero wins in the warm or edited pairs. Sustained speedup remains unproven, and weighted host CPU idle differed across modes.

## Held handles and exact host timestamps

A stronger mutation probe wrote through an open APFS mapping and restored the exact original mtime of `1765443210123456789` ns. The host's inode and file size stayed fixed and both the byte hash and ctime changed. The guest's already-open descriptor returned the previous bytes in the frozen VMM and in both interrupt modes. Linux's buffered FUSE policy invalidates cached data after an observed change to size or mtime. Opening a new handle can invalidate cached pages without addressing a read through an existing handle. [Linux 7.3.5 attribute invalidation](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/inode.c)

The separate live-read candidate negotiates FUSE 7.39 shared-mapping support and sets `FOPEN_DIRECT_IO` on regular mutable workspace opens and creates. Linux sends ordinary reads and writes to the live host file descriptor and continues to support private and shared guest mappings. A dirty guest mapping is written back over the requested range before an ordinary direct read. An explicit live-read request requires a kernel that advertises the shared-mapping capability and a fresh FUSE negotiation. [Linux 7.3.5 file and mapping operations](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/file.c) · [FUSE protocol](https://github.com/gregkh/linux/blob/v7.3.5/include/uapi/linux/fuse.h)

On stock B5, the live-read VMM returned the new bytes through both a held read-only `pread` and a held read/write `read`. A newly faulted mapping saw the edit. After same-time atomic replacement, both held descriptors read their original inode and a new open reached the replacement. Read-only shared mappings, private copy-on-write and writable guest shared mappings passed, including reading dirty guest-mapped data before a flush and observing it on the host after fsync. All 16 ordinary workspace edit checks passed. The stock live-read repeat's median times were 898.353 / 654.447 ms for warm HVF / OrbStack and 2,103.846 / 1,956.441 ms after an edit, with 79.27% weighted host CPU idle. [Live receipts](virtiofs-mutable-host-replay.tar.gz)

Linux 7.3.5 separately routes a server-selected direct handle's splice read through the page cache. On stock B5, held `splice`, `sendfile` and a prefaulted guest shared mapping all returned the previous bytes after the host mmap edit. The upstream fix in Linux 7.3.6 routes splice through the direct read iterator. Already resident guest mmap pages still follow cached mapping semantics. [Upstream splice fix](https://github.com/torvalds/linux/commit/10bd6b32965265688fa277d166ab224de8e86eb2) · [Linux 7.3.6 stable changelog](https://cdn.kernel.org/pub/linux/kernel/v7.x/ChangeLog-7.3.6)

## Host LOOKUP follow-up

A warmed exact-name lookup uses a cached parent descriptor and one live, no-follow `fstatat`. An expired descriptor can require a containment check. Case aliases, hard links and renames can require an extra host name lookup. Keeping the live stat preserves metadata and inode changes independently of the guest page-cache policy. Darwin's alternative attribute API also resolves the vnode and fetches attributes. [Apple XNU stat](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_syscalls.c) · [Apple XNU attribute lookup](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/vfs/vfs_attrlist.c)

The older 2,719-LOOKUP trace and the newer exact 1,351-LOOKUP control had at most two simultaneously outstanding LOOKUPs. In the two captures, 58 and 40 requests respectively overlapped another LOOKUP of the same wire length. That filters possible exact-name duplicates without identifying parent or name. Only guest send and end times were observed. The earlier warmed 1,058-file host-handler replay averaged 2.134 µs per request at its median scan time. At that rate the entire handler would account for about 5.8 ms across 2,719 requests, an extrapolation across runs. [Replay and trace reconciliation](virtiofs-mutable-host-replay.tar.gz) · [Original host timing receipts](../2026-11-25/managed-ci-git-and-exec-receipts.tar.gz)

## Reproduce the VMMs

The archive holds the exact 42-file frozen source captured from the dirty worktree at `76a329b6e464441ec1f6f0263940b0a327b7fa39`, separate candidate patches and full source manifests. Both patches were applied independently to an extracted archive and verified against their tested complete source hashes. The source manifests contain the signed ARM64 digests, toolchain and kernel source references.

```sh
mkdir -p /path/to/replay
tar -xzf virtiofs-mutable-host-replay.tar.gz -C /path/to/replay
cd /path/to/replay
tar -xzf source/virtiofs-first-reply-irq-base.tar.gz
git -C baseline-vmm apply "$PWD/irq/virtiofs-first-reply-irq.patch"
cd baseline-vmm
cargo test --locked -p vmm-virtio --lib -j 4
cargo build --release --locked -p micropod-vmm -j 4
codesign --force --sign - --entitlements entitlements.plist target/release/micropod-vmm
codesign --verify --strict target/release/micropod-vmm
```

For the live-read candidate, extract a fresh source tree and use `live/virtiofs-live-reads.patch` in the apply step. Build with the same commands. The IRQ candidate passed 53 Rust crate tests. The live-read candidate passed 49, including capability negotiation, regular OPEN and CREATE flags and restored negotiation state.

Launch the IRQ candidate with `MICROPOD_VIRTIOFS_EARLY_IRQ=0` or `1` to record the control or early behavior. Launch the live-read candidate with `MICROPOD_VIRTIOFS_LIVE_READ=1` and use the fresh guest's `direct_io_mmap=true` startup line to verify negotiation. The archive includes an Alpine held-open probe and the Linux Python read, splice and mapping matrix.

## Reproduce the B5 splice backport

The ARM64 Linux build uses the pinned 16 KiB B5 config, the three B5 patches, GCC 15.2.0 and GNU binutils 2.45.1. It builds a stock Image, applies the single upstream splice patch with zero fuzz, builds `fs/fuse/file.o`, and relinks the candidate Image. Both builds completed and use the same resolved config and release string. The published B5 Image and the rebuilt stock Image have different SHA-256 values. The rebuilt stock and splice Images are the same-source pair. Place the upstream archive in `kernel/inputs/` alongside the archived inputs. [Build receipts](virtiofs-mutable-host-replay.tar.gz) · [Linux 7.3.5 source archive](https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.5.tar.xz)

| B5 Image | SHA-256 |
|---|---|
| Published | `5eb46b31203fe4b4d53782f4ba7b216274ad5cd63424df711fc96fd36577e52b` |
| Rebuilt stock | `ae067356ec5e6c21890633e8793acb6b8fe88fe4d3e16af9df438104c6865b8b` |
| Rebuilt with splice fix | `dba972178942b384b9eefd10dc1d92c0b9f063d5bcb2a9604e388400283f0ab6` |

```sh
JOBS=4 sh kernel/inputs/build-virtiofs-splice-kernel.sh \
  kernel/inputs /path/to/new-output-directory
```

The runtime probe uses the same signed live-read VMM and checkout image. Enable `MICROPOD_VIRTIOFS_LIVE_READ=1` and pass `--require-live-splice` when running `kernel/guest_splice_contract.py` with the patched Image. On a separate untouched 127-byte file, both splice and sendfile must preserve the file descriptor offset and return the correct range, short read and EOF. On the externally changed file, both held copy operations must see the edit with the prefaulted mapping still present.
