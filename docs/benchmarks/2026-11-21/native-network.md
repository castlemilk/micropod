# Container networking on Gamma

Micropod attached 32 namespaces to a Linux bridge in **36.0 ms** through netlink. Standalone Netavark took **84.6 ms**. Once attached, 32 concurrent streams delivered **8,287 and 8,346 MiB/s** respectively. The faster way to start a service on this rig is to reuse its pod interface and keep the network configuration inside the running guest service. [Individual rounds, timings, cache identities and engine counters](native-network.json.gz)

The optimization brief was to minimize elapsed time from submitting fresh CI containers to receiving a verified service response at 16 and 32 jobs. Measure attachment, DNS, established traffic and offline Go work separately on Gamma with matched CPU, memory, images and warm caches. Charge pod preparation explicitly and keep every measured round and failed attempt. Run the comparisons locally with GitHub Actions off.

## Configuring the same Linux bridge

Gamma has an 18-core Apple M5 Max and 128 GiB of memory. The test used the warm four-vCPU, 4 GiB Micropod VM, Linux 6.18.35, containerd 2.4.2 and crun 1.31. Five rounds alternated backend order. Each wave attached 16 or 32 fresh network namespaces to the same pre-existing internal bridge, verified every IPv4 address and the absence of a default route, transferred a known payload between two namespaces and removed every endpoint. The table reports medians of elapsed batch time. [Linux crossover fixture](../../../guest/runner/netavark_bench_linux_test.go)

| Endpoints | Configuration | Setup, ms | Teardown, ms | Parallel TCP, MiB/s |
| ---: | --- | ---: | ---: | ---: |
| 16 | Micropod netlink | 17.68 | 59.63 | 8,325 |
| 16 | Netavark | 35.73 | 81.69 | 8,058 |
| 32 | Micropod netlink | 36.03 | 80.07 | 8,287 |
| 32 | Netavark | 84.64 | 122.14 | 8,346 |

The Netavark arm used the signed Alpine ARM64 package for v2.1.0. Each setup or teardown invoked its executable with the same static address, an unmanaged bridge and its firewall driver set to `none`. Both arms excluded network creation, DNS provisioning, registry access and pod creation. The traffic measure used 16 or 32 streams between one pair of namespaces. At 32 endpoints the slowest direct setup batch took 208 ms, so the median advantage does not establish a tail-latency guarantee. [Netavark interface](https://github.com/containers/netavark/blob/v2.1.0/docs/netavark.1.md) · [Upstream release](https://github.com/containers/netavark/releases/tag/v2.1.0)

## Fresh CI services and service traffic

Containerd already creates a veth pair for a pod. Micropod now verifies the pause process, peer and bridge, moves that peer to the selected service bridge and configures the pod address before launching its workload. CRI retains ownership of the pair and its original IPAM lease until pod removal. This reduced mean production bridge attachment from **31.03 to 1.67 ms** across twelve attachments in each measurement window. Firewall setup runs once per network. Service registrations and multi-address aliases are indexed per network.

Stock Docker CLI jobs fetched a per-run token from an existing HTTP service using its network alias. The clock included starting independent clients, creating fresh containers, executing wget, delivering results and automatic container removal. Both engines had warm images and one untimed readiness request. No pods were pre-created for this experiment. Each cell is the median of three rounds, totaling 288 timed jobs. [Service workload](../../../scripts/bench_service_fanout.sh)

| Engine | 16 fresh service clients | 32 fresh service clients |
| --- | ---: | ---: |
| Micropod bridge | 1.18 s | 2.44 s |
| OrbStack | 2.42 s | 4.01 s |

The next experiment used two same-named services on distinct internal networks. Each client verified its own server identity, downloaded a checksum-verified payload, then measured DNS, HTTP latency and data transfer. These are medians of six samples per row in the matched four-vCPU VMs. Ubuntu used two processes on loopback. Bytes stayed inside each guest. Published ports, host-to-guest transfers and external NIC throughput require separate measurements. [Traffic probe](../../../scripts/netbench/main.go) · [Docker network qualification](../../../scripts/qualify_native_network.sh)

| Data path | Service DNS p50, µs | Fresh HTTP p50, µs | Keep-alive p50, µs | Single stream, MiB/s | 32 streams, MiB/s |
| --- | ---: | ---: | ---: | ---: | ---: |
| Micropod bridge | 84.5 | 233.5 | 54.5 | 6,600 | 11,020 |
| Micropod MACVLAN L2 | 73.5 | 208.0 | 59.0 | 6,829 | 12,767 |
| OrbStack | 30.5 | 225.5 | 19.5 | 4,682 | 12,205 |
| Ubuntu loopback | — | 190.5 | 97.0 | 5,469 | 12,647 |

OrbStack had the lowest median DNS and keep-alive latency. Micropod MACVLAN had the highest median parallel throughput on this fixture. Bridge remains the default for frequent container churn. The Gamma kernel rejected IPVLAN link creation, so it has no performance entry. The two-network replay also verified busy-network removal, alias scoping and cleanup. A stock Docker Compose project brought up two services, completed its probe and removed the project network.

## DNS under concurrency

Fourteen paired rounds compared the installed per-network DNS implementation with OrbStack. Each client used its own Go resolver for 300 IPv4 queries so the client library could not combine concurrent lookups. At 32 clients each round issued 9,600 queries per engine. All queries completed. Results are medians of the round-level measurements.

| Concurrent resolvers | Micropod queries/s | OrbStack queries/s | Micropod p95 | OrbStack p95 |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 15,546 | 29,259 | 118 µs | 77 µs |
| 16 | 79,026 | 57,281 | 387 µs | 691 µs |
| 32 | 71,353 | 68,698 | 711 µs | 1,188 µs |

Three candidate implementations ran alongside the two controls. Answering locally on the receive goroutine reduced the matched 32-client rate from 60.4k to 53.4k queries/s. A single reader using Linux `recvmmsg` and `sendmmsg` improved its one-client p50 from 61 to 29 µs, while its 32-client rate fell from 74.5k to 63.2k. Two batched readers delivered 62.0k against the paired control's 70.3k at 32. The installed implementation therefore retains bounded concurrent handling with per-network name lookup. Host load varied across experiments. The 3.9% difference in median throughput between Micropod and OrbStack at 32 is smaller than the run-to-run variation.

Set `MICROPOD_BENCH_DNS_CLIENTS` and `MICROPOD_BENCH_DNS_LOOKUPS` when running the network qualification script with the current probe image. The raw receipt includes each candidate round and both controls. A separate test on the installed worker reconnected its virtual uplink in **1.23 s**. The same running container resolved its network alias and the public npm registry before and after repair. Its kernel boot ID and process start time stayed identical.

## Source-only Go CI

The same offline Go fixture ran vet, eight uncached test cases, three links and the built executable in each job, with a private writable workspace. The three engine orders rotated across rounds. Micropod and OrbStack launched fresh containers using the stock Docker CLI. Ubuntu used ordinary processes on the same Mac. All three guests had four vCPUs and 4 GiB. The charged column adds each native batch’s measured pod preparation time before taking the median. [Go workload](../../../scripts/bench_go_fanout.py)

| Engine | 16 jobs | 16 including preparation | 32 jobs | 32 including preparation |
| --- | ---: | ---: | ---: | ---: |
| Micropod | 2.856 s | 3.201 s | 6.005 s | 6.964 s |
| OrbStack | 4.249 s | 4.249 s | 10.509 s | 10.509 s |
| Raw Ubuntu | 2.016 s | 2.016 s | 4.273 s | 4.273 s |

All 432 jobs produced the same executable SHA-256. All 144 timed Micropod jobs reused the same module and compiled dependency inodes. Across the native measurement window, including its accounting jobs, the engine recorded 152 image hits, 304 shared-cache attachments, 5.03 cumulative seconds creating containers, 17.42 starting them and 21.07 waiting for a startup slot. Concurrent spans overlap. The offline fixture exercises no service network, so it cannot establish a networking speedup. One earlier 32-job attempt returned an empty stdout receipt. The raw bundle retains that failure separately from the three complete rounds. Python runs the existing measurement harness on macOS. The production network service and traffic probe are Go, and the workload runs in Linux.

## Installed worker and private allocation

The signed rig worker kept its existing warm disk. The stock CLI exercised named service networks on the installed endpoint, built and loaded a multi-stage image and opened the shared Go cache. The private allocation image separately used a dedicated Apple VM, an allocation-only rootless engine and its own cgroup subtree. It pulled an image, served an internal alias and a loopback port, enforced the requested resource limits, built and ran a Dockerfile, then passed the retirement fence and verified deletion. The final ARM64 artifact took 123.26 s on first unpack and 12.97 s with its base image warm, including the fixture work and cleanup. These checks ran without a GitHub job or credential.

The Gamma measurement database stores the same raw JSON under run `gamma-native-network-20261121` and kind `native_network`. [Raw measurements](native-network.json.gz)
