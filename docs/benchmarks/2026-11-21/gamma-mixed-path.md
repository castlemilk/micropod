# Gamma mixed published-port throughput and gateway recovery

The test keeps 32 original Mac-to-container TCP connections downloading 8 MiB HTTP bodies while a second client opens 240 fresh connections. The question is whether Micropod can sustain both transfers and short requests on the same warm VM, even if its internet gateway disappears. The baseline is Micropod throughput at `4f887ba5`. The peer is OrbStack 2.2.5 on the same physical M5 Max. [Previous 10.8% gap](gamma-vnic.md) · [Raw samples, failures, counters and fixtures](gamma-mixed-path.json.gz)

The four-CPU published path improved in every paired round against the previous Micropod build. OrbStack retained a bandwidth lead on both the original mixed workload and the fixed-arrival test. Fresh requests completed faster on Micropod. The one-CPU timeout and the uncapped default gateway reset passed the targeted faults on the original connections. A separate uncapped throughput-mode EOF remains unattributed.

## Matched release results

Gamma had 18 CPU cores and 128 GiB of RAM, running macOS 26.5.1 (25F80). Each Linux VM had four vCPUs and 4 GiB. Each service had 1 GiB and a 512-PID limit. The driver read the effective limits inside every service and checked the image configuration and layers. The same arm64 service image had configuration digest `80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889`. All engines ran sequentially in six rotated orders. The counted Micropod release used the production runner bootstrap, with the baseline diagnostic collector asleep. The host was shared.

The table uses only rounds in which both Micropod and OrbStack verified the marker and exact body sizes, moved bytes on every original socket and recorded zero reopens through drain. The latency columns give the median of per-round p95s on those same rounds. The paired difference is the median of the individual rate ratios. The independent completion counts preserve failures outside the paired sample.

| Service CPU quota | Micropod / OrbStack qualified | Matched rounds | Micropod MiB/s | OrbStack MiB/s | Paired difference | Fresh p95, Micropod / OrbStack |
|---|---:|---:|---:|---:|---:|---:|
| 4 CPUs | 6/6 · 5/6 | 5 | 3,953 | 4,774 | -17.9% | 37.1 / 1,004.7 ms |
| 1 CPU | 6/6 · 5/6 | 5 | 3,069 | 3,707 | -17.1% | 66.7 / 1,010.2 ms |
| Uncapped | 5/6 · 6/6 | 5 | 2,318 | 3,279 | -24.8% | 86.5 / 1,008.1 ms |

Against the previous Micropod build, the new path won 6/6 paired four-CPU rounds, with median throughput 4,287 versus 3,392 MiB/s. The median paired change was +39.4%. Against OrbStack it won 2/5. The four-CPU paired-ratio percentile bootstrap interval was -21.2% to +6.8%. It describes resampling this small shared-host series.

Mac one-minute load averages ranged from 32.9 to 143.2 across the release runs. Both VMs exposed CPUs 0–3. In the one-CPU case both Go services reported two runnable Go execution threads under the same 100 ms CFS quota period.

## Fixed fresh-request rate

The original test sends each fresh request after the previous one completes. A slower responder therefore sees fewer small requests per second and a longer bulk window. A second client scheduled one new connection every 25 ms for six seconds on each engine and counted bytes over that same wall-clock window. It disabled HTTP keep-alives for the fresh clients, measured latency from scheduled arrival and waited for every response and final bulk body. The original client closed its idle connection before each request. Each engine again served 32 persistent streams. The raw fixture records client dispatch delay and the progress of every stream.

The new release completed 6/6 rounds and OrbStack 6/6. In 6 common rounds, Micropod delivered 3,672 MiB/s at 65.3 ms fresh p95. OrbStack delivered 4,916 MiB/s at 1,004.0 ms. The median paired difference was -24.5%, with 0 Micropod wins. Previous Micropod delivered 3,795 MiB/s across 6/6 qualifying rounds.

Mac process counters bracketed identity warm-up, the six-second window and drain. The new Micropod VMM consumed 1.74 CPU-seconds per elapsed second and accumulated 2.00 thread-seconds runnable off-CPU per elapsed second. Its relay process accounted for 0.97 CPU-seconds per elapsed second. OrbStack's VM helper used 4.29 CPU-seconds and accumulated 4.89 thread-seconds runnable off-CPU per elapsed second. Micropod's VMM identities were verified from open worker disk handles. These are process-wide CPU measurements and may include other activity in OrbStack. [Apple scheduler accounting](https://github.com/apple/darwin-xnu/blob/main/osfmk/kern/thread.h)

## Where the downloads stopped

In the ordinary four-CPU comparison, the median per-round p95 to connect was 1.15 ms on Micropod and 2.21 ms on OrbStack. From a completed request write to the first response byte those p95s were 36.07 and 1,004.20 ms. These phase measurements use the same 5 paired rounds as the release table.

A diagnostic Mac client sampled cumulative bytes on all 32 sockets every 5 ms, with 400 ms of bulk-only traffic on either side of the fresh requests. Each probe also recorded request write, first byte and completion. No byte movement between two samples means the Mac application observed no reads in that interval. It cannot identify the instant a packet crossed the NIC.

| Trace path | Samples with all 32 idle, by elapsed time | p95 from request written to first byte, ms |
|---|---:|---:|
| Old published | 36.2–46.8% | 256.2–300.8 |
| Old guest DNAT direct | 40.3–60.9% | 101.8–195.9 |
| OrbStack, original trace | 1.9–3.1% | 1007.9–1012.2 |
| Old published, release trace window | 0.8–13.4% | 51.3–133.0 |
| Release published | 6.2–34.9% | 70.9–237.6 |
| Release guest DNAT direct | 5.5–16.2% | 27.9–45.3 |
| OrbStack, release trace | 1.4–3.5% | 225.2–1008.0 |

On the original published path, all downloads were idle for 36.4–47.0% of the time a fresh request was waiting for its first byte, versus 5.6–11.7% of the intervals outside that wait. The stalls also appeared when the Mac dialed Linux DNAT directly. These observations place a substantial part of the wait downstream of Mac acceptance. The overlapping intervals cannot establish that arrivals caused every stall.

Previous path. During a separately instrumented run the service namespace added 58,100 retransmitted TCP segments against 14,121,480 outgoing segments (0.411%), 45 TCP timeouts, 0 listen drops and 0 quota-throttled periods. In 637,433 eBPF samples at service `tcp_sendmsg` entry, 55.5% had at least the congestion window's worth of packets outstanding, 6.3% met the receive-window bound and 2.1% had filled the send buffer. The eBPF percentages count send calls. Reordering can also trigger retransmission.

Release. During a separately instrumented run the service namespace added 4,412 retransmitted TCP segments against 12,642,118 outgoing segments (0.035%), 0 TCP timeouts, 0 listen drops and 0 quota-throttled periods. In 571,408 eBPF samples at service `tcp_sendmsg` entry, 0.6% had at least the congestion window's worth of packets outstanding, 4.8% met the receive-window bound and 1.9% had filled the send buffer. The eBPF percentages count send calls. Reordering can also trigger retransmission.

Previous path guest counters recorded 0 softnet drops and 153 receive-processing budget overruns. Conntrack insert failures, drops and early drops increased by 0, 0 and 0. Softirq occupied 38.7% / 2.6% / 2.5% / 2.1% of CPUs 0–3 respectively.

Release guest counters recorded 0 softnet drops and 12 receive-processing budget overruns. Conntrack insert failures, drops and early drops increased by 0, 0 and 0. Softirq occupied 10.6% / 8.8% / 9.7% / 41.4% of CPUs 0–3 respectively.

During release traces, the Mac VMM accumulated 3.27 runnable off-CPU thread-seconds per elapsed second in intervals when every download was idle, versus 2.54 with progress. Corresponding VMM CPU time was 0.67 and 1.22 CPU-seconds per elapsed second. This alignment covered 100.0% of the measured overlap. Both samplers targeted 5 ms. Intervals over 50 ms were excluded from this correlation. VMM-wide scheduling and network delivery can overlap.

The native worker now gives published ports their own host-only virtio interface, independent of the internet interface. The Mac relay still scopes each guest connection to the matching gateway. The watchdog repairs the affected guest address and first hop. A failed route or handshake advances the next probe. On the throughput setting, Linux uses fair queuing on the published interface and the service veth. The private NIC interrupt moves off CPU 0 when it has one IRQ and multiple CPUs. Dedicated Mac data workers drain up to 12 bulk events per batch. The default relay retains two. [Worker behavior and configuration](../../ci-worker.md) · [Apple host-only networking](https://developer.apple.com/documentation/vmnet/operating_modes_t/vmnet_host_mode)

## Gateway and timeout regressions

A signed physical test detached the VM's internet NIC and released the last Mac attachment to that network. It repeatedly checked that the actual egress address was absent and the published address present for 32.08 seconds. A separate probe verified 280 fresh HTTP responses during the absence. The simultaneous client transferred 63.09 GiB and completed 4,417 additional fresh requests over warm-up through recovery. All 32 original sockets survived. The raw receipt also retains the initial test-harness run in which the VM shut down before clients had drained their final bodies. The regression test now waits for the client to acknowledge drain before tearing down.

Within a conservative 29.54-second interval guaranteed to lie entirely inside the outage, every download advanced at least 1,808 MiB and the load client completed 4,080 fresh requests.

| Docker service fault | Fresh responses | GiB transferred | Reopened / client errors |
|---|---:|---:|---:|
| 1 CPU, published guest NIC down | 23 | 2.07 | 0 / 0 |
| 1 CPU, guest egress repeatedly forced down for 35 s | 843 | 82.90 | 0 / 0 |
| Uncapped throughput, three egress reconnects | 205 | 17.20 | 0 / 0 |
| Uncapped default, three egress reconnects | 1,520 | 13.12 | 0 / 0 |

The fault driver checked the container ID and boot ID before and after every case. Each original TCP connection verified the service identity before load and exact 8 MiB bodies through drain. The 15-second fresh and 30-second body deadlines stayed in force. Native default and throughput also exercised the Docker published-port API contract. The receipt includes network events, repairs and both contract transcripts.

The additional uncapped run used the default relay that previously reset. Micropod default qualified 6/6 rounds and OrbStack 6/6. In their 6 common rounds the medians were 2,918 and 4,609 MiB/s, with fresh p95 of 7.6 and 1,005.9 ms respectively.

A separate uncapped throughput round returned EOF on a service identity request. Both Mac gateway addresses remained present in the 100 ms observer, and the one guest handshake retried across that lease recovered. The failed run ended before its client could identify the socket. An instrumented repeat completed 12/12 rounds on the original sockets, with 2,880 fresh requests and 3,264/3,264 guest handshakes established. The kernel recorded 9 TCP reset events with reason `SK_RST_REASON_TCP_FLAGS` while the clients completed every body. A kernel reset event alone cannot attribute the earlier EOF. Gamma denied Mac packet capture on the BPF device. The event remains unresolved. The client now records the fresh-request index, local socket, write time and first-byte time on failure in ordinary runs as well as trace runs. A fixture closed its accepted socket after reading an identity request. The ordinary mixed, traced mixed and fresh-only profiles all reported the client port, a completed write, zero first-byte time and EOF.

After enabling failure details in the ordinary client, another six uncapped rounds per engine used the production bootstrap and the original arrival protocol. Micropod throughput completed 6/6 and OrbStack 6/6. Across 6 common rounds their medians were 4,611 and 5,387 MiB/s. Each failed client invocation is preserved under `ordinary-max` in the receipt.

## The relevant throughput reference

No hardware bandwidth limit was measured. The earlier 16,340 MiB/s result put both peers inside Linux. A published port also crosses Linux TCP and virtual Ethernet, macOS networking, the relay and the Mac client. The fixed-size comparison below moved the same 6 GiB with 32 persistent connections and 24 full bodies per connection in each round. The raw guest process had the same CPU, memory and PID limits and the same Reno/20 ms return-path route as the container. The Mac loopback service used four Go execution threads. The sibling client ran inside the warm guest.

| 6 GiB path | Valid runs | Median MiB/s |
|---|---:|---:|
| Mac → Micropod published port | 3/3 | 4,402 |
| Mac → guest DNAT | 3/3 | 3,697 |
| Mac → raw guest process | 3/3 | 4,666 |
| Linux sibling → service | 3/3 | 8,405 |
| Mac → Mac loopback | 3/3 | 4,746 |
| Mac → OrbStack published port | 3/3 | 4,378 |

Gamma exposed a single combined queue pair and 256-entry rings per virtio NIC. An earlier probe observed roughly 59 KiB per transmit call with segmentation offload active. RPS distributed receive processing but reduced mixed throughput. Negotiated MTU 9,000 improved the synchronized test by less than 1%. The tested vsock bulk prototype sustained 53–125 MiB/s and failed all four synchronized trials. This kernel supports eBPF tracing. Its configuration disables the TC BPF classifier and action support needed for the suggested peer redirect. Connections between a CI job and its database or cache can stay on the shared Linux network and avoid this entire Mac path. [Prior transport measurements and kernel configuration](gamma-vnic.md) · [Linux network scaling](https://docs.kernel.org/networking/scaling.html)

The published path delivered 94.3% of the measured raw Mac-to-guest process rate and 52.4% of the sibling rate. These percentages use the medians of the three fixed-byte rounds. With separate client and server placements, the timings alone cannot assign independent costs to the relay, guest bridge and virtual NIC.

The reference was repeated with the six-second open-loop workload. Each route occupied every position once in six balanced orders. The raw Linux process, container server and sibling client had the same four-CPU quota. The native Mac service used four Go execution threads. Both Mac and Linux clients were built from the same fixed-arrival source.

| Same 40 arrivals/s on each path | Valid rounds | Bulk MiB/s | Fresh p95, ms |
|---|---:|---:|---:|
| Mac → Micropod published port | 6/6 | 2,839 | 103.3 |
| Mac → guest DNAT | 6/6 | 3,282 | 63.0 |
| Mac → raw guest process | 6/6 | 4,986 | 29.4 |
| Linux sibling → service | 6/6 | 7,750 | 58.9 |
| Mac → Mac loopback | 6/6 | 4,029 | 115.1 |
| Mac → OrbStack published port | 5/6 | 4,217 | 1,007.8 |

With fresh work arriving, the raw guest process beat the published container in 5/6 paired rounds, with a median paired gain of +41.4%. The raw and published path medians were 4,986 and 2,839 MiB/s. The Linux sibling delivered 7,750 MiB/s. The OrbStack cell excludes one fresh identity request that returned EOF.

## Tuning screens and repeatability

The four-round queue screen on one private worker measured 3,466 MiB/s and 52.7 ms loaded p95 with the stock queue settings, 4,488 MiB/s and 24.3 ms with fair queuing on the dedicated NIC, and 4,858 MiB/s and 26.4 ms with fair queuing at both the service and the NIC. Reducing maximum GSO size to 32 KiB gave 507 MiB/s. A six-round crossover with a 12-event relay batch gave 6,327 MiB/s for the selected combination versus 5,932 for OrbStack. This tuning series used 160 fresh requests. The separate release comparison above used 240.

| Fair-queue byte quantum, fixed-rate screen | Valid runs | MiB/s | Fresh p95, ms |
|---|---:|---:|---:|
| Kernel default | 5/5 | 5,027 | 43.4 |
| 64 KiB NIC | 5/5 | 4,738 | 39.5 |
| 16 KiB NIC and service | 5/5 | 4,221 | 60.2 |
| 64 KiB NIC and service | 5/5 | 3,949 | 49.2 |
| OrbStack | 5/5 | 4,537 | 1,004.1 |

The service queue recorded 243,246 additional pacing deferrals during the instrumented transfer. A new container tested changes to pacing while preserving the NIC queue. The separate-process row reused the production C forwarding implementation with the same two data owners. All variants received 40 fresh requests per second.

| Fixed arrival rate at four CPUs | Valid rounds | MiB/s | Fresh p95, ms |
|---|---:|---:|---:|
| Production relay and service pacing | 6/6 | 4,186 | 54.2 |
| Service fair queuing without pacing | 6/6 | 4,849 | 30.4 |
| 100 µs service pacing timer slack | 6/6 | 4,615 | 54.6 |
| Separate host process, production C relay and service pacing | 6/6 | 4,894 | 35.9 |
| OrbStack | 6/6 | 5,534 | 608.5 |

| Diagnostic relay, four CPUs | Valid runs | MiB/s | Fresh p95, ms |
|---|---:|---:|---:|
| Two data workers on one NIC | 6/6 | 4,807 | 35.5 |
| Two data workers on two NICs | 6/6 | 3,054 | 78.9 |
| OrbStack | 5/6 | 4,486 | 1,006.1 |

The two virtual NICs used separate host-only networks and guest IRQs on CPUs 3 and 2. Both test policies used two Mac data workers, scoped DNAT and the same service. This diagnostic used 160 fresh requests. Its rates are comparable within this table.

Moving the relay to a separate process won 2/6 against the in-process implementation. Disabling service pacing won 3/6 and changing timer slack won 2/6. The release retains the in-process relay and kernel pacing defaults.

To test the proposed NAT and conntrack cost, the same two-worker host relay forwarded to one four-CPU service. The routed address was private to the test worker. The guest admitted the Mac peer and the service port in both directions, with a catch-all drop for the test destination. The paired comparisons use the same six-second offered load.

| Guest forwarding path, same Mac relay | Valid rounds | Bulk MiB/s | Fresh p95, ms | Paired change vs ordinary translation | Faster paired rounds |
|---|---:|---:|---:|---:|---:|
| Destination and source NAT | 6/6 | 3,271 | 93.4 | reference | — |
| Destination NAT with scoped return routing | 5/6 | 3,387 | 73.7 | -1.2% | 2/5 |
| Private routed service address | 6/6 | 3,027 | 101.7 | -4.7% | 3/6 |
| Private routed address with connection tracking bypass | 6/6 | 3,303 | 114.9 | +5.1% | 3/6 |
| OrbStack reference | 5/6 | 4,098 | 1,006.1 | +40.3% | 4/5 |

A separate eight-request replay verified the kernel paths. The source NAT rule counted all eight ordinary connections. With destination NAT alone, the return exception counted all eight and the source NAT count stayed flat. The routed address carried packets in both directions. The raw-table tracking exceptions counted 48 inbound and 32 outbound packets on the untracked lane. Both routed lanes were torn down after validation. None of the alternatives won more than half its paired rounds. The production mapping keeps its existing translation and lease enforcement.

An earlier release comparison overlapped local builds and competing host work. It is retained as a stress result. Rates below are independent medians over valid rounds for that engine. The uncapped previous build returned EOF on a fresh request. The four-CPU OrbStack service reopened connections in two rounds.

| Service CPU quota | Valid, old / release / OrbStack | MiB/s, old / release / OrbStack |
|---|---:|---:|
| 4 | 6/6/4 of six | 2,234 / 2,225 / 3,993 |
| 1 | 6/6/6 of six | 2,805 / 2,592 / 3,395 |
| max | 5/6/6 of six | 2,370 / 2,443 / 4,320 |

## Reproduction

Use a signed Apple Silicon worker, matching runner tools and the same image on all three engines. Set `BASELINE_HOST`, `CANDIDATE_HOST`, `ORBSTACK_HOST`, `NETBENCH` and `BENCH_GUEST_PROBE_DIR` as documented in the preceding qualification. Start the new Micropod worker with `MICROPOD_CI_PORT_RELAY=kqueue-throughput`. Use an empty output directory for each quota. [Matched driver](../../../scripts/bench_published_ports.sh)

```sh
BENCH_CONTAINER_CPUS=4 BENCH_ROUNDS=0 BENCH_OVERLAP_ROUNDS=6 \
  BENCH_ROUND_PAUSE=1 BENCH_MAX_TIME_WAIT=4000 BENCH_NETWORK_COUNTERS=1 \
  BENCH_RECORD_FAILURES=1 bash scripts/bench_published_ports.sh results-4cpu
```

Repeat with `BENCH_CONTAINER_CPUS=1` and `max`. For per-socket timing, run the Mac netbench client with `-profile mixed -trace-mixed -streams 32 -requests 160`, the URL and expected marker. Read the `trace` object for cumulative byte counts and request timestamps on the same monotonic clock. The compressed JSON includes the fixed-arrival and outage clients under `records["fixtures/fixed.go"]` and `records["fixtures/hold.go"]`. The local SQLite receipt uses kind `published_ports` and run `gamma-mixed-path-20261121`. All builds, tests and benchmarks ran locally. GitHub Actions stayed off.

The archive records SHA-256 hashes for the measured binaries and source. The repository formatter subsequently updated four Swift files. Formatting the measured copies reproduces the checked-in copies byte for byte.

For the fixed-arrival client, run the following from the repository root against a started service. Set `SERVICE_URL` and `SERVICE_MARKER` to its published address and expected marker. Build the same Go source for Linux arm64 to measure the sibling path.

```sh
benchdir=$(mktemp -d)
gzip -dc docs/benchmarks/2026-11-21/gamma-mixed-path.json.gz |
  jq -r '.records["fixtures/fixed.go"]' > "$benchdir/fixed.go"
go build -trimpath -o "$benchdir/fixed" "$benchdir/fixed.go"
"$benchdir/fixed" "$SERVICE_URL" "$SERVICE_MARKER"
```
