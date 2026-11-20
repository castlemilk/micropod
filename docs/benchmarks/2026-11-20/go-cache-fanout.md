# Twenty Go jobs on one warm Gamma worker

Twenty distinct Go revisions completed vet, fresh tests and a verified build in **10.41 s on Micropod**, including the first fill of empty Linux caches. OrbStack took **13.85 s** and raw Ubuntu took **9.20 s**. These are medians of two cold runs per engine on the same Mac. Each revision produced a distinct executable, and the bytes for each revision matched across all three engines. [Per-job results, traces and controls](go-cache-fanout/measurements.json.gz)

## Where the time went

All 20 jobs already mounted one module volume and one Go build volume. On cold stores, their separate Go processes began compiling the same inputs concurrently. An unprimed burst on the four-vCPU, 4 GiB Micropod qualification worker exceeded the 360 s cutoff. Docker stopped answering health checks while the Rust service still answered. The supervisor required a restart on its journaled disk. Gamma's everyday worker retained its original boot. The failed run did not capture kernel pressure or a count of completed jobs.

Priming compiled exports and running full vet first completed in 17.85 s, but the jobs still invoked vet 385 times. Go's test command requests a different set of vet checks. The shipped `micropod ci warm-go` runs `go test -c -o /dev/null` and `go vet` on one representative checkout. Both use the job's real Go caches. The 20 different revisions then needed just 40 additional vet actions. The producer never executes a test or records a passing result. [Go test implementation](https://go.dev/src/cmd/go/internal/test/test.go)

| Cold workload on Micropod, 20 distinct revisions | Batch wall time | Compiler invocations | Vet invocations | CPU consumed |
| --- | ---: | ---: | ---: | ---: |
| Four active jobs at a time | 18.99 s | 420 | 513 | 67.74 CPU-s |
| Eight active jobs at a time | 25.07 s | 512 | 460 | 94.16 CPU-s |
| Prime once, then admit all 20 | 9.48 s | 194 | 266 | 25.95 CPU-s |

The last row includes the producer's 133 compiler and 226 vet invocations, 61 further compiler invocations across the jobs, and fresh testing and linking. The last two rows were separately profiled every 200 ms through the Rust control socket. Minimum available guest memory rose from 1,531 to 2,687 MiB, and CPU pressure stall time fell from 23.75 to 4.26 s. Full memory stalls fell from 135 ms to zero. Every pressure sample returned and neither profiled run registered an OOM kill. These counters describe those completed runs. The cause of the original timeout is unresolved. [Linux pressure stall accounting](https://docs.kernel.org/accounting/psi.html)

## Same hardware and workload

Gamma is an 18-core M5 Max with 128 GiB. All three ARM64 Linux VMs had four vCPUs and 4 GiB. Each container had one CPU and a 1 GiB limit. Raw processes shared Ubuntu's allocation. All three used the same Go 1.26.11 executable, source files, runtime-spec v1.3.0 archive and compiler flags. A local file proxy made the module available offline with its checked-in Go checksum. Every job received a private writable workspace, ran eight tests with `-count=1`, built the program and checked the revision returned by the executable.

| Workload on Gamma | Micropod | OrbStack 2.2.5 | Raw Ubuntu |
| --- | ---: | ---: | ---: |
| 20 distinct revisions, empty stores, including priming | 10.41 s | 13.85 s | 9.20 s |
| 16 jobs on one revision, warm stores, full source CI | 3.22 s | 5.66 s | 2.93 s |
| 32 jobs on one revision, warm stores, full source CI | 6.51 s | 9.94 s | 5.02 s |

The 20-job runs used the full Docker path on both engines. Each received fresh stores in both rounds, and the second round reversed the engine order. The 16- and 32-job results are medians of three rotating rounds. Micropod dispatched fresh runc containers over an open vsock session, OrbStack used Docker, and Ubuntu created a private directory for each process. Session or SSH setup was outside the warm dispatch clocks. Warm jobs still invoked all three Go commands. At 32 jobs all engines recorded 96 links and zero compiles. Micropod's three 32-job samples ranged from 4.45 to 7.31 s. [Benchmark driver](../../../scripts/bench_go_fanout.py)

## Footprint and failure recovery

One trusted scope backed the footprint experiment. Its module volume used **840 KiB** throughout, including a single 130,899-byte zip and the unpacked module. Every job observed the same device and inode for the zip and the compiled runtime-spec archive. The toolchain binary had one observed inode and the same SHA-256 across engines.

| Jobs that populated the same scope | Allocated build-cache bytes | Allocated module-cache bytes |
| --- | ---: | ---: |
| One revision, one job | 66,785,280 | 860,160 |
| The same revision, 20 more jobs | 66,805,760 | 860,160 |
| Then 20 distinct revisions | 84,627,456 | 860,160 |

Twenty identical requests against an empty scope elected one producer and 19 waiters joined. Killing the elected container released the Linux lock. A waiting request finished successfully and a later request rechecked Go's cache. An invalid package failed twice. A snapshot containing a deliberately failing test warmed successfully and failed on both real test executions. Coordination left a zero-byte lock and a 102-byte completion record.

For an identical source image and build profile, 20 simultaneous requests for the existing prepared suite published one image and 19 callers reused it. First preparation took 2.92 s for all callers. The result shared every parent layer and added 19,774,321 logical image bytes. With the suite and native session ready, three fresh 20-container test batches took **203, 162 and 153 ms**. Each ran 160 tests and checked the unchanged executable. Applications with different source can reuse compiler inputs while producing their own binaries. [Worker commands](../../ci-worker.md)

## Reproduce

Create an offline fixture from this checkout. The fixture builder reads the pinned module through the normal host Go module cache. Use the same Linux toolchain base with an empty `/workspace` on both engines.

```sh
scripts/bench_go_fanout_fixture.sh "$NEW_DIRECTORY"
docker --host "$ENGINE" buildx build --builder default --load --quiet --provenance=false \
  --build-arg "BASE=$GO_BASE" -f "$NEW_DIRECTORY/Dockerfile" "$NEW_DIRECTORY/source"
python3 scripts/bench_go_fanout.py --endpoint "$ENGINE" --image "$IMAGE_ID" \
  --scope "$QUALIFICATION_SCOPE" --warm-cli "$MICROPOD_BIN" --output /tmp/micropod-go20.json
```

For OrbStack use its socket and `--prime`. For raw Ubuntu copy the fixture's `source` under the guest workspace, install the identical Go toolchain, and pass `--ubuntu INSTANCE --workspace GUEST_PATH --prime`. The raw jobs use the same UID as the container fixture because a file-mode test exercises the setuid bit. To measure an already-warm store, omit priming. For identical source add `--same` and optionally `--handle HANDLE` on Micropod. Fresh qualification scopes make cold trials independent while preserving existing shared caches.

The receipt contains 33 measured batches and 713 verified source jobs, plus the separate prepared-suite and cancellation controls. Import it to query the `go_cache_fanout` SQLite view. [Offline fixture](../../../scripts/bench_go_fanout_fixture.sh)

```sh
python3 scripts/ci_benchmark_store.py go-cache-fanout \
  docs/benchmarks/2026-11-20/go-cache-fanout/measurements.json.gz
```
