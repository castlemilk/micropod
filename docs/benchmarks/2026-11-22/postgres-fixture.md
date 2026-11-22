# PostgreSQL on the warm shared-kernel CI worker

The original Gamma receipt put PostgreSQL at **10.785 s of a 13.020 s median warm pipeline**. A later resource-matched run captured the cause. On Micropod the first Docker stop request preceded destruction by **10.109 s median** with the old check and **0.114 s** with the corrected final-TCP check. The old check could succeed against the temporary initialization server. Every old database needed SIGKILL. Every updated database exited zero after a real SQL write and read. The corrected path is the control for the new fixture. [Original receipt](../2026-11-20/gamma-worker-pipelines.json) · [Docker events and application results](../2026-11-20/full-ci/pipelines.json.gz) · [Trace aligned to each database start](postgres-saved-lifecycle.trace.json)

## Saved matched results

Gamma is an 18-core M5 Max with 128 GiB. Both Docker engines had four vCPUs and 4 GiB configured. Linux reported 4,118,708,224 bytes on Micropod and 4,180,480,000 on OrbStack. Times below are seconds, **p50 / nearest-rank p95**. Each pipeline cell has three unchanged warm repeats. Each database cell has six runs, three edits and three repeats. With these counts p95 is the slowest observation. Stage times overlap. [Recomputed data and source hashes](postgres-saved-baselines.json)

| Engine and application check | Warm pipeline | PostgreSQL stage | DB start → stop request | Stop request → destroy | DB exits |
| --- | ---: | ---: | ---: | ---: | --- |
| Micropod, old readiness | 11.813 / 11.924 | 11.055 / 11.853 | 0.474 / 0.862 | 10.109 / 10.128 | 6 × 137 |
| Micropod, final TCP and SQL | **3.276 / 3.809** | **1.343 / 2.141** | 0.878 / 1.427 | **0.114 / 0.183** | 6 × 0 |
| OrbStack, old readiness | 17.525 / 33.493 | 13.969 / 19.633 | 1.253 / 1.730 | 10.362 / 11.640 | 6 × 137 |
| OrbStack, final TCP and SQL | 8.730 / 33.207 | 10.857 / 16.759 | 6.251 / 9.294 | 0.710 / 3.034 | 6 × 0 |

In the original receipt the warm pipeline was 13.020 / 13.484 s on Micropod and 21.656 / 33.769 s on OrbStack. The database stages were 10.785 / 11.049 s and 12.943 / 23.825 s. That receipt timed the whole stage. The later events isolate shutdown but have no separate timestamps for fixture initialization, final TCP readiness or SQL. A preliminary Micropod series stopped after 16 completed batches when Alpine package resolution failed on a source edit. In the completed matched series the runners reported zero first-attempt failures across 24 measured runs, despite the 12 forced database exits on the old path. [Worker and failure record](../2026-11-20/full-ci/rig.json)

### Go, npm and image caches

These new Mac measurements time individual commands. Seven independent rounds each created an empty private store, populated it from a local origin, removed the origin and reran the same command in a fresh checkout. Go ran with one CPU worker. Both products returned their expected output. Empty offline stores failed on both tools as intended. CI scheduler queue time is unavailable for direct submissions. [Seven rounds, cache inventories and tool versions](gamma-native-package-cold-warm.json)

| Native Mac command | Cold p50 / p95 (s) | Warm p50 / p95 (s) | Warm evidence |
| --- | ---: | ---: | --- |
| `go build` | 5.442 / 6.259 | **0.145 / 0.154** | 7/7 builds reused compiled packages, zero warm compiler/assembler calls vs 106 per cold build. 36,805,525 bytes in 410 files. |
| `go mod download` | 0.012 / 0.015 | 0.010 / 0.011 | 7/7 reused the same module payload. 626 bytes in nine files per store. |
| `npm ci` | 0.182 / 0.266 | **0.209 / 0.225** | 7/7 reused the same 229-byte content blob. npm showed no median speedup for this one-package fixture. |

All 42 timed commands passed on the first attempt. Payload inode identities and cache sizes held across cold-to-warm runs. Byte counts are logical file bytes. The Mac used Go 1.27.2, Node 24.22.2 and npm 11.19.1. Its command times have a different boundary from fresh Linux containers.

| Saved Linux cache operation on Gamma | Micropod p50 / p95 (s) | OrbStack p50 / p95 (s) |
| --- | ---: | ---: |
| Cold Go build, 107 compiler/assembler calls | 4.454 / 6.782 | 4.208 / 4.729 |
| Cold Go module download | 0.002 / 0.006 | 0.007 / 0.010 |
| Cold npm cache population (`npm cache add`) | 0.157 / 0.207 | 0.169 / 0.223 |
| Warm Go, one fresh container | 0.291 / 0.550 | 0.552 / 0.612 |
| Warm Go, 16-container batch | 1.442 / 2.887 | 3.025 / 4.902 |
| Warm npm, one fresh container | 0.391 / 0.640 | 0.581 / 0.927 |
| Warm npm, 16-container batch | 1.896 / 2.485 | 3.870 / 4.299 |

Five saved rounds per width cover 145 payload reuses per tool per engine across 1, 4, 8 and 16 clients. There were zero package job failures and zero warm compiler calls. Each engine retained one 221-byte npm blob, 626 Go module bytes and 33,085,592 Go build bytes. The warm batch clock includes Docker, checkout, command, verification and teardown. Cold population clocks cover the named commands. [Matched cache receipts](../2026-11-20/gamma-worker-orbstack-ubuntu.json)

On the saved Micropod image benchmark, a new Go suite image key took **1.456 / 1.842 s** to publish and **0.085 / 0.094 s** for an exact repeat. All six cold keys and six matching hits retained their source and image IDs within each pair. The first publication sent a 7,546,326-byte compressed layer. The next five distinct sources with identical compiled output each imported 13,824 metadata bytes and zero blob bytes. A simultaneous 20-request batch recorded one miss and 19 hits in 3.066 s. Separately, warm Go and Node Dockerfile solves on Micropod recorded 48/48 and 40/40 cached steps. These are image-cache and BuildKit measurements, independent of Go/npm payload hits. [Image publication and byte counts](../2026-11-20/go-suite-layers.json.gz) · [Dockerfile step receipts](../2026-11-20/worker-profile/adaptive-buildkit.json.gz)

### Matched raw Ubuntu at scale

A separate warm Ubuntu **24.04.4 ARM64 VM on the same Mac** had four vCPUs and 4 GiB. All three used the same verified Go 1.26.11 executable. Three measured batches per cell report batch p50 / p95 in seconds. Raw Ubuntu ran processes with separate work directories. Missing from this comparison is a raw Ubuntu PostgreSQL pipeline. [All job identities, results and timings](../2026-11-20/full-ci/go-jobs.json.gz)

| Go workload | Micropod | OrbStack | Raw Ubuntu |
| --- | ---: | ---: | ---: |
| 16 fresh vet/test/build jobs | 3.225 / 3.570 | 6.639 / 7.238 | 2.589 / 3.010 |
| 32 fresh vet/test/build jobs | 6.168 / 6.942 | 12.972 / 13.585 | 5.773 / 6.272 |
| 32 jobs running the prepared suite | 0.586 / 0.679 | 4.172 / 4.283 | 0.197 / 0.211 |

In a separate saved 32-job Go trace, preparing the suite reduced median CPU pressure per job from 2,035 ms to 55 ms and CPU consumption from 620 ms to 36 ms. Per-job stall durations overlap. PostgreSQL-specific kernel pressure, throttling and I/O still need the instrumented fixture run. [Kernel trace and sampling boundaries](../2026-11-20/full-ci.md)

## Prepared PostgreSQL experiment

The experiment builds two opt-in images from the same local upstream PostgreSQL 16 digest. The control runs the upstream initializer per job. The candidate runs `initdb` once and stores the stock cluster and empty `ci` database in an immutable layer outside the upstream data volume. The image build checks for any public relations or stored role passwords and verifies a clean cluster shutdown. Each job gets a new container writable layer and generated credential. The runner uses the normal TCP readiness probe, creates the same table, inserts and reads 42, and runs the existing Go race, HTTP, Node and source-edit checks. Kernel settings, runtime defaults and the relay are outside this experiment. [Fixture](../../../ci/fixtures/postgres-profile/fixture.sh) · [Canonical application SQL](../../../ci/samples/go-app/integration/postgres_test.go)

The live harness records each of the following with its clock and boundary.

| Measurement | Boundary |
| --- | --- |
| Create to ready | Testcontainers call through final readiness, including engine/container setup. |
| Fixture materialization | Container entry to last initialization hook (control), or credential installation in the private writable layer (candidate). Guest uptime, 10 ms resolution. |
| Final readiness | Two intervals are reported. The guest interval starts at materialization and ends at the first successful final TCP probe. The test process also records the inclusive readiness wait. |
| SQL / observation / teardown | Separate monotonic spans for the identical SQL round trip, collection of evidence and `Terminate`. Docker events independently require exit zero, destruction and a graceful stop. |
| Job and batch wall | Client monotonic time. Local executor dispatch wait is recorded separately. External queue time stays null without scheduler submission/start timestamps. |
| Image and kernel | Per-build cached/executed steps, rootfs layer IDs, image and base-delta bytes. Per-DB cgroup CPU, throttling, pressure, block I/O and memory events where exported. Perfetto JSON places each test on its own lane. |

The harness alternates modes within each round and excludes round zero from timing summaries. It runs one full application per mode and the same PostgreSQL check at the requested widths. Every attempt is retained. The recovery control kills only a disposable database belonging to this run, checks the next database rejects its predecessor's credential and has no previous table, then checks clean shutdown. The harness checks unique containers, private volume identities and volume cleanup. The fixture's startup, recovery and isolation remain unverified on a VM in this session.

### Reproduce locally

Use an **already-running, idle, dedicated Micropod worker** with the stock Linux ARM64 Debian `postgres:16` image locally available by upstream digest. The normal application fixture needs its Go, Node, Alpine and Testcontainers Ryuk images and build dependencies. The package image argument names the local image from `scripts/bench_cache_image/Dockerfile`. The recorded Gamma toolchain image config ID is shown below. Change the ID only if using another provisioned toolchain and keep its recorded identity with the result. Run from this branch's repository root.

```sh
worker_dir=${MICROPOD_CI_HOME:?set this to the dedicated existing worker directory}
worker_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worker"])' "$worker_dir/worker.json")
results=$(mktemp -d "${TMPDIR:-/tmp}/micropod-sql.XXXXXXXX")
package_image=sha256:73e5c74172d3555c685f3c8aad44163b52893478974e4c9926ba16a8a2c3a350
python3 -B scripts/bench_postgres_fixture.py \
  --endpoint "unix://$worker_dir/docker.sock" --worker-id "$worker_id" \
  --postgres postgres:16 --package-image "$package_image" --clients 1 4 16 --rounds 20 \
  --out "$results/postgres.json" --database "$results/measurements.sqlite3"
```

The harness checks Docker worker and boot identities before the experiment and after each batch. Its private fixture build key forces execution of the fixture step while keeping the base available. Cold registry pull time and APFS physical allocation require separate evidence. The optional package probe uses a new disposable container with one CPU, 1 GiB, no network, and private empty stores on each round. It runs after the database measurements. Compare full application and DB-only batches by workload, mode and width. A short installation check can use `--rounds 1 --clients 1`.

### Captured and missing evidence

On 22 November 2026 the dedicated worker socket was absent. The preflight failed before launching a job. A private native PostgreSQL 18.6 fallback also failed at `initdb` because macOS denied `shmget`; it produced no database timings. The application Go and Node unit suites passed locally, and the integration executable cross-compiled for Linux ARM64. The first cross-compile attempt lacked two Go dependencies in the read-only cache; the successful build used the pinned versions with the repository's `go.sum`. Host-native package commands above are new measurements. The original Gamma comparisons and traces are archival. [Worker preflight](postgres-live-preflight.json) · [Local PostgreSQL failure](postgres-native-preflight.json)

Still missing are live control/candidate first-attempt results, p50/p95 for the split phases and concurrent batches, the candidate's image size and hit counts, database cgroup counters at 1/4/16 clients, and observed crash recovery on the shared VM. A CI queue distribution requires submission and lease timestamps from the scheduler. The host relay, rig processes, CI workflows and deployment settings were untouched.

[SQLite data](postgres-profile.sqlite3) includes the matched baselines, all seven local package rounds and the failed preflights. The command below rebuilds the baseline and event trace from the checked-in inputs. The second command repeats the host-native package measurement into a fresh database.

```sh
results=$(mktemp -d "${TMPDIR:-/tmp}/micropod-evidence.XXXXXXXX")
python3 -B scripts/summarize_ci_postgres.py --out "$results/saved.json" \
  --trace "$results/lifecycle.trace.json" --database "$results/measurements.sqlite3"
python3 -B scripts/profile_ci_package_commands.py --rounds 7 \
  --out "$results/native.json" --database "$results/measurements.sqlite3"
sqlite3 "$results/measurements.sqlite3" \
  'SELECT engine, revision, pg_p50_s, pg_p95_s, stop_p50_s, exit_codes FROM postgres_saved_pipeline;'
```
