**24 November 2026 · 237.05 · Can receive-flow steering follow a service thread that changes CPUs?**

Source/fixture, Micropod analysis base `a60d203b16b24abd857e1b5c9e817636b241f850`. Compiled Linux 7.3.5's original get_rps_cpu and set_rps_cpu. On a single modeled RX queue, both arms used the same four-CPU RPS hash map, one flow and an updated global last-reader entry. The only change enabled the per-queue RFS flow table. CPU 0 was the hash target; the reader moved from CPU 0 to CPU 3 before 64 further arrivals. The FIFO model held the initial backlog and processed the same fixed packet budget per CPU before each arrival in both arms. Hardware steering was outside this fixture.

| Pending packets at migration | New packets assigned to reader CPU with RFS, out of 64, for 1 / 2 / 4 dequeues per CPU per arrival |
| ---: | --- |
| 0 | 64 / 64 / 64 |
| 8 | 0 / 58 / 62 |
| 32 | 0 / 34 / 54 |

Static RPS assigned 0/64 to CPU 3 in all cells. With RFS and an outstanding backlog, a drain rate of one kept new arrivals on CPU 0: each new packet extended the last queue tail before the head caught it. The alternate initial counter position crossed 32-bit wrap and yielded identical selections. All 1,392 packet IDs per arm left the modeled queues in order across 18 paired fixed workloads (3 depths × 3 drain rates × 2 counter positions). The fixture models FIFO service, lookup tables and a single flow with a valid last-reader entry. These branch counts have no statistical interval. No actual NIC, on-wire loss, application delivery, fresh p95/p99, CPU/GiB, runnable time or throughput was measured.

Enabling RFS can follow a moved reader when its prior CPU has drained sufficiently. An active queue can retain a flow on the old CPU for the entire observation window. Preserve stock steering. Before a real RFS trial, verify the effective flow tables, actual application CPU migrations and old-CPU backlog progress alongside per-CPU softirq work and receiver-delivered bytes.

Raw-verified local report `rfs-flow.receipt.md`. All case outcomes `rfs-flow.json`, SHA-256 `ba9ee1b76afbb0fe0953fb9f5793e6aac45f2e8199910297fe65375785f3ebf9`. Original `net/core/dev.c` SHA-256 `8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274`; Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Run `python3 -B rfs_flow.py` in batch07-sched. Use `--verify-source /path/to/linux-7.3.5/net/core/dev.c` to check the exact extracted functions.
