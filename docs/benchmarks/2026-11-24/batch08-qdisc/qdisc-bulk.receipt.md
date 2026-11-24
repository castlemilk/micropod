**24 November 2026 · 231.08 · Does one-queue qdisc batching change virtio byte admission or notification count?**

Source/fixture. Micropod base `c9ec734fc9692e31ca99122fe13c9b71a5478c80`, pinned Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. The control dispatched one SKB per list. The candidate used Linux’s original single-TX-queue bulk-dequeue function with the actual available DQL bytes and a fixed budget of 64. Both ran the original list-transmit loop and virtio/BQL functions at TX NAPI weight 64. The modeled FIFO offered 32 equal SKBs to an empty 256-descriptor ring, with one descriptor per SKB, a 524,288-byte initial allowance, no device completions and a device accepting each requested notification.

| SKB size | Submitted per arm | Bytes charged per arm | Device notifications, single → batched |
| ---: | ---: | ---: | ---: |
| 1,460 B | 32 | 46,720 B | 32 → 1 |
| 16 KiB | 32 | 524,288 B | 32 → 1 |
| 32 KiB | 17 | 557,056 B | 17 → 2 |
| 63 KiB | 9 | 580,608 B | 9 → 1 |

With 63 KiB buffers the first eight left 8 KiB of allowance. The ninth crossed the byte allowance and both arms stopped there. The bulk list needed one notification to cover those nine admissions. At 32 KiB the first list used the allowance exactly, then the next single buffer crossed it. Four fixed input pairs, eight first attempts. The deterministic fixture has no sampling interval or statistical uncertainty. The 15 and 23 unsubmitted SKBs in the last two rows stayed upstream. Receiver delivery, TCP or device losses, fresh p95/p99, CPU/GiB, runnable time and device wake latency remain unmeasured. Real devices may suppress notifications and complete descriptors while transmitting.

**Verdict.** A lower kick count can be explained by list grouping alone even when admitted and charged bytes are identical. Keep the existing queue policy. On an admitted diagnostic, pair per-queue kick deltas with actual charge and receiver progress before attributing a throughput gain to batching. This counterfactual single-buffer control isolates grouping and does not establish the serving guest's qdisc policy.

Local fixture and raw evidence revision `19d4f8b9bc00404d829759754ae398938a0daccc`. Raw-verified local `qdisc-bulk.json`, SHA-256 `500e3ec19b740d1c36a73e334f02e5226db28b3fa48e90323db87411e0723fe8`. Each row retains all dequeue groups and cumulative ring/charged bytes. Reproduce using `python3 -B qdisc_bulk.py LINUX_7_3_5_TREE`. The JSON pins six kernel source members, the reused fixture, both new source files, the compiled fragments and the compiler.
