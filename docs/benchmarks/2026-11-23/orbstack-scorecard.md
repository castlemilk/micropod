# Micropod and OrbStack on Gamma

The 20–24 November runs measured these workloads on the same M5 Max with four vCPUs and 4 GiB configured per VM. The studies used different Micropod builds. On 24 November the Standard, two-worker configuration cleared the published-TCP throughput target in an independent local holdout. [24 November comparison](../2026-11-24/gamma-local-peer/results.md)

## CI and container startup

| Time to finish | Micropod | OrbStack | What the clock includes |
| --- | ---: | ---: | --- |
| Full CI after a source edit | 5.651 s | 22.551 s | Go, npm, image builds and PostgreSQL exercised via Testcontainers. Same application bytes. Three measured revisions after priming. |
| Same CI revision rerun | 3.276 s | 8.730 s | Warm cache with actual test execution and cleanup. |
| 32 concurrent Go jobs | 5.974 s | 9.423 s | Stock Docker CLI launches, vet, eight tests and build. Includes preparation of Micropod's one-use pods. Three rotated batches. |
| One warm Alpine launch and exit | 67 ms | 236 ms | Five-round median. Micropod used its CI command and OrbStack used Docker. This does not time cold VM boot. |

[Full pipeline receipts](../2026-11-20/full-ci.md) · [32-job measurement](../2026-11-21/native-worker.md) · [Warm launch](../2026-11-20/gamma-ci-worker.md)

## Mac-to-container TCP under load

On 24 November Micropod delivered **8,046.4 MiB/s** against OrbStack’s **7,207.3 MiB/s** on one published port with 32 ongoing downloads and 40 fresh requests per second. Micropod won all 16 controlled pairs. The median within-pair advantage was **11.67%** (95% interval **11.25–12.62%**). Fresh p95 favored OrbStack, **5.24 ms** against **9.94 ms**. Both completed all 3,840 requests with zero bulk reconnects. A separate four-pair comparison under the load present after cleanup favored Micropod in three pairs. [Controlled and ambient results](../2026-11-24/gamma-local-peer/results.md)

With 32 separate published services and eight Go builds competing for four vCPUs, Micropod delivered 8,424 MiB/s against OrbStack’s 8,133 MiB/s. The median within-pair lead was 4.2%, with 14 throughput wins in 16 pairs across two independent boots. Half the services served hot files and half served memory, with the same 160/192 KiB TCP queue assignments on both engines. Fresh p95 was 12.9 versus 59.1 ms. Micropod finished provisioning through cleanup first in all 16 pairs. These measurements used the current Linux engine with the earlier signed Mac relay. The rebuilt Mac relay failed guest TCP connection setup on Gamma. [32-service results and queue assignments](../2026-11-24/gamma-ci-concurrency/published-link-results.md#split-160-and-192-kib-queues-across-the-services) · [Rebuilt worker readiness](../2026-11-24/gamma-ci-concurrency/20261124T165007Z-link-peer-bca5lu92/publication-readiness.json)

With Docker CPU sets applied on both engines, each service could run on one of two guest CPU pairs. Two fresh boots delivered 8,671 versus 8,129 MiB/s, with Micropod winning all 16 paired throughput comparisons. Fresh p95 was 12.09 versus 56.59 ms and the slowest stream delivered 227 versus 142 MiB/s. Micropod finished provisioning through cleanup earlier in 14/16 pairs. OrbStack reached the last build exit earlier in 15/16 pairs. These measurements used the updated Linux runner and the previously authorized Mac relay. The rebuilt Mac relay independently reported a Local Network denial from its launch agent. [Mixed CI measurements and build identities](../2026-11-24/gamma-ci-concurrency/published-link-results.md#native-docker-cpu-placement-with-files-and-memory-together) · [Mac permission diagnostic](../2026-11-24/gamma-ci-concurrency/published-link-results.md#local-network-permission-on-the-rebuilt-mac-relay)

With the same CPU placement and the full-preemption 16 KiB guest kernel, Micropod finished the last build earlier in all eight pairs in the independent run with the ordinary CI command. Last-job time was 12.09 versus 13.20 s, throughput was 9,254 versus 8,023 MiB/s, and fresh p95 was 9.68 versus 51.84 ms. Provisioning through final cleanup took 14.19 versus 16.48 s. The signed release passed the 16 KiB recovery and OOM tests. Published traffic used the earlier authorized Mac relay. [Matched 4 and 16 KiB kernels and independent CI results](../2026-11-24/gamma-ci-concurrency/kernel-page-results.md)

The 21 November one-port holdout below used the earlier relay.

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

On the signed 16 KiB CI worker with 64 containers, sharing one vCPU per communicating pair raised Micropod’s short-burst throughput by a paired 10.4%. In 500 ms sustained traffic at that placement, Micropod served 190,420 requests/s versus OrbStack’s 163,492. Their request p99s were 2.52 and 0.65 ms, respectively. The shortest quiet Micropod median was 46.7 µs with paired placement, versus 38.1 µs for unrestricted OrbStack. [64-container HTTP comparison](../2026-11-24/gamma-ci-concurrency/sibling-results.md)

With eight concurrent two-revision Go builds at nice +5, inherited container weights and 32 active same-vCPU pairs, Linux runner `b4b4bdb7` served 183,214 requests/s versus 161,438 for OrbStack. The builds finished in 3.15 versus 3.26 s. Micropod led both measures in all eight pairs. OrbStack’s request p99 was 1.00 ms versus Micropod’s 3.39 ms. [Concurrent builds and dependency traffic](../2026-11-24/gamma-ci-concurrency/sibling-results.md#native-docker-cpu-shares)

## What remains to win

The [optimization register](../../research/2026-11-23-optimization-register.md) links each research direction to its GitHub row, evidence and next check. Two local Go series measured 48–51% less time packing a single IPv4 service reply and 320 B/op versus 1,072 B/op. The end-to-end DNS rows above still use the earlier guest. [Raw encoder samples and compatibility checks](dns-answer-encoding.txt)

1. **Fresh latency during published downloads.** The four-vCPU local peer holdout cleared the throughput and 75 ms p95 criteria. OrbStack still served small requests faster. The gap after client dispatch was at least 3.58 ms at p95 in every controlled pair. This is the remaining measured latency target for this workload. [24 November peer result](../2026-11-24/gamma-local-peer/results.md) · [Original benchmark handoff](gamma-throughput-gap.md)
2. **Quiet service calls.** Socket-verified quiet HTTP on the current signed worker took 72.6 µs at median with unrestricted placement and 46.7 µs when the client and service shared a vCPU. OrbStack took 38.1 µs unrestricted. A shorter fair-scheduler slice also reduced busy tail latency at a throughput cost. Quiet DNS on the revised guest still needs a matched measurement. [Quiet HTTP history](quiet-service-http.md) · [Signed-worker comparison](../2026-11-24/gamma-ci-concurrency/sibling-results.md)
3. **Unscored product fronts.** Comparable cold boot and first build, filesystem edit propagation, durable guest I/O, idle host memory and reclaim, energy, amd64 translation, and desktop sleep/wake and update recovery need matched results. Individual Micropod qualification and offline regression passes establish correctness in their test cases. They do not establish a peer lead.

## Local changes awaiting matched product runs

| Component | Micropod measurement | Remaining comparison |
| --- | --- | --- |
| Fresh connection setup | Deferring kqueue read-filter registration saved 6.68% of asynchronous setup CPU and 2.52% of full-flow relay CPU in a local stream fixture. [Confirmation](relay-handshake-reads-confirmation.json) | Actual published TCP throughput and fresh p95/p99 at the same worker count. |
| CI suite preparation | Six packages took 5.180 → 4.615 s to compile with empty action caches and 0.989 → 0.440 s warm. Generated artifacts matched. A separate exact-hit fixture reduced host preparer time from 23.5 to 16.3 ms with a scripted image inspection. [Compile measurements](go-suite-compile-local.json) · [Cache-hit fixture](go-suite-hit-local.json) | Measure changed revisions and exact image hits on the worker with the real Docker engine. |
| Service DNS | In eight paired runs of the local handler, eight-address A took 389 → 344 ns and truncated 256-address A took 964 → 122 ns. Single-address A stayed near 210 ns. Missing names and a single address with EDNS cost about 4 ns more. A previous change reduced single-service AAAA from 277 to 120 ns. [Replica lookup](dns-replica-bounded.json) · [Question lookup](dns-question-lookup.md) | End-to-end p95 for the same A/AAAA mix at one and 32 resolvers, including publication churn. |
| Docker logs and attach | On a local file-backed spool of 1,024 mixed 96-byte records, replay throughput improved 2.45× for both streams, 2.07× for stdout-only and 2.29× for stderr-only across 12 paired blocks. Allocations fell from 1,025 to 25. The intervals included parity for single records and 64 KiB frames. [Raw results](docker-output-frames.json) | Matched user-visible logs and attach in a running guest, including follow latency. |
| Shared-folder edits | With 256 unrelated files, nested edit handling fell from 18.13 to 1.05 ms. With 2,048 unrelated files, deletion then fell from 420 to 240 µs and repeat deletion from 241 to 62 µs. The index added about 192 KiB during large-fixture initialization. [Subtree scans](shared-view-directory-local.json) · [Deletion index](shared-view-index-local.json) | Automatic event delivery and time until the guest sees the verified edit. |
| Desktop stats | Selecting 1,024 distinct IDs fell from 2.724 to 0.183 ms. A 16-ID selection rose from 1.108 to 1.138 µs. [Native Swift samples](native-stats-selection.json) | Full desktop polling and XPC cost. |

Both the host relay scorer and new peer holdouts verify the raw listener count. Peer runs also bind the actual client arguments and service marker. The first-build fixture checks for empty Go caches and a pinned module. A partially warm control took 0.175 s and invoked the compiler once, versus 3.702 s and 106 compiler or assembler invocations from empty stores. [Host scorer](../../../scripts/relaybench/test_compare.py) · [Peer verifier](../../../scripts/relaybench/peer_verdict.py) · [First-build control](first-go-build-local.json)

At 20:53 AEDT on 23 November, Gamma’s isolated Linux worker held its only lease. The isolated owner handoff is pending. [Performance backlog](https://github.com/castlemilk/micropod/issues/227)
