# Full CI on a warm Gamma worker

On Gamma, the updated Docker pipeline completed a Go code edit in **5.65 s** and the unchanged rerun in **3.28 s**. The same workflow took **22.55 s** and **8.73 s** on OrbStack. Both paths built and exercised an HTTP service, ran fresh race and npm tests, rebuilt an edited Node image, and created and removed PostgreSQL through Testcontainers and Ryuk. [Pipeline receipts](full-ci/pipelines.json.gz)

## Benchmark question

> How long does a developer wait for verified CI results after a source edit, and how much work can the next 16 or 32 jobs reuse? Include source preparation, lint, builds, actual test execution and cleanup. Keep the VM warm, verify artifacts and failures, and compare equivalent workloads on the same physical Mac.

## Docker, Go, npm and PostgreSQL

Each of three measured revisions changed a live HTTP response header. Both pipelines and engines produced the same application bytes within each revision. Every edit changed the executable SHA-256. Each edited run was followed immediately by an unchanged run. Order rotated across engines and pipeline versions. The first complete block primed both engines. Times are medians of the three subsequent blocks. [Workload and assertions](../../../scripts/bench_worker_pipeline.py)

| Pipeline on Gamma | New source edit | Same revision again |
| --- | ---: | ---: |
| Micropod before | 27.168 s | 11.813 s |
| Micropod updated | 5.651 s | 3.276 s |
| OrbStack before | 36.688 s | 17.525 s |
| OrbStack updated | 22.551 s | 8.730 s |

The PostgreSQL entrypoint starts a temporary socket-only server during initialization. The previous test observed its ready log, called local `pg_isready`, and began teardown. In all 12 measured baseline runs, Docker eventually sent SIGKILL and PostgreSQL exited 137. The updated test waits for TCP, inserts and reads back a value through SQL, then checks cleanup. PostgreSQL exited zero in all 12 updated runs. On Micropod this stage fell from **11.05 to 1.34 s** across the six runs per version. The compiler toolchain installation now precedes the source copy in the build image. Go service builds and checks run independently, and cached images still execute the Go race and npm suites. [PostgreSQL image entrypoint](https://github.com/docker-library/postgres/blob/master/docker-entrypoint.sh) · [Database events](full-ci/pipelines.json.gz)

A preliminary run encountered a DNS failure while the old build recipe fetched Alpine packages after a source change. Gamma’s original worker recorded an automatic network repair in 1.32 s, resolved the package host again, and retained its boot ID. The completed paired series records failed attempts and time to green for each phase. GitHub Actions was not used. [Worker identities and recovery](full-ci/rig.json)

## Concurrent Go CI

The workload is Micropod’s own Linux guest module. Source jobs run `go vet ./...`, `go test -count=1 -v ./...` and `go build` in each fresh workspace. Preparing a suite runs vet and builds the per-package test executables and main application once. Each dispatched job runs all seven tests, exercises the compiled file reader and verifies the executable checksum. The runtime-spec dependency is vendored in the immutable source. The module store therefore contains no download payload in this series. The Go build store is shared across preparations and jobs. [Go test flags](https://pkg.go.dev/cmd/go#hdr-Testing_flags) · [Executable and cache proofs](full-ci/cache-controls.json)

| Batch, warm revision | Micropod Rust/vsock and runc | OrbStack Docker | Raw Ubuntu processes |
| --- | ---: | ---: | ---: |
| 1 × vet, test, build | 0.652 s | 0.876 s | 0.422 s |
| 1 × prepared suite | 0.051 s | 0.283 s | 0.033 s |
| 16 × vet, test, build | 3.225 s | 6.639 s | 2.589 s |
| 16 × prepared suite | 0.255 s | 2.973 s | 0.120 s |
| 32 × vet, test, build | 6.168 s | 12.972 s | 5.773 s |
| 32 × prepared suite | 0.586 s | 4.172 s | 0.197 s |

Range across the three prepared 32-job batches was 0.489–0.679 s on Micropod, 3.372–4.283 s on OrbStack and 0.124–0.211 s on raw Ubuntu.

The three measured rounds cover 882 jobs. Every container or raw private workspace had a unique identity, a stable kernel boot ID, seven passing tests and the same application hash. At 32 jobs the prepared Micropod batch took 0.586 s against 0.197 s on Ubuntu, an absolute gap of 389 ms. Opening the prepared Micropod session separately took 52 ms. [Per-job timings and identities](full-ci/go-jobs.json.gz)

Gamma is a shared 18-core Apple M5 Max with 128 GiB. All three ARM64 Linux VMs had four vCPUs and 4 GiB configured. The Go 1.26.11 executable was byte-identical on all three. Each container had one CPU and 1 GiB, while the raw processes shared the Ubuntu VM allocation. Raw time includes creating and copying each private workspace, testing, building or reusing the product, verification and removal. SSH setup is outside the raw clock. Micropod includes dispatch and OCI cleanup. OrbStack includes the ordinary Docker client request and cleanup. The Docker service pipeline was compared on the two engines. Raw Ubuntu is the matched control for the Go stages. Python records the benchmark on the Mac. Linux executes shell, Go and the test binaries. [Rig and raw toolchain](full-ci/go-jobs.json.gz)

### First submission of a new revision

Each pair introduced a new reachable Go command and required a new binary. The clock starts before taking the source snapshot and ends when the last job returns its checked result. It includes the suite cache miss where applicable, native handle preparation, session startup and dispatch. Both orders ran once at each concurrency to balance the shared Go cache. These are two pairs per level on a shared host. [First-revision stage times](full-ci/changed-revisions.json.gz)

| Jobs on a new revision | Source path | Prepare and run |
| ---: | ---: | ---: |
| 1 | 1.321 s | 2.921 s |
| 16 | 4.824 s | 4.526 s |
| 32 | 6.934 s | 4.568 s |

A prepared-image cache hit took 76 ms. Four concurrent requests for the same edited checkout produced one miss, three hits and one image. A source change altered the executable and its observed output. A vet failure published no suite, and a test that compiled successfully failed on both fresh runs. On one additional cache miss, the Docker client trace recorded 0.716 s attached to the compiler, 1.403 s to commit its staging image and 0.990 s to publish the final layer. Those command times are a diagnostic sample that includes client overhead. [Cache controls](full-ci/cache-controls.json) · [Preparation trace](full-ci/prepare.json)

### Filesystem and kernel traces

Under heavier load the previous filesystem-watch test missed a rename and deletion in one 32-job run. It slept 100 ms before using a new recursive watch, then collected events for 700 ms. The revised test synchronizes on the nested file event, performs the rename and deletion, then waits for a marker on the same inotify queue. It verifies the original first event, all original required events, the modify-event bound and watcher shutdown. The five-second deadline is only reached on a failure. The revised test passed 384 repetitions in 32 containers before the final matrix. All three runtimes used this same revision. Earlier timings with the fixed sleeps are archived separately. [Earlier passing series](full-ci/original-watch-jobs.json.gz) · [Failed run](full-ci/watcher-failure.json.gz) · [Watch test](../../../guest/guest_test.go)

In a separate 32-job kernel trace, median CPU pressure per job fell from **2035 ms to 55 ms** after preparing the suite. Median CPU consumption fell from 620 ms to 36 ms. The 32-job worker policy used Linux SCHED_BATCH. Stalls from concurrently running jobs overlap. The trace includes per-job timestamps for OCI setup, vet, tests, build, verification and removal. [Perfetto timeline](full-ci/ci.trace.json.gz) · [Kernel counters](full-ci/changed-revisions.json.gz) · [Linux pressure accounting](https://docs.kernel.org/accounting/psi.html)

The full Docker pipeline ran on Gamma’s existing worker. The native comparison used a second worker with the same allocation and the guest service enabled. On that worker, 32 native CI jobs ran alongside a real Docker-managed PostgreSQL integration test. Their guest-clock intervals overlapped by 0.450 s, and the server exited zero. The original worker retained its boot ID. [Same-kernel coexistence](full-ci/coexistence.json) · [Checked-in Docker pipelines](full-ci/checked-in-pipelines.json)

## Reproduce on an Apple Silicon Mac

Use a persistent Micropod worker with the native OCI service installed, an explicit OrbStack Docker socket, and a disposable ARM64 Ubuntu guest. Give all three four vCPUs and 4 GiB. The benchmark Go image needs a local Linux ARM64 Go toolchain, a shell, GNU coreutils and an empty `/workspace`. The measured toolchain was Go 1.26.11. The worker guide covers provisioning and signing. [Worker setup](../../ci-worker.md)

Prepare the actual Micropod guest module and one scoped pair of Go stores. The following commands run from the repository root with Bash. `BASE` names the local toolchain image. `UBUNTU` names the disposable Lima instance.

```bash
export MICROPOD_BIN="$PWD/.build/release/micropod"
scope=micropod-guest-ci
run=$(mktemp -d)
git archive HEAD -- 'guest/*.go' guest/go.mod guest/go.sum | tar -C "$run" -xf -
(cd "$run/guest" && env -u GOROOT go mod vendor)
src=$("$MICROPOD_BIN" ci snapshot "$BASE" "$run/guest")
suite=$(ci/prepare-go-suite.sh "$src" "$scope")
src_handle=$(ci/oci-batch.sh prepare "$src" "$scope")
suite_handle=$(ci/oci-batch.sh prepare "$suite" "$scope")
orb=(docker --host "unix://$HOME/.orbstack/run/docker.sock")
prefix=micropod-internal/go-suite-bench-$(uuidgen | tr '[:upper:]' '[:lower:]')
"$MICROPOD_BIN" ci docker tag "$src" "$prefix:source"
"$MICROPOD_BIN" ci docker tag "$suite" "$prefix:suite"
"$MICROPOD_BIN" ci docker save "$prefix:source" "$prefix:suite" | "${orb[@]}" load
```

Install the matching toolchain in the disposable Ubuntu guest. Prepare its test binaries independently from the source. The benchmark compares all product SHA-256 digests and the Go executable on all three systems.

```bash
raw() { limactl shell --workdir / -- "$UBUNTU" "$@"; }
rawdir=$(raw mktemp -d /tmp/micropod-guest-ci.XXXXXXXX)
rawcache=/var/tmp/micropod-guest-ci-cache
raw mkdir -p "$rawdir/source" "$rawdir/suite" "$rawcache/mod" "$rawcache/build"
raw ln -s "$rawcache" "$rawdir/cache"
"$MICROPOD_BIN" ci docker run --rm --network none --entrypoint tar "$src" -C /usr/local -cf - go |
  raw sudo tar -C /usr/local -xf -
tar -C "$run/guest" -cf - . | raw tar -C "$rawdir/source" -xf -
raw sh -ec 'cat > "$1/suite/suite.sh"' sh "$rawdir" < ci/samples/go-app/ci-suite.sh
raw env PATH=/usr/local/go/bin:/usr/bin:/bin GOENV=off GOTOOLCHAIN=local GOWORK=off \
  'GOFLAGS=-trimpath -p=2' CGO_ENABLED=0 GOMAXPROCS=2 GOTELEMETRY=off GOPROXY=off GOSUMDB=off \
  "GOCACHE=$rawdir/cache/build" "GOMODCACHE=$rawdir/cache/mod" sh -ec '
    cd "$1/source"
    sh "$1/suite/suite.sh" compile "$1/suite"
    go build -trimpath -buildvcs=false -o "$1/suite/product" .
  ' sh "$rawdir"
python3 scripts/bench_go_suite.py --source-image "$src" --suite-image "$suite" \
  --source-handle "$src_handle" --suite-handle "$suite_handle" --scope "$scope" \
  --ubuntu "$UBUNTU" --ubuntu-workspace "$rawdir" --clients 1 16 32 --rounds 3 --output "$run/jobs.json"
python3 scripts/bench_go_suite_revision.py --base "$BASE" --checkout "$run/guest" --scope "$scope" \
  --clients 1 16 32 --rounds 2 --trace --output "$run/edits.json"
ci/oci-batch.sh forget "$src_handle"
ci/oci-batch.sh forget "$suite_handle"
```

For the Docker, Go, npm and PostgreSQL comparison, extract the previous pipeline and run the alternating source-edit benchmark. It creates run-specific tags, verifies the binary changes across edits, and records database container exit events. The SQLite views `full_ci_stages`, `go_suite_batches`, `go_suite_jobs`, `go_suite_first_revisions` and `go_suite_kernel_jobs` expose the individual measurements. For steady-state comparisons, select passed runs and rounds greater than zero. [Benchmark data store](../../../scripts/ci_benchmark_store.py)

```bash
mkdir "$run/baseline"
git archive fd3ce75d -- ci | tar -C "$run/baseline" -xf -
python3 scripts/bench_worker_pipeline.py --baseline "$run/baseline" --rounds 3 --output "$run/pipelines.json"
```
