# Reusing unused read allowance in one kqueue poll

A 128 KiB bulk read left half its 256 KiB allowance unused. Giving that unused allowance to a later bulk read in the same poll raised verified burst throughput by **5.52%** across eight paired blocks. The one-byte reply on a separate established stream had a **35.67% higher p95** and lost every pair. Keep the existing Micropod default. [Raw first attempts](first-attempts.json)

| Measure | Stock control | Reuse unused allowance | Median paired change | 95% paired bootstrap interval |
| --- | ---: | ---: | ---: | ---: |
| Receiver throughput | 8,975.9 MiB/s | 9,628.8 MiB/s | +5.52% | +2.50% to +9.63% |
| Bulk reads per burst | 24.0 | 16.5 | −31.25% | −31.25% to −31.25% |
| Data callback CPU per verified GiB | 0.07381 s | 0.07417 s | +1.06% | −1.10% to +5.64% |
| One-byte reply p95 | 0.201 ms | 0.274 ms | +35.67% | +32.30% to +40.23% |
| One-byte reply p99 | 0.256 ms | 0.344 ms | +45.39% | +21.97% to +69.74% |

Stock and candidate ran in the same native binary on Gamma. Each used the dedicated kqueue data owner and 128-event callback policy from the C source in the scored four-vCPU baseline, SHA-256 `93d30bc14268a4d759d0ba2c79c6b4cae1665914f7699cdb799087b920f4b815`. Both arms reserved 512 KiB of scratch. Stock limited every read to 256 KiB. In the candidate, a successful established guest bulk read earned its unused allowance for the remainder of that poll. A later guest bulk read could spend that allowance when its kqueue event indicated more than 256 KiB available. The cap never exceeded 512 KiB. The experiment checked that bulk bytes read in each poll stayed within 256 KiB per returned event. [Pinned live build](../disposable-local-fixture/20261124T062433Z/revised-runtime-build.json) · [Candidate patch](read-credit.patch)

Each burst staged eight 128 KiB and eight 384 KiB downloads, alternately arranged across sixteen established socketpairs. This deliberately favors credit reuse. A seventeenth established stream received a one-byte reply immediately after the write of one designated 128 KiB download. The schedule balanced the two arrangements and all eight marker positions. A real user-initiated dispatch source drove the kqueue owner. Timing ended when the bulk receiver verified all 4 MiB. Short latency ran from the marker offer through its successful read on another thread. The CPU interval includes only data-owner callbacks. Setup, reverse markers, FIN verification and warmups were outside scoring. [Workload](burst.c)

All 1,024 scored bursts delivered identical per-stream payloads, all 1,024 one-byte replies arrived, and all 34,816 half-closes were verified. The candidate removed 3,840 read/write pairs over its 512 bursts. A stock poll carried at most 3 MiB of bulk data in this workload. A candidate poll carried up to 4 MiB before returning to kqueue for a newly ready reply. Throughput improved in seven of eight blocks. The table shows medians of per-block measurements. Intervals resample eight entire pairs with replacement. Each per-block p99 is the slowest of its 64 scored replies. [Timing and analysis](run.py)

This experiment used unnamed Unix stream socketpairs on one local data owner. The prevalence and ordering of these readiness hints in the revised VM workload remain unknown. A separate diagnostic guest run could record short and above-cap bulk reads in the same real poll before allocating VM timing to the candidate. Fresh TCP connections, the VMM and OrbStack were outside this test.

Reproduce with `python3 -B run.py smoke`, or recompute the table with `python3 -B run.py summary`. An independent run requires a fresh output path and acquires the same exclusive lock as the local VM suite. The saved raw file SHA-256 is `72a4cf7da55c2fc34ede47f15f2af963832011db36efe8e1278680587dc83e06`.

## Independent no-borrowing control

A second schedule, declared before timing and run with seed 230152413, offered exactly 256 KiB on every stream. It preserved 16 streams, 4 MiB per burst, all 16 marker positions, the same receiver and both policy paths in a common binary. All eight pairs completed. Each of the 1,024 scored bursts used exactly 16 reads and 16 writes. The candidate never read above 256 KiB. Every byte, marker and half-close passed. The new control has its own paired analysis. [Control measurements](homogeneous-first.json) · [Control driver](homogeneous.py)

| Measure | Stock control | Reuse enabled | Median paired change | 95% paired bootstrap interval |
| --- | ---: | ---: | ---: | ---: |
| Receiver throughput | 11,846.0 MiB/s | 11,920.8 MiB/s | +4.03% | −0.46% to +11.76% |
| Data callback CPU per verified GiB | 0.07832 s | 0.07759 s | −4.41% | −9.94% to +0.24% |
| One-byte reply p95 | 0.279 ms | 0.266 ms | −4.53% | −19.93% to +0.46% |
| One-byte reply p99 | 0.334 ms | 0.307 ms | −11.69% | −28.19% to −1.38% |

The homogeneous control showed a throughput shift comparable to the mixed-supply point estimate despite identical transfer counts. These data establish that borrowing removed read/write calls in the mixed bursts and coincided with higher marker p95 in every such pair. They do not isolate how much of the throughput difference came from those saved calls. A VM comparison or an interleaved policy-by-supply design would be needed to attribute that effect.
