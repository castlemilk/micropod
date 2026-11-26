### 24 November 2026 · 231.03 · Doubling Linux GRO's receive-list batch threshold

**Keep the stock threshold of eight segments.** Doubling `net.core.gro_normal_batch` to 16 halved receive-list dispatches in two fixed polls. It also held a marked short packet behind up to eight later SKB offers. The fixture measured receive-list dispatches and positions. Delivered MiB/s, elapsed latency, fresh p95/p99, wire loss and CPU/GiB were unmeasured.

**Source/fixture.** The single changed input was 8 → 16 in the original Linux 7.3.5 `gro_normal_one`, `gro_normal_list`, `gro_flush`, `gro_flush_normal` and `napi_complete_done` functions. Each pair offered identical SKBs in one ordinary NAPI poll. The marker is a singleton representing an ACK or small fresh packet on that receiving queue. Aggregate inputs represent already-completed GRO SKBs with their segment counts. There was no outstanding GRO hash-chain work, deferred IRQ, timer or concurrent reschedule. The fixture recorded every handoff into the next stack layer.

| Offered SKBs in each poll | List dispatches, 8 → 16 | Later SKBs offered before marked singleton moved up, 8 → 16 |
| --- | ---: | ---: |
| 32 one-segment SKBs, eighth marked | 4 → 2 | 0 → 8 |
| Five one-segment SKBs, first marked | 1 → 1 | 4 → 4 |
| Four pairs of a seven-segment aggregate and a singleton, first singleton marked | 4 → 2 | 0 → 2 |
| Four pairs of a 16-segment aggregate and a singleton, first singleton marked | 5 → 5 | 1 → 1 |
| One eight-segment aggregate followed by seven singletons, first singleton marked | 2 → 1 | 6 → 6 |

**Delivery.** Five matched deterministic polls retained all 61 SKBs (152 represented segments) in order per arm. Every input appeared once at handoff. The completion path dispatched every residual list; small-poll delivery remained bounded by poll completion. No statistical interval applies to deterministic positions. A second invocation reproduced the first output byte for byte.

**Next check.** Only select this setting for a separate VM trial if the current guest shows frequent short GRO receive lists. Measure the receiving queue's completed segments per SKB and list sizes alongside delivered MiB/s, drops and fresh p95/p99. The guest receive path can handle ACKs for published downloads; its list handoffs do not establish how many response bytes reached the Mac.

**Reproduction.** Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. From `docs/benchmarks/2026-11-24/batch11-gro-batch`, run `python3 -B reproduce.py /path/to/linux-7.3.5`. Five source-file digests and both segment-count call sites are verified. Script SHA-256 `d9f09ff7121751780988fe6eee6ef836d54e9066484bc8ca646a079d98e16138`, fixture SHA-256 `87319cac59f37348f491044adaef8467bfc25b5d5cbb6407ef2f982a6e5ab2b0`. First raw output `gro-first.json`, SHA-256 `622dbe21eeb93ff9652c424dbbdb614a2b8b5cf5647a4aa1ff6539b59f8f9965`.
