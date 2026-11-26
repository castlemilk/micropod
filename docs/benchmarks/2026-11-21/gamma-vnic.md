# Gamma published TCP on the warm Linux worker

On 21 November 2026 the old Mac relay sent connections from the LAN address during private bridge repairs. Those connections reached the guest but missed its gateway-scoped Docker port mapping. Micropod now binds connections to the worker’s gateway and interface, and looks up that interface again during a transient setup failure. All six deliberate repairs completed with the same VM boot and live container. Each repair coincided with 32 persistent downloads and a wave of 32 fresh downloads. The persistent clients downloaded 25 GiB per round and recorded zero replacement connections. [Raw measurements, traces and configuration](gamma-vnic.json.gz)

The benchmark question was whether Micropod could serve 32 simultaneous Mac-to-container downloads faster than OrbStack and keep every original connection alive while new clients arrived. The comparison fixes the payload, image and service resources, separates fresh sockets from persistent streams, and records both bytes per second and fresh-request tail latency.

## Matched four-CPU services

The short test synchronizes the first response on 32 fresh TCP connections and transfers 8 MiB on each. The mixed test keeps all 32 downloads running while making 240 new HTTP connections. Each cell is a median across rounds completed by all three engines. The mixed table also requires bytes on all 32 original connections and zero reopens on every engine.

| Runtime | Fresh request p95, idle | Fresh 32-stream burst, MiB/s | Concurrent downloads during probes, MiB/s | Fresh request p95 during downloads |
|---|---:|---:|---:|---:|
| Native default | 0.46 ms | 4,345 | 3,294 | 5.41 ms |
| Native throughput | 0.45 ms | 5,880 | 5,220 | 25.25 ms |
| OrbStack | 0.47 ms | 5,487 | 5,849 | 110.86 ms |

The short test completed 6/6 matched triplets and the mixed test completed 6/6. The receipt includes partial triplets, individual bursts, all failed or reopened connections, the execution order, and host CPU load. The Mac client and all services were on the same physical M5 Max. Both Linux VMs exposed four vCPUs. Both services reported `400000 100000` for CPU, 1 GiB of memory, and a PID limit of 512.

The Docker image configuration digest was `80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889`. The service, body size and client build were identical across engines. OrbStack 2.2.5 and Micropod shared Gamma with other users. Absolute throughput varied substantially between series. The receipt preserves the same-window comparisons. [Matched driver](../../../scripts/bench_published_ports.sh)

The release’s throughput setting was 7.2% ahead of OrbStack on median fresh-burst throughput and 10.8% behind OrbStack on mixed throughput. Relative to Micropod’s own default, bulk throughput rose 58.4% under mixed load and fresh-request p95 moved from 5.41 to 25.25 ms.

The throughput setting beat the native default in 5/6 paired burst rounds and 6/6 mixed rounds. It beat OrbStack in 3/6 burst rounds and 0/6 mixed rounds. Each p95 is the median of the per-round 95th percentiles. The client checked each endpoint against its expected service marker and verified each download’s byte count.

The preceding build measured 7,055 versus 5,592 MiB/s on fresh bursts and 5,543 versus 6,320 MiB/s under mixed load. The release repeats these comparisons after the watchdog change using a stricter socket-reuse check. Movement between those two time windows also includes shared-host variation.

## Service CPU quota

The same release binaries and image also ran with one CPU and with the per-service quota removed. All VMs still had four vCPUs. These medians use the 32 continuous downloads and 240 fresh requests.

| Service quota | Complete triplets | Native default, MiB/s | Native throughput, MiB/s | OrbStack, MiB/s | Loaded p95, default / throughput / OrbStack |
|---|---:|---:|---:|---:|---|
| One CPU | 5/6 | 4,405 | 6,384 | 5,034 | 3.25 / 35.30 / 55.17 ms |
| Uncapped | 5/6 | 5,269 | 7,498 | 7,382 | 3.24 / 16.92 / 7.10 ms |

Every four-CPU mixed round completed on the original 32 sockets for all three engines. With one CPU, Micropod throughput completed five of six, while Micropod default and OrbStack completed all six. With no service CPU quota, Micropod throughput and OrbStack completed all six, while the native default completed five. Every completed round transferred bytes on all 32 original connections through warm-up, measurement and drain.

Two involuntary network outages remain visible in the release data.

- With one CPU, the throughput worker hit the client’s 30-second deadline reading a response body. The watchdog could not repair the guest link in place and performed a full NIC reconnect, which took 7.01 seconds. The counters include nine established resets between the start of that quota series and the failed round. The origin of the initial link loss remains unresolved.
- With an uncapped service, the default worker reset a fresh client connection ten seconds into the final mixed round. Its Mac gateway was missing. The first full reconnect failed its gateway check. A subsequent retry restored the gateway in 7.76 seconds. Micropod throughput and OrbStack completed their runs in this round.

## TCP recovery on the local return route

With two relay data workers and Reno, four-CPU synchronized bursts sometimes ran above 6,000 MiB/s and sometimes paused for about 200 ms. The service’s TCP timeout counter increased. Eight rounds on the same running container rotated seven gateway-route configurations. Each trial used three fresh 256 MiB bursts and a separate interval with 32 streams and 160 fresh requests. TCP counter deltas below cover the fresh-burst client invocation, including its small and single-stream requests.

| Route on the service | Median fresh burst, MiB/s | Mixed, MiB/s | Loaded p95 | Bursts over 200 ms | TCP timeouts |
|---|---:|---:|---:|---:|---:|
| Reno, kernel defaults | 5,780 | 5,837 | 22.4 ms | 4/24 | 5 |
| Reno, 50 ms | 4,582 | 6,138 | 21.3 ms | 0/24 | 6 |
| Reno, 20 ms | 5,137 | 5,987 | 21.0 ms | 0/24 | 6 |
| Reno, 5 ms | 5,109 | 6,034 | 21.7 ms | 0/24 | 7 |
| Reno, 20 ms, ssthresh 128 | 5,856 | 5,777 | 22.1 ms | 0/24 | 3 |
| Reno, 20 ms, ssthresh 256 | 5,062 | 5,731 | 23.4 ms | 0/24 | 9 |
| BBR, 20 ms | 3,808 | 4,826 | 8.6 ms | 0/24 | 0 |

Every tested lower recovery floor eliminated the four transfers over 200 ms seen with the kernel default in this window. The 20 ms floor bounds the cost of an isolated timeout on this private hop. A later socket trace found the initial slow-start threshold stayed at the Linux default in every sampled fresh response. Gamma sets `tcp_no_ssthresh_metrics_save=1`. The release therefore requests only the Reno preference and 20 ms floor. The apparent difference between the two slow-start threshold rows cannot be attributed to the threshold. The route applies only to the service’s directly attached gateway IPv4 address. This includes guest-originated traffic using that source. The guest-wide congestion controller and unrelated destinations retain their own settings. The receipt records each kernel route, retransmission and loss-probe deltas, and every timing. [Linux TCP recovery parameters](https://docs.kernel.org/networking/ip-sysctl.html)

A service-scoped eBPF probe verified Reno on 33,653 calls to `tcp_sendmsg` while the guest-wide default was BBR. An internal named bridge acquired the per-gateway route only on a container with a published port. Both internal containers lacked a default route. The final qualification read back the shipping route from a newly booted worker and a newly created service. [Route implementation](../../../guest/runner/docker_port_nat_linux.go)

## Source of the connection resets

The first eight alternating mixed-load trials included a Micropod failure. Gamma lost the private gateway for 6.03 and 6.02 seconds. When the second interval ended, the guest emitted 111 SYN resets that had no matching container-bridge packet. The guest TCP counter for outgoing resets rose by exactly 111. The observer lost zero packets on either interface. Nine other reset headers had matching packets from the container. Listen drops, listen overflows, SYN cookies, socket memory aborts and softnet drops all had zero delta in the worker namespace. CPU 0 recorded eight softnet time-squeeze events.

Four deliberate repairs per relay reproduced the source selection. The old relay emitted 37 SYNs from the Mac LAN address. All 37 received a guest reset. The eBPF stack classified them as `SK_RST_REASON_NO_SOCKET` in `tcp_v4_send_reset` on the local IP delivery path. Its other 371 SYNs had the expected gateway source and appeared on the container bridge. All 402 SYNs on the updated relay used the private gateway, with zero guest reset headers. An unscoped route lookup selected a different source during every observed gateway absence. Simultaneous packet captures establish the source comparison. A subsequent replay on the updated worker with the reset tracepoint active recorded an empty reset map across two repairs. Conntrack reported zero insert failures, drops and early drops. Its active count rose from 2 to 209 of 65,536 entries. Mac link-layer capture required elevated access unavailable to this session. Host attribution uses interface address selection and TCP socket telemetry, correlated with the guest packet sequence numbers and stacks. The Apple vmnet API does not expose a host datagram descriptor to this relay. [Guest header observer](../../../guest/runner/cmd/porttrace/main_linux.go) [Kernel reset probe](../../../scripts/profile_port_resets.bt) [Mac route observer](../../../scripts/vnic_watch.c)

The default native worker binds each upstream socket to the expected source address and interface. Before any application byte is consumed, a transient missing route or handshake timeout can create a new socket within the setup budget. Connection refusal still closes immediately. Lease revocation cancels pending retries, drains queued handoffs and closes the active sockets before the port can be reused. Ordinary guest traffic and the guest firewall keep their existing policy. The optional SwiftNIO implementation also binds the source address.

In an earlier one-CPU series, all HTTP requests completed but one trial reopened eight verified bulk connections. The service’s established-reset count rose by eight across that series. The worker log and wall clock place an automatic 19.20-second guest-link repair inside the affected trial. This is a separate observation from the mis-sourced SYNs. The prior data do not establish where each of those established sockets closed.

When the Mac gateway still exists, the release restores a missing guest default route and repeats the ARP probe before detaching a NIC. A missing Mac gateway, an explicit reconnect, or a failed guest repair still uses the full reconnect. In two independent faults we removed only the guest default route during a one-CPU service transfer. The watchdog restored it in place in 1.07 and 1.05 seconds after detection. All 32 streams finished 175 GiB per fault with zero reopens. The boot ID and service were unchanged. On the final build, a separate explicit NIC reconnect also preserved 32 established streams through 50 GiB and served 32 fresh synchronized downloads on the same port. [Watchdog](../../../Sources/MicropodRuntime/CIWorkerNetwork.swift)

## Short bursts and long streams

A separate crossover, using Reno with the original recovery timer, starts each stream behind the same gate, verifies the service marker, and varies socket reuse, first-response synchronization and byte count independently. Reuse is checked with the client connection trace. The short transfer totals 256 MiB. The long transfer totals 6 GiB. The earlier 5,861 MiB/s Micropod result and 5,494 MiB/s OrbStack result used different workload shapes. [Workload source](../../../scripts/netbench/main.go) [Rotated crossover](../../../scripts/bench_vnic_bursts.sh)

| Four-CPU test, MiB/s | Original relay | Two workers with Reno | OrbStack |
|---|---:|---:|---:|
| Fresh, synchronized, 256 MiB | 4,137 | 6,286 | 4,598 |
| Preconnected, synchronized, 256 MiB | 4,031 | 4,796 | 5,520 |
| Preconnected, freely drained, 6 GiB | 4,407 | 6,103 | 6,246 |

On those fresh synchronized sockets, the last stream connected at 0.96 ms for Micropod and 0.86 ms for OrbStack. The last first header arrived at 4.30 and 24.42 ms. The last body completed at 40.74 and 56.00 ms. Values are median run maxima across 32 streams. This separates time waiting for headers from time draining the bodies.

## In-flight data under mixed load

A probe on the service’s sending sockets verified the effective congestion-window cap before timing. Replacing a route alone retained Linux’s cached TCP metrics, so the screening fixture cleared only its own metrics for the gateway and primed three connections before every case. Without a cap, Reno reached a window of 6,508 segments during the diagnostic transfer. The 64-, 128- and 256-segment settings all reached their exact requested cap. The production worker leaves the flight limit under TCP control. [Linux TCP metric cache](https://github.com/torvalds/linux/blob/v6.18/net/ipv4/tcp_metrics.c)

| Maximum in-flight segments | Burst, MiB/s | Mixed, MiB/s | Mixed fresh p95 |
|---|---:|---:|---:|
| Kernel default | 2,555 | 4,535 | 29.34 ms |
| 64 | 2,219 | 2,071 | 5.22 ms |
| 128 | 2,981 | 3,511 | 5.93 ms |
| 256 | 2,949 | 4,004 | 9.91 ms |

## Virtual NIC and guest networking

Linux 6.18.35 exposed one combined virtio queue pair and 256-entry rings. The guest NIC and bridge had TCP segmentation and generic receive offload enabled. The host-side veth advertised segmentation offload with GRO disabled. During a 6 GiB transfer, the unmodified NIC averaged 59.0 KiB per transmit call and 41.7 segments per call. All 48,676 observed receive calls ran on CPU 0. RPS distributed the receive calls across all four cores. CPU 0 spent 73–79% of its sampled time in softirq during three additional transfers. These observations establish an imbalance, and the intervention measures its end-to-end cost. [Kernel NIC probe](../../../scripts/profile_vnic.bt) [Linux network scaling](https://docs.kernel.org/networking/scaling.html)

Negotiated MTU 9,000 moved median synchronized throughput from 3,449 to 3,474 MiB/s. On the same container, splitting acceptance from two data workers delivered 4,222 MiB/s versus 3,781 on the single owner. Two dedicated host-only virtio interfaces produced 3,475 MiB/s. A direct virtio-vsock prototype completed zero of four synchronized 32-stream trials. Its sustained downloads ranged from 53 to 125 MiB/s across the tested concurrency levels. These experiments used private workers.

RPS plus RFS reduced mixed loaded p95 from 4.15 to 3.61 ms, while median mixed throughput changed from 4,145 to 3,872 MiB/s. Adding fq_codel on the service veth and bridge yielded 3,840 MiB/s and 4.22 ms. All settings were restored. Moving only already-classified bulk streams to I/O workers reduced loaded p95 from 9.9 to 7.5 ms but reduced synchronized throughput from 3,468 to 3,197 MiB/s.

The same server executable also ran directly in the Micropod Linux guest with the same CPU, memory and PID limits. This measures what removing the guest bridge and NAT could deliver on this rig. The sibling client used the same Linux binary and resource limits on each engine.

| Route | Fresh 256 MiB, MiB/s | Persistent 6 GiB, MiB/s |
|---|---:|---:|
| Mac via Micropod loopback | 2,538 | 2,568 |
| Mac directly to guest DNAT | 2,565 | 2,702 |
| Mac directly to guest process | 1,949 | 2,530 |
| Micropod sibling to service | 8,377 | 9,582 |
| OrbStack sibling to service | 10,002 | 13,496 |

The running kernel supports eBPF tracing. Its configuration disables `CONFIG_NET_CLS_BPF`, `CONFIG_NET_CLS_ACT`, `CONFIG_BPF_STREAM_PARSER` and AF_XDP. A TC redirect experiment needs a different kernel and a design that preserves per-lease NAT and revocation. Apple exposes custom Virtio devices starting in macOS 27. Gamma runs macOS 26.5.1. Both the direct guest-process timings and the measured socket-reset path favor retaining the stock driver here. [Apple custom Virtio availability](https://developer.apple.com/videos/play/wwdc2026/224/) [Apple vmnet MTU configuration](https://developer.apple.com/documentation/vmnet) [Linux segmentation offloads](https://docs.kernel.org/networking/segmentation-offloads.html)

For a CI job talking to PostgreSQL, Redis or a registry on the same warm worker, attach the job and service to the same Docker network and use the service name and container port. That keeps the bytes in Linux. The sibling and host measurements use different client placements and answer different questions. The table compares the same placement for both engines. [Worker networking](../../ci-worker.md)

## Reproduction on an Apple Silicon rig

Start two private four-vCPU, 4 GiB native Micropod workers, one with its default relay and one with `MICROPOD_CI_PORT_RELAY=kqueue-throughput`. Configure OrbStack with four vCPUs and 4 GiB. Use the same local arm64 service image on all three and the same Mac client for all timings. Give the shared probe directory an arm64 Linux executable named `netbench` built from `scripts/netbench/main.go`. The driver verifies the image config, layer digests, actual cgroup limits, published port and service marker before starting.

Set `BASELINE_HOST`, `CANDIDATE_HOST` and `ORBSTACK_HOST` to the respective Docker-compatible sockets, `NETBENCH` to the Mac executable and `BENCH_GUEST_PROBE_DIR` to the shared probe directory. Run the following from the checkout, with a new output directory.

```sh
BENCH_CONTAINER_CPUS=4 BENCH_ROUNDS=6 BENCH_OVERLAP_ROUNDS=6 \
BENCH_REQUESTS=240 BENCH_ROUND_PAUSE=1 BENCH_MAX_TIME_WAIT=4000 \
BENCH_NETWORK_COUNTERS=1 BENCH_RECORD_FAILURES=1 \
bash scripts/bench_published_ports.sh results-4cpu
```

Repeat with `BENCH_CONTAINER_CPUS=1`, then with `BENCH_CONTAINER_CPUS=max BENCH_ROUNDS=0` for the uncapped mixed case. The workload-shape driver accepts one fixture name, URL and expected service marker per tab-separated row. Run it with `NETBENCH` set and `bash scripts/bench_vnic_bursts.sh fixtures.tsv shapes`. Enable `MICROPOD_CI_PORT_PROFILE=1` when starting a worker for relay histograms, and run the NIC and reset probes in separate diagnostic intervals. The SQLite store uses run `gamma-vnic-20261121` and kind `published_ports`.

Local verification covered 11 Swift relay tests, the Linux packet-filter cases, and 2,560 client connections and 80 revocations under AddressSanitizer and UndefinedBehaviorSanitizer. The public Docker API exercised dynamic and fixed ports, collision rollback, removal, port reuse, and publication on available internal networks. The rig kernel did not provide IPVLAN. GitHub Actions was kept off.
