# UI performance evaluation — 1 October 2026

This round measures the desktop UI separately from guest VM memory and runtime throughput. The comparison uses the previous responsive release bundle and a new optimized release build on the same macOS 26.5.1 host. Raw results are in [baseline-foreground.json](performance/baseline-foreground.json), [optimized-foreground.json](performance/optimized-foreground.json) and [model-benchmarks.json](performance/model-benchmarks.json).

## Desktop measurements

Values below are the median of two foreground runs per case. Memory is measured at the end of the sampling window; each timing column compares the corresponding per-run measurements.

| Synthetic inventory / view | Physical footprint, MiB before → after | Resident memory, MiB before → after | CPU, % of one core before → after | Main-actor ping p95, ms before → after |
| --- | --- | --- | --- | --- |
| 10 / Workloads | 115.30 → 115.70 | 186.51 → 188.63 | 0.56 → 0.37 | 2.710 → 0.316 |
| 10 / Overview | 140.40 → 140.25 | 211.32 → 210.90 | 0.31 → 0.31 | 0.290 → 0.305 |
| 1,000 / Workloads | 133.55 → 133.60 | 206.51 → 206.50 | 1.31 → 0.75 | 0.851 → 0.383 |
| 1,000 / Overview | 305.95 → 149.65 | 375.95 → 221.15 | 0.56 → 0.74 | 0.321 → 0.363 |

The large-inventory overview uses **51% less physical memory** and **41% less resident memory**. Its running-workload preview renders eight rows, with the full inventory accessible through View all. Other views' steady memory is approximately unchanged. Every optimized case consumed less than 1% of one CPU core during the sampling window, and every per-run p95 main-actor ping was below 0.45 ms. Workloads CPU decreased; overview CPU at 1,000 workloads increased slightly, so the measurements do not establish a CPU improvement for every view.

The optimization round's final profile has binary SHA-256 `baa5b29c5c5ae6ecc2ae7266dc1943e04563292f6769f9dfa691eff3afb6bfb2`, matching its release bundle at that point. The final comparison ran after compilation and smoke checks had completed. The subsequent [2 October visual refinement](refinement.md) rebuilds the bundle with shared design-system components.

## Changes

- Workload metadata, search text, grouping and selected-item indexes reuse the current inventory. Metrics ticks update values without rebuilding labels and ports. Observed revision counters keep cached views reactive; unchanged inventory polls preserve their metadata revision.
- The overview shows eight running workloads with a View all action. Network topology indexes attachments once, builds nodes lazily and draws edges into a viewport-sized canvas rather than a bitmap spanning the full graph.
- Log and terminal decoding, upstream pull/build event parsing, and bounded stream retention run away from the UI actor. They publish the latest bounded snapshot on a 33 ms cadence, with no idle timer. Build-stage interpretation remains on the UI actor but caches its parsed stages and joined output, processing only changed retained lines. Search indexes also reuse retained data.
- Native log readers use 64 KiB chunks and seek backward for requested tails. Bounded backpressure preserves full ordinary native CLI/MCP output. EOF and cancellation close file handles and reap PTY children.
- History queries, JSON formatting and storage sizing run on utility tasks. Launch restores only current machine histories. Expensive chart tasks cancel when the native window is minimized, occluded, closed or hidden. Hidden metrics polling has a 30-second minimum interval; invalid polling preferences cannot cause a tight loop.

## Retained output budgets

| Data | Budget | Overflow behavior |
| --- | --- | --- |
| Rendered logs | 1,000 rows and 1 MiB; 16 KiB per row | Keep newest rows, show eviction/truncation counts |
| Terminal scrollback | 256 KiB | Keep newest whole characters; show eviction notice |
| Terminal raw delivery | 1 MiB | Explicit error and detach; preserve byte-stream correctness |
| CLI raw delivery | At most 64 × 64 KiB | Explicit slow-consumer error; stop and reap producer |
| CLI complete-line delivery | 64 lines of at most 16 KiB plus truncation markers | Backpressure preserves complete-line order |
| Native log delivery | Eight complete lines; each line at most 1 MiB | Backpressure; oversized lines fail explicitly |
| Operation output | 512 events / 128 KiB per operation; 8 KiB per event | Keep newest events; show trimmed-output notice |
| Completed operations | Newest 100, plus running operations | Discard oldest completed history |
| In-memory metrics | At most 2,500 samples per current series | Trim oldest samples; historical charts query SQLite |

These limits describe payload retention; object overhead, view caches and transient snapshots add memory beyond those values. Visible output trimming does not delete source log files. Native full-log consumers preserve ordinary output; exceptionally long lines have an explicit delivery limit.

## Optimized model measurements

Two release-mode runs use identical synthetic inventories. They compare the unchanged pure mapping/grouping routines with their cached equivalents. No hardware-dependent timing threshold is enforced by the tests.

| Workloads | Full inventory mapping | Metrics overlay using cached metadata | Full grouping/sorting | Repeated cached read |
| --- | --- | --- | --- | --- |
| 1,000 | 1.11–1.13 ms | 0.35–0.40 ms | 1.26 ms | Under 0.001 ms |
| 5,000 | 5.70–6.25 ms | 2.11–2.13 ms | 6.62–7.08 ms | Under 0.001 ms |

The constant-time cached-read microbenchmark excludes SwiftUI rendering and Observation overhead. It measures repeated reads of an unchanged model, not an end-to-end interaction. Metric overlays still scale with inventory size; search/filter changes still perform a new filter and sort.

Native full-log delivery preserved all 20,000 lines in order using the eight-line queue. Throughput varied from approximately 21,000 to 68,000 lines/s across the two runs; scheduler and host activity affect this result. It is a synthetic warm-file measurement, without an old/new throughput comparison.

## Method and scope

`scripts/profile_ui.py` launches isolated app processes with 10 and 1,000 synthetic workloads, disables managed agents, automatic updates and CLI-link management, and uses private control sockets. Mock stats deliberately fail and the machine inventory is empty, preventing fixture data from writing or reconciling the user's persisted metrics. Existing persisted system history may be read.

Each case warms up for four seconds, samples eight seconds of steady polling, and repeats twice. A helper requests and verifies foreground activation. `ps` reports resident memory and cumulative process CPU time; `vmmap -summary` reports macOS physical footprint. The control socket's ping runs on the main actor, providing a responsiveness probe during polling. CPU percentages use one core as 100% and exclude child CLI processes. Ping latency is not frame time, scrolling latency or a complete first-paint measurement.

The first baseline cases overlapped the end of compilation/testing; later cases ran while the host was otherwise doing normal background work. CPU times have a 0.01-second reporting resolution and the sampling windows are short. Treat timings as local observations, not cross-machine guarantees or precise launch-speed claims. The earlier non-foreground baseline and intermediate optimization profile are retained as diagnostic data but excluded from the main comparison.

No real VM, container, build, network or cache workload is stopped or benchmarked here. The measurements do not establish guest-memory savings, a cache hit speedup, sustained live-chart rendering cost or absence of all long-running leaks.

## Reproduce

```sh
python3 scripts/profile_ui.py \
  --app dist/Micropod.app/Contents/MacOS/Micropod \
  --output /tmp/micropod-ui-profile.json --foreground --footprint

MICROPOD_PERF_BENCH=1 swift test -c release --disable-swift-testing \
  --filter 'InventoryPerformanceTests|NativeLogStreamerTests.testPerformanceNativeLogBacklog'
```

The profiler opens and activates temporary app windows, terminates each process, and removes its private fixture files. Record the binary hash in each result when comparing builds. XCTest is selected explicitly because this package's other executable entry points interfere with the separate Swift Testing runner in release mode.

## Verification

The focused debug run passed 90 tests with two optional benchmark skips. The optimized run passed 199 tests with no failures, covering all app tests, the responsive native render matrix, cache invalidation and Observation, metrics storage, image progress, bounded output, terminal cleanup and native log ordering. A five-test run repeated the responsive workspace matrix and store-performance checks after the dashboard visibility adjustment. After the final cache invalidation and shared-log teardown corrections, 70 targeted release tests passed with two optional benchmark skips.

The performance guards check retention budgets and behavior rather than asserting wall-clock thresholds. They include 100,000-event/line/chunk stress cases, altered intermediate build output, split UTF-8/ANSI reads, explicit overload, close/occlusion/window migration and cancellation. Final review also corrected unchanged-status cache invalidations and verified complete-line backpressure for shared CLI/API log consumers.

The final release app rebuilt successfully, passed strict bundle-signature verification, stayed alive through the isolated six-second polling smoke check, and terminated cleanly. Strict Swift formatting checks and `git diff --check` passed for the changed files.

## Visual-refinement follow-up

The [2 October refinement report](refinement.md#post-refinement-performance-guard) records a short foreground guard for the later app build, including its matching binary hash, steady and peak footprints, CPU and main-actor responsiveness. The historical measurements above remain tied to their original binaries.
