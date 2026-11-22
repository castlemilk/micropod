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

## Three PostgreSQL fixture cases

The earlier two-case experiment varied the data mount and initialization together. The corrected harness uses three cases on one already-running worker. It resolves the locally provisioned official PostgreSQL 16 ARM64 image to one repository digest, verifies its local image ID and rootfs layers, then runs each derived case by immutable image ID. Startup selects its action from the explicit fixture mode. [Dockerfile](../../../ci/fixtures/postgres-profile/Dockerfile) · [Entrypoint](../../../ci/fixtures/postgres-profile/fixture.sh)

| Case | Effective `PGDATA` expected on the worker | Startup |
| --- | --- | --- |
| `fresh` (practical baseline) | `/var/lib/postgresql/data`, a new Docker volume | Upstream `initdb` for every job |
| `fresh-overlay` (storage control) | `/var/lib/micropod-fixture/data`, private writable root overlay | The same upstream `initdb` for every job |
| `prepared` | `/var/lib/micropod-fixture/data`, private writable root overlay | Open the pristine, prebuilt cluster and set a new job credential |

Compare **fresh → fresh-overlay** for the storage change at fixed initialization. Compare **fresh-overlay → prepared** for the effect of reusing the fixture on the same storage. Fresh → prepared answers the practical end-to-end question. Each case uses the same final-TCP gate, SQL, Go, HTTP, Node and source-edit assertions. All cases must exit zero on normal teardown and pass the same recovery check. An intentionally killed database must exit 137, and its successor must reject the old password, have no previous table, and successfully create, write and read its own `ci_probe` table. [SQL and readiness](../../../ci/samples/go-app/integration/postgres_test.go) · [Recovery and storage probes](../../../scripts/postgres_fixture_storage.py)

**The measured SQL connection is loopback.** Docker exec launches `psql` inside the database container. Both `pg_isready` and `psql` use TCP to `127.0.0.1`. A bridge comparison requires a separate run with a prestarted sibling client on a private bridge, a fixed database mode and pinned client image, and the identical create/insert/select assertion returning 42 on a fresh database per attempt. It needs its own timing series and client-start boundary.

### Clocks and storage accounting

The timed application and DB-only runs record create-to-ready, inclusive final readiness, fixture materialization, materialized-to-ready, SQL and teardown. Fixture events and the successful readiness probe share the guest's 10 ms uptime clock. The probe returns the mode, `PGDATA` and timestamps in its existing Docker exec response. The client clock closes at process exit, before the harness parses the output or audits the lifecycle. Docker mount and exit events establish timed container and volume identities. Every measured batch checks for leaked volumes outside its timer. External scheduler queue time stays null for local submissions. [Benchmark harness](../../../scripts/bench_postgres_fixture.py)

Storage diagnostics use separate disposable databases on the pinned worker. Single-client diagnostics precede the timing series. Widths 4 and 16 run after all timed samples. Within each diagnostic cohort every database reaches final TCP readiness before any job executes the canonical SQL assertion. The harness checks `SHOW data_directory`, Docker mount type/name/destination, the deepest covering Linux mount in `/proc/self/mountinfo`, and the worker's Docker storage driver. Both overlay cases still have the upstream anonymous volume at the stock path. Only the stock case stores its database there.

| Quantity | Measurement and boundary |
| --- | --- |
| Image layers | Digest-pinned common parent, rootfs diff IDs and exact integer bytes reported by Docker history for the added rows. The receipt keeps Docker's whole-image size and base delta in separate fields. |
| Fresh data volume | A read-only helper measures allocated and apparent bytes with `du` before server start and after clean stop. Overlay jobs report null for the data volume. |
| Writable container layer | Docker `container inspect --size` reports each diagnostic job's `SizeRw` at create, after all jobs are ready, and after clean stop. This includes changes anywhere in that container's writable root. |
| Database cgroup writes | Linux cgroup-v2 `io.stat` write bytes per device at readiness and after SQL. Missing or empty accounting is marked explicitly. The receipt also includes available CPU, memory and pressure counters. |
| Guest device writes | A read-only observer samples whole guest block devices. The receipt separates startup through all-ready, the ready-state inventory, and SQL through all-stopped. Sector deltas use 512 bytes. These counters include background guest I/O and writeback. |

At 16 simultaneous jobs, installing a fresh credential and starting a prepared cluster **could** copy lower-layer files into each job's upper layer. Ready-state `SizeRw` growth and guest writes can quantify costs. Attributing those costs specifically to copy-up would also require file- or operation-level evidence, such as observing the relevant upper files or a scoped copy-up trace. Image bytes alone cannot establish that attribution.

### Reproduce locally

From the repository root, first run the local contracts. They exercise entrypoint dispatch, incorrect case/path rejection, digest matching, mount resolution, byte accounting and the single-client gate without opening a Docker socket.

```sh
python3 -B scripts/test_postgres_fixture_storage.py -v
```

For a live smoke, use the already-authorized, idle dedicated worker. Its stock ARM64 Debian `postgres:16` image needs an upstream repo digest. The application needs its usual Go, Node, Alpine, Testcontainers Ryuk images and build inputs. The harness checks the worker UUID, boot, daemon, CPU/RAM and storage driver. The following commands use one result directory and stop on a failed smoke.

```sh
set -eu
worker_dir=${MICROPOD_CI_HOME:?set this to the existing dedicated worker directory}
endpoint="unix://$worker_dir/docker.sock"
worker_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["worker"])' "$worker_dir/worker.json")
results=$(mktemp -d "${TMPDIR:-/tmp}/micropod-pg-storage.XXXXXXXX")
python3 -B scripts/bench_postgres_fixture.py \
  --endpoint "$endpoint" --worker-id "$worker_id" --postgres postgres:16 \
  --smoke-only --clients 1 --out "$results/smoke.json" --database "$results/measurements.sqlite3"
pg_pin=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["passed"] and d["smoke"]["passed"]; print(d["postgres_base"]["reference"])' "$results/smoke.json")
python3 -B scripts/bench_postgres_fixture.py \
  --endpoint "$endpoint" --worker-id "$worker_id" --postgres "$pg_pin" \
  --clients 1 4 16 --rounds 20 --out "$results/profile.json" --database "$results/measurements.sqlite3"
```

The scale invocation also runs all three modes at one client before any measured rounds. Each measured round includes the full application at one client and the DB-only check at each requested width. A six-round cycle balances the three case positions. The optional `--package-image` accepts the existing Linux ARM64 package fixture for a separate post-run cache measurement. Query the result directly or open the sibling `.trace.json` for the test phases.

```sh
sqlite3 -header -column "$results/measurements.sqlite3" \
  'SELECT mode,clients,mount_kind,driver,rw_created_bytes,rw_ready_bytes,rw_stopped_bytes,volume_stopped_bytes FROM postgres_storage_jobs;'
sqlite3 -header -column "$results/measurements.sqlite3" \
  'SELECT mode,clients,phase,guest_device,write_bytes FROM postgres_storage_guest_writes;'
```

### Evidence available on 22 November 2026

The dedicated Gamma worker socket was absent at the new smoke preflight. Zero SQL jobs started. The raw preflight preserves the unattempted smoke and the missing worker measurements. The three-mode fixture has local contract coverage and a Linux ARM64 integration build. Its phase p50/p95, recovery outcomes, effective mounts, image and writable-layer bytes, volume sizes, cgroup/device writes at 1/4/16 clients and the 16-job copy-up hypothesis still need live evidence. No bridge measurement was taken. [Current smoke preflight](postgres-storage-preflight.json) · [Earlier worker preflight](postgres-live-preflight.json) · [Earlier native PostgreSQL shared-memory failure](postgres-native-preflight.json)

[SQLite data](postgres-profile.sqlite3) contains the matched historical baselines, all seven local package rounds and the failed preflights. The command below rebuilds the baseline and event trace from the checked-in inputs. The second command repeats the host-native package measurement into a fresh database.

```sh
results=$(mktemp -d "${TMPDIR:-/tmp}/micropod-evidence.XXXXXXXX")
python3 -B scripts/summarize_ci_postgres.py --out "$results/saved.json" \
  --trace "$results/lifecycle.trace.json" --database "$results/measurements.sqlite3"
python3 -B scripts/profile_ci_package_commands.py --rounds 7 \
  --out "$results/native.json" --database "$results/measurements.sqlite3"
sqlite3 "$results/measurements.sqlite3" \
  'SELECT engine, revision, pg_p50_s, pg_p95_s, stop_p50_s, exit_codes FROM postgres_saved_pipeline;'
```
