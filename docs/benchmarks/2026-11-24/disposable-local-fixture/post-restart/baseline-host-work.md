# Host work in the revised Gamma published-TCP baseline

On 24 November the revised relay delivered **6,573.34 MiB/s** in one scored six-second window. Its VMM and relay together used **0.5883 CPU-seconds per scored GiB**. Every one of the 16 Micropod windows in the 21 November peer holdout used more CPU per GiB, ranging from 0.8631 to 1.0714. All 17 Micropod windows delivered on all 32 bulk streams and completed their 240 scheduled fresh requests with zero failures and zero reopens. [Revised receiver](../20261124T090510Z-local-d0y_1j57/baseline/receiver/scored-1-A.json) · [Historical raw holdout](../../../2026-11-21/gamma-vcpu-priority.json.gz)

| Metric | Historical median, 16 Micropod windows | Historical fastest window | Revised window |
| --- | ---: | ---: | ---: |
| Receiver throughput, MiB/s | 2,709.83 | 4,069.29 | 6,573.34 |
| Fresh request p95 / p99, ms | 35.21 / 58.15 | 13.55 / 23.05 | 5.87 / 9.55 |
| Mean host cores used by VMM + relay | 2.441 | 3.620 | 3.711 |
| VMM + relay CPU-seconds per scored GiB | 0.9559 | 0.9334 | 0.5883 |
| VMM CPU-seconds per scored GiB | 0.6053 | 0.5916 | 0.3961 |
| Relay CPU-seconds per scored GiB | 0.3481 | 0.3417 | 0.1922 |
| VMM runnable off-CPU thread-seconds per wall-second | 2.094 | 0.986 | 0.568 |
| Relay runnable off-CPU thread-seconds per wall-second | 0.124 | 0.157 | 0.073 |
| Slowest eight streams’ share of scored bytes | 24.74% | 24.85% | 24.92% |

Compared with the historical fastest window, the revised window transferred **1.6154×** as many bytes per scored second. The accounting identity breaks that ratio into **1.0254×** combined VMM and relay CPU-seconds per bracket second, **1.5866×** scored bytes per combined CPU-second, and **0.9929×** the ratio of bracket duration to scored duration. Reading throughput as a host scheduling effect alone would miss the change in observed CPU cost. Each process counter bracket includes client setup and drain. The 16-window medians use within-window sums for the combined processes. [Replay](baseline_host_work.py)

The revised window’s slowest and fastest bulk streams delivered 203.50 and 206.88 MiB/s. Bringing all 32 streams up to that observed fastest rate, with the fastest rate held fixed, would add **46.96 MiB/s (0.71%)**. That calculation describes the small observed imbalance. Changes to worker count could still affect every stream’s rate. The fixed-budget worker comparison should therefore compare total delivered bytes and CPU/GiB alongside stream dispersion.

The fixed client, service image, four-vCPU allocation and Interactive launchd role match across the two dates. The runtime binary and host conditions changed. The historical Micropod windows had a median one-minute host load of 63.4. The revised run recorded 91.68% idle before timing, and its socket check established the matched return route with the per-socket controller unobserved. These observations give no paired estimate of a relay change or a new OrbStack result. The scheduled QoS comparison can separate the launchd-role effect on the revised runtime. [Historical protocol](../../../2026-11-21/gamma-vcpu-priority.md) · [Revised run plan](../20261124T090510Z-local-d0y_1j57/baseline/receiver/plan.json)
