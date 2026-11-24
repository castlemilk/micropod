**24 November 2026 · 231.08 · Does faster fq credit refill help a short reply when an established bulk flow returns?**

Source/fixture on Micropod base `ad9d174eda5eb499e0e15675829e21a00d836f84`. Compiled the unmodified Linux 7.3.5 fq enqueue, socket classification, list selection and dequeue functions from verified archive SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Only the detached-flow refill delay changed, from the stock 40 ms to 4 ms. The fixture used 250 Hz, matching the archived base config, and fixed ordinary and new-flow credits at 3,028 and 15,140 bytes respectively. One existing flow had 64 × 1,514-byte buffers. A second flow sent 15,000 bytes, drained and detached with 140 bytes of credit. That same socket then returned with six buffers ahead of a newly active socket's 256-byte response.

| Idle time | Returning buffer size | Returning buffers dequeued before short reply, stock → candidate |
| --- | ---: | ---: |
| 4 ms | 1,514 B | 1 → 1 |
| 8 or 40 ms | 1,514 B | 1 → 2 |
| 44 ms | 1,514 B | 2 → 2 |
| 4, 8, 40 or 44 ms | 63 KiB | 1 → 1 |

At the two intermediate waits the earlier refill gave the returning socket 3,028 bytes of credit against 140 bytes on stock. With small buffers that placed 3,028 bytes ahead of the short response instead of 1,514. A 63 KiB buffer alone exhausted either allowance. The comparison used eight fixed workload pairs, four per arm order. All 16 first arms drained 72 packets each with each flow's order checked. Each arm order and subsequent dequeue sequence is retained. The supplied idle gaps and sizes cover specified cases and supply no population estimate. Device service, application loss, fresh p95/p99, throughput, CPU/GiB and runnable time were unmeasured.

**Verdict.** Keep the stock refill delay. Earlier replenishment favored the returning bulk sender at the expense of the separate short response in two of eight cases. For a target run, measure the actual size of service buffers and the idle gaps of returning sockets before spending a VM comparison on faster refill.

Raw-verified local report `refill.receipt.md`. Raw `refill.json`, SHA-256 `293883b2aa452df0cdea6fabddf07d5ef6a31b69e1db2fe09eb5922d94ffcb45`. Reproduce from the report directory with `python3 -B reproduce.py LINUX_7_3_5_TREE refill`. A second compilation and replay reproduced the raw bytes.
