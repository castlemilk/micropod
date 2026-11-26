# Yield to a queued relay handoff

A new connection received its first reply earlier in two of three tested positions in an 8 MiB bulk burst. With no new connection, both arms finished the bulk burst in four nonempty kqueue polls within one productive callback.

| Handoff enqueued after bulk write | Bulk ahead of handoff entry, control → yield | Bulk ahead of first readable reply, control → yield |
| ---: | ---: | ---: |
| 1 of 32 | 7.75 → 1.75 MiB | 7.75 → 3.75 MiB |
| 16 of 32 | 4.00 → 0.00 MiB | 4.00 → 2.00 MiB |
| 25 of 32 | 1.75 → 1.75 MiB | 1.75 → 1.75 MiB |

The fixture ran a native dedicated data owner on a serial dispatch queue with eight established downloads on Darwin anonymous stream socketpairs. Both arms used the same executable, 128-event callback budget, 24-event poll capacity, ordinary readiness and 256 KiB maximum read. The fixture queued exactly one asynchronous handoff on that owner's queue when the designated bulk write succeeded. The candidate finished every event in the current poll and returned if the handoff was waiting. The control continued its ordinary drain. The no-handoff case exercised the same data path with eight established flows.

At handoff entry the fixture staged a connected socketpair in the state used for asynchronous connect completion and supplied a one-byte server-first reply. When that byte became readable at the client, the fixture peeked at its value and counted the bytes available in the eight receiving bulk sockets. Every trial checked all 8 MiB of per-flow data, reverse markers, both half-closes and final flow retirement. Control and candidate ran twice in opposite orders. An independent rebuild and replay returned byte-identical JSON.

These measurements establish ordering for the selected arrival positions. Dispatch callbacks after yielding were submitted explicitly. Real accept timing, TCP connection establishment, system scheduling, CPU cost per poll, MiB/s, and fresh-request latency need a timed comparison. The candidate remains confined to the benchmark patch.

Run `python3 -B run.py` in this directory on Darwin. The driver copies the source into a temporary directory before building. The four source hashes, patch hash, compiler flags, macOS version and 16 raw trials are in [result.json](result.json). Its SHA-256 is `f9a2dd333ce0e4db56c3e044abf128dddf0246404b3185d7f2c962f0e5248d98`.
