**24 November 2026 · 230.10 · Can the producer bound the TCP send queue before admitting another bulk write?**

Local/host-only, Darwin 25.5.0 arm64. The native fixture invoked Micropod’s stock `prepare()` at revision `7bec8a7246f30e1a275f5d2c8568c53566d91490`. Each fresh private IPv4 loopback connection had one writer, TCP_NODELAY enabled, TCP_NOTSENT_LOWAT at its inherited zero and identical socket options. The 512 KiB send-buffer request read back as 538,956 B, the listener’s 8 KiB receive-buffer request as 8,192 B, and the accepted peer’s initial receive buffer as 326,640 B in every arm. The receiver held application reads for two 256 KiB bulk offers, followed by a 17 B marker. The producer could prioritize this marker ahead of bulk bytes its TCP socket had yet to accept. It subsequently delivered the full bulk remainder in order.

The control attempted each offer in full. The candidate changed only producer admission. Each nonblocking send could admit at most the positive difference between 65,536 B and the current `TCP_CONNECTION_INFO.tcpi_snd_sbbytes` readback. That Darwin field includes in-flight data. Both arms read the same counters around each offer and used the same receiver checks and drain acknowledgements.

| Observation | Eager | 64 KiB admission budget |
| --- | ---: | ---: |
| Highest sampled sender backlog per connection | 458,960–524,288 B | 65,536 B in 8/8 |
| Bulk bytes verified by receiver before marker | 524,288 B in 8/8 | 65,536 B in 6/8, 131,072 B in 2/8 |
| Marker admitted in full while receiver still held reads | 8/8 | 1/8 |
| Ordered bulk, full marker and both EOFs | 8/8 | 8/8 |
| Sender and peer reported retransmitted packets | 0 | 0 |

Eight randomized, order-balanced pairs, four per order, all 16 first attempts retained. The budget reduced bytes ahead of the marker in 8/8 pairs. The second bulk write encountered 0 B in the sender buffer in two candidate connections, permitting another 65,536 B even though the receiving application had not read. The kernel can acknowledge data already buffered at the peer. The reported ranges describe this host and workload. Each connection verified 524,288 bulk bytes and all 17 marker bytes with exact sequence and half-close checks. Packet-capture loss, throughput, fresh p95/p99, CPU/GiB and runnable time were unmeasured.

**Verdict.** The application budget bounded sampled sender occupancy and reduced bytes ahead of a newly available marker. It also deferred admitting the marker until receiver drain in seven pairs. This fixture’s producer owns the stream’s serialization order. An existing transparent TCP relay must preserve source order, and independent connections do not share this stream. Keep stock. Establish which service-path socket actually builds up queued data, using per-socket send-queue observations and matching receiver progress, before any timed comparison under the delivery and latency guardrails.

Local raw-verified report `admission.receipt.md` and all first attempts in `admission-first.jsonl` (SHA-256 `4c74519e336f65db741629bad0bb32ffa9ff9ee83f0a2cddd31661a3e7438337`). Fixture `admission.c` SHA-256 `8ec34a442f351363b59f62f6a005485e9ff9af2e8085c13b0910daa7a8ac5f38`. Run `python3 -B reproduce.py NEW.jsonl` and `python3 -B verify.py NEW.jsonl` from `batch08-native-admission` on Darwin with Apple clang. The raw header records source pins, toolchain and randomized order.
