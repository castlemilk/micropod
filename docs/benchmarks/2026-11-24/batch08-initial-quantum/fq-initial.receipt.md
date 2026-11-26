**24 November 2026 · 231.08 · Does fq initial credit delay a short flow behind a new bulk flow?**

Local fixture and raw evidence revision `3ecbb6787b6dcba35860e38fe99c7aabf0ad8370`. Local report `fq-initial.receipt.md`.

Source/fixture. Micropod base `922e862694ae6d6e9cb3cc9fcfd6c0a86d9ada21`. Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Changed only `initial_quantum` from 15,140 B to 3,028 B. Ordinary quantum stayed at 3,028 B, matching the control's ordinary credit from the archived service fq readback. The fixture compiled the original flow classifier, new/old list selection and dequeue policy. It supplied three sockets in one eligible band with unlimited pacing, fixed eligible timestamps and FIFO packets. One existing bulk flow had 32 × 1,514 B queued and ordinary credit. A newly classified bulk flow had 32 × the selected SKB size queued. One newly classified flow added a 256 B response at the specified point.

| New bulk SKB | Response added after this many dequeues | Other packets dequeued before the response, control → candidate | Qdisc bytes ahead, control → candidate |
| ---: | ---: | ---: | ---: |
| 1,514 B | 0 | 10 → 2 | 15,140 → 3,028 |
| 1,514 B | 1 | 9 → 1 | 13,626 → 1,514 |
| 1,514 B | 12 | 0 → 0 | 0 → 0 |
| 63 KiB | 0 | 1 → 1 | 64,512 → 64,512 |
| 63 KiB | 1 or 12 (two separate pairs) | 0 → 0 | 0 → 0 |

When both new flows were queued before dispatch with 1,514 B bulk packets, smaller initial credit advanced the established flow's first packet from position 12 to 4 and moved the newly classified bulk flow's last packet from position 55 to 63. Each arm drained all 65 packet identities per workload with per-flow order verified. Six fixed workload pairs, 12 first attempts, 390 packets per policy. This deterministic comparison supplies exact dequeue counts. It omits device service time, pacing delays and driver backpressure. End-to-end delivered throughput, loss, fresh p95/p99, CPU/GiB and runnable time were unmeasured.

**Verdict.** Smaller initial credit helps a short flow in the tested overlap with small bulk packets. With 63 KiB buffers the first bulk packet alone consumed either credit allowance and the short flow saw no improvement. Keep the stock control. First measure bulk packet sizes and overlap of newly active flows at the actual service qdisc. A live initial-credit comparison needs the application delivery and latency guardrails.

Raw-verified local `fq-initial.json`, SHA-256 `ae2fb27caa0ece9e20bfe49f36d88bb64cf34ad803db1f38c53d8092d65801fd`. It retains every dequeue order. Reproduce from the pinned Linux source with `python3 -B fq_initial.py LINUX_7_3_5_TREE`. A second compile and replay reproduced the exact JSON.
