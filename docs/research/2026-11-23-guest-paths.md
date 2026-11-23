# Which guest path each TCP experiment exercises

The existing native macvlan publication starts with a leased Mac loopback listener. The Mac relay opens the guest-side TCP connection. In the VM, a dedicated NIC and a private, addressless per-container macvlan named `mppub0` carry the published traffic. Pod-local rules deliver it to the service's Docker address. The container's ordinary `eth0` remains a veth. The archived release service sent 244,082,976,085 bytes over `mppub0` and 350 over `eth0` during the reported interval. [Mac port ownership](../../Sources/MicropodRuntime/CIWorkerPorts.swift) · [Guest endpoint and translation](../../guest/runner/docker_port_direct_linux.go) · [Measured path](../benchmarks/2026-11-21/gamma-direct-macvlan.md#ownership-and-paths)

| Experiment | Starting fixture | Evidence needed to attribute a result |
| --- | --- | --- |
| 5. Bypass the Mac relay | First compare the ordinary published listener with diagnostic host access to the **same guest ingress for the same container and boot**. Keep the existing Mac relay as the control. Native vmnet forwarding needs its own comparison. | Record the client dial target, service marker and image, guest route, destination port owner, process and interface counters, and unchanged cgroup limits. Before treating a bypass as a published-port candidate, exercise loopback visibility, collision rollback, port revocation including accepted sockets, and rebind to a different owner. |
| 6. Change the guest link | The Docker network driver already offers ipvlan L2 on the ordinary workload interface. The direct published endpoint requires that interface to be a veth, then creates its own private macvlan. Test east-west ipvlan L2 independently. A published-link comparison needs a distinct ingress fixture and a demonstrably active candidate interface. | Read back the actual link kind, mode, master and namespace from the boot under test. For the scored flow, record directional byte deltas on both interfaces. Preserve service identity, routes, isolation and return-path controls. Evaluate L3 and netkit separately. A create or attach counter proves setup only. |
| 7. Co-located TCP splicing | The guest userspace forwarder owns an accepted socket and a dialed socket. The kernel/macvlan path forwards packets to the service without a guest forwarding process owning that pair. Use a disposable guest forwarder with two TCP legs as the control for a splice implementation. | Verify both established four-tuples and their ownership, then verify implementation identity, actual splice operations, payload hashes, half-close, cancellation and short replies. Keep the Mac relay, service and production kernel protections fixed. |

[Docker link implementations](../../guest/runner/docker_links_linux.go) · [Accepted Docker driver inputs](../../guest/runner/docker_networks_linux.go) · [Userspace socket forwarding](../../guest/runner/docker_ports_linux.go) · [Kernel publication](../../guest/runner/docker_port_nat_linux.go) · [Existing ownership suite](../../ci/runner-macvlan.test.sh)

The 4,986 MiB/s raw guest and 2,839 MiB/s published-container medians changed the server endpoint as well as the host path. Their difference cannot be assigned to the Mac relay alone. The earlier same-container private-ingress comparison is a closer historical control, with a different load and client protocol from the current stock baseline. [Mixed-load topology](../benchmarks/2026-11-21/gamma-mixed-path.md) · [Same-container diagnostic](../benchmarks/2026-11-21/gamma-published-kernel.md)

Replaying the six `mixed-reference` rounds from 21 November gives a more specific answer for the bypass experiment. All 12 published and direct guest-DNAT client records pass the current 32-stream, 240-arrival delivery check. DNAT won four of the six throughput pairs. Its median within-pair improvement was 27.5%, with a descriptive paired bootstrap interval of −19.9% to +42.2%. Three DNAT rounds exceeded the proposed 75 ms fresh-request p95 ceiling (75.078, 137.880 and 88.682 ms). Those rounds explain why the old 63.0 ms arm median would give the wrong candidate decision. This replay covers the historical service and boot. A revised-relay result still needs a fresh paired run. [Raw mixed-load records](../benchmarks/2026-11-21/gamma-mixed-path.json.gz) · [Experiment #232](https://github.com/castlemilk/micropod/issues/232)

A historical experiment on Linux 6.18.35 recorded 46 successful splice syscalls and 16,777,819 bytes summed over the two pipe legs for an 8 MiB body plus protocol traffic. The archived Go forwarding prototype reached a 110.3 ms median fresh p95 in its mixed-load runs. The research proposal's in-kernel socket splicing implementation remains unmeasured. The historical netkit creation result also belongs to 6.18.35. [Raw experiment and qualification](../benchmarks/2026-11-21/gamma-mixed-scheduler.md)

## Offline socket-pair check

A capture for a known test flow needs the guest boot ID at `sys/kernel/random/boot_id`, the forwarder's `PID/fd` symlinks, and `PID/stat`, `PID/ns/net` and `PID/net/tcp` for the relevant processes. Preserve raw symlink targets. The accepted socket and the dialed socket can belong to different network namespaces, including when a child inherited its listener. Supply a process that can see each table. All inputs must be from the same guest and observation window.

```sh
python3 -B scripts/relaybench/guest_paths.py "$PROC_CAPTURE" \
  --forwarder "$FORWARDER_PID" --ingress-pid "$INGRESS_NS_PID" --egress-pid "$EGRESS_NS_PID" \
  --incoming "$ACCEPTED_LOCAL" "$ACCEPTED_PEER" --outgoing "$DIALED_LOCAL" "$DIALED_PEER"
```

Each endpoint argument takes an IPv4 address and port. The checker requires distinct inodes for the two established flows and requires the forwarder's descriptor table to contain both. It checks process start ticks, namespace IDs and guest boot identity across its reads. A copied tree can establish the contents of that capture. Its acquisition time, the bytes copied, and the mechanism used still require independent evidence. [Offline verifier](../../scripts/relaybench/guest_paths.py) · [Regression fixtures](../../scripts/relaybench/test_guest_paths.py)

## Guest link traffic in a scored window

The link checker reads a saved JSON capture with `before`, `after` and `client`. Both snapshots contain the Linux guest `boot_id`, the service's `netns` symlink text, the guest `monotonic_ns` sample time and all service interfaces from `ip -j -s -d link show` in `links`. Collect the first snapshot before starting the offered-load client and the second after it exits. Preserve the actual client JSON in `client`. For the existing download workload, bytes leave the service through TX.

```sh
python3 -B scripts/relaybench/guest_link_path.py capture.json --device mppub0 --kind macvlan --mode private --direction tx
```

The report checks for an unchanged namespace and link inventory, verifies link type and optional mode, and requires the claimed interface's directional byte delta to cover the client's completed bulk payload. It reports traffic on every competing interface, including any that also carry enough bytes to explain the entire transfer. Interface totals include headers, retransmissions and unrelated traffic. A large counter alone cannot establish which socket carried the data or the time alignment of independently supplied samples. An isolated fixture and an observed route give the counter comparison its meaning.

Replaying the historical `workers/direct` start/end snapshots gives 478,377,036,186 additional TX bytes on `mppub0` and 70 on `eth0`. Those snapshots omit link kind, interface index and guest boot readbacks at the two boundaries. They support the historical interface-traffic comparison only. [Checker](../../scripts/relaybench/guest_link_path.py) · [Archive regression](../../scripts/relaybench/test_guest_link_path.py)
