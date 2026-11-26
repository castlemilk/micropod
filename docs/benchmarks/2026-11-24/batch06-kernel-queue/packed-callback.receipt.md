**24 November 2026 · 231.02 · Immediate versus batched virtio TX completion notifications**

Source/fixture, Micropod base `17bcd4355234b11da3a7a1da2ded52f4dc20f5d1`. The Linux 7.3.5 virtio-net TX NAPI send path can arm a delayed callback after a kick. We compared that packed-ring arm with the same kernel's immediate prepare-and-poll arm. Both used EVENT_IDX, a 256-slot ring and the same completed descriptors. Each buffer occupied one descriptor. The sequential device model completed descriptors in order and the guest reclaimed all outstanding completions as soon as a requested notification occurred. This isolates the notification policy and its interrupt-count tradeoff.

| Outstanding descriptors | First notification after completions, delayed → immediate | Total modeled notifications, delayed → immediate |
| ---: | ---: | ---: |
| 1 | 1 → 1 | 1 → 1 |
| 16 | 13 → 1 | 2 → 16 |
| 32 | 25 → 1 | 3 → 32 |
| 128 | 97 → 1 | 4 → 128 |
| 256 | 193 → 1 | 4 → 256 |

Six occupancies (1, 4, 16, 32, 128 and 256), each at three ring positions including wrap crossings. All 18 fixed pairs reclaimed all buffers, 1,311 descriptors/arm. Ring position left the counts unchanged. With 32 outstanding descriptors, immediate notification removed 24 additional completions of wait for the first reclaim, at a cost of 29 additional modeled notifications. No independent replications or sampling interval apply to these deterministic cases. The model excludes host scheduling, concurrent polling, RAM ordering races and device-side batching. Packet delivery, actual IRQ/NAPI wakeups, throughput, fresh p95/p99, CPU/GiB and runnable time remain unmeasured.

Retain delayed rearming in the control. Before testing early notification on a real guest, verify packed ring, EVENT_IDX, effective TX NAPI and the number of descriptors outstanding when completion notification is armed. Check whether receiver progress stalls while completed descriptors wait for a guest wakeup. A path that services completion via another poll can have a smaller delay and fewer IRQs than the fixture.

Raw-verified local report `packed-callback.json`, SHA-256 `63552ac6388bbc5b29a3e5ea8d2656d279df8e0305e200d3f628094518ee2bb0`. Extract `drivers/virtio/virtio_ring.c` and `include/uapi/linux/virtio_ring.h` from Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Run `python3 -B packed_callback.py LINUX_TREE`. The driver checks both member hashes and compiles their original callback, descriptor, poll, and event-index functions against the local fixture.
