**24 November 2026 · 231.08 · Would doubling the stock TCP Small Queues cap admit another send?**

Source/fixture. The pinned Linux 7.3.5 archive SHA-256 is `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Micropod analysis base `ad9d174eda5eb499e0e15675829e21a00d836f84`. The fixture compiles the original `tcp_small_queue_check` body from `net/ipv4/tcp_output.c` SHA-256 `b55846bf35be5799cc19318c9215aa1b8a9a4881f8e3794cf5dc08b8aa4ea5b7`. The source initializes the cap to 4 MiB and the socket's pacing shift to 10. Normal transmission calls this predicate with factor zero. Its cap calculation applies with fq as well, and the predicate has no qdisc selector.

Changed only the per-network-namespace `tcp_limit_output_bytes` from its source default of 4 MiB to 8 MiB. For each pair, held fixed the per-socket pacing rate, SKB allocation charge, socket write-memory charge, retransmit-queue length and completion readback. The configured TX delay was zero. SKB allocation sizes of 2,048 and 69,632 B model a small and larger GSO allocation. Pacing rates and memory charges are fixture inputs. They have no live stock-socket readback.

| Per-socket pacing rate | Stock stopped sends | 8 MiB stopped sends | Changed decisions |
| --- | ---: | ---: | ---: |
| 128 MiB/s | 14/16 | 14/16 | 0/16 |
| 1 GiB/s | 12/16 | 12/16 | 0/16 |
| 4 GiB/s | 10/16 | 10/16 | 0/16 |
| 6 GiB/s | 10/16 | 6/16 | 4/16 |
| 8 GiB/s | 10/16 | 2/16 | 8/16 |

Each cell has two SKB charges and eight fixed socket memory charges, with a retransmit queue containing three entries. Four additional pairs exercised queue-depth and completion boundaries. At a 6 GiB/s pacing rate and a 5 MiB socket charge, zero or one retransmit entries let both arms proceed. Three entries stopped the stock arm while the candidate passed. If a completion reduced the memory charge to exactly 4 MiB on recheck, stock also passed despite having set the throttled bit. The bit alone cannot count sends actually stopped. In all, 13/84 paired cases changed the return value. All 168 first evaluations are recorded, 42 pairs per order. These are fixed cases, with no sampling interval.

**Verdict.** Keep the 4 MiB control. With shift 10 and the tested SKBs, the compiled gate used the larger of twice the SKB allocation and the socket's pacing rate divided by 1,024, limited by the configured cap. Up to 4 GiB/s of pacing on **one socket**, the 4 MiB cap could not make the outcome more restrictive than 8 MiB. Aggregate application throughput across 32 streams does not establish a per-socket kernel pacing rate. Before a VM trial, establish repeated true stops with more than 4 MiB charged after recheck, a queue of at least two outstanding retransmit entries, and a pacing/size-derived limit above 4 MiB. The fixture contains no transport delivery, drop, fresh p95/p99, CPU/GiB, runnable-time or VM throughput measurements.

Raw-verified local report `tsq.receipt.md` and all first attempts `tsq-first.json`, SHA-256 `417e5bc54886d8ab62ccc4d201f1fd523b21a2eb6e30998a5bbbf6bb490656f3`. Reproduce from the report directory with `python3 -B reproduce.py LINUX_7_3_5_SOURCE NEW.json`. The replay checks each observed decision and records the pinned source, compiler and fixture hashes.
