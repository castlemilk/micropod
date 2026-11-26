# VirtioFS completion locality on the workspace share

Enabling submitter-CPU completion increased median warm stock Git status from 129.20 to 150.45 ms. The eight-job stock Git wave took 310.93 ms with the switch off and 315.89 ms with it on. The four engine pairs per setting support keeping the switch off. [Scorecard](workspace-queues-and-native-buildx-gamma.json) · [Raw receipts](workspace-queues-and-native-buildx-gamma-receipts.tar.gz)

The workspace Virtio-MMIO device receives ordinary file operation replies on one request queue. The guest completes those replies in process context through Linux's per-CPU workqueue. In an earlier routing experiment, the fastest CPU for a pinned Git job followed the interrupt from CPU 0 to CPU 1. This experiment moves completion work toward the CPU that submitted the request. [Interrupt routing experiment](virtiofs-workspace-async-release.md#workspace-interrupt-routing) · [Linux workqueue placement](https://github.com/gregkh/linux/blob/v7.3.5/include/linux/workqueue.h)

## Completion dispatch

The candidate applies to the single normal request queue of the exact `workspace` tag. A successful foreground submission that expects a reply publishes its CPU after descriptor and FUSE accounting, ahead of the normal notification. The interrupt callback uses the hint when the CPU is online. A device already polling the ring can reply before the hint is published, so every IRQ can still schedule completion through Linux's regular per-CPU dispatch. The worker clears the hint when it takes the ring lock to harvest replies. Queue stop also clears the hint before reuse. [Kernel patch](../../../ci/patches/virtiofs-workspace-local-completion.patch) · [Pinned VirtioFS source](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/virtio_fs.c)

Both modes use the same work item on `system_percpu_wq`. Linux serializes that item even when successive notifications select different CPUs. Reply validation, asynchronous request callbacks and queue drains use the existing process-context path. Linux can move the pending work if the requested CPU goes offline after the check. The measured workers kept all four vCPUs online. [Workqueue non-reentrance conditions](https://github.com/gregkh/linux/blob/v7.3.5/Documentation/core-api/workqueue.rst#non-reentrance-conditions) · [Linux CPU hotplug handling for queue_work_on](https://github.com/gregkh/linux/blob/v7.3.5/kernel/workqueue.c)

## Unpinned stock Git

Each setting ran four alternating Micropod and OrbStack pairs on the same 1,058-file Mac-authored checkout. The single-container job used 2 CPUs and 1,536 MiB for Git, Go build and Go tests. Each eight-container wave shared a read-only checkout, gave each container 0.5 CPU and 256 MiB, and recorded overlap and empty Git output for all 32 status invocations per engine and setting. Aggregate sampled host idle ranged from 78.93% to 79.64% for single jobs and 67.44% to 70.85% for eight-job waves. These are ambient runs.

| Median | Micropod off | Micropod on | OrbStack in off window | OrbStack in on window |
|---|---:|---:|---:|---:|
| Warm Git status | 129.20 ms | 150.45 ms | 52.92 ms | 53.92 ms |
| Warm Git, build and tests | 828.00 ms | 860.10 ms | 678.09 ms | 672.53 ms |
| Edited Git status | 141.50 ms | 127.74 ms | 55.19 ms | 56.51 ms |
| Edited Git, build and tests | 2,052.58 ms | 2,035.89 ms | 2,013.26 ms | 1,979.21 ms |
| Eight Git jobs, guest wave | 310.93 ms | 315.89 ms | 142.06 ms | 142.11 ms |
| Eight Git jobs, host to last result | 316.75 ms | 322.41 ms | 150.06 ms | 150.06 ms |

The median Micropod-to-OrbStack ratio for paired full edited jobs rose from 1.021 to 1.029. The eight-job Micropod per-job median rose from 294.95 to 302.03 ms. Both arms used the same `220f7580` Image, `4b25f7d3` VMM and `e00d6da9` guest runner, with one workspace request queue and asynchronous release enabled. The separate four-queue VMM experiment used the earlier `61b4e143` kernel Image, whose sysfs exposed the asynchronous release flag alone.

## CPU 1 diagnostic

Two separate captures pinned stock Git to CPU 1 to exercise completion away from the interrupt. Both traces reported zero loss. The interrupt-side enqueue ran on CPU 0 for every matched main-thread operation below. With the switch off, the workqueue picked CPU 0 for every reply. With it on, the counts show where the requested pool, worker and reply all moved to CPU 1. One reply of each operation completed on CPU 3 in a worker invocation shared with a trace-observer request. The remaining replies used the stock dispatch. [Paired raw traces and dispatch analysis](workspace-queues-and-native-buildx-gamma-receipts.tar.gz) · [Linux workqueue trace fields](https://github.com/gregkh/linux/blob/v7.3.5/include/trace/events/workqueue.h)

| Git operation | CPU 1 replies off | CPU 1 replies on | Send to reply p50 / p95 off | Send to reply p50 / p95 on |
|---|---:|---:|---:|---:|
| LOOKUP | 0 / 1,423 | 1,405 / 1,407 | 10 / 17 µs | 20 / 26 µs |
| OPEN | 0 / 1,076 | 1,075 / 1,076 | 18 / 23 µs | 27 / 34 µs |
| READ | 0 / 1,131 | 957 / 1,131 | 14 / 22 µs | 22 / 27 µs |

The median and p95 workspace enqueue-to-worker delay rose from 2 / 2 µs to 10 / 13 µs. Four separate untraced CPU 1 runs per setting put median stock Git at 143.47 ms off and 152.79 ms on.

## Workspace correctness

Both settings passed ordinary edit visibility, held exact-mtime reads, shared mappings, held splice and sendfile, and four stock Docker PID 1 checks. Every Micropod material run read the expected bytes on its first post-edit observation. Each scored worker finished with an empty container scope. [Device and stock-client receipts](workspace-queues-and-native-buildx-gamma-receipts.tar.gz)

Both diagnostic workers also passed same-tag mounts, ordinary binds, hard-link revalidation, and held-inode reads across atomic replacement. Each verified 32 live sysfs flips while eight clients were active, with 128 byte checks and an fsynced write per client. The guest restored the initial flag, drained the last workspace mount, remounted, and read the expected bytes. All four scored and diagnostic workers shut down cleanly. The read-only APFS audits found zero FSEvents journal files and bytes on each worker. [Live switch, remount and retirement receipts](workspace-queues-and-native-buildx-gamma-receipts.tar.gz)

## Reproduce the Image

The builder verifies the pinned Linux 7.3.5 archive, resolved B5 configuration, B5 patches, splice backport and workspace asynchronous-release patch. It then applies the completion patch and checks the result with `checkpatch.pl`. The ARM64 Image SHA-256 is `220f7580341241f49c94c1530da9d623610728e5f197ce1175d52eb0a99b7a25`. Its embedded configuration matches B5. The first build stopped at two missing memory-barrier comments before compilation. The rebuilt patch documents both barriers, passed checkpatch without warnings and built with GCC 15.2.0 and GNU binutils 2.45.1. [Kernel builder](../../../ci/patches/build-virtiofs-workspace-local-completion-kernel.sh) · [Pinned input lineage](virtiofs-workspace-async-release.md#reproduce-the-image)

```sh
JOBS=4 sh ci/patches/build-virtiofs-workspace-local-completion-kernel.sh \
  /path/to/pinned-inputs /path/to/new-output
```

For a matched private test, boot that Image with `virtiofs.workspace_async_release=1` and either `virtiofs.workspace_local_completion=0` or `virtiofs.workspace_local_completion=1`. The completion flag defaults to zero. The guest parameter `/sys/module/virtiofs/parameters/workspace_local_completion` reports `N` or `Y` and permits a privileged owner to change the setting for subsequent dispatch. Keep the same CLI, VMM, initrd, guest runner, ARM64 container image, Git index and resource limits across the two settings.
