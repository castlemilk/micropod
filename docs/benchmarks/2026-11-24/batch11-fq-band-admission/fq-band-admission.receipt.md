# Fresh-reply priority and fq admission with 32 bulk streams

24 November 2026 · castlemilk/micropod #231 · 231.08, fq limits, retransmit timers and in-flight windows · source/fixture · raw verified locally.

**Keep priority 0 for this admission hypothesis.** Moving a fresh reply from priority 0 to 6 admitted the same single packet in each arm when the 32 bulk flows were all at their per-flow limit. Those flows alone can account for 3,200 of the band's 10,000 queue slots. The positive control shows when separation does help. A full default-priority band rejected the fresh reply, and the other band admitted it. This experiment covers enqueue admission. Dequeue order and fresh latency remain open.

| Queue state before the probe | Ordinary priority 0, band 1 | Changed priority 6, band 0 |
| --- | --- | --- |
| 32 bulk flows × 100 skbs, separate empty fresh flow | Admitted | Admitted |
| 100 bulk flows × 100 skbs, separate empty fresh flow | Rejected at band limit | Admitted |
| 32 bulk flows × 100 skbs, probe on one of the full flows | Rejected at flow limit | Rejected at flow limit |

Micropod base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. The direct reply path requests fq on the service interface when its root is implicit noqueue. The mixed workload specifies 32 bulk downloads and 240 scheduled fresh requests. The fixture isolates a single fresh arrival with 32 bulk sockets, one fq flow per socket, and no additional competing flows. Its queue depths are deliberately saturated synthetic inputs. They were not read from a serving VM.

The compared variable was the incoming packet's priority (0 → 6). The driver compiled Linux 7.3.5's stock priority table, mapper, and band and per-flow enqueue checks from `net/sched/sch_generic.c` and `net/sched/sch_fq.c`. It supplies a classified socket in a busy queue, a zero packet timestamp and stock limits. It records each probe in a fresh process. One deterministic comparison, three paired queue states, six first probe outcomes. No statistical interval applies. Units are queued socket buffers (skbs) and admitted/rejected probes. No wire drops, delivered MiB/s, fresh p95/p99, CPU/GiB or runnable time were measured.

**Next check.** Preserve ordinary priority for the stock arm. If a job later records default-band drops on the serving interface, capture the effective priority map, both queue limits and per-band versus per-flow drop counters before timing a priority change. Assess dequeue latency separately.

Reproduce in this directory with `python3 -B reproduce.py`. It verifies both local source hashes before compiling. Source copies match the kernel files previously read from the pinned Linux 7.3.5 archive and the verified `gregkh/linux` v7.3.5 tag. Raw observations are in `first-attempt.json` (SHA-256 `20d57e54da9b936b14aff496dbbfad917418ea570bca93d903397fe630b68b90`). The report and raw receipt are local.
