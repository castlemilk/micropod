# Relay read size, final reads and CI log decoding

The historical four-vCPU mixed TCP holdout put Micropod at 2,709.8 MiB/s and OrbStack at 3,010.4 MiB/s. At 22:59 AEDT on 23 November, Cuttlefish reported one of one isolated Linux slots and four of six Gamma Mac slots leased. All results below were collected offline. [VM holdout and workload](gamma-throughput-gap.md)

## Serving a fresh reply alongside bulk downloads

Sixteen established streams shared one native Darwin relay owner. We varied how many streams had data ready. For the table, each ready stream supplied 512 KiB. The fixture inserted a one-byte reply immediately after the first bulk write. Each cell shows the number of bulk reads needed to deliver the whole payload and the KiB delivered ahead of that reply.

| Ready downloads | Fixed 256 KiB | Fixed 512 KiB | 512 KiB when at most two events are ready | One larger read per such poll |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 2 / 0 | 1 / 0 | 1 / 0 | 1 / 0 |
| 2 | 4 / 256 | 2 / 512 | 2 / 512 | 3 / 256 |
| 3 | 6 / 512 | 3 / 1,024 | 6 / 512 | 6 / 512 |
| 16 | 32 / 3,840 | 16 / 7,680 | 32 / 3,840 | 32 / 3,840 |

The one-larger-read policy saved a read with one or two ready downloads while matching the 256 KiB control's queued bytes at each tested arrival position. A separate case made the reply ready before polling, and all four policies served it first. The count and sanitizer runs also covered backpressure, half-close in both directions, and a nearly exhausted callback budget. A marker inserted between writes measures service order. It cannot measure the delay of a real request that arrives during a write.

We timed 12 balanced blocks per schedule, with 88 MiB verified per arm and block. Timings include a single-threaded producer, the relay, a consumer and payload checks. On alternating ready counts, the one-larger-read policy changed throughput by +0.75% against fixed 256 KiB, with a paired bootstrap interval of −13.39% to +68.76%. The interval included zero under all three schedules. Both adaptive policies remain benchmark-only. [Raw timings, counts, hashes and qualification](relay-sparse-read-budget.json) · [Reproduction driver](../../../scripts/relaybench/sparse_read_budget.py)

The opt-in relay profile now counts full-cap reads on established bulk downloads for which the kernel hinted more data was available. It counts the subset from polls that returned at most two events and had room to receive a third. A separate Gamma diagnostic lease at the chosen worker count can measure how often this opportunity occurs. Keep profiling disabled for scored runs. [Profile fixture and source hashes](relay-read-opportunity.json)

## Closing a connection on its final data read

A fixture-only change handles a graceful FIN immediately when a normal read event reports the exact remaining byte count and the relay forwards all of it. With a 148-byte reply, reads fell from two to one and readiness polls from three to two. With 262,257 bytes, reads fell from three to two and polls from four to three. A delayed FIN, partial writes and flagged terminal events retained the stock read counts. The local socket tests cover both directions and lease revocation. The occurrence rate on TCP remains unknown. [Sanitizer results and call counts](relay-final-read-fin.json)

## Decoding CI logs

The guest runner now consumes complete container log records directly from its buffered reader. It retains partial records across reads and preserves their output order. In 12 paired blocks of 1,024 interleaved 96-byte records, decoding to stdout/stderr was 2.16× faster and emitting the actual CI JSON was 1.33× faster (95% paired interval 1.27–1.36×). Both variants produced identical bytes. JSON-path allocations fell from 4,098 to 2,049 per batch. Single-record and 64 KiB-record timing intervals included parity.

Three focused decoder tests passed. The full Linux/arm64 runner test binary cross-compiled offline. End-to-end guest log latency still needs a running container. [Raw CI log samples](cri-log-decoding.json) · [Decoder tests](../../../guest/runner/cri_output_linux_test.go)
