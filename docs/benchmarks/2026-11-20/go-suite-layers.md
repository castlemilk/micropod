# Publishing a Go CI suite on the warm worker

On Gamma, median preparation time for a new source image fell from **3.68 s to 1.46 s** across six paired revisions. Each revision changed a documentation file and produced identical Go outputs. The existing exporter committed the compiler container and used a BuildKit copy. The Rust guest service appended the outputs directly to the source image. Both ran vet and compiled the suite against the same warm module and build volumes. The timer covered the full preparer invocation, including Docker registration and compiler cleanup. Source snapshot creation was outside the timer. [Raw measurements](go-suite-layers.json.gz)

| Six new source images, tested in alternating order | Median | Range |
| --- | ---: | ---: |
| Commit compiler and export with BuildKit | 3.68 s | 3.08–13.44 s |
| Publish an OCI layer in the guest | 1.46 s | 1.21–1.84 s |
| Look up the exact prepared source again | 85 ms | 72–94 ms |

Each result retained all ten parent layers and the parent runtime configuration, including `ArgsEscaped`. The first import sent a 7,546,326-byte compressed suite in a 7,560,704-byte archive. Each of the five following revisions sent **13,824 bytes of image metadata**, with zero blob bytes and zero time in compression. All six had distinct result manifests. An edit to a value reachable from the executable produced a different layer and the expected new application output. Ordinary Docker ran all eight tests on every resulting image. [OCI image configuration](https://github.com/opencontainers/image-spec/blob/main/config.md)

Twenty simultaneous requests for a seventh source published one image in **3.07 s** and returned 19 cache hits. Once prepared, fresh batches of 16 and 32 native containers ran eight tests per job and verified the executable in median **154 ms and 316 ms** across three rounds. The earlier worker's missing publication route selected the BuildKit fallback in a compatibility control. A compilation error left the output tag absent. After Docker collected a disposable layer, the running service detected its stale descriptor and reproduced the original image digest. The local Docker contract replay passed all nine recorded cases and the 32-client isolation check. [Recorded Docker cases](oci-startup/docker-cases.tar.gz)

## Storage after unpacking

Containerd reported **12,734,464 allocated bytes and 12 inodes** for each final suite snapshot. The six source revisions shared a compressed blob, yet their six unpacked suite snapshots occupied an additional **76,406,784 bytes**. Containerd identifies an applied snapshot by the ordered chain of layers beneath it. [OCI ChainID definition](https://github.com/opencontainers/image-spec/blob/main/config.md#layer-chainid)

In a separate Gamma experiment we placed the suite immediately above the common toolchain, followed by the source and the empty working-directory layer. We checked the base directory, inspected all 26 checkout archive members per revision, and accepted only regular files and directories under `/workspace`. Each reordered image retained its Docker configuration, revision-specific source, eight tests and executable checksum. Containerd then reported **14,356,480 additional bytes** across one shared suite snapshot and twelve small checkout snapshots, an **81.2% reduction** with the original source images resident in both cases. All sizes are snapshotter allocations inside Linux. The production publisher preserves the parent layer order.

A candidate for the native path is a single independently leased, read-only suite directory shared across source revisions. An alternative for Micropod-owned checkout images is the measured layer order, once the snapshot producer can prove its path and deletion semantics at creation. A change to the main package also left 4,745,791 of 12,690,358 output file bytes identical. Separating package test executables is worth measuring against the extra snapshot and mount cost.

## Source-only comparison

Gamma was an 18-core M5 Max with 128 GiB. Each runtime had four vCPUs and approximately 4 GiB. All used Linux ARM64 Go 1.26.11, warmed caches, offline dependencies and the same job. Each job ran vet, eight fresh tests and a verified application build. Five rounds per width rotated engine order. Micropod used a ready runc session, OrbStack used fresh Docker runs, and raw Ubuntu used processes in fresh work directories inside a separate warm Lima guest. VM boot, Micropod session opening and Ubuntu SSH connection setup were outside the timers. [Benchmark driver](../../../scripts/bench_go_fanout.py)

| Fresh source jobs | Micropod median (range) | OrbStack median (range) | Raw Ubuntu median (range) |
| --- | ---: | ---: | ---: |
| 16 | 4.61 s (2.75–5.49) | 10.22 s (8.58–25.82) | 3.10 s (2.67–3.55) |
| 32 | 6.31 s (5.83–8.98) | 30.99 s (15.85–31.84) | 6.80 s (4.95–10.09) |

All 720 jobs returned the same application checksum. Each 32-job batch made 96 linker calls and zero compiler or vet-tool calls. The source path bypasses suite publication. Micropod and raw Ubuntu traded places at 32 jobs, including in an earlier series. The 16-job gap and repeated linking remain separate optimization targets. [Earlier comparison](go-cache-fanout.md)

## Reproducing the publication comparison

Use the offline Go fixture, a local toolchain image with an empty `/workspace`, and an existing trusted Go cache scope primed from the fixture's module proxy. Run the preparer from baseline commit `f5d1174d` and the candidate checkout against the same worker. Give both scripts the same immutable source ID. For each pair, change only a documentation file and alternate the invocation order. Run the candidate a second time on the same ID to record an exact hit. The `ci.go.suite` event on stderr reports the publication method, digests, bytes and timings. [Fixture builder](../../../scripts/bench_go_fanout_fixture.sh) · [Worker setup](../../ci-worker.md)

```sh
src=$("$MICROPOD_BIN" ci snapshot "$TOOLCHAIN_IMAGE" "$CHECKOUT")
time "$BASELINE_CHECKOUT/ci/prepare-go-suite.sh" "$src" "$CACHE_SCOPE"
time ci/prepare-go-suite.sh "$src" "$CACHE_SCOPE"
time ci/prepare-go-suite.sh "$src" "$CACHE_SCOPE"
python3 scripts/ci_benchmark_store.py go-suite-layer \
  docs/benchmarks/2026-11-20/go-suite-layers.json.gz
```

Query `go_suite_layer_publications` for the six pairs, hit times, blob bytes, import bytes and phase timings. The receipt also contains per-job source results, the retention and compatibility controls, and both snapshot layouts.
