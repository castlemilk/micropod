# 229.01 · One data worker on the primary or host-only guest link

Moving a single publication data worker from the primary guest interface to a dedicated host-only interface at the same 1,500-byte MTU won three of six blocks on fresh connections and three of six on preconnected sockets. The archived client-delivered byte counts give little reason to expect the attachment change alone to close the throughput gap. [Issue #229](https://github.com/castlemilk/micropod/issues/229)

| Synchronized 32-stream burst | Primary eth0 MiB/s | Host-only eth1 MiB/s | Median paired change | 95% paired bootstrap interval |
|---|---:|---:|---:|---:|
| Fresh sockets | 3,891.4 | 4,036.4 | +1.96% | −12.50% to +34.87% |
| Preconnected sockets | 4,168.7 | 4,130.5 | −1.62% | −22.53% to +14.42% |

Each mode delivered 1.5 GiB per arm over six blocks of 32 verified 8 MiB transfers. All first attempts completed, with zero unexpected reconnects or incorrect initial connection reuse. The archive's timestamp resolution is one microsecond. Rates use receiver bytes divided by elapsed time and agree with the archived client rates. The driver rotated all seven arms and placed these two arms in each relative order three times. Each arm always ran its fresh burst before its preconnected burst. The 95% intervals resample entire pairs within each mode, using 10,000 draws and seed 7317.

**Path identity.** On VM boot `78138F28-4F2C-454E-83D4-3AF2041E4E14`, `split1` bound its upstream connection via gateway 192.168.73.1 to 192.168.73.2 on the primary eth0. `private1` used 192.168.128.1 to 192.168.128.2 on host-only eth1. Both had a dedicated acceptor, one data worker, an MTU of 1,500 and the same guest DNAT rule from port 47521 to 10.88.0.5:8080 on the service bridge. The relay scoped each upstream socket to the selected gateway and checked the same service marker on both loopback listener ports. The worker reported four vCPUs and 4,118,708,224 bytes of guest memory. A service-specific cgroup readback for this lane screen is absent.

These are measurements of the two configured routes, including their different addresses, gateway and Mac listener ports. The archive supplies the guest routes and link identities, with no per-arm packet capture or before/after interface counters for these bursts. The study used the earlier bridged publication path. It did not exercise 9,000-byte MTU, the revised direct path, OrbStack, or fresh arrivals during sustained throughput. The trial therefore supplies one fixed-MTU comparison toward #229.01. Earlier reported comparisons included a two-interface/two-worker arm and an original-versus-split relay comparison. This comparison uses only `split1` and `private1`. [Historical study](../../2026-11-21/gamma-vnic.md) · [Paired observations and source hashes](results.json)

Reproduce from this directory with `python3 -B replay.py | cmp - results.json`. The replay verifies the original archive, link identities, workload, connection checks, all 32 stream phase records and attempt counts.
