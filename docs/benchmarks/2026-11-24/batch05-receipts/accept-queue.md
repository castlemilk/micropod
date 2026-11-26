**24 November 2026 · 230.03 · Bounding accepts per ready listener**

Source/fixture, Darwin kqueue and the Micropod dispatch code. Changed only the maximum accepts per ready listener from 32 to eight, retaining the same owner, queues and callback. Base `7d9b565173a901cb18942e00384838da96e0ba98`, candidate source SHA-256 `d4fe208205317072e2d23bd487ec9b8c4f7d1ad48c0f1adc6b5aa7d1ed4e4d54`. Private socketpairs model the accept queues. The original named-socket setup was denied before any scored attempt and is preserved separately.

Six cases, two repetitions per arm in ABBA order, all 412 request markers per arm received their own replies and FINs. With 40 offers on a busy lease, a second lease queued after one, 20 or 40 hot offers waited behind 32 → 8 handoffs. When the sparse lease appeared first, it waited behind zero in both arms. Draining the hot queue alone required two → five nonempty polls. The two repeats agreed. These are service-order counts. Kernel-listener drops, elapsed throughput, fresh p95/p99, CPU/GiB and runnable time were unmeasured.

Retain 32 for the single-listener worker comparison. Revisit eight only if real multi-lease contention is observed. Raw-verified fixed-work output `accept-queue.json`, SHA-256 `4c09b75d915834bc52c8bb664b7fec2ae9e2a53d3dadbc87c69f0374fce17f80`. Local reproducer `run_accept_queue.py`.
