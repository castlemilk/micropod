# Gamma published TCP profile

Against the previous Micropod release, median fresh-request latency changed by **-15.4%** and 32-stream throughput by **+51.2%**. Against OrbStack the changes were **+5.6% in latency** and **-22.2% in throughput**. These measurements cover a Mac client using a published TCP port on the same M5 Max. The faster relay is opt-in with `MICROPOD_CI_PORT_RELAY=kqueue` in the worker environment. One naturally occurring guest handshake exhausted both connection attempts. [Measurements, unsuccessful attempts, CPU stacks and raw counters](gamma-published-profile.json.gz)

| Mac client measurement | Previous Micropod | Micropod with kqueue | OrbStack | Kqueue wins vs previous |
| --- | ---: | ---: | ---: | ---: |
| Fresh HTTP p50 | 852 µs | 721 µs | 683 µs | 10/12 |
| Fresh HTTP p95 | 2,757 µs | 1,446 µs | 1,087 µs | 10/12 |
| Fresh HTTP p99 | 4,608 µs | 2,496 µs | 1,519 µs | 10/12 |
| Client connection available, p50 | 145 µs | 150 µs | 163 µs | 8/12 |
| Connection available to first response byte, p50 | 680 µs | 545 µs | 456 µs | 10/12 |
| Keep-alive HTTP p50 | 325 µs | 414 µs | 222 µs | 7/12 |
| One stream | 622 MiB/s | 1,203 MiB/s | 2,286 MiB/s | 8/12 |
| 32 simultaneous streams | 2,141 MiB/s | 3,238 MiB/s | 4,163 MiB/s | 10/12 |

The table uses the 12 complete three-engine rounds from 12 scheduled rounds. Failed engine blocks out of 12 each were 0 / 0 / 0 for previous Micropod, kqueue and OrbStack, respectively. Kqueue beat OrbStack in 5/12 rounds for fresh p50 and 2/12 at 32 streams. Engine order rotated through all six permutations twice. One-minute host load ranged from 11.6 to 24.4. Per-round 32-stream throughput ranged over baseline 1,280–3,507 MiB/s, candidate 1,731–4,342 MiB/s, orbstack 3,446–6,158 MiB/s. [Previous same-Mac comparison](gamma-published-kernel.md)

A separate 768 MiB single-connection test gave 1,255, 1,377 and 2,584 MiB/s, respectively, across 12 rounds. Kqueue won 7 of 12 against the previous relay.

The median keep-alive request rose from 325 to 414 µs across rounds. Kqueue was quicker in 7 individual pairs. Small requests during downloads had the largest latency gap to OrbStack, with p95 at 5.3 times OrbStack’s value.

## Where time and CPU went

Mac stack samples repeatedly placed the previous relay in socket reads, writes and vectored writes. The guest transmitted 18 GiB with zero transmit drops during its baseline profile. The new relay uses a 256 KiB scratch buffer shared by the worker. A short write retains only the undelivered bytes and pauses that reader until the destination can accept them. A fixed-work comparison measured the supervisor’s user and system CPU time over four alternating pairs. Sampling was disabled during these pairs.

| Fixed work | Previous CPU | Kqueue CPU | Change | Previous instructions | Kqueue instructions |
| --- | ---: | ---: | ---: | ---: | ---: |
| 800 fresh HTTP requests | 0.233 s | 0.116 s | -50.2% | 0.84 billion | 0.53 billion |
| 6 GiB across 32 warm streams | 3.437 s | 1.342 s | -61.0% | 8.70 billion | 5.46 billion |

The kqueue relay’s instrumented fresh requests placed median Mac accept-to-guest-connect time in the **128–256 µs** bucket. Median completed-connect-to-first-guest-byte time was **64–128 µs**. This second interval includes guest processing. The separate 32-stream trace forwarded 8.00 GiB with 35,821 writes, including 12 partial or blocked writes.

Six alternating pairs used one container to isolate the remaining Mac relay cost. Its published port measured 684 µs fresh p50 and 3,900 MiB/s at 32 streams. Its private guest address measured 378 µs and 3,506 MiB/s. Both paths traversed the VM network and Linux port translation.

## Keeping new connections responsive during downloads

The first native relay allowed four large writes per ready socket. Its mixed fresh p95 rose from 9.1 ms on the previous relay to 27.0 ms. Four trials on one guest isolated the effect of limiting each ready socket to one write and handling new and small connections first.

| Work per ready socket | Fresh p95 during downloads | Download throughput |
| --- | ---: | ---: |
| Up to 4 × 256 KiB writes | 23.5 ms | 5,415 MiB/s |
| 1 × 256 KiB, small connections first | 6.3 ms | 5,363 MiB/s |
| 1 × 64 KiB, small connections first | 3.8 ms | 4,393 MiB/s |
| 1 × 32 KiB, small connections first | 2.8 ms | 3,144 MiB/s |

The selected schedule services every ready event in the batch and allows one write of up to 256 KiB per socket. Six balanced end-to-end rounds started 240 fresh requests 40 ms after launching a 6 GiB transfer on 32 connections. Fresh percentiles cover the entire sequence, including any requests finishing after the downloads.

| Engine during downloads | Fresh p50 | Fresh p95 | Download throughput |
| --- | ---: | ---: | ---: |
| Previous Micropod | 5,297 µs | 8,138 µs | 4,286 MiB/s |
| Updated Micropod | 4,240 µs | 6,386 µs | 5,090 MiB/s |
| OrbStack | 369 µs | 1,205 µs | 6,858 MiB/s |

Under this load, p95 time to obtain a client connection was 280 µs on kqueue and 227 µs on OrbStack. After the client finished writing, p95 time to the first response byte was 6.07 ms and 0.66 ms, respectively. These phase percentiles are measured independently.

The release binary then ran six alternating pairs against one container with its relay counters enabled. All 32 downloads continued through the same Mac published port. Only the route used by fresh requests changed. Both routes completed in 6/6 pairs. Fresh p95 was 6.32 ms through the published port and 3.85 ms direct to the guest. The corresponding write-to-first-byte p95 values were 6.03 ms and 2.11 ms. Median download throughput was 4,894 and 5,391 MiB/s.

## Handshake failures and rollout

Two earlier comparisons stopped after a guest connect on the new relay took 10.03 and 10.01 seconds. An instrumented socket reported `ETIMEDOUT` with zero application bytes transferred. Requests to the same service’s private guest address also experienced connect timeouts.

The relay now gives the first guest handshake one second. On a timeout it opens one new socket with a nine-second budget. It enables reads from the Mac client only after a handshake succeeds. Established streams and explicit connection refusals never enter recovery. Dropping SYN packets for 1.7 seconds on a single disposable service produced one retry and one recovery. A client with retries disabled received the correct response in 2.01 seconds. A separate 8,000-request test recorded zero errors. A subsequent rotation still saw both attempts expire on the candidate after nine complete rounds. All three interrupted comparisons are archived.

A follow-up capture at the guest NIC and bridge found 22,226 distinct incoming SYNs and 22,225 matching container SYN-ACKs. The one unmatched SYN was the final packet in the capture. A direct guest connection timed out during this run. The capture cannot localize that loss to either side of the Mac–guest link.

At more aggressive connection rates a separate test recorded macOS `EADDRNOTAVAIL` with sequential, randomized and interface-bound source ports. That error is distinct from the ten-second timeout. For the final 12 rounds the benchmark waited outside timed work for at most 4,000 host sockets in TIME_WAIT or SYN_SENT before each block. The observed starting counts ranged from 403 to 3,868. The benchmark did not change host network settings. The established NIO relay remains the default while the handshake failures are investigated.

## Reproduction and qualification

All three engines used four vCPUs, approximately 4 GiB, and matching arm64 image configuration and root filesystem digests. OrbStack reported Docker Engine 29.8.2. Each completed engine block measured 400 fresh requests, 400 keep-alive requests and three synchronized 32-stream transfers. The client verified service identity, a reference payload hash and each response length. Sampling and relay counters ran separately from the comparison. The release binary was qualified through both worker entry points after the opt-in setting was added. Its binary digest and the timed binary’s digest are recorded separately.

Build the Mac client with `go build -o /tmp/micropod-netbench scripts/netbench/main.go`. Configure `BASELINE_HOST`, `CANDIDATE_HOST`, `ORBSTACK_HOST` and `NETBENCH` and preload the same benchmark image on all three. Run `BENCH_ROUNDS=12 BENCH_MAX_TIME_WAIT=4000 BENCH_RECORD_FAILURES=1 scripts/bench_published_ports.sh /path/to/new-results`. This records failed blocks and returns a failure status after all scheduled attempts. For mixed traffic use `BENCH_ROUNDS=0 BENCH_MIXED_ROUNDS=6`. [Benchmark driver](../../../scripts/bench_published_ports.sh)

Set `PUBLISHED_URL`, `MARKER`, `SUPERVISOR_PID` and `NETBENCH` to profile a running service using `scripts/profile_published_ports.sh /path/to/new-profile`. With the kqueue relay, `MICROPOD_CI_PORT_PROFILE=1` records connection-phase histograms, bytes, backpressure and guest handshake outcomes when the lease closes. [Mac profiler](../../../scripts/profile_published_ports.sh)

For the route diagnostic, use the same container’s private guest IP and kernel-mapped port. Start `netbench -profile bulk -streams 32 -bursts 24 -url "$PUBLISHED_URL" -marker "$MARKER"`. After 40 ms start `netbench -profile fresh -requests 240 -url "$FRESH_URL" -marker "$MARKER"`. Wait for both clients. Alternate the order of published and private guest URLs for the fresh client over six pairs.

Local qualification covered server-first TCP, half-close, backpressure, fixed and dynamic ports, collision rollback, revocation of 32 live clients and immediate port reuse. AddressSanitizer and UndefinedBehaviorSanitizer covered 2,560 connections, 80 port-reuse cycles and a 16 MiB half-closed exchange. Clang static analysis reported zero findings. The guest supported internal bridge and MACVLAN publication. IPVLAN link creation was unavailable on this kernel. The SQLite run ID is `gamma-published-profile-20261121`, kind `published_ports`. [TCP tests](../../../Tests/MicropodRuntimeTests/NativePublishedPortsTests.swift) [Port qualification](../../../scripts/qualify_published_ports.sh)
