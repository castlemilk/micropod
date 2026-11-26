# Published TCP connection teardown and CPU cost

The last four-vCPU Gamma holdout measured clean medians of 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. The 300.6 MiB/s gap still awaits a fresh paired VM measurement. [Original measurements](throughput-alignment-and-vmm.md)

## One fewer kernel call on the last FIN

The Darwin relay disables the read filter when it sees EOF in either direction. On the last EOF, it immediately shuts down the peer's write side and retires both descriptors. Closing the descriptors already removes their filters. A benchmark patch skips that final disable. The first FIN still disables its filter and leaves the other direction available to send its response.

A native socket-pair fixture exercised both close orders, flat and split queues, backpressure with a retained suffix, and a flagged terminal error. Each orderly close saved one actual `kevent` submission. The 12 cases per arm verified payload order, EOF and shutdown counts under address and undefined-behavior sanitizers. [Candidate patch](../../../scripts/relaybench/retiring_read_filter.patch) · [Raw call counts and CPU samples](relay-retiring-read-filter.json)

Each of 16 pairs ran 512 immediate and 512 asynchronous flows per arm. For asynchronous setups, stock used 21.93 µs of relay CPU per flow and the candidate used 21.38 µs. The paired change was −2.47% (95% interval −4.61% to +2.13%). The immediate setup control changed by +0.89% (−5.97% to +2.98%). The saving applies once per orderly connection, and the 32 established bulk streams carry many downloads per connection. The candidate stays in the benchmark fixture.

## Count the bytes covered by the host CPU measurement

In the archived holdout the host process snapshots bracketed client startup, six seconds of scoring, and the wait for the last responses. The client recorded bytes only during scoring. Across the 15 pairs clean on both engines, the median host time outside the bulk interval was 187.84 ms on Micropod and 1,307.93 ms on OrbStack. These are wall durations. The archive has insufficient data to assign CPU or payload to the extra time. [All 38 invocations, both run orders and original archive hash](holdout-counter-windows.json)

The updated client emits per-stream and total body bytes for warmup, scoring, drain, and the whole invocation. The host pilot records CPU seconds per full-invocation bulk GiB and hardware counters per full-invocation bulk byte for each observed process. The peer scorer recomputes CPU cost from raw counters and the verified byte totals. It reports the historical CPU-per-scored-GiB calculation separately. The new denominator covers all `/data` response bodies. The numerator includes setup, fresh requests, and any other work by the observed processes between the snapshots. CPU specific to the six-second window still requires sampling at its boundaries.

In a deterministic in-memory HTTP test, delaying only the last fresh response by three seconds left the scored bytes at 2,048 MiB. Drain traffic rose from 256 to 1,280 MiB. The new totals record 2,560 and 3,584 MiB for those invocations. [Client and delayed-drain regression](../../../scripts/netbench/offered/bulk_bytes_test.go)

Use the tools built from this checkout on both arms of the subsequent worker comparison. The Darwin arm64 load client built with Go 1.27.2 has SHA-256 `4f6877088bf57a659e59249437aadd782b121a96fa3e600cf83ad981d170ca53`. Older pinned peer receipts remain replayable and report the full-invocation cost as unknown.

```sh
python3 -B scripts/relaybench/holdout_counter_windows.py | cmp - docs/benchmarks/2026-11-23/holdout-counter-windows.json
python3 -B -m unittest discover -s scripts/relaybench -p 'test_*.py' -q
GO111MODULE=off GOPROXY=off go test -race -p 2 -count 3 -cpu 2 ./scripts/netbench/offered
python3 -B scripts/relaybench/build_host_role_tools.py "$NEW_TOOLS"
```

At 23:36 AEDT on 23 November, Cuttlefish reported one of one slots leased on the isolated Linux runner and zero of six on the Gamma Mac. The first eligible measurement remains the stock four-vCPU, two-worker baseline after the warm-CI owner releases the slot and current disk clearance is established. The stock scorer now checks that service TX bytes and the VMM and relay process counters advance or stay equal between warmup and scoring. Its regression rejected seven receipts that passed the old checks after reusing warmup counts. The worker comparison then varies two versus four workers at fixed four vCPUs. A fresh matched peer holdout determines the end-to-end gap.
