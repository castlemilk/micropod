# Stock Docker launch and exit on Apple Silicon

**No live pairs on 22 November 2026.** Gamma's dedicated Micropod manifest specifies four vCPUs and 4096 MiB. Its session file and Docker socket were absent. The OrbStack socket existed. Access to its daemon and release of the four-vCPU published-TCP slot were unverified. The local check recorded the stock Docker executable, version 29.7.2, build a7dcaa6fdb, and its SHA-256. It made zero guest launches and zero daemon requests. Live image and boot identities, daemon versions, batch timings, failure rates and paired spread are pending. [Local receipt](docker-launch-preflight.json)

## What the earlier Gamma runs measured

The saved launch/exit series measured **native-path CI performance** on an M5 Max. Both guests had four vCPUs and 4 GiB. These are whole-batch medians and observed ranges from five rounds in the repeat series. The percentages and ratios in the historical receipts include the cost of entering through each client's own path. Five rounds give little information about p95 or p99. [Raw samples](../2026-11-20/gamma-worker-orbstack-ubuntu.json)

| Timed entry point | 1 client, median [min–max] | 16 clients, median [min–max] |
| --- | ---: | ---: |
| Micropod `ci run` | 67 ms [61–125] | 322 ms [265–893] |
| OrbStack `docker run --rm` | 236 ms [195–397] | 2,746 ms [1,963–17,079] |

PostgreSQL remains a separate compatibility workload, pinned at [2ef1bc4](https://github.com/castlemilk/micropod/commit/2ef1bc402125f760fa5e91446660d646b5e3337e).

## The control

| Arm | Timed entry point | Endpoint |
| --- | --- | --- |
| Micropod stock | Pinned stock `docker --host … run --rm` | `~/.micropod/ci/docker.sock` |
| OrbStack stock | Same executable and arguments | `~/.orbstack/run/docker.sock` |
| Micropod native CI | `micropod ci run --existing-worker-only` | Same Micropod worker, boot and stock Docker binary |

The primary comparison measures end-to-end launch and exit through the stock CLI, including the Docker daemon, VM and socket transport. The third arm measures the cost of Micropod's native entry point on its own engine. The new flag uses the normal warm socket attestation and exits if that worker disappears. The benchmark resolves both Unix endpoints before the clock starts and verifies the native client's Docker lookup.

All arms submit the same Alpine 3.20 digest and select `linux/arm64`. The harness verifies the registry digest and hashes the native image config from each local engine. The entire Alpine command runs with `--cpus 1 --memory 256m --network none --pull=never`. It reads its CPU quota, memory limit, network interfaces and preverified boot ID. For the same job index all arms must return byte-identical stdout and stderr and exit 23. The run-scoped label supports checking removal after exit. [Fixture and pinned digests](../../../scripts/bench_docker_launch.py)

Both engines must report four effective vCPUs. The harness checks the Micropod manifest and OrbStack's active configuration for 4096 MiB and four vCPUs, then checks Docker's usable memory falls within 10% of 4 GiB and within 5% across engines. The receipt includes the client executable hashes, negotiated Docker client/server versions, OrbStack version, socket identities, guest boots and host model. [OrbStack resource settings](https://docs.orbstack.dev/settings)

Each engine gets the same untimed stock-Docker warmup at 1 and 16 clients. The default schedule has six blocks, covering all six arm orders at each width. Width order alternates. Each batch starts when all client threads are ready and ends at the last CLI exit. Prewarm, image inspection, idle sampling, result validation and receipt writes are outside that clock. The experiment measures local launch time with no CI queue.

Each arm starts with empty running-container lists and at least 90% host CPU idle over one second. A pair must start within five percentage points of idle. The receipt preserves every attempted job, including timeouts, wrong output and unexpected exits. A timed job failure leaves other scheduled arms eligible if both daemons remain idle and clean. Losing the worker, idle admission, warmup or cleanup stops the run and preserves the remaining count as unattempted. For each comparison the receipt gives every matched block's times, elapsed-time difference, ratio, median and observed min–max. Positive differences mean the candidate took longer than stock Docker on Micropod.

## Reproduce

From an isolated checkout of `perf/stock-docker-launch-control-20261122`, the following checks need no running engines. A blocked `check` returns 1 and writes the reason to the receipt. Use a new output directory for each run.

```sh
out=$(mktemp -d)
python3 -B scripts/test_bench_docker_launch.py
python3 -B scripts/bench_docker_launch.py plan --seed 20261122 --output "$out/plan.json"
python3 -B scripts/bench_docker_launch.py check --output "$out/preflight.json"
```

Build the opt-in CLI from this checkout. The build leaves the installed CLI and worker alone. The live invocation is for the already authorized, dedicated idle slot after the published-TCP retest has released it. Both existing engines must already have the pinned Alpine digest locally. The harness reads configuration and uses the existing engines.

```sh
swift build -c release --product micropod --disable-automatic-resolution
python3 -B scripts/bench_docker_launch.py run --slot-released \
  --worker-home "$HOME/.micropod/ci" --orbstack-socket "$HOME/.orbstack/run/docker.sock" \
  --docker "$(command -v docker)" --micropod "$PWD/.build/release/micropod" \
  --seed 20261122 --cycles 1 --output "$out/launch.json"
python3 -B scripts/ci_benchmark_store.py apple-stock-docker-launch "$out/launch.json" \
  --database "$out/measurements.sqlite3"
```

The default cycle schedules 306 timed launches, 34 warmup launches and two boot probes. The `docker_launch_pairs` SQLite view contains eligible stock and native pairs from finished schedules. Every job and each incomplete or excluded pair can be reconstructed from the raw JSON. The database write is optional and happens after measurement.

Local validation exercised the real guest shell with fixture files, the six-order schedule, both comparison calculations, first-attempt failure retention and SQLite ingestion using engine doubles. A locally compiled Mac CLI rejected missing and empty worker directories without creating session state. These checks supply no live engine samples.
