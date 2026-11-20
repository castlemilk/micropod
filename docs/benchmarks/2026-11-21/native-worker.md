# Native crun worker on Gamma

Micropod completed 32 concurrent warm Go jobs through the stock Docker CLI in **5.252 s**. OrbStack took **9.423 s** and bare processes in warm Ubuntu took **3.623 s** on the same Mac. Charging Micropod for all pod preparation brings its time to **5.974 s**. The Micropod engine comprised a Rust service over vsock, containerd 2.4.2 and crun 1.31. [Individual batches, stage traces and qualifications](native-worker.json.gz)

## Matched source jobs

Gamma was an 18-core M5 Max with 128 GiB and macOS 26.5.1. Each Linux VM had four vCPUs and 4 GiB configured. Micropod ran Linux 6.18.35, OrbStack 2.2.5 ran Engine 29.8.2, and Ubuntu 24.04.4 ran Linux 6.8. Each job received a private writable workspace and the same source revision, Go 1.26.11, build flags and warm dependencies. Each ran vet, eight tests with `-count=1`, a build, and its resulting executable. Ubuntu's clock includes copying and removing each workspace and excludes establishing SSH. [Benchmark driver](../../../scripts/bench_go_fanout.py)

Elapsed seconds below are medians of three batches per cell. The engine order rotated each round. Micropod pre-created one-use, empty pods before dispatch. The last two columns include their measured preparation time. All engines launch fresh workload processes.

| Engine | 16 jobs | 32 jobs | 16 including preparation | 32 including preparation |
| --- | ---: | ---: | ---: | ---: |
| Micropod Docker API, eight concurrent starts | 2.862 | 5.252 | 3.261 | 5.974 |
| Micropod direct scheduler | 2.648 | 5.644 | 3.041 | 6.341 |
| OrbStack | 4.109 | 9.423 | 4.109 | 9.423 |
| Raw Ubuntu processes | 1.895 | 3.623 | 1.895 | 3.623 |

Together the unrestricted and tuned matrices completed **1,152 jobs**, 9,216 individual tests and 3,456 links. Every product had the same SHA-256. Compile and vet actions hit the warm cache. The 576 Micropod jobs used the same inodes for the module archive, compiled dependency and Go executable across both entry points and worker boots. Python drives the measurement and writes the SQLite result on the host. All workload commands execute in Linux.

## What limiting startup changes

At 32 jobs, an unrestricted 9.26 s diagnostic window recorded 7.86 s with at least one runnable task waiting for CPU, 2.07 s of I/O pressure and 2.24 s of memory pressure. These intervals can overlap. There were zero OOM kills. Container creation averaged 267 ms and start averaged 222 ms over 33 launches, including one accounting container. At 16 jobs they averaged 42 ms and 53 ms. The warm image and pod lookup on the direct path took medians of 9 ms and 3 ms at 32.

An independent four-round crossover alternated unrestricted setup with eight simultaneous starts on the same boot. At 32 jobs the median fell from **7.031 to 6.373 s** (9.4%). At 16 it rose from **3.056 to 3.479 s** (13.8%). The slot is returned as soon as crun starts the container. Gamma's opt-in worker uses eight slots. The general default remains unrestricted. Host load varied between the two larger measurement blocks, including OrbStack's 32-job median of 20.805 s in the earlier block. Those block-to-block differences cannot isolate the effect of the setting.

## Rig qualification

- A real Cuttlefish attempt handed a file to a second stage through a named volume and collected its artifact. A separate fixture read a private, read-only input and confirmed cleanup. A stock Go Testcontainers client started PostgreSQL 16 and exercised Cuttlefish's query tracing. After an interrupted client, Ryuk reaped its session's container and a peer session kept running.
- The stock CLI preserved stdout, stderr and exit codes for foreground jobs and exec. A retained exit and labeled volume survived a clean restart. SQL returned 42 over a dynamically published Mac port. A conflicting port was rejected and released. Shutdown refused an active database.
- A disposable worker lost its supervisor while two containers were running. After reboot its interrupted process reported an unknown exit, its auto-remove container was gone, and the published port could be reused. A completed job retained its exit code, logs and volume contents. [Repeat the crash qualification](../../../scripts/qualify_native_worker_crash.sh)
- A Node 24.22.3 scheduler job populated npm's cache with `is-number@7.0.0`. A Docker CLI job installed and used the package offline with only loopback. Both opened the same 3,730-byte file, inode 58040. Go and npm file identities survived starting the installed worker under the rig account's macOS login service.
- Requested network repair completed in 1.52 s. The same running container resolved the npm registry before and after repair. Its process start time and Linux boot ID were identical. Cuttlefish's passive and active operator checks also passed on the registered worker with an unrelated Docker context and TLS settings in the shell.
- The final Swift suite reported 1,717 tests, 88 skipped and zero failures. Six Linux guest tests, four Rust tests and the local Cuttlefish qualifications passed. One earlier direct wave failed a fixture assertion whose name was lost in truncated output. A separate foreground-output failure was fixed and checked with 32 attached clients. An earlier Swift timing assertion passed its individual and full-suite repeats.

The native path qualifies ordinary trusted Cuttlefish stages and the local service cases above. GitHub runner allocations with private nested engines, BuildKit/buildx, named service networks, interactive I/O and archive copy remain migration work. GitHub Actions stayed off. [Worker configuration and supported operations](../../ci-worker.md)

## Reproduce

Use the source-only fixture and matching Go toolchain for each engine. On the native worker, capture `ci runner-prime` separately before each batch. For the other arms, select `--runner`, the OrbStack `--endpoint`, or the raw Ubuntu `--ubuntu` and `--workspace` arguments. [Fixture preparation](../2026-11-20/go-cache-fanout.md#reproduce)

```sh
endpoint=$(micropod ci runner-docker-endpoint)
for clients in 16 32; do
  micropod ci runner-prime "$clients"
  python3 scripts/bench_go_fanout.py --endpoint "$endpoint" --image "$FIXTURE_IMAGE" \
    --scope go-pipeline --same --clients "$clients" --output "/tmp/worker-$clients.json"
done
scripts/qualify_native_worker.sh
python3 scripts/ci_benchmark_store.py native-worker docs/benchmarks/2026-11-21/native-worker.json.gz
```
