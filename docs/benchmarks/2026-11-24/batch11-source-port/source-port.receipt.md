### 24 November 2026 · 230.12 · Randomize the relay’s guest-facing ephemeral source port

**Archived VM, original first attempts verified locally.** The Gamma trial of 21 November exercised an experimental Darwin relay on a loopback listener forwarding to the same Linux guest service. Only the candidate set `SO_RANDOMPORT=1` on the outbound socket before `connect`. The comparator used the kernel's ordinary allocation. The two saved C sources differ by this option and a header include. A third interface-bound arm was interleaved but is outside this comparison. Each attempt began with identity and payload checks, ran 380 keep-alive and 380 fresh identity requests, then receiver-side bulk tests including one synchronized 32-stream burst of 8 MiB per stream.

| Receiver outcome | Ordinary selection | Randomized selection |
| --- | ---: | ---: |
| Complete first attempts | 13/18 | 12/18 |
| Failed initial identity checks / failed subsequent fresh requests | 5 / 0 | 5 / 1 |
| Fresh marker responses actually completed | 4,940 | 4,579 |
| Bytes received in completed synchronized bursts | 3.25 GiB | 3.00 GiB |
| Burst throughput, median of the 12 jointly complete pairs | 4,439.9 MiB/s | 4,593.0 MiB/s |
| Fresh p95 / p99, medians of the 12 jointly complete pairs | 0.534 / 0.706 ms | 0.557 / 0.764 ms |

The candidate won 7/12 common throughput pairs. Its median paired gain was +5.01% (descriptive 95% bootstrap interval −7.85% to +13.65%). Six blocks scheduled ordinary selection first and twelve scheduled random first, including four and eight of the common completions, respectively. The interval used 10,000 whole-block resamples stratified by this order, seed 23012. The schedule rotated deterministically and all failures clustered in blocks 7–12. Failed attempts never reached the burst; their elapsed bulk throughput is unavailable. Errors retain their actual stage and ordinal. The fresh p95/p99 checks preceded the burst. Under-load latency, packet drops, connected-path retransmissions, per-process CPU/GiB and runnable time were unavailable.

**Verdict.** Keep ordinary source-port selection. Randomization did not establish higher receiver throughput or improve completion. Some client failures occurred while dialing the host listener. The outbound option and the relay’s logged address errors cannot explain every failure. A future trial needs separate accounting at the client-to-listener and relay-to-guest connects plus observed ephemeral port pressure; this candidate has no priority over the revised stock baseline.

Micropod study base `52d67399aad63ed5935c8a615727379d3f1a3636`. Retained study `gamma-published-profile.json.gz` at archive commit `56b59864d3545cba23cf102cf46cf119f119da08`, SHA-256 `234f8f89de4462068e31934a8b1fc0ec6ecc93d814dd2da97b13c574481ebe93`. Analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Private `first-attempt-inputs.json.gz` preserves 72 original stdout/stderr files for the 36 compared invocations, original relay events, sources, job script and binary hashes (SHA-256 `d0e3e555bfdaa8e6f12087a67451070dd4ef53dfa28b9e825f00b0511b1dad7f`). From this directory run `python3 -B replay.py`. Two runs reproduced `source-port.json`, SHA-256 `ed79e5914ada400f31de4dcfae33a38386794eaf44ae7d5e0c5dabfd3c58ed53`. The previous report identified address errors on all three policies. This receipt scores completion and receiver throughput for the ordinary-versus-random socket option while retaining every failed first attempt.
