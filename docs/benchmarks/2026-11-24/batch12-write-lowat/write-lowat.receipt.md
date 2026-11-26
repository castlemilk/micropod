# 230.10 · Batch relay writes after a receiver falls behind

Keep ordinary write readiness for the released-VM comparison. A benchmark patch that temporarily raised the socket send threshold to 16 KiB reduced the relay's retry writes on large retained suffixes. It also postponed the first retry until the receiver had drained 16 KiB. Two historical mixed Gamma profiles recorded a partial or blocked write on just 0.01036% and 0.05268% of write attempts. Those rates put a live worker-count comparison ahead of this tuning.

## Measured on the Darwin data owner

The fixed-work harness drove the pinned Micropod C relay through its real kqueue data owner on two anonymous Unix stream socketpairs. For the rows below, the sender initially faced a full 64 KiB destination and the receiver released 4 KiB per step. Stock inherited a 2 KiB send low-water mark. The fixed treatment requested a 16 KiB socket threshold throughout. The adaptive treatment raised it only for a retained suffix of at least 16 KiB, checked the socket buffer and restored the previous setting for a short remainder or upon completion.

| Bytes pending | Retry writes, stock / fixed / adaptive | Receiver drain at first progress, KiB | Receiver drain at final write, KiB |
| ---: | ---: | ---: | ---: |
| 1 KiB | 1 / 1 / 1 | 4 / 16 / 4 | 4 / 16 / 4 |
| 20 KiB | 5 / 2 / 2 | 4 / 16 / 16 | 20 / 32 / 20 |
| 32 KiB | 8 / 2 / 2 | 4 / 16 / 16 | 32 / 32 / 32 |

The receiver also admitted a 12 KiB prefix of a 32 KiB write before backpressure. For its 20 KiB remainder, retries fell from five to two, with the same 20 KiB of additional drain before the final write. Each 8 KiB send-buffer control kept its inherited socket setting. The adaptive treatment restored a pre-existing 8 KiB low-water mark as well. Each freely draining payload needed zero retries. Every case verified byte order, the reverse-direction marker, both EOFs and lease retirement, including a FIN queued immediately behind the payload.

A separate implementation set the per-filter kqueue flag `NOTE_LOWAT` instead. With the inherited socket setting it still needed eight retries on the blocked 32 KiB case. Combined with a fixed 16 KiB socket threshold the relay attempted 3,074 retries in the bounded polling harness, versus two with the socket threshold alone. The harness invokes four drain calls after each receiver step, so that count describes repeated readiness in this workload. Discard that implementation.

## Scope and replay

Each of three compiled builds ran the same 15 deterministic cases. Two clean compilations reproduced the JSON byte for byte. A third, built with AddressSanitizer and UndefinedBehaviorSanitizer, reproduced all 45 observations. The experiment measured retry work and bytes of receiver progress. TCP throughput, scheduled latency, CPU/GiB and VM runnable time require a timed TCP run. Adaptive socket option lookups and changes also cost system calls.

The uncapped VM mixed lease recorded 153 partial or blocked writes in 1,476,438 attempts. A second mixed lease recorded 169 in 320,835. These counters cover both directions and include retries that blocked again. The archives do not identify which of those writes had a 16 KiB suffix. [Prior VM accounting](../../2026-11-23/gamma-throughput-gap.md) · [Second mixed lease](../../2026-11-21/gamma-published-profile.json.gz)

Run `python3 -B run.py | cmp - result.json` from this directory on Darwin. For the instrumented builds, run `python3 -B run.py --sanitize`. The driver extracts the C implementation, header and shared fixture from commit `2e9b37c1e68334c443d71b729f0bd6334d824ddd` before applying each benchmark-only patch in a temporary directory. Receipt SHA-256 `4ee209a8aafcc94d3115e9e52ba84508d2fc0cd5ad065c17608371b25e9fa317`. [Measurements and source hashes](result.json) · [Adaptive socket patch](adaptive-socket.patch) · [Per-filter patch](suffix-lowat.patch) · [Workload](write_lowat.c) · [Reproducer](run.py)
