**24 November 2026 · 230.03 · A second bulk turn before the next kqueue poll**

Local/host-only on Darwin 25.5.0 arm64. Micropod source revision `ad9d174eda5eb499e0e15675829e21a00d836f84`, stock `PublishedTCP.c` SHA-256 `f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee`. The stock dedicated relay owner returns to kqueue after serving each ready set. The candidate spends one more event from the same callback budget when a genuine single-event poll reports a classified bulk socket with at least 512 KiB readable. The candidate keeps the stock 256 KiB read size and checks for closure or a pending write before making the extra turn. The callback normally has 128 events and polls up to 24 at a time.

Private Darwin stream socketpairs exercised the production kqueue, pump and half-close path. Each bulk flow first delivered a 16 KiB classification payload. A separate connection either remained quiet, had its one-byte reply ready before poll one, or made it ready immediately after the first successful bulk write. A total of eight fixed workloads ran in counterbalanced pairs with two repetitions per workload, 32 first attempts overall. Both repetitions agreed in every cell. The table excludes the identical final empty poll.

| Ready bulk flows and payload | Fresh reply | Nonempty polls, stock → candidate | Additional bulk bytes forwarded after the fresh byte became ready and before its relay write, stock → candidate |
| --- | --- | ---: | ---: |
| 1 × 1 MiB | Absent | 4 → 2 | — |
| 1 × 1 MiB | Already ready | 4 → 3 | 0 → 0 |
| 1 × 1 MiB | After first bulk write | 4 → 3 | 0 → 262,144 |
| 1 × 512 KiB | After first bulk write | 2 → 2 | 0 → 262,144 |
| 1 × 256 KiB | After first bulk write | 2 → 2 | 0 → 0 |
| 2 × 1 MiB | After first bulk write | 4 → 4 | 262,144 → 262,144 |
| 4 × 1 MiB | After first bulk write | 4 → 4 | 786,432 → 786,432 |
| 1 × 1 MiB, first callback limited to one event | After first bulk write | 4 → 3 | 0 → 0 |

Each policy forwarded and verified 22,544,384 bulk bytes, 14 fresh replies, 40 reverse markers and both FINs on all 40 connections. All retired cleanly. Read and write counts were identical across every pair. The one-flow, 1 MiB workload needed four reads and four writes under either policy. Counts and service positions repeated exactly for the fixed workloads. This study did not measure elapsed throughput, fresh p95/p99, on-wire loss, per-process CPU/GiB or runnable time.

**Verdict.** Keep the stock poll policy. The extra turn saved two polls in the best bulk-only case. When a 512 KiB transfer overlapped a newly ready reply, it put another 256 KiB ahead of that reply and saved zero polls. Two or four ready bulk sockets showed no savings. Before spending a timed slot, the service trace would need to show frequent single-flow polls with at least 512 KiB ready, appreciable CPU spent in those polls and enough fresh-latency margin.

Raw-verified local report `single-bulk.receipt.md`. All first attempts, source hashes and compiler identity are in `single-bulk-first.jsonl`, SHA-256 `5d33b41c7e5ccfe33bed6b95e161db988b76ec05f2774a8fb0e36642cccf2cb0`. Reproduce on Darwin using `python3 -B reproduce.py NEW.jsonl` from the report directory. Candidate relay SHA-256 `1aaac9f90bdba340e491f7aaf895283f7837f35d92c658a32c5f31902475a267`.
