# Published TCP on Gamma, 24 November 2026

Micropod’s Standard launchd role with two relay workers beat OrbStack 2.2.5 on bulk throughput in all 16 controlled pairs. The median within-pair lead was **11.67%**, with a 95% paired bootstrap interval of **11.25% to 12.62%**. The highest Micropod fresh-request p95 was **10.618 ms**, under the 75 ms target. OrbStack served fresh requests faster in every pair. [Peer verdict and per-pair results](20261124T103005Z-run-8j1yw9d6/verdict.json) · [Timing and guard audit](20261124T103005Z-run-8j1yw9d6/audit.json)

| Controlled workload | Micropod | OrbStack |
| --- | ---: | ---: |
| Bulk throughput, median (MiB/s) | 8,046.4 | 7,207.3 |
| Fresh requests, median window p50 (ms) | 6.577 | 2.543 |
| Fresh requests, median window p95 (ms) | 9.940 | 5.239 |
| Fresh requests, median window p99 (ms) | 11.023 | 8.048 |
| Observed host CPU-seconds per scored GiB, median | 0.561 | 1.017 |
| Clean scored windows | 16/16 | 16/16 |
| Fresh failures / offered | 0/3,840 | 0/3,840 |
| Bulk reopens / recorded interface drops | 0 / 0 | 0 / 0 |

The signed Micropod worker used four vCPUs, a 4 GiB VM, the stock 7.3.5 guest, macvlan publishing, 128 events per callback and a 256 KiB read cap. The live job and mapped executable identified the selected Standard configuration. OrbStack also had four vCPUs and 4 GiB configured. Both services ran the same ARM64 image with a four-CPU quota, 1 GiB memory limit and 512-PID limit. The source of the Micropod setting was a separate eight-pair QoS experiment. A separate four-pair worker experiment held the launch role at Interactive and favored two workers throughout. [Live fixture identities and limits](20261124T103005Z-run-8j1yw9d6/fixtures-before.json) · [QoS, workers and preserved baseline](../gamma-qos-and-workers/results.md)

The fixed client kept 32 downloads active on one published loopback port and offered 240 new identity requests over six seconds per window. Three warm-up pairs preceded 16 randomized scored pairs, balanced within each two-pair block. Each window required two consecutive host samples of at least 90% idle, and paired arms had to start within five percentage points. The recorded admission samples ranged from 90.06% to 95.17%. The median throughput lead was 11.57% with Micropod first and 11.75% with OrbStack first. The 95% interval resamples the sixteen whole pairs. [Frozen plan](20261124T103005Z-run-8j1yw9d6/plan.json) · [Recorded host observations](20261124T103005Z-run-8j1yw9d6/admission.jsonl) · [Audit](20261124T103005Z-run-8j1yw9d6/audit.json)

Observed CPU covers the Micropod VMM and relay supervisor, and the OrbStack helper. Their counter windows include client setup and drain. On scored bytes, Micropod used 44.9% fewer observed CPU-seconds per GiB. The client’s worst dispatch delay on Micropod was 0.485 ms. Even deducting each Micropod window’s largest dispatch delay, its post-dispatch p95 exceeded the paired OrbStack scheduled p95 by at least 3.58 ms in every pair. The raw measurements bound the latency difference without assigning it to a particular relay or guest operation. [Process counters](20261124T103005Z-run-8j1yw9d6/verdict.json) · [Dispatch bound](20261124T103005Z-run-8j1yw9d6/audit.json)

## Performance under the host load present after cleanup

A fresh pair of disposable services ran one warm-up pair and four scored pairs with the same build, quotas and client. The driver sampled host idle once before each client and started immediately at the observed load. Micropod won **3/4** pairs, with a descriptive median paired lead of **7.48%**. The median throughputs were **7,704.2** and **7,166.8 MiB/s**. Median fresh p95 was **10.976 ms** on Micropod and **5.788 ms** on OrbStack. Both completed all 960 fresh requests with zero bulk reconnects. [Ambient schedule](20261124T103809Z-ambient-d51leqrq/plan.json) · [Per-pair raw results and medians](20261124T103809Z-ambient-d51leqrq/ambient-summary.json)

| Scored pair | First engine | Micropod host idle | OrbStack host idle | Micropod MiB/s | OrbStack MiB/s |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | OrbStack | 90.55% | 87.96% | 8,179.9 | 7,253.4 |
| 2 | Micropod | 87.85% | 90.39% | 8,003.0 | 7,210.9 |
| 3 | Micropod | 67.38% | 71.08% | 7,405.4 | 7,122.6 |
| 4 | OrbStack | 81.95% | 80.89% | 6,600.0 | 7,117.3 |

Both runs used private fixtures on Gamma’s M5 Max with macOS 26.5.1. The local guards observed the runner processes, disk and active OrbStack containers throughout the timed clients. Cuttlefish’s Gamma Mac and isolated Linux runners last reported before 05:50 UTC, so the results cover the locally monitored host. Cleanup removed both runs’ private launchd jobs, temporary scopes and labeled OrbStack containers. The original 6,573.34 MiB/s baseline still matched all 24 manifest entries. [Fleet observation](20261124T103005Z-run-8j1yw9d6/fleet-at-selection.json) · [Controlled cleanup](20261124T103005Z-run-8j1yw9d6/cleanup.json) · [Controlled OrbStack cleanup](20261124T103005Z-run-8j1yw9d6/orbstack-cleanup.json) · [Ambient cleanup](20261124T103809Z-ambient-d51leqrq/cleanup.json) · [Ambient OrbStack cleanup](20261124T103809Z-ambient-d51leqrq/orbstack-cleanup.json) · [Baseline manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)

## Replaying the measurements

From this directory, the following commands recompute the two results and the controlled timing audit. Each run also retains the source files used during measurement. Replaying both archived scorers reproduced every field of their saved summaries. [Controlled driver archive](20261124T103005Z-run-8j1yw9d6/drivers.tar.gz) · [Ambient driver archive](20261124T103809Z-ambient-d51leqrq/drivers.tar.gz)

```sh
python3 -B score.py 20261124T103005Z-run-8j1yw9d6
python3 -B audit.py 20261124T103005Z-run-8j1yw9d6
python3 -B ambient.py 20261124T103809Z-ambient-d51leqrq
```
