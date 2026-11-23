# Micropod and OrbStack on Gamma

The 20–21 November runs measured these workloads on the same M5 Max with four vCPUs and 4 GiB configured per VM. They used different Micropod builds across studies. Each row belongs to its own experiment. The 23 November changes have offline verification and await a new end-to-end run.

## CI and container startup

| Time to finish | Micropod | OrbStack | What the clock includes |
| --- | ---: | ---: | --- |
| Full CI after a source edit | 5.651 s | 22.551 s | Go, npm, image builds and PostgreSQL exercised via Testcontainers. Same application bytes. Three measured revisions after priming. |
| Same CI revision rerun | 3.276 s | 8.730 s | Warm cache with actual test execution and cleanup. |
| 32 concurrent Go jobs | 5.974 s | 9.423 s | Stock Docker CLI launches, vet, eight tests and build. Includes preparation of Micropod's one-use pods. Three rotated batches. |
| One warm Alpine launch and exit | 67 ms | 236 ms | Five-round median. Micropod used its CI command and OrbStack used Docker. This does not time cold VM boot. |

[Full pipeline receipts](../2026-11-20/full-ci.md) · [32-job measurement](../2026-11-21/native-worker.md) · [Warm launch](../2026-11-20/gamma-ci-worker.md)

## Mac-to-container TCP under load

The last independent holdout used one published port, 32 ongoing downloads and 40 new requests per second. It predates the revised relay.

| Measure | Micropod | OrbStack |
| --- | ---: | ---: |
| Bulk throughput, clean-arm median | 2,709.8 MiB/s | 3,010.4 MiB/s |
| Scheduled fresh requests, p95 / p99 | 35.2 / 58.1 ms | 220.3 / 1,027.4 ms |
| Highest fresh p95 in any clean round | 70.946 ms | 1,013.622 ms |
| Fresh failures / requests offered, all attempts | 0 / 3,840 | 1 / 3,840 |
| Reopened bulk connections, all attempts | 0 | 0 |
| Observed host CPU per GiB, clean-round median | 0.956 CPU-s | 1.074 CPU-s |

Micropod's p95 and p99 were lower in every one of the 15 common clean pairs. All 16 Micropod rounds met 75 ms p95. Every clean OrbStack round exceeded it. The CPU counters cover Micropod's VMM and supervisor and OrbStack's observed helper, including setup and drain. Total product CPU, energy and historical fresh p50 are unavailable from this holdout.

Micropod won seven of the 15 common pairs on throughput. Its median within-pair throughput ratio was 0.854 with a descriptive 95% interval of 0.709–1.259. The difference between the two clean-arm medians was 300.6 MiB/s. Matching the historical paired point estimate would take a 17.1% lift. These are two different summaries of a variable shared-host workload. [Raw holdout](../2026-11-21/gamma-vcpu-priority.json.gz) · [Analysis and per-round results](../2026-11-22/gamma-tcp-contrasts.md)

## Service-to-service networking

| In-guest measurement | Micropod | OrbStack |
| --- | ---: | ---: |
| Single DNS resolver, p95 | 118 µs | 77 µs |
| 32 concurrent DNS resolvers, p95 | 711 µs | 1,188 µs |
| Keep-alive HTTP, p50 | 54.5 µs bridge, 59.0 µs MACVLAN | 19.5 µs |
| 32-stream bulk throughput | 11,020 MiB/s bridge, 12,767 MiB/s MACVLAN | 12,205 MiB/s |

DNS used 14 paired rounds at each concurrency. All lookups completed. HTTP and stream figures are medians of six samples per network mode. The bridge is the default. A distinct sustained 6 GiB sibling test also favored OrbStack, 13,496 versus 9,582 MiB/s. Network mode, concurrency and transfer duration change the result. [DNS and service traffic](../2026-11-21/native-network.md) · [Sustained sibling traffic](../2026-11-21/gamma-vnic.md)

## What remains to win

The [optimization register](../../research/2026-11-23-optimization-register.md) links each research direction to its GitHub row, evidence and next check. Two local Go series measured 48–51% less time packing a single IPv4 service reply and 320 B/op versus 1,072 B/op. The end-to-end DNS rows above still use the earlier guest. [Raw encoder samples and compatibility checks](dns-answer-encoding.txt)

1. **Mixed published throughput.** Run the stock four-vCPU baseline, then change only the relay worker count from two to four. The one-port host-only pilot gained 63.9% at a fixed callback budget over three short pairs. Its VM benefit is unknown. An independent same-budget, 16-pair OrbStack holdout with a lower paired throughput bound above 1, zero Micropod fresh losses or bulk reopens, and fresh p95 at or below 75 ms is the next defensible throughput win. [Benchmark handoff](gamma-throughput-gap.md)
2. **Quiet service calls.** A second archived series put Micropod’s reused HTTP p50 above OrbStack’s in 11 of 14 pairs, with a median paired difference of +49 µs. The new probe checks that successive requests actually reuse the socket and records connection setup, retries and response timing. Repeat quiet DNS and HTTP on the revised guest. [Quiet HTTP measurements and probe](quiet-service-http.md)
3. **Unscored product fronts.** Comparable cold boot and first build, filesystem edit propagation, durable guest I/O, idle host memory and reclaim, energy, amd64 translation, and desktop sleep/wake and update recovery need matched results. Individual Micropod qualification and offline regression passes establish correctness in their test cases. They do not establish a peer lead.

The desktop sampler now retains its timestamp formatter and deduplicates long container lists in order. Selecting 1,024 distinct IDs fell from 2.724 to 0.183 ms in a local Swift benchmark. A 16-ID selection rose from 1.108 to 1.138 µs. Full desktop polling and XPC cost still need measurement. [Native Swift samples](native-stats-selection.json)

Two further changes improved local workloads. In the full in-process DNS reply method, eight-address responses fell from 1.93 to 0.66 µs and truncated 256-address responses from 40.07 to 2.06 µs. The single-address control went from 396 to 407 ns. In the shared-view edit handler, scanning an affected subtree took 1.05 ms versus 18.13 ms for the whole tree with 256 unrelated files. The automatic event-to-guest path and matched guest DNS queries still need timing. [DNS measurements](dns-multi-address.json) · [Shared-view measurements](shared-view-directory-local.json)

New published-port holdouts verify the actual client arguments, service marker and single-port count before scoring. The first-build fixture now verifies empty Go caches and a pinned module. In a local control, a partially warm build invoked a compiler once and took 0.175 s, compared with 106 compiler or assembler invocations and 3.702 s from empty stores. [Peer verifier](../../../scripts/relaybench/peer_verdict.py) · [First-build control](first-go-build-local.json)

At 17:01 AEDT on 23 November, the isolated Gamma Linux CI worker held its only lease and the Mac worker had four of six slots leased. The isolated owner handoff is pending. [Performance backlog](https://github.com/castlemilk/micropod/issues/227)
