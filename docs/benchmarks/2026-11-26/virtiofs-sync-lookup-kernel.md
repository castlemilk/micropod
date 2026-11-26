# Synchronous virtiofs LOOKUP completion

The archived warm Git trace recorded 1,366 LOOKUP replies. All completed on guest CPU 0, and 790 requests came from other vCPUs. The 1,362 LOOKUPs with matched workqueue events waited a median of 1 µs between the IRQ queuing the worker and its execution, with 4 µs at p95 and 7 µs at p99. Median FUSE send-to-end latency was 9 µs. [Trace receipts](../2026-11-25/managed-ci-git-and-exec-receipts.tar.gz)

Linux schedules the per-queue completion worker from the virtqueue IRQ callback. `may_block` causes that worker to dispatch the individual asynchronous request to another worker. The high-priority queue separately frees `FORGET` requests. [Linux 7.3.5 virtiofs](https://github.com/gregkh/linux/blob/v7.3.5/fs/fuse/virtio_fs.c)

The experiment lets the submitting task complete a synchronous LOOKUP when it owns the only outstanding request on its queue. The IRQ takes the private waitqueue lock and wakes the requester. The requester validates and reaps the reply under the usual queue locks, then finishes it in process context. A second submission or a queue drain transfers responsibility to the completion worker. A signal or a one-jiffy wait expiry returns control to the regular FUSE wait. The full-ring handoff publishes the new backlog while the queue lock still protects the original reply. Each request queue holds one waitqueue and one ownership state. [Kernel patch](../../../ci/patches/virtiofs-sync-lookup.patch)

## Reproduce the image

The build uses the resolved 16 KiB B5 config, GCC 15.2.0 and GNU binutils 2.45.1 from Alpine. The builder verifies the upstream archive and all pinned B5 inputs, checks the patch, compiles the driver object and builds the Image. The exact original config can also be recovered from the B5 Image with the kernel's `scripts/extract-ikconfig`. [Builder](../../../ci/patches/build-virtiofs-sync-lookup-kernel.sh) · [Bounded buddy patch](../2026-11-24/gamma-ci-concurrency/bounded-buddy.patch)

```sh
JOBS=4 ci/patches/build-virtiofs-sync-lookup-kernel.sh \
  /path/to/linux-7.3.5.tar.xz /path/to/b5.config \
  docs/benchmarks/2026-11-24/gamma-ci-concurrency/bounded-buddy.patch \
  /path/to/new-output-directory
```

Boot the same Image with `virtiofs.sync_lookup_completion=0` and `virtiofs.sync_lookup_completion=1`. The default is off. The built-in parameter is readable at `/sys/module/virtiofs/parameters/sync_lookup_completion`. A direct completion in ftrace pairs `fuse_request_send` and `fuse_request_end` on the same PID and request ID, with no enclosing completion worker. Keep traced diagnostic runs separate from wall-time measurement.

The Linux ARM64 driver object and full Image built successfully. The Image SHA-256 is `b115ef1d632016e932a721ebe777d98974b5e44b0d250baa824328fc7734b31e`. The resolved config matches the B5 config SHA-256 `92e12b18d6a6e36f0d304fccba6bf8430c7809eddcf3fe9dbd9b666631a7056d`. Twenty-one host scenarios extracted the actual C paths and ran with AddressSanitizer and UndefinedBehaviorSanitizer. They covered reply validation, queue contention, full-ring backlog, teardown, signal, timeout and stale callback handling in a mock ring.

## Same-image guest trace

| Kernel parameter | LOOKUP replies | Requester completions | LOOKUP send-to-end p50 / p95 / p99 |
|---|---:|---:|---:|
| Off | 1,351 | 0 | 9 / 15 / 23 µs |
| On | 1,350 | 148 | 6 / 16 / 24 µs |

The trace window covered the Git subprocess. With the parameter enabled, 1,200 LOOKUP replies still paired with a completion worker. In both captures, all observed OPEN, READ, RELEASE and READDIRPLUS replies paired with that worker. The 148 requester completions measured 12 / 18 / 27 µs at p50 / p95 / p99. The remaining enabled-mode replies measured 6 / 14 / 23 µs. Queue exclusivity selects which requests take the new path, so these subsets describe the captured requests under each path.

In the enabled trace, 1,100 of 1,350 LOOKUP intervals overlapped another FUSE request on the same connection. All 148 requester completions were among the 250 intervals without observed overlap. The control ended every LOOKUP on guest CPU 0. With the flag enabled, 690 of 1,202 LOOKUPs completed by another task ended on CPUs 1–3. The sharing path can queue the worker from the submitting CPU. The trace shows a change in worker placement alongside the direct completions.

## Mounted Git build and host edits

| Kernel parameter | Warm HVF / OrbStack | After an edit HVF / OrbStack | HVF wins warm / after an edit |
|---|---:|---:|---:|
| Off | 809.1 / 669.5 ms | 2,077.1 / 2,139.5 ms | 0/4 / 4/4 |
| On | 864.5 / 793.0 ms | 2,259.5 / 2,416.5 ms | 0/4 / 4/4 |

The timed workload used the mounted 1,058-file checkout and summed guest Git, Go build and test durations. Each flag setting ran its own four OrbStack pairs. Host idle moved from 78.29% to 76.25% with the flag off and from 83.96% to 55.28% with it on. The settings were measured under different host loads, leaving the effect on whole-job time unresolved. Both settings passed all 16 host-edit observations.
