**24 November 2026 · 231.08 · Does fq's CE counter measure newly marked IPv4 packets?**

Source/fixture on Micropod base `ad9d174eda5eb499e0e15675829e21a00d836f84`. Compiled Linux 7.3.5's original fq enqueue and dequeue functions, IPv4 ECN marking and checksum update from verified archive SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Only the qdisc's CE threshold changed, from its stock 4,294,967,295,000 ns to 2,000,000 ns. Each workload dequeued a 1,514-byte test buffer with a complete IPv4 header ahead of an on-time background buffer. Using an eligible background flow put the packet on the flow scheduler. The original ECN bits and age past the supplied transmit timestamp were fixed within each pair.

| IPv4 ECN at enqueue | Candidate counter increments across four ages | Headers newly marked CE |
| --- | ---: | ---: |
| Not-ECT | 2 | 0 |
| ECT(1) | 2 | 2 |
| ECT(0) | 2 | 2 |
| Already CE | 2 | 0 |

The candidate counted the 2,000,001 ns and 4,000,000 ns dequeues in every row. It counted neither the 1,000,000 ns nor the exact 2,000,000 ns case. Stock produced zero increments and zero new marks. All 16 fixed pairs ran, eight per arm order. Both buffers drained in all 32 arms. The DSCP bits survived and an independent full-header checksum validated every foreground IPv4 header. These constructed ages and codepoints have equal representation by design. Their frequency on the target is unknown. No client, wire loss, throughput, fresh p95/p99, CPU/GiB or runnable time was measured.

**Verdict.** The candidate reported eight threshold exceedances and produced four new CE marks. A qdisc counter alone cannot establish how many published-path packets newly signaled congestion. Keep stock. Before proposing a live marking change, verify ECN negotiation and attribute pre-existing CE, ECT-capable traffic and newly marked packets to the service flow.

Raw-verified local report `mark.receipt.md`. Raw `mark.json`, SHA-256 `69e2cc3c09c0a58a115e0be8f39dea1f5460f5d5390a94c28b184288473691b7`. Reproduce from the report directory with `python3 -B reproduce.py LINUX_7_3_5_TREE mark`. A second compilation and replay reproduced the raw bytes.
