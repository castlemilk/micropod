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

## Local changes awaiting matched product runs

| Component | Micropod measurement | Remaining comparison |
| --- | --- | --- |
| Fresh connection setup | Deferring kqueue read-filter registration saved 6.68% of asynchronous setup CPU and 2.52% of full-flow relay CPU in a local stream fixture. [Confirmation](relay-handshake-reads-confirmation.json) | Actual published TCP throughput and fresh p95/p99 at the same worker count. |
| CI suite preparation | Six Go packages took 5.180 → 4.615 s with empty action caches and 0.989 → 0.440 s warm. Generated test artifacts matched. [CI measurements](go-suite-compile-local.json) | Changed revisions on the worker. Exact prepared-image hits already bypass this step. |
| Service DNS | Eight-address A replies fell from 1.93 to 0.66 µs, truncated 256-address replies from 40.07 to 2.06 µs. A separate change reduced single-service AAAA from 277 to 120 ns. Ordinary A stayed near 315 ns in that experiment. [Multi-address responses](dns-multi-address.json) · [Question lookup](dns-question-lookup.md) | End-to-end p95 for the same A/AAAA mix at one and 32 resolvers. |
| Shared-folder edits | With 256 unrelated files, nested edit handling fell from 18.13 to 1.05 ms. With 2,048 unrelated files, deletion then fell from 420 to 240 µs and repeat deletion from 241 to 62 µs. The index added about 192 KiB during large-fixture initialization. [Subtree scans](shared-view-directory-local.json) · [Deletion index](shared-view-index-local.json) | Automatic event delivery and time until the guest sees the verified edit. |
| Desktop stats | Selecting 1,024 distinct IDs fell from 2.724 to 0.183 ms. A 16-ID selection rose from 1.108 to 1.138 µs. [Native Swift samples](native-stats-selection.json) | Full desktop polling and XPC cost. |

Both the host relay scorer and new peer holdouts verify the raw listener count. Peer runs also bind the actual client arguments and service marker. The first-build fixture checks for empty Go caches and a pinned module. A partially warm control took 0.175 s and invoked the compiler once, versus 3.702 s and 106 compiler or assembler invocations from empty stores. [Host scorer](../../../scripts/relaybench/test_compare.py) · [Peer verifier](../../../scripts/relaybench/peer_verdict.py) · [First-build control](first-go-build-local.json)

At 17:16 AEDT on 23 November, Gamma’s isolated Linux worker held its only lease. The isolated owner handoff is pending. [Performance backlog](https://github.com/castlemilk/micropod/issues/227)
