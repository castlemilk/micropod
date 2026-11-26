# Quiet service HTTP on Gamma

The archived stock bridge measured 54.5 µs median keep-alive p50 against OrbStack’s 19.5 µs. Fresh p95 went the other way, 340 versus 545.5 µs. The old client verified each service marker but did not record which socket served each keep-alive request. The opt-in diagnostic below checks that assumption before attributing the difference to the guest network.

## Archived service traffic

The four-vCPU stock series retained six samples for each path, with 200 serial calls per mode in each sample. Each cell is the median of the six reported percentiles, in microseconds. The archive groups these samples by path without crossover round IDs, so differences between these medians are descriptive. Ubuntu used two processes on its loopback interface. The other services communicated between containers in the same Linux guest. [Native network receipt](../2026-11-21/native-network.json.gz)

| Path | Keep-alive p50 | Keep-alive p95 | Fresh p50 | Fresh p95 |
| --- | ---: | ---: | ---: | ---: |
| Micropod bridge | 54.5 | 109 | 233.5 | 340 |
| Micropod macvlan | 59 | 122 | 208 | 334 |
| OrbStack | 19.5 | 63 | 225.5 | 545.5 |
| Ubuntu loopback | 97 | 174.5 | 190.5 | 329 |

Earlier samples before pod-interface reuse measured bridge/OrbStack keep-alive p50 at 110/30 µs and fresh p95 at 649/712 µs. Each arm had six samples. The epochs are separate. Neither retains individual request durations, reconnect counts or an HTTP error denominator. Two additional installed-worker qualification samples recorded keep-alive p50 of 45 and 37 µs, without a matched peer. The explicitly excluded empty receipt in this archive came from a 32-job Go workload.

The DNS crossover also recorded short HTTP phases before each DNS workload. Matching its stock and OrbStack controls by experiment, DNS client count and round gives 14 pairs in each stratum. The client made eight HTTP calls per mode, serially, in every row. The DNS client count identifies the later DNS workload. Positive differences below mean Micropod took longer. With eight requests, the stored sample p95 is its maximum.

| Later DNS clients | Median paired keep-alive p50 difference | Rounds with higher Micropod keep-alive p50 | Median paired keep-alive p95 difference | Median paired fresh p50 / p95 difference |
| ---: | ---: | ---: | ---: | ---: |
| 1 | +49 µs | 11/14 | +9 µs | +37.5 / +37.5 µs |
| 16 | +40.5 µs | 12/14 | +27 µs | +19.5 / −138 µs |
| 32 | +70.5 µs | 14/14 | +40.5 µs | −34 / −102 µs |

The separate sibling transfer experiment alternated engine order over six rounds using numeric service IPs. All 24 arm/mode runs exited successfully with exact byte counts and zero unexpected reconnects. The 32-stream fresh burst delivered 256 MiB per arm per round. Micropod/OrbStack medians were 8,377/10,002 MiB/s, with a median within-pair change of −21.5%. The 32-stream established transfer delivered 6 GiB per arm per round. Its medians were 9,582/13,496 MiB/s and its paired change was −26.9%. These workloads measured throughput inside the guest. Quiet requests and Mac-published ports require separate measurements. [Sibling transfer receipt](../2026-11-21/gamma-vnic.json.gz)

## Diagnostic

The client warms one HTTP/1.1 connection to the service’s `/id` endpoint, then issues 100 serial requests. Every scored request checks the expected body, socket identity, reuse flag, dial count and acquisition count. A retry on another socket, wrong service, missing trace or incomplete run returns a failing exit status while retaining the raw samples on stdout. The default whole-run deadline is 30 seconds and each request has a two-second limit.

Each row gives monotonic nanoseconds from request start through connection acquisition, completed request write, first response byte and completed body. The interval from writing to first byte includes server work and scheduling on both ends. Isolating packet-transit time would require independent timestamps. For engine comparisons, describe the whole run as incomplete if any row failed. Compare identical instrumented clients, with matched CPU, image and randomized paired engine order.

To reproduce the archive tables and build the diagnostic offline:

```sh
python3 -B scripts/relaybench/quiet_http_archive.py
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -p 2 -trimpath -buildvcs=false \
  -o "$SHARED_PROBE_DIR/quiet-http" scripts/netbench/quiet/main.go
```

Set `MICROPOD_BENCH_QUIET_HTTP_DIR` to that absolute, guest-visible directory to include the probe in the native-network qualification. The script mounts the binary read-only and runs it on each network before the traffic probes. On 24 November the separate 64-container CI fixture ran the socket-verified probe on both guests. It measured quiet and busy traffic with one, two and four guest CPUs available across each client–service pair. [Qualification entry point](../../../scripts/qualify_native_network.sh) · [Probe source](../../../scripts/netbench/quiet/main.go) · [Measured placement and scheduler results](../2026-11-24/gamma-ci-concurrency/sibling-results.md)

## Offline verification

Under Go 1.27.2 on Darwin arm64, `go test -p 2 -race -count 3 -cpu 2 -v scripts/netbench/quiet/main.go scripts/netbench/quiet/main_test.go` passed all seven simulated-transport cases in each repetition. A mock Docker command confirmed zero extra clients in the default qualification and two in the opted-in run, both before bulk traffic. Shell syntax validation passed. The Linux arm64 binary built without fetching dependencies and had SHA-256 `409c3b0a4a81bde4d7c0a10990c4a08dca78d50137b4ec2c2db04a9180a7731d`.
