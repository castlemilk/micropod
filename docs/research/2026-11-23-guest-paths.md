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

## What the pinned 7.3.5 worker can test

The archived `full` worker has netkit built in. The same kernel explicitly disables ipvlan and AF_XDP. Its config SHA-256 is `a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c`. The archive records Image SHA-256 `7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd`. Replay the config from the repository root with the command below. The same diagnostic accepts a candidate's resolved config via `--config PATH`. [Archived full config](../benchmarks/2026-11-21/gamma-direct-macvlan.json.gz) · [Diagnostic](../../scripts/relaybench/guest_network_config.py)

```sh
python3 -B scripts/relaybench/guest_network_config.py --gamma-stock
```

| Datapath | Stock build | Implication for the experiment |
| --- | --- | --- |
| Direct private macvlan | `VETH=y`, `MACVLAN=y` | Direct publication verifies a veth at the original address and creates the private macvlan child. Use this as the published-path control. [Direct endpoint](../../guest/runner/docker_port_direct_linux.go) |
| ipvlan | `IPVLAN=n` | The Docker network API accepts ipvlan and its Linux link code requests L2. This worker lacks the driver for either L2 or L3. Qualifying L2 requires a kernel with ipvlan enabled. L3 also needs separate link provisioning. [Workload links](../../guest/runner/docker_links_linux.go) |
| netkit peer redirect | `NETKIT=y`, `BPF_SYSCALL=y` | Linux provides primary and peer program attachments and a redirect action. The released product path above creates a macvlan. A netkit trial requires independently provisioned links, observed attachments and directional traffic on the intended link. |
| netkit AF_XDP | `XDP_SOCKETS=n` | An AF_XDP candidate needs another kernel configuration. The pinned driver's XSK pool setup also rejects paired devices and requires a leased RX queue, lower-device XSK operations and advertised XSK features. |
| io_uring zero-copy receive | `IO_URING_ZCRX=y` | For a device-bound registration the kernel resolves a DMA device for the chosen RX queue and opens its page-pool memory provider. Successful registration and delivery into registered buffers on the actual worker remain open. |
| TCP pipe splice | `NET=y`, `INET=y` | The TCP stream operations include pipe splice. Ordinary `splice(2)` rejects two non-pipe file descriptors. The proposed paired-socket module needs its own ABI and an owner of both established sockets. The userspace forwarder accepts and dials those sockets. [Forwarder](../../guest/runner/docker_ports_linux.go) |
| SOCKMAP / SOCKHASH | `BPF_SYSCALL=y`, `NET=y`, `INET=y`, `BPF_STREAM_PARSER=y` | The build includes the socket map types and stream-parser infrastructure. A successful attach and verified end-to-end bytes on this kernel remain open. The earlier zero-of-six result used 6.18.35. |

Source locations refer to the worker builder's pinned Linux 7.3.5 archive, SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. See `drivers/net/{Kconfig,Makefile}` and `drivers/net/netkit.c` (`netkit_xmit`, `netkit_xsk`, `netkit_prog_attach`) for the link paths. The RX queue registration checks are in `io_uring/zcrx.c` at lines 902–928. Pipe handling is in `fs/splice.c:1300` and `net/ipv4/af_inet.c:1082`. The map type registrations and stream parser selections are in `include/linux/bpf_types.h:122`, `net/core/Makefile:44` and `net/Kconfig:361`. [Source digest and build options](../../ci/build-worker-kernel.sh)

## Fair scheduling on the same worker

With debugfs mounted at its usual location, Linux 7.3.5 exposes `/sys/kernel/debug/sched/cgroup_mode`. Reading it lists all five settings and puts parentheses around the selected one. The source default is `up smp (concur) max tasks`. The selection changes fair group weighting for the whole guest. Stock enables `CGROUP_SCHED`, `FAIR_GROUP_SCHED`, `DEBUG_FS` and `DEBUG_FS_ALLOW_ALL`. These controls work independently of sched_ext. The separate `CFS_BANDWIDTH=y` option supports the CPU quota. A comparison needs a readback on the disposable boot, the same quota and weights, and a competing cgroup. See `kernel/sched/debug.c:636`, `kernel/sched/fair.c:5224` and `init/Kconfig:1172`. [Archived stock config](../benchmarks/2026-11-21/gamma-direct-macvlan.json.gz)

| Mode | How the fair scheduler apportions group weight |
| --- | --- |
| `up` | Uses the full group shares on each participating CPU. |
| `smp` | Distributes the configured shares according to each CPU's estimated fraction of group load. |
| `concur` | Scales shares by the smaller of estimated runnable task count and available CPUs before distributing them. |
| `max` | Scales by available CPUs, then caps per-CPU shares at the weight for nice −20. |
| `tasks` | Scales by estimated runnable task count before distributing the shares. |

The fair class already calls `pick_eevdf()`. The kernel exposes its global base request size as `sched/base_slice_ns` under debugfs. For a fair task, a nonzero `sched_runtime` can request a slice from 0.1 to 100 ms. Stock also enables `SCHED_CACHE`. Reading `sched/llc_balancing/enabled` gives the user's requested setting. Activation additionally requires multiple last-level-cache domains in the guest's scheduler topology. The stock config alone establishes neither their presence nor a latency benefit. See `kernel/sched/fair.c:1187`, `fair.c:6369`, `kernel/sched/debug.c:234` and `kernel/sched/topology.c:947` in the same source archive. [Pinned builder inputs](../../ci/build-worker-kernel.sh)

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
