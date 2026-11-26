# Relay buffer alignment and host CPU time

The last four-vCPU Gamma comparison recorded clean medians of 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. The difference was 300.6 MiB/s. Across the 15 pairs clean on both sides, the median Micropod/OrbStack ratio was 0.854 with a 95% paired interval of 0.709–1.259. Both numbers come from the archived VM comparison. [VM measurements and graph](../2026-11-22/gamma-end-to-end-vm.png) · [Original comparison](../2026-11-22/gamma-tcp-contrasts.json)

## Does aligning the relay buffer improve throughput?

The relay reads into a 256 KiB buffer embedded in its private state. In the initial screen, sixteen balanced blocks compared two addresses inside the same external allocation. Putting the buffer on a 16 KiB page boundary increased paired bulk throughput by 17.0% (95% interval +1.4% to +26.7%). The external control itself ran slower than the embedded stock buffer. [Four-arm screen](relay-scratch-alignment.json)

A second experiment compiled the stock C source and compared it with a candidate that puts the buffer first and page-aligns the whole relay allocation. Both requested 262,200 bytes per relay and kept the ordinary read size. Each workload ran 24 pairs, evenly split between stock-first and candidate-first. The table reports medians for each arm and the median of the 24 within-pair changes. Those calculations can give different directions when the paired effects vary. [Stock comparison, build hashes and raw timings](relay-scratch-inline.json)

| Local workload | Stock MiB/s | Aligned MiB/s | Paired throughput change | 95% paired interval |
| --- | ---: | ---: | ---: | ---: |
| 256 KiB bulk writes | 3,106 | 3,299 | +9.4% | −2.4% to +20.0% |
| 256 KiB bulk writes with one mid-batch reply | 3,184 | 3,163 | −1.6% | −9.0% to +2.6% |
| 4 KiB writes | 1,129 | 1,125 | +2.3% | −6.0% to +13.7% |
| 4 KiB writes with one mid-batch reply | 1,047 | 1,122 | −2.1% | −17.1% to +12.2% |

For bulk alone, owner CPU seconds per GiB changed by −7.5% (−18.7% to +5.9%). With a mid-batch reply, bulk-run marker p95 changed by +2.2% (−8.0% to +12.0%) and p99 by +3.7% (−28.9% to +69.6%). All 15,360 one-byte markers across the two marked workloads arrived in the expected order. The fixture verified the bulk bytes, reverse traffic and both half-closes. One background thread drives the producer, relay and consumer through Darwin sockets. The marker measures forwarding delay on an established socket. A real fresh TCP request also requires connection setup. The allocation change remains a benchmark candidate.

## How much CPU did faster VM rounds receive?

The replay ranks the clean four-vCPU Micropod rounds within each of three archived runs, then compares the slowest and fastest quarters. Each cell shows slow → fast medians. VMM is the host process running the virtual machine. Average host cores are process CPU seconds divided by observer wall seconds. Wait is summed across runnable threads, so it can exceed one second per wall second. [All 40 rounds and source hashes](gap-process-work.json)

| Archived run | Clean rounds | Throughput (MiB/s) | VMM average host cores | VMM runnable wait (thread-s/s) | VMM instructions per payload byte |
| --- | ---: | ---: | ---: | ---: | ---: |
| OrbStack holdout, Micropod arm | 16 | 2,056 → 3,800 | 1.20 → 2.10 | 2.66 → 1.22 | 2.119 → 2.072 |
| Full-Reno confirmation | 12 | 1,677 → 4,500 | 0.83 → 1.93 | 2.80 → 1.59 | 1.649 → 1.482 |
| Full-Reno kernel holdout | 12 | 2,060 → 5,074 | 0.88 → 2.14 | 2.60 → 1.34 | 1.511 → 1.464 |

In the peer holdout, supervisor instructions per payload byte also moved little (1.083 → 1.074). Host process accounting includes setup and drain around the scored client window. Ranking by throughput can show an association with scheduling, while faster transfers can also demand more CPU. The paired worker pilot now saves average host cores, wait, instructions per byte and cycles per byte for each clean arm. These will show whether any throughput gain from adding workers coincides with lower work per byte, different CPU availability, or both.

## Next live measurement

At 23:07 AEDT on 23 November, the isolated Linux worker held its only slot and the Mac had two of six slots leased. No owner-released scope was available. The first eligible run uses the stock relay, two workers and four vCPUs, six seconds warm and six seconds scored, with current effective disk clearance. A separately released paired trial can then change only the worker count from two to four at the same CPU budget. Its decision uses fresh-request failures and tails alongside bytes delivered and host CPU costs. The fresh Micropod/OrbStack holdout remains the test of the 300.6 MiB/s gap.

## Reproduction

From the root of the performance checkout on macOS, the two relay drivers compile temporary binaries and emit their raw receipts on stdout. The process-work replay reads the hash-checked archived VM measurements. The relay test suite passed all 96 tests.

```sh
python3 -B scripts/relaybench/scratch_alignment.py
python3 -B scripts/relaybench/scratch_inline.py
python3 -B scripts/relaybench/gap_process_work.py | cmp - docs/benchmarks/2026-11-23/gap-process-work.json
python3 -B -m unittest discover -s scripts/relaybench -p 'test_*.py' -q
```
