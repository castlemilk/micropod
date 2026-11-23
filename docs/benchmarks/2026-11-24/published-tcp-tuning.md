# Published TCP tuning on 24 November

A 17-byte reply on a connection that had previously carried bulk data waited behind up to 1 MiB of other downloads in the stock relay. A scheduling change removed that wait when the reply was visible in the same kqueue batch. With the reply queued last, its median per-run p95 fell from 159.1 to 5.9 µs. The local throughput measurements were inconclusive. The last end-to-end clean medians on Gamma remain 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. [Historical VM comparison](../2026-11-23/gamma-throughput-gap.md)

## Service order within a relay callback

The experiment keeps new flows first. On a connection already classified as bulk, a read with 1–4,096 bytes ready gets one turn ahead of larger reads in the same batch. It caps that turn at 4,096 bytes in case more data arrives between the kernel's readiness notification and the actual read. The patch applies to the benchmark copy of the relay. [Candidate patch](../../../scripts/relaybench/short_reused_ready.patch)

Sixteen connections each supplied 64 KiB. A seventeenth supplied the tagged 17-byte reply. An unclassified connection supplied one byte and always went first. Both builds verified all payloads and preserved the relative order of the sixteen bulk streams. [All 17 insertion positions](relay-short-reused-positions.json)

| Bulk streams queued before the tagged reply | Bytes forwarded before it on stock | Bytes forwarded before it on candidate |
| ---: | ---: | ---: |
| 0 | 1 | 1 |
| 8 | 524,289 | 1 |
| 16 | 1,048,577 | 1 |

The timing fixture put the tagged reply last. Each arm ran 64 waves per sample, with 16 balanced pairs per workload. The reply clock runs from relay callback entry to the successful write on a Darwin socketpair. Throughput includes producing and verifying the payloads. Paired intervals resample whole pairs. [Raw samples, build hashes and timing method](relay-short-reused-timing.json)

| Local metric | Stock median | Candidate median | Median paired change (95% interval) |
| --- | ---: | ---: | ---: |
| Tagged reply p95 | 159.1 µs | 5.9 µs | −96.3% (−97.4% to −95.7%) |
| Tagged reply p99 | 254.7 µs | 9.2 µs | −96.7% (−97.6% to −93.9%) |
| Mixed throughput | 3,044 MiB/s | 3,158 MiB/s | +3.4% (−2.1% to +12.4%) |
| Bulk-only throughput | 3,233 MiB/s | 3,277 MiB/s | +1.2% (−0.8% to +5.5%) |
| Mixed relay CPU per GiB | 133.2 ms | 132.6 ms | −0.6% (−5.1% to +2.7%) |

When eight downloads each presented a 4 KiB tail, giving the tails and tagged reply priority put 32,785 extra bytes ahead of the first large download. With 32 full downloads, the first 24-event poll could already contain 1.5 MiB of work before the relay saw the next unclassified flow. A 64 KiB burst arriving after a 17-byte notification required a second poll under the cap. These cases make an established request/reply workload the useful next test for this patch. The stock Gamma workload opens fresh connections for its small requests. [Boundary cases, payload and half-close checks](relay-short-reused-ready.json)

## Load-client CPU cost

The pinned load client counts bytes after every response body chunk. In a separate memory-only experiment, spacing the 32 active stream counters 128 bytes apart increased copy throughput by 7.8% (95% paired interval +3.5% to +12.0%) with 32 KiB chunks and by 61.1% (+54.9% to +73.9%) with 4 KiB chunks. CPU per GiB fell 6.9% and 39.2%, respectively. Both single-writer throughput intervals included zero. Even the packed counters sustained 197 GiB/s with 32 writers and 32 KiB chunks in this fixture. Keep the pinned client identical on both sides of the VM comparison. [All 64 pairs and source hashes](offered-counter-layout.json)

## Next Gamma measurement

At 09:46 AEDT on 24 November, the isolated Linux runner held its only slot. The first released window still goes to the stock four-vCPU, two-worker baseline. Its verifier now checks 32 positive integer byte counts against total bytes, elapsed time and reported throughput for both warmup and scoring. [Fleet observation](gamma-fleet-0946-aedt.json)

The subsequent one-port pilot holds the VM at four vCPUs and the callback budget at 128. Both jobs must match on the saved launch controls, loaded Micropod environment and observed supervisor nice value after accounting for their scope and selected worker count. The two-pair screen requires four workers to improve on two in both run orders, clean scored attempts, a candidate fresh p95 of at most 75 ms, and measured host costs. A positive median from a split decision is recorded with a rejection. An incomplete pair suppresses the aggregate. The independent peer holdout remains the test of the historical 300.6 MiB/s gap. [Pilot commands](../2026-11-23/gamma-throughput-gap.md#first-released-window)

## Reproduce offline

The relay suite passed 105 tests in 15.838 s. The stock baseline suite passed 23 tests in 0.334 s. The offered-load client passed its Go race tests in 1.030 s. A fresh offline tool build reproduced the pinned client SHA-256 `4f6877088bf57a659e59249437aadd782b121a96fa3e600cf83ad981d170ca53`.

Run these from the performance checkout on Darwin arm64 with Go 1.27.2 on PATH. The stock verifier lives in the sibling kernel-path checkout at `a5f0e19e`.

```sh
python3 -B scripts/relaybench/test_short_reused_ready.py
python3 -B scripts/relaybench/test_short_reused_positions.py
python3 -B scripts/relaybench/short_reused_timing.py
python3 -B scripts/bench_offered_counter_layout.py
python3 -B -m unittest discover -s scripts/relaybench -p 'test_*.py' -q
GO111MODULE=off GOPROXY=off go test -race -p 2 -count 1 -cpu 2 ./scripts/netbench/offered
(cd ../kernel-path-20261122 && MICROPOD_RELAY_SOURCE=../phase0-host-scheduling python3 -B -m unittest discover -s scripts -p test_gamma_path.py -q)
```
