# Background VirtioFS releases on the Mac workspace

The same-Image experiment reduced median stock Git status on a warm 1,058-file Mac checkout from 177.42 ms to 137.90 ms. The complete warm Git, Go build and test job fell from 902.76 ms to 845.22 ms. With background release enabled, all 1,072 observed release replies associated with `close(2)` arrived after the system call returned. [Run summary](native-push-and-fuse-gamma.json) · [Raw receipts](native-push-and-fuse-gamma-receipts.tar.gz)

## Why close can return sooner

Linux 7.3.5 enables automatic submounts for a VirtioFS connection. Its normal `close(2)` path synchronously waits for a `FUSE_RELEASE` reply on those connections so a submount can release its inode references before teardown. The Micropod workspace server does not announce `FUSE_ATTR_SUBMOUNT`. It gives files on host volumes distinct inode numbers within the same guest share. [Linux release path](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/file.c) · [Linux mount and final queue drain](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/virtio_fs.c) · [Micropod server](../../../vmm/crates/vmm-virtio/src/virtiofs.rs)

The experiment uses `virtiofs.workspace_async_release=1` to omit the kernel's `FUSE_SUBMOUNTS` capability for the exact `workspace` tag and use the existing background release path. Ordinary Linux binds still reference the shared superblock. The last mount drains the connection before freeing that superblock. The experiment retains the workspace's 20 ms entry and attribute validity, held direct-I/O reads, shared mapping behavior and explicit `fsync`. The flag defaults off. [Kernel patch](../../../ci/patches/virtiofs-workspace-async-release.patch) · [FUSE capability definitions](https://github.com/gregkh/linux/blob/v7.3.5/include/uapi/linux/fuse.h)

## Stock workload

Each mode used four alternating Micropod and OrbStack pairs on independently staged copies of the same 1,058-file checkout with the Mac-authored Git index. The same signed VMM, initrd, runtime, Linux ARM64 image and job limits applied throughout. Each job ran ordinary stock Git status, Go build and three uncached tests, then verified its source and executable. The table reports untraced guest medians. Host idle averaged 79.47% with the flag off and 78.57% with it on. [Full workload and host samples](native-push-and-fuse-gamma-receipts.tar.gz)

| Guest workload | HVF off | HVF on | OrbStack in off window | OrbStack in on window |
|---|---:|---:|---:|---:|
| Warm Git, build and tests | 902.76 ms | 845.22 ms | 644.26 ms | 675.67 ms |
| Edited Git, build and tests | 2,122.92 ms | 2,011.39 ms | 1,931.28 ms | 1,940.28 ms |
| Warm Git phase | 179.65 ms | 139.99 ms | 55.22 ms | 53.37 ms |
| Edited Git phase | 177.41 ms | 142.64 ms | 56.51 ms | 56.25 ms |

Six separate stock status invocations per mode used the same read-only checkout contract. Their medians were 177.42 ms off and 137.90 ms on. Host idle in those two windows was 81.79% and 84.06%. The enabled observer also ran six untraced invocations immediately after its capture, with a median of 145.12 ms. The independently timed full workload and the two standalone series retain their own sample clocks. [Standalone runs and raw stock receipts](native-push-and-fuse-gamma-receipts.tar.gz)

## FUSE reply ordering

The trace used one stock Git invocation per mode and retained all CPU records without loss. The table counts matched send-to-reply pairs from the main Git task. The archive includes the complete workspace connection, including Git's preload threads. The control trace first failed the observer parser because Linux prints the close events in two syscall-specific formats. Replacing only those representations for analysis preserved every timestamp, task and line number. The original capture and hashes are retained. [Trace analysis](../../../scripts/trace_raw_git_release.py) · [Both captures](native-push-and-fuse-gamma-receipts.tar.gz)

| Opcode | Count off | p50 / p95 off | Count on | p50 / p95 on |
|---|---:|---:|---:|---:|
| LOOKUP | 1,562 | 14 / 22 µs | 1,461 | 11 / 20 µs |
| OPEN | 1,076 | 20 / 32 µs | 1,076 | 21 / 25 µs |
| READ | 1,131 | 14 / 27 µs | 1,131 | 11 / 21 µs |
| RELEASE | 1,076 | 11 / 27 µs | 1,076 | 8 / 11 µs |
| RELEASEDIR | 183 | 10 / 13 µs | 183 | 8 / 9 µs |

Both runs matched 1,072 regular RELEASE submissions to a `close(2)` interval. The control returned after every release reply. The enabled run returned before all 1,072 replies. The close interval p50/p95 changed from 19/42 µs to 0/1 µs at the trace's one-microsecond resolution. Git submitted another FUSE request before receiving 805 of the enabled RELEASE replies. The file operation counts show that background release still sends and completes requests. [Close and request reconciliation](native-push-and-fuse-gamma.json)

All 6,471 and 5,876 observed completion-work enqueues respectively ran in hard-IRQ context on guest CPU 0 and targeted CPU 0. The VMM asserts one SPI for the Virtio-MMIO device. Linux registers one MMIO interrupt, invokes the queue callback and places the completion work on the interrupt's CPU. The main Git task issued 893 of 1,076 OPEN requests from CPU 3 in the control and 1,069 of 1,076 from CPU 0 with the flag enabled. The change in task placement also affects the individual trace timings. The captures record the handling CPU and the close/reply ordering. [Virtio-MMIO interrupt handler](https://github.com/gregkh/linux/blob/v7.3.5/drivers/virtio/virtio_mmio.c) · [Linux workqueue placement](https://github.com/gregkh/linux/blob/v7.3.5/include/linux/workqueue.h) · [Raw captures](native-push-and-fuse-gamma-receipts.tar.gz)

## Workspace interrupt routing

An owner-only probe in a separate disposable worker identified the `workspace` device as `virtio6` at `a000c00.virtio_mmio`, Linux IRQ 15 and GIC SPI 54. It matched the VirtioFS sysfs tag and device link, MMIO device-tree interrupt, and Linux IRQ action. During the first workload its counter advanced by 319,427 on CPU 0. After the probe directed that interrupt to CPU 1, the counter advanced by 320,157 on CPU 1. The other three counters for that IRQ stayed fixed in each window. The probe restored hex mask `f`, requested CPUs `0-3` and effective CPU 0, then removed its command scope. [Routing and restore receipts](native-push-and-fuse-gamma-receipts.tar.gz) · [Demand-only probe](../../../scripts/workspace-irq/main_linux.go)

Ten engine pairs per Git affinity and routing state used stock Git on the same 1,058-file fixture, with the background release flag enabled on Micropod. The fastest placement followed the interrupt CPU, and it beat unrestricted placement in all ten Micropod pairs in each state. Median unrestricted OrbStack Git was 51.08 ms and 50.71 ms across the two windows. Host idle was 82.15% and 81.98%. Exact edit controls passed through both routing states. [Paired scores and host samples](native-push-and-fuse-gamma.json) · [Raw route comparison](native-push-and-fuse-gamma-receipts.tar.gz)

| Effective workspace IRQ CPU | Unrestricted Git | Git on CPU 0 | Git on CPU 1 | Git on CPUs 0–1 | Git on CPUs 2–3 |
|---|---:|---:|---:|---:|---:|
| CPU 0 | 144.72 ms | 100.94 ms | 147.41 ms | 121.53 ms | 154.28 ms |
| CPU 1 | 146.01 ms | 144.29 ms | 101.71 ms | 131.04 ms | 148.06 ms |

These measurements establish the importance of interrupt locality for this single-job workload. The production path uses the existing IRQ and task placement defaults. A follow-up with unbound placement for the ordinary VirtioFS completion work would measure whether the benefit extends to unpinned and concurrent jobs while retaining the existing queue-drain logic. [Linux unbound workqueue](https://github.com/gregkh/linux/blob/v7.3.5/kernel/workqueue.c)

## Workspace lifecycle

Both settings passed the 16 ordinary edit observations, the held exact-mtime and mmap checks, held splice and sendfile, and the stock PID 1 controls. Separate terminal workers mounted the same tag a second time and bound the fixture through another path. The first run's immediate hard-link assertion saw the old count of one through the cached original name and two through its new alias. After the existing validity window, the retry saw equal device, inode and link count through all six paths. It also verified a held inode across atomic replacement, eight concurrent readers with 64 reads each, eight fsynced writers, and last-mount unmount and remount in both modes. Both workers shut down cleanly and their audited APFS volumes contained zero FSEvents journal files or bytes. [Correctness and mount receipts](native-push-and-fuse-gamma-receipts.tar.gz)

Both terminal probes stopped at the explicit abort step. Pinned Linux sets `no_control` and `no_force_umount` for VirtioFS, so the exact connection has no writable fusectl abort file. The probes issued no forced abort. The successful last-unmount checks covered the normal shutdown path through queue drain, connection abort and remount. [Linux mount defaults](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/virtio_fs.c) · [FUSE control filesystem](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/control.c) · [Terminal probe receipts](native-push-and-fuse-gamma-receipts.tar.gz)

## Reproduce the Image

The ARM64 builder verifies the upstream Linux 7.3.5 archive, the B5 config and its three patches, the upstream splice fix and the workspace release patch. It builds one Image with GCC 15.2.0 and GNU binutils 2.45.1. The embedded config matched the resolved B5 config byte for byte. The Image SHA-256 is `61b4e143b26039e4642f48b3819e0233f22b44f5c3e88e109cbc9c17508cc85f`. The outer launcher's receipt-writing command hit a read-only zsh variable after compilation. The Image header, embedded config, final output hashes, build log and empty builder scope independently verified the result. [Kernel builder](../../../ci/patches/build-virtiofs-workspace-release-kernel.sh) · [Pinned B5 and splice lineage](virtiofs-mutable-host.md#reproduce-the-b5-splice-backport)

```sh
JOBS=4 sh ci/patches/build-virtiofs-workspace-release-kernel.sh \
  /path/to/pinned-inputs /path/to/new-output
```

Boot the same `Image` with `virtiofs.workspace_async_release=0` and `virtiofs.workspace_async_release=1`. The stock Git trace script reads the mode from sysfs, times the same read-only Mac-index checkout and uses a bounded ftrace observer in the protected test worker. The terminal mount probe targets the owned `workspace` connection on a disposable worker after timed jobs and edit checks finish. [Stock Git tracing](../../../scripts/trace_raw_git_release.py) · [Terminal mount probe](../../../scripts/qualify_virtiofs_release_mounts.sh)
