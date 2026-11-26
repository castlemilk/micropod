# Gamma published TCP comparisons, 24 November 2026

On Gamma’s four-vCPU VM, Standard delivered more bulk data than Interactive in all eight controlled QoS pairs. Interactive lowered the median fresh-request p95 from 10.187 ms to 6.356 ms. With the launch role fixed at Interactive, two relay workers delivered more data than four in every controlled pair and used fewer host CPU-seconds per GiB.

| Schedule | Change | Median throughput (MiB/s) | Median paired change | Second arm wins | Evidence |
| --- | --- | ---: | ---: | ---: | --- |
| Controlled QoS | Standard → Interactive | 7,934.1 → 6,294.1 | −20.70% | 0/8 | [Receiver summary](../disposable-local-fixture/20261124T100757Z-local-zw8k9wvr/receiver/summary.json) |
| Controlled workers | Two → Four | 6,504.7 → 5,845.0 | −10.11% | 0/4 | [Receiver summary](../disposable-local-fixture/20261124T100302Z-local-ul3niw24/receiver/summary.json) |
| Ambient QoS | Standard → Interactive | 7,777.2 → 6,264.7 | −19.61% | 0/8 | [Receiver summary](../disposable-local-fixture/20261124T101318Z-local-0ax_2slx/receiver/summary.json) |
| Ambient workers | Two → Four | 6,413.5 → 5,774.7 | −10.24% | 0/4 | [Receiver summary](../disposable-local-fixture/20261124T101629Z-local-wrcho9e3/receiver/summary.json) |

Paired changes use the median of the throughput ratios within pairs. Standard and Interactive each used two workers. The worker comparison varied only the relay worker count on the fixed-budget build. Both comparisons used one published port, 128 events per callback, 32 bulk streams and 240 fresh requests scheduled at 40/s during each six-second window. The guest return route specified Reno. The stock kernel does not expose the congestion controller of the accepted socket. [QoS fixtures](../disposable-local-fixture/20261124T100757Z-local-zw8k9wvr/receiver/fixtures.json) · [Worker fixtures](../disposable-local-fixture/20261124T100302Z-local-ul3niw24/receiver/fixtures.json)

| Schedule | Arm | Fresh p95 / p99 (ms) | Host CPU-s/GiB | Runnable s/s, VMM / relay | Pre-window host idle |
| --- | --- | ---: | ---: | ---: | ---: |
| Controlled QoS | Standard | 10.187 / 11.122 | 0.571 | 3.003 / 1.998 | 90.37–95.34% |
| Controlled QoS | Interactive | 6.356 / 11.469 | 0.609 | 3.053 / 1.276 | 90.10–93.44% |
| Controlled workers | Two | 6.194 / 10.499 | 0.596 | 3.055 / 1.285 | 93.63–95.95% |
| Controlled workers | Four | 6.637 / 9.768 | 0.709 | 3.025 / 1.780 | 91.90–94.44% |
| Ambient QoS | Standard | 10.313 / 11.149 | 0.580 | 3.000 / 1.998 | 85.82–93.83% |
| Ambient QoS | Interactive | 6.304 / 8.944 | 0.616 | 3.052 / 1.280 | 83.55–92.98% |
| Ambient workers | Two | 6.197 / 11.791 | 0.605 | 3.068 / 1.285 | 91.21–93.07% |
| Ambient workers | Four | 6.711 / 13.508 | 0.719 | 3.032 / 1.798 | 87.41–91.12% |

Latency values are medians of the scored windows’ percentiles. Host CPU is the sum for the VMM and relay per delivered GiB. Interactive’s controlled throughput change had a paired bootstrap 95% interval of −21.44% to −19.41%. Its median paired VMM scheduler wait increased by 0.196 seconds per wall second. The worker comparison had four scored pairs. [QoS decision and scheduler counters](../disposable-local-fixture/20261124T100757Z-local-zw8k9wvr/receiver/summary.json) · [Worker decision and process counters](../disposable-local-fixture/20261124T100302Z-local-ul3niw24/receiver/summary.json)

The controlled runs required two consecutive samples at or above 90% idle and at most five percentage points between paired arms, with 60 seconds per admission. The ambient runs recorded one idle sample immediately before each client and used the same traffic and run orders under the host’s natural load. Across the four completed schedules, all 48 scored clients accounted for 32 bulk streams and all 11,520 fresh requests, with zero stream reopens or recorded interface drops. Each per-window JSON retains delivered bytes, elapsed time and process measurements. Cleanup removed all eight launchd jobs and their four temporary scopes. [Controlled QoS cleanup](../disposable-local-fixture/20261124T100757Z-local-zw8k9wvr/cleanup.json) · [Controlled worker cleanup](../disposable-local-fixture/20261124T100302Z-local-ul3niw24/cleanup.json) · [Ambient QoS cleanup](../disposable-local-fixture/20261124T101318Z-local-0ax_2slx/cleanup.json) · [Ambient worker cleanup](../disposable-local-fixture/20261124T101629Z-local-wrcho9e3/cleanup.json)

The original stock baseline remains **6,573.34 MiB/s**, with fresh p95/p99 of **5.871/9.550 ms**. All 24 files matched the preserved manifest by SHA-256. The suite guard detected the earlier timed QoS pair and refused a duplicate continuation. The complete comparisons above ran as independent schedules. Earlier attempts timed out waiting for idle, and the earlier partial pair remains in its original directory. [Original scored baseline](../disposable-local-fixture/20261124T090510Z-local-d0y_1j57/baseline/receiver/scored-1-A.json) · [Preserved manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json) · [Earlier QoS pair](../disposable-local-fixture/20261124T094404Z-local-m05uc5et/host-role/receiver/summary.json) · [Worker timeout](../disposable-local-fixture/20261124T095144Z-local-sanx5o0e/receiver/status.json) · [QoS timeout](../disposable-local-fixture/20261124T100003Z-local-5nctn3ki/receiver/status.json)

The standalone fixture accepts `--ambient-diagnostic` with `--mode host-role` or `--mode workers`, `--socket-evidence route` and `--run`. Ambient runs record descriptive measurements and omit the controlled verdict. The driver archive matches the hashes in the controlled QoS plan. [Fixture entry point](../disposable-local-fixture/local_terminal.py) · [Controlled driver snapshot](controlled-drivers.tar.gz)
