# Published TCP ports on Gamma

On 21 November 2026, removing the Linux guest relay and enabling TCP segmentation offload on the Mac bridge reduced median fresh HTTP latency from **567 to 479 µs**. OrbStack reached **357 µs**. At 32 concurrent downloads Micropod delivered **4,041 MiB/s**, within 1% of its previous result. OrbStack delivered **6,201 MiB/s**. [Raw timings and traces](gamma-published-kernel.json.gz)

| Mac client measurement | Previous Micropod | Updated Micropod | OrbStack |
| --- | ---: | ---: | ---: |
| Fresh HTTP p50 | 567 µs | 479 µs | 357 µs |
| Fresh HTTP p95 | 878 µs | 742 µs | 532 µs |
| Fresh HTTP p99 | 1,183 µs | 946 µs | 706 µs |
| Start of request to client TCP connection available, p50 | 87 µs | 89 µs | 86 µs |
| Connection available to first HTTP byte, p50 | 465 µs | 370 µs | 250 µs |
| Keep-alive HTTP p50 | 180 µs | 161 µs | 150 µs |
| Single TCP stream | 1,684 MiB/s | 1,989 MiB/s | 3,877 MiB/s |
| 32 concurrent TCP streams | 4,069 MiB/s | 4,041 MiB/s | 6,201 MiB/s |

The updated worker won nine of twelve paired fresh-p50 comparisons against the previous worker, eight at p95 and six at 32 streams. Its p50 fell 15.4% and its single-stream throughput rose 18.1% using the table medians. Fresh p50 remained 123 µs above OrbStack. The 32-stream result reached 65% of OrbStack’s bandwidth. Percentiles in the table are computed independently per phase.

## Connection path

The Mac broker continues to own the exclusive loopback listener. In the previous worker, a held HTTP request produced a guest listening socket, an accepted connection from the Mac, and an outbound TCP socket to the container. In the updated worker the guest keeps a bound, non-listening socket to reserve the port. Linux matches the Mac gateway, guest NIC, guest address and leased TCP port, then translates the destination to the container. Source translation gives internal networks a return path. Both traces returned the expected HTTP 200 and marker after the Mac client half-closed. The updated trace recorded three new connections on the translation rule and zero matching guest relay sockets. [Per-connection evidence](gamma-published-kernel.json.gz)

The idle vmnet interface that holds the bridge open previously lacked segmentation offload. Enabling it on that interface made the actual Mac bridge advertise IPv4 and IPv6 TCP segmentation offload. The selected configuration uses a 1,500-byte MTU. The Mac forwarding loop also uses bounded adaptive buffers for native published leases. A lease owns its accepted and guest-side channels. Before CNI recycles the pod address, the guest removes the rule and retires connection-tracking entries matching both endpoints of the lease. [Native guest mapping](../../../guest/runner/docker_port_nat_linux.go) [Mac port ownership](../../../Sources/MicropodRuntime/CIWorkerPorts.swift)

## Where time remains

In a separate six-pair diagnostic against one warm container, direct access to its private VM ingress took **781 µs** at fresh p50. Access through the Mac loopback listener took **1,262 µs**. Direct ingress was faster in all six fresh-latency pairs. At 32 streams the same paths delivered **2,520 and 1,887 MiB/s** respectively. These samples ran under a different host load from the three-engine table. The diagnostic isolates the cost of accepting and forwarding a connection on the Mac. It also provides a reference for the VM path when the Mac listener is bypassed. [Diagnostic rounds](gamma-published-kernel.json.gz)

Distributing guest uplink receive processing across all four CPUs spread the network soft interrupts across cores. Median 32-stream throughput fell from **3,373 to 3,067 MiB/s** over six alternating pairs. The worker retains the kernel’s existing receive steering. A separate 9,000-byte MTU trial also failed to establish a parallel throughput gain. The supplied Linux 6.18.35 kernel has connection-tracking netlink enabled and the netfilter flow-table option disabled. [Queue counters and experiments](gamma-published-kernel.json.gz)

## Method and verification

Gamma has an 18-core Apple M5 Max, 128 GiB RAM and macOS 26.5.1. All three engines ran on that Mac with four vCPUs and approximately 4 GiB each. Both Micropod workers used containerd and crun. OrbStack reported Docker Engine 29.8.2. Each engine exported the same Linux arm64 image configuration and root filesystem. Each server stayed warm for all twelve rounds. The six engine orders ran twice, one engine at a time. Host one-minute load ranged from 12.22 to 21.31 during the primary series.

Each engine completed 4,800 fresh HTTP requests, 4,800 keep-alive requests and 36 bursts of 32 simultaneous 8 MiB downloads. A start barrier held all 32 responses open before the client drained any body. Measurements include connection setup and transfer. The client checked the identity on every small response, hashed the reference payload on every invocation, and checked every transferred byte count. The table gives medians of round results. An earlier unpaced run exhausted Mac client source ports in round seven. The primary run spaced rounds by eight seconds outside the timed samples and completed all 36 engine blocks. The receipt retains the incomplete trial separately. [Benchmark driver](../../../scripts/bench_published_ports.sh) [Go client](../../../scripts/netbench/main.go)

Local checks covered dynamic and fixed publication, rollback on a duplicate binding, immediate reuse, offline rejection, and publication on internal bridge and MACVLAN networks. The Gamma kernel rejected IPVLAN link creation. A release check held 32 verified keep-alive connections, removed their container, observed all clients close, and served a new container on the same Mac port. The guest fallback passed the same lease checks. The final release smoke reported seven kernel leases. The fallback run reported five relay leases. Nine Swift tests and ten Linux guest tests passed. [Qualification driver](../../../scripts/qualify_published_ports.sh) [Checks and counters](gamma-published-kernel.json.gz)

To repeat the comparison, build `scripts/netbench/main.go` on the Mac, set `NETBENCH` to that executable and select three distinct engine sockets with `BASELINE_HOST`, `CANDIDATE_HOST` and `ORBSTACK_HOST`. Load the same netbench image on all three. Run `BENCH_ROUNDS=12 scripts/bench_published_ports.sh /path/to/new-results`. The measurement store identifies this series as `gamma-published-kernel-20261121`, kind `published_ports`.
