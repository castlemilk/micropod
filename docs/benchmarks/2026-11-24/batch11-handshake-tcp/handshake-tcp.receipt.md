# Deferred read registration on two-worker Darwin TCP

**24 November 2026 · #230 · 230.14 · local/host-only.** Keep eager registration. With the benchmark switch off and on, receiver median rates were **2,416.8 → 1,982.0 MiB/s**. The median *within-pair* change was +4.03%, four wins in six, with a descriptive 95% whole-pair bootstrap interval of −46.96% to +128.50%. Raw throughput varied widely across blocks. Neither arm passed the 75 ms fresh p95 guardrail in any completed window. These results cannot select a faster VM relay.

One change enabled deferred registration of read filters for pending asynchronous guest connects. Both executables compiled the production Swift/C NativeLoopbackRelay from `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Each had one exposed port, two dedicated data workers, a 128-event callback budget, 256 KiB reads and disabled profiling. The sole compile-time change was `MICROPOD_BENCH_DEFER_HANDSHAKE_READS=0/1`. The no-profile fixtures confirm the post-restart binaries, C objects, Swift/C sources, client, server and observer match the first build by SHA-256. Each scored client used 32 receiver streams, six seconds of offered work and 240 concurrent open-loop fresh requests at 40/s. Both TCP legs were Darwin loopback. Each arm checked the service marker and hashed one 8 MiB body before scoring. The client then checked response identity, body lengths and stream reopen counts.

## First attempts and guardrails

The machine restarted after the initial candidate client started and before it returned any bytes to the receipt. Its raw client files are empty. The original order, admission and start record are preserved. The new post-boot campaign randomized six complete counterbalanced pairs. Across both campaigns the control completed 6/6 starts and the candidate 6/7. Comparisons below use only the six jointly complete post-restart pairs. The interruption is excluded from percentiles and rate and has unknown delivery and latency.

| Observed metric | Eager | Deferred |
| --- | ---: | ---: |
| Delivered receiver rate, median MiB/s | 2,416.8 | 1,982.0 |
| Fresh p95, median of window p95 (ms) | 161.15 | 172.25 |
| Fresh p99, median of window p99 (ms) | 215.49 | 232.07 |
| Completed windows meeting 75 ms p95 | 0/6 | 0/6 |
| Fresh attempts in completed windows | 1,440 | 1,440 |
| Application errors / stream reopens | 0 / 0 | 0 / 0 |
| Host-wide lo0 input-queue drops | 0 | 0 |
| Relay CPU-s per scored GiB | 0.272 | 0.265 |
| Relay runnable thread-s/wall-s | 2.080 | 2.079 |

Median CPU and runnable time cover the whole client lifetime and the denominator is delivered bulk bytes during the scored window. Client and server costs are in the summary. The pre-arm idle estimator returned zero on every post-restart arm and does not distinguish zero idle from no tick delta. The designated 90% idle condition was unverified throughout. Minimum free disk was 396.3 GiB. These observed-load windows add no matched OrbStack evidence. Keep the unchanged relay for qualified VM testing.

## Reproduce

All recorded post-restart client outputs were compared with their enclosing attempt records, including the 32 stream counts. Use `python3 -B summarize.py` to reproduce `post-restart-summary.json`. Build inputs, compile flags and per-file digests are in `build.json` and `post-restart-build.json`. The shared host-only fixture sources are in the adjacent `batch11-host-hot-wait` directory. Use its build instructions, then `python3 -B build.py NEW_BUILD_DIR COMPILED_SHARED_DIR` and `python3 -B run.py NEW_BUILD_DIR NEW_RESULTS_DIR`. No traffic is needed for replay.

Raw-verified locally. The interrupted `first/receipt.json` has SHA-256 `b997e6039d04a4e9c1a0ec23a4919f8f9f254b7a027810b71f38183097490d6c`. The complete `post-restart-first/receipt.json` has SHA-256 `1af1c22303a18f71fd213a0b6e0b036b3991b2a16dc260dadda58790dd9d3f1d`.
