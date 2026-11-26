**24 November 2026 · 231.08 · Can disabling Linux TCP autocorking advance the first short response?**

Source/fixture on Micropod base `ad9d174eda5eb499e0e15675829e21a00d836f84`. Compiled unmodified Linux 7.3.5 `tcp_should_autocork` and `tcp_push`. The verified source initializes `tcp_autocorking=1`. The candidate changed only this setting to 0. Each arm had a nonempty write tail, NODELAY, no MSG_MORE and a 1,460 B MSS. Ten fixed socket states ran once under each policy, five in each order. The measurement counted calls to the pending-frame push function and increments of the autocork statistic. The fixture returned hard-coded socket state to the external helpers. The completion-race case supplied a lower socket-memory charge on the second read.

| Socket state | Stock calls to push pending frames | Disabled calls | Stock autocork events |
| --- | ---: | ---: | ---: |
| First 17 B, empty retransmit queue, with or without extra memory charge (two pairs) | 1 each | 1 each | 0 each |
| Reused 17 B or 32,000 B of a 64,000 B bulk goal, prior data in flight and extra charge (two pairs) | 0 each | 1 each | 1 each |
| Partial bulk, extra charge already flagged as throttled | 0 | 1 | 0 |
| Partial bulk, completion clears extra charge between reads | 1 | 1 | 1 |
| Full bulk goal, charge at threshold, noncollapsible buffer, or empty retransmit queue after earlier data was acknowledged (four pairs) | 1 each | 1 each | 0 each |

The archived Gamma diagnostics provide workload context. Each row below subtracts the same service namespace's `/proc/net/netstat` before snapshot from its after snapshot. The historical control and trial were different paths in the earlier VM study. Its release capture records Linux 6.18.35, while the two namespace counter snapshots have no individual kernel identity attached. No archived arm changed the autocork setting. The accompanying traces each used 32 bulk streams and 160 fresh requests with zero reopens and complete phase samples. Their measurement intervals sit inside the wider namespace snapshots.

| Historical service scope | Δ TCPAutoCorking | Δ TCPOrigDataSent | Events per million original data segments |
| --- | ---: | ---: | ---: |
| `diagnostics/control` | 621 | 14,121,027 | 43.98 |
| `diagnostics/trial` | 744 | 14,217,491 | 52.33 |

**Verdict.** Keep stock. Switching autocorking off could advance the push call on eligible reused sockets, while a first response with an empty retransmit queue already advanced in both arms. A newly counted event can still push on the same invocation, and a socket already throttled can defer without a new count. The historical namespace totals therefore cannot attribute a bulk stall or quantify its duration. Measure per-service-socket deferrals, completion and receiver progress in the same window before attempting a timed sysctl comparison. No packets were sent by the source fixture. The A/B delivery, losses, throughput, fresh p95/p99, CPU/GiB and runnable-time effects remain unmeasured.

Raw-verified local report `autocork.receipt.md` and `autocork.json`, SHA-256 `b6e9aede8291070feba5a5cf75808f518823e8ad2b8c084869ab97d40482eecc`. The raw file preserves all 20 fixture arms, the same-scope absolute values and original netstat text hashes. The historical input `gamma-mixed-path.json.gz` has SHA-256 `09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a`. Reproduce from the report directory with `python3 -B reproduce.py LINUX_7_3_5_TREE`. An independent compile and replay reproduced the raw file byte-for-byte.
