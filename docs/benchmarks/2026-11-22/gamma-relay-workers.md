# Published TCP relay throughput on Gamma

Four host relay workers delivered 14,813 MiB/s with 32 downloads on one logical port. The previous two-worker relay delivered 8,656 MiB/s. The paired change was +65.6% (95% paired bootstrap interval +54.3% to +68.6%, 12/12 faster). With one download on each of 32 ports, changing only the two-worker placement policy delivered +78.5% (95% paired bootstrap interval +58.9% to +108.9%, 11/11 faster). [Per-stream byte counts, probe timings and failures](gamma-relay-workers.json.gz)

These are host-component measurements on Gamma’s M5 Max, with 18 CPU cores, 128 GB and macOS 26.5.1. The fixture runs Micropod’s Darwin kqueue data path between already-connected local stream sockets. The outstanding end-to-end comparison includes Mac TCP, the virtual NIC, Linux and the container. The latest full Gamma run measured **2,710 MiB/s for Micropod and 3,010 MiB/s for OrbStack**, with fresh HTTP p95 of 35.2 and 220.3 ms. This session received `EPERM` on a Mac loopback bind and permission denied on OrbStack’s Docker socket. [Previous VM comparison](../2026-11-21/gamma-vcpu-priority.md)

## Confirmed runs

The confirmation began on 22 November 2026 at 10:24 AEDT. Every round offered 32 continuous downloads and 240 new, short exchanges at 25 ms intervals over six seconds. The three configurations ran in all six orders twice per topology. Each round warmed every stream to at least 1 MiB first. The fixture reproduces the previous Swift per-port cursor and calls the candidate’s production selector. The client compares every received byte with its stream’s payload, verifies totals after draining, and checks both directions of half-close. Each fresh exchange creates two connected socket pairs, registers the relay, sends an eight-byte marker and verifies the reply. Timing starts at the scheduled arrival. Each probe runs on a pthread independent of libdispatch’s relay queues. Profiling counters were off during timing.

| Logical ports | Mac relay | Clean rounds | Bulk MiB/s | Fresh p95, ms | Process CPU-s/GiB |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | Previous, two workers | 12/12 | 8,656 | 18.3 | 0.52 |
| 1 | Staggered, two workers | 12/12 | 9,412 | 17.8 | 0.51 |
| 1 | Staggered, four workers | 12/12 | 14,813 | 15.5 | 0.57 |
| 32 | Previous, two workers | 11/12 | 5,046 | 19.3 | 0.46 |
| 32 | Staggered, two workers | 12/12 | 9,271 | 18.5 | 0.51 |
| 32 | Staggered, four workers | 12/12 | 15,753 | 14.9 | 0.58 |

On a single port, comparing the four-worker and two-worker candidates directly gives +55.1% (95% paired bootstrap interval +49.7% to +67.2%, 12/12 faster). The median paired change in fresh p95 is -13.9%.

Rates and p95s are medians over each configuration’s clean rounds. Paired changes use rounds completed by both arms. Intervals resample whole matched rounds 10,000 times. Process CPU includes the relay, the generators, the receivers and their payload verification. The 71 successful runs verified 4.35 TiB during the scored windows. The previous two-worker relay timed out in round 5 of the 32-port test while waiting for its final probes.

## How the relay changed

Each published port previously started round-robin at worker zero. All 32 persistent downloads on 32 newly active ports therefore used the same worker. The first connection on each new port now takes the next starting worker from the accept queue. Further connections rotate within that port. The two-worker distribution in this fixture changed from 32/0 to 16/16. One-port traffic still splits 16/16.

Both parallel modes default to two workers. Setting `MICROPOD_CI_PORT_RELAY_WORKERS=4` starts four. Each owner processes up to 24 events in a callback when there are three or four owners, leaving time for a queued handoff or lease revocation. The limit for one or two owners is 128. A six-pair, four-worker screen compared those two limits before either confirmation. `micropod ci status` reports the actual count as `publishedRelayWorkers`. The VM and container retain independent CPU settings. [Worker configuration](../../ci-worker.md)

A separate 12-round pass per topology ran probe clients on libdispatch. On one port the four-worker candidate gained 64.8% in paired throughput. Across the two topologies the four-worker candidate finished 24/24 runs. The old two-worker relay timed out in three 32-port runs. Ten two-second and four six-second diagnostic repeats finished. The failing stage in the original three runs is unknown. Six further repeats with eight-second per-socket deadlines completed. The archive includes every attempt.

With 32 KiB client buffers, the AddressSanitizer and UndefinedBehaviorSanitizer pass exercised 697,137 partial or blocked writes across the two candidate configurations. Each run also closed a live lease with connections on every owner, checked both ends for EOF, verified a sibling stream stayed live and reused the logical target. Thirteen Swift worker tests passed. The named broker XCTest stopped at the socket bind with errno 1. The Linux ARM64 service and Mac client built, and the Docker driver passed one-port and 32-port fixture checks for valid and rejected receipts.

## Reproduction

The implementation revision is `2ee6f14375781702107dafc43322334fabf49e73` and the baseline is `b97a532a01d866b7b7914acda85e8c07b14cc209`. On macOS, run `python3 scripts/relaybench/compare.py /tmp/new-relay-results` from the repository. When applying the patches under different commit IDs, pass `--baseline` with the local revision immediately before the relay change. The driver builds both C revisions, saves the source and binary hashes, keeps every attempted round and writes the paired summary. For the backpressure check add `--sanitize --profile --client-buffer-kib 32 --seconds 2 --rounds 1`. [Comparison driver](../../../scripts/relaybench/compare.py)

For the Docker comparison, use separate worker homes and matching four-vCPU, 4 GiB VMs for both Micropod builds and OrbStack. Use the same Linux kernel and Interactive worker settings on the Micropod arms. Capture the Micropod status for both. Set `MICROPOD_CI_PORT_RELAY_WORKERS=4` on the candidate. Build the multi-listener netbench service for Linux ARM64 and preload the same image on all three engines. Build `scripts/netbench/offered/main.go` for the Mac client. Use the existing matched driver with `BENCH_VM_CPUS=4,4,4`, `BENCH_CONTAINER_CPUS=4`, `BENCH_ROUNDS=0` and `BENCH_OFFERED_ROUNDS=18`. Run `BENCH_OFFERED_PORTS=1` and `BENCH_OFFERED_PORTS=32` into separate output directories. The latter publishes distinct guest ports on one container with one CPU quota and verifies an individual service marker for each mapping. [Matched Docker driver](../../../scripts/bench_published_ports.sh) · [Required engine and probe setup](../2026-11-21/gamma-worker-sizing.md)
