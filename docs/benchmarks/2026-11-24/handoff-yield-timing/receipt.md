# Yielding to a queued handoff during a bulk burst

On Gamma, yielding the native relay owner after a kqueue poll reduced the time a queued stream waited to receive its first byte. Its p95 fell from **0.552 to 0.285 ms**. The candidate improved p95 in seven of eight paired blocks. Bulk throughput and callback CPU cost showed no clear improvement. Keep this as a candidate for a live latency comparison.

| Measurement | Stock owner | Yield when handoff queued | Median paired change | 95% paired bootstrap interval |
| --- | ---: | ---: | ---: | ---: |
| Handoff enqueue to owner entry, p95 | 0.532 ms | 0.126 ms | −76.0% | −77.5% to −73.6% |
| Handoff enqueue to received marker, p95 | 0.552 ms | 0.285 ms | −45.6% | −50.7% to −39.3% |
| Handoff enqueue to received marker, p99 | 0.657 ms | 0.427 ms | −44.7% | −56.4% to +15.1% |
| Verified bulk burst | 9,139 MiB/s | 8,787 MiB/s | −3.58% | −15.85% to +3.98% |
| Data-drain callback CPU per verified bulk GiB | 0.0732 s | 0.0751 s | +2.24% | −4.76% to +16.89% |

The revised stock and candidate relay used the same four fixed controls: one measured dedicated owner, a user-initiated serial dispatch queue, 128 events per callback and a 256 KiB read cap. The benchmark built the stock C relay at `2e9b37c1e68334c443d71b729f0bd6334d824ddd` and the existing native candidate patch. The candidate publishes a pending-admission count and ends a data callback after serving a complete poll when an admission is pending. The Darwin dispatch source automatically scheduled subsequent callbacks. Both arms recorded two data-drain callbacks in every scored wave. [Native candidate patch](../handoff-aware-yield-native/candidate.patch) · [Earlier ordering experiment](../handoff-aware-yield/sweep.md)

Each wave started with eight established flows on anonymous Darwin stream socketpairs, primed for bulk delivery, with a verified 1 MiB payload offered on each. On a prescribed successful bulk write, the fixture enqueued one additional stream on the same serial queue. Its adoption staged socketpairs at asynchronous-connect completion; the guest side sent a one-byte marker. A separate thread read and checked the marker. The main thread independently read and checked the bulk payloads. Each arm delivered four scored GiB, 512 scored markers and 9,216 ordered half-closes. Every flow retired.

Bulk time runs from resuming the dispatch source to final verified bulk consumption. Callback CPU covers the relay drain on the queue and excludes the separate stream-adoption closure. Neither measure includes bulk fixture creation or teardown. Marker latency begins at handoff enqueue. It includes scheduling the adoption, staging the stream, forwarding the byte and scheduling the receiving thread. These are host-only local-stream measurements with deliberately synchronized bursts; a TCP accept, a guest VM and OrbStack were outside the workload.

The predeclared eight paired blocks used seed `230062411`, four blocks in each arm order and two excluded warmups per arm per block. Each block exercised every arrival position 1–32 twice in randomized order, shared by both arms. The table gives arm medians across blocks. Each block's p95 and p99 are nearest-rank statistics over 64 first-byte observations, so its p99 is the block maximum. The paired intervals resample entire blocks 20,000 times. All first attempts are retained, including a block with 35.2% lower candidate throughput. System-wide load and thermal variation were uncontrolled. The measured burst rates are unsuitable for comparison to the published-TCP VM baseline.

Run `python3 -B run.py summary first-attempts.json` to reproduce the table. The raw receipt SHA-256 is `bfa40eb5975da7462adf84bfd088958526c2fd7c1eb2731d36abc17f31465517`. [Raw waves, schedule, source and binary digests](first-attempts.json) · [Build and scoring driver](run.py) · [Socketpair workload](burst.c)
