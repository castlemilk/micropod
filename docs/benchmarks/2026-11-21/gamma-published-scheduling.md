# Published TCP under load on Gamma

On Gamma’s 18-core M5 Max, scheduling at most two bulk socket events before checking for new requests reduced Micropod’s fresh-request p95 from **8.68 to 5.00 ms** with 32 downloads and a one-CPU service. Download throughput during those requests fell from **4,004 to 3,543 MiB/s**. At four CPUs fresh p95 improved in three of five complete rounds. OrbStack retained a substantial bandwidth lead at both limits. [Raw measurements, errors, CPU samples and packet timings](gamma-published-scheduling.json.gz)

## Equal resources inside the service

Both VMs exposed four CPUs. Linux reported a one-CPU quota, 1 GiB and 512 PIDs for a Micropod service launched with no resource flags. The OrbStack service had an unlimited CPU quota, memory and PIDs inside its VM. The Go probe observed GOMAXPROCS 2 and 4 respectively. This changes the interpretation of earlier same-Mac results. They measure product defaults. For the following runs the benchmark set CPU, memory and PID limits and confirmed the actual values inside every service. [Earlier run](gamma-published-profile.md)

| CPU quota | Engine | Idle fresh p50 | Dedicated 32 streams, MiB/s | Fresh p50 under load | Fresh p95 under load | Concurrent downloads, MiB/s |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 1 | Previous Micropod | 676 µs | 3,304 | 5.68 ms | 8.68 ms | 4,004 |
| 1 | Updated Micropod | 615 µs | 3,161 | 2.80 ms | 5.00 ms | 3,543 |
| 1 | OrbStack | 574 µs | 4,919 | 7.38 ms | 611.97 ms | 4,705 |
| 4 | Previous Micropod | 712 µs | 3,549 | 5.74 ms | 10.46 ms | 3,679 |
| 4 | Updated Micropod | 754 µs | 3,305 | 2.61 ms | 9.08 ms | 2,612 |
| 4 | OrbStack | 482 µs | 5,494 | 4.93 ms | 1,003.25 ms | 5,462 |
| No child quota | Updated Micropod | 424 µs | 4,040 | 2.09 ms | 3.61 ms | 3,998 |
| No child quota | OrbStack | 676 µs | 5,146 | 3.78 ms | 11.38 ms | 6,288 |

Each cell is the median of per-block measurements in complete matched rounds. Each block used one engine at a time on the same Mac, the same preloaded ARM64 image, 1 GiB and 512 PIDs per service. The one- and four-CPU runs rotated all six engine and quota combinations through six orders. Dedicated tests ran 400 new HTTP connections, 400 keep-alive requests and three synchronized 32-stream bursts. For the mixed test, every download finished an 8 MiB transfer before the client opened the first of 240 new connections. Downloaders continued until its last response. Every successful mixed block recorded bytes on all 32 original connections.

The six one-CPU triplets completed. Updated Micropod improved loaded fresh p95 in five pairs. All six four-CPU dedicated triplets completed. Five of six four-CPU mixed triplets completed, with one OrbStack EOF. Updated Micropod’s loaded p99 in those five was 33.64 ms, against 17.59 ms on the previous relay. OrbStack’s four-CPU p95 ranged from 15.7 to 1,007.1 ms across its completed mixed blocks. The long waits appeared primarily between writing the request and receiving its first byte. Attribution inside OrbStack requires a peer-side trace.

The native Docker API now accepts an explicit `--cpu-quota=-1`. The two-engine series with that setting completed 6/6 dedicated and 4/6 mixed pairs. OrbStack’s mixed p95 ranged from 7.8 to 205.3 ms. Two fresh Micropod requests reset. The port reported 33 guest handshake retries and zero recoveries over its lifetime, including outstanding download connections. The Mac had 1,285 and 1,233 sockets in TIME_WAIT or SYN_SENT before the two timed blocks. Locating the lost handshakes requires simultaneous host and guest SYN traces. Linux confirmed `cpu.max=max 100000` for both services. Additional physical checks covered the default, half a CPU and four CPUs on both engines, and rejection of a quota below -1 on Micropod.

## Where the request waits

The guest observer timestamped the same HTTP request and reply on the VM’s external interface and the container bridge using the Linux kernel clock. The service published two ports so the 32 downloads could continue independently of the small requests. Six balanced rounds per route produced **3,240 of 3,240 matched requests, zero packet-socket drops and zero reversed timestamps**. Interface filters copied only headers for the selected IPv4/TCP service. Sequence and acknowledgement numbers linked the request to its reply across DNAT. These instrumented runs used the default one-CPU Micropod service. [Guest observer](../../../guest/runner/cmd/porttrace/main_linux.go)

| Median per-round p95 | Idle, published port | Loaded, published port | Loaded, fresh client direct to guest |
| --- | ---: | ---: | ---: |
| Guest NIC ingress to bridge | 23 µs | 78 µs | 77 µs |
| Bridge request to bridge reply | 197 µs | 2,013 µs | 2,380 µs |
| Bridge reply to NIC egress | 14 µs | 23 µs | 29 µs |
| Whole guest request and reply | 221 µs | 2,026 µs | 2,639 µs |

These are independent percentiles. The bridge-to-reply interval includes the veth, container TCP stack, process scheduling and application. Eight alternating pairs moved the fresh requests to an identical sibling service in the same VM while keeping 32 downloads on the busy service. Fresh p95 fell from 7.09 to 5.69 ms. CPU pressure and per-thread run-queue samples are in the receipt. The remaining delay is shared with the VM and the Mac network path.

A separate fixed-work test measured the relay’s contribution to bulk transfers with four CPUs. The same Mac client downloaded 6 GiB over 32 verified persistent connections to one container. Eight rounds alternated the published address with its private guest DNAT address. 8/8 pairs completed. The published path delivered **4,907 MiB/s** and used **1.184 Mac supervisor CPU-seconds** per transfer. Direct-to-guest delivered **4,983 MiB/s** and used **0.000 supervisor CPU-seconds**. The direct route had higher bandwidth in 3/8 pairs. Both routes still cross the VM boundary and use the same guest port translation.

A three-route check moved the same client workload into a sibling container on the guest bridge. All clients used 32 warm connections and transferred exactly 6 GiB to the client. The two guest processes shared the VM’s four CPUs in the guest-local case. The published Mac port delivered **5,861 MiB/s**, the Mac-to-guest address **5,837 MiB/s**, and the guest-local bridge **16,340 MiB/s**. There were 6/6 complete rounds. The guest-local bridge exceeded Mac-to-guest throughput in 6/6. The guest-local measurement also changes the client OS, bypasses guest DNAT and shares the server’s CPU allocation. The separate contribution of the virtual NIC, translation and host TCP stack remains open. CI jobs and their companion services on the same worker can use the service name and container port on a shared Docker network. This transfer used its resolved container address.

## Relay scheduling and kernel experiments

The previous relay sorted the events already ready when it woke. A handshake arriving immediately afterwards could wait behind a full batch of bulk reads. The updated relay keeps bulk reads and their pending writes on a second Darwin kqueue serviced by the same serial owner. Once a direction reads at least 16 KiB, only that direction moves. The owner checks for fresh connections and small writes between groups of two bulk events. It keeps a single 256 KiB scratch buffer. Per-port instrumentation now records the first guest-bound write and the interval from that write to the first guest response.

Eight balanced same-container trials per variant gave loaded fresh p95 of 11.95 ms on the previous schedule, 5.69 ms with two bulk events, 7.74 ms with four and 6.84 ms with eight. A 32 KiB receive window cut p95 to 2.98 ms and reduced throughput to 1,182 MiB/s. The two-event schedule delivered 3,808 MiB/s in that experiment.

On Linux 6.18.35, limiting the virtio transmit byte queue to 128 KiB reduced throughput from 5,290 to 2,074 MiB/s and raised loaded fresh p95 from 3.16 to 11.17 ms. A 2 MiB cap gave 4,794 MiB/s and 2.78 ms. Six trials each of `pfifo_fast`, `fq` and `fq_codel` showed queue-to-queue variation and zero drops in the sampled queue counters. The worker retains its existing qdisc and byte queue settings.

Two additional six-round comparisons used each engine’s defaults and exchanged the signed Micropod binaries across two warm VM disks at the midpoint. Dedicated 32-stream throughput was 3,237 / 3,998 / 5,129 MiB/s for previous Micropod / updated Micropod / OrbStack. During uninterrupted downloads, loaded fresh p95 was 5.57 / 2.79 / 6.61 ms with 5,865 / 5,157 / 7,334 MiB/s. Eleven complete triplets contributed to the latter. One Micropod request reset and one OrbStack request returned EOF in the same round. All twelve fixed 6 GiB mixed triplets completed. Four fixed-work CPU pairs measured 0.102 / 0.116 Mac supervisor CPU-seconds for 800 fresh requests and 1.075 / 1.090 for 6 GiB on previous / updated Micropod. The kqueue implementation remains opt-in.

## Reproduction

Build the Mac `netbench` client from `scripts/netbench/main.go` and put a static Linux/arm64 build called `netbench` in a directory visible to all three VMs. Point `BASELINE_HOST`, `CANDIDATE_HOST` and `ORBSTACK_HOST` at their Docker sockets. Set `NETBENCH` to the Mac client and `BENCH_GUEST_PROBE_DIR` to the absolute shared directory. The comparison driver checks the image digest, root filesystem and in-container limits before timing. It records headroom, engine order, every failure, phase timings and overlapping bytes per connection. Both matched Micropod workers used `MICROPOD_CI_PORT_RELAY=kqueue`. [Driver](../../../scripts/bench_published_ports.sh) [Workload](../../../scripts/netbench/main.go)

```bash
BENCH_CONTAINER_CPUS=4 BENCH_ROUNDS=6 BENCH_OVERLAP_ROUNDS=6 \
  BENCH_MAX_TIME_WAIT=4000 BENCH_RECORD_FAILURES=1 \
  scripts/bench_published_ports.sh /path/to/new-results
```

For guest packet timing, build `./cmd/porttrace` from `guest/runner` for Linux/arm64 and run it in the benchmark VM’s network namespace. Pass `-guest` and `-guest-port` for the external DNAT endpoint and `-pod` and `-pod-port` for the translated service. Start the client after the ready record. Stop the observer after the last reply to collect both packet-socket drop counters.

Local verification covered eight Swift tests, fixed and dynamic ports, rollback, revocation, reuse, full-duplex backpressure, Linux filter and Docker resource tests. AddressSanitizer and UndefinedBehaviorSanitizer passed 2,560 connections over 80 lease releases. Clang static analysis returned zero findings. SQLite run `gamma-published-scheduling-20261121` uses kind `published_ports`. [Machine-readable receipt](gamma-published-scheduling.json.gz)
