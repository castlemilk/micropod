# 231.03 · Linux NET_RX softirq time budget

Keep the stock 8,000 µs time budget. In the compiled action, a 12,000 µs budget let one CPU poll four additional owners when the deadline bound. With a single saturated owner, Linux scheduled the next softirq after one poll under both settings. The fixture supplies no evidence for a publication throughput improvement. [Issue #231](https://github.com/castlemilk/micropod/issues/231)

**Setter and effective clock.** The archived Gamma release kernel uses 250 Hz, giving a 4,000 µs tick. The source initializes both the stock budget and its minimum to two ticks. Starting each write from stock, 2,000, 4,000 and 7,999 µs returned `-EINVAL` and read back as 8,000. A write of 8,001 succeeded and read back exactly, while the action scheduled the same three-tick deadline as 12,000. The separate packet budget stayed at 300.

| Controlled poll sequence | Polls at 8,000 / 12,000 µs | Simulated elapsed at 8,000 / 12,000 µs | What ended the action |
|---|---:|---:|---|
| 32 owners with 1 work unit per 1,000 µs poll, starting at a tick | 8 / 12 | 8 / 12 ms | Time limit, with 24 / 20 owners pending |
| Same sequence, starting 3,500 µs into a tick | 5 / 9 | 5 / 9 ms | Time limit, with 27 / 23 owners pending |
| 16 saturated owners, 64 work units per 100 µs poll | 5 / 5 | 0.5 / 0.5 ms | The packet budget was checked after 320 units |
| One saturated owner | 1 / 1 | 0.1 / 0.1 ms | The repoll moved to the next softirq |
| One lightly loaded owner | 1 / 1 | 0.1 / 0.1 ms | The queue drained |
| One 12 ms poll with a single work unit | 1 / 1 | 12 / 12 ms | The deadline was checked after the poll returned |

The 12 ms poll incremented `time_squeeze` under both settings even though the queue drained. The single saturated owner scheduled more work with a zero `time_squeeze` delta. A live follow-up needs poll counts and pending owners alongside the softnet counter to attribute a difference to this limit.

**Evidence.** The driver verifies the archived release config and compiles the full Linux v7.3.5 `net_rx_action`, its applicable tick conversion and the integer sysctl conversion against a userspace fixture. Poll duration, work, saturation and initial owners are inputs. The fixture advances a deterministic clock and models identical owners, without concurrent arrivals, RPS traffic or a VM. Delivered throughput, CPU/GiB and sibling p95/p99 remain unmeasured. Earlier #231.03 controls changed the driver poll weight, deferred device interrupts or GRO batching. This trial changes the per-action deadline across scheduled owners. [Archive and 36 observations](net-rx-budget.json) · [Source pins and extraction](extract.py) · [Fixture](probe.c)

Replay from this directory with `python3 -B reproduce.py | cmp - net-rx-budget.json`. To verify the excerpt against a full Linux v7.3.5 source tree or the five pinned blobs, add `--kernel-source /path/to/source` after `reproduce.py`. The source-verified and embedded-excerpt runs produced identical JSON. An additional Clang address and undefined-behavior sanitizer run completed all 36 cases.
