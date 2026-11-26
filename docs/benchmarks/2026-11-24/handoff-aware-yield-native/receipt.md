# Native relay candidate for queued handoffs

The benchmark patch connects the Swift accept path to the C data owner. Both normal and profiled adoptions increment the destination owner's atomic counter immediately before queue submission and decrement it once at entry. A dedicated data callback finishes every event already returned by kqueue, then yields if its owner has queued handoffs. Each accepted descriptor still goes through the existing adoption and serial release paths. Both builds used the same 128-event ceiling and 256 KiB read cap. [Candidate patch](candidate.patch)

Two bounded checks ran twice with the native Swift dispatch source on macOS 26.5.1, ARM64. Both repetitions returned identical observations. [Raw observations, compiler versions and source hashes](result.json)

| Check | Observation |
| --- | --- |
| Overlapping admissions on two owners | Pending counts on the two owners went from (2, 1) to (1, 1), (0, 1) and (0, 0). Three Swift adoption closures reached the C entry point, including one profiled admission. Invalid descriptors exercised the setup-error path before dialing. |
| Automatic drain after a yield | With one synthetic handoff signal held pending, the receiver verified 786,432 bytes and EOF. The real dispatch source ran three productive callbacks, each forwarding 262,144 bytes. The test issued no follow-up drain calls. |

The same native candidate C source reproduced the earlier ordering experiment across 16 trials. The workload adapter signals the actual destination owner's enqueue/start functions on candidate trials. The control leaves the same binary's counter at zero. Both arms verified every byte of eight 1 MiB streams, the fresh marker when offered, and all half-closes. The no-handoff case still finished in one productive callback on both arms. [Original fixed-work experiment](../handoff-aware-yield/receipt.md) · [Workload adapter](ordering-adapter.patch)

| Enqueue after bulk write | Bulk bytes ahead of first readable reply, control → candidate |
| ---: | ---: |
| 1 of 32 | 7.75 → 3.75 MiB |
| 16 of 32 | 4.00 → 2.00 MiB |
| 25 of 32 | 1.75 → 1.75 MiB |

The ordering sweep stages the fresh accepted socketpair and submits subsequent drain callbacks explicitly. The separate Swift check above verifies automatic dispatch resumption but uses an invalid descriptor for the adoption probes. TCP handshakes, scheduled latency, CPU cost and VM throughput remain unmeasured.

Run `python3 -B run.py` in this directory on Darwin to reproduce. The driver extracts the three original sources from `2e9b37c1e68334c443d71b729f0bd6334d824ddd` into a temporary tree, compiles the stock and candidate executables against the existing relay main, and runs the socketpair checks. Its C instrumentation records complete callback byte totals, and its Swift test extension can access the actual private target and owner queues. [Build and test driver](run.py)
