**24 November 2026 · 231.08 · Placing fair queueing on the service interface**

Archived VM first attempts, raw-verified offline. Changed only the service interface root queue from noqueue to fq within each fixed publication-NIC discipline. Same four-vCPU Micropod guest, service image, Reno gateway route, IRQ CPU 0 and client. Four rotating blocks per setting, 32 bulk streams and 100 sequential fresh requests per attempt. Configuration readbacks and all 16 arm records survive. This is one service-queue experiment with two fixed NIC contexts.

| NIC discipline | Median MiB/s, stock → fq service | Median paired rate change (observed range) | Fresh p95/p99 ms, stock → fq service | Attempts meeting 75 ms p95 |
| --- | ---: | ---: | ---: | ---: |
| pfifo_fast | 3,466 → 4,220 | +17.74% (−18.13% to +38.94%) | 52.73/74.58 → 39.13/45.90 | 3/4 → 4/4 |
| fq | 4,488 → 4,858 | +6.95% (−2.44% to +11.63%) | 24.28/27.85 → 26.36/39.29 | 4/4 → 4/4 |

The service queue won 3/4 throughput pairs in each context. Every arm completed 400/400 fresh requests and had zero reopenings. Both tails are medians of per-attempt client observations. Closed-loop launches changed the overlap duration. The per-stratum sample is too small for the existing interval estimator. Packet loss, queue drops, CPU/GiB and runnable time were unavailable.

Keep the revised stock baseline. Service-side fq warrants a separate comparison with verified queue placement and fixed open-loop arrivals if the production path has the same service hop. Its tail effect changed sign with NIC queue policy. Original study base `4f887ba5d28f47fa37d4bd0a2d89cd0914d74754`, archive revision `692ace081c989f80fb2bce27a5a13af13098b77c`, replay base `17bcd4355234b11da3a7a1da2ded52f4dc20f5d1`. Source `gamma-mixed-path.json.gz`, SHA-256 `09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a`. Run `python3 -B service_fq.py`; local report `service-fq.json`, SHA-256 `a616ecae093e28665ce7dd3683610fbffb262fd3bceb4a3b1d90900e4ebc0eb9`.
