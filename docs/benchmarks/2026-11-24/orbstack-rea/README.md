# OrbStack on Gamma and a Micropod device experiment

24 November 2026 · OrbStack 2.2.5 (21124), arm64 · Micropod performance checkout `2e9b37c1`

The Micropod kernel used for the 24 November published-TCP baseline already compiles out arm64 KPTI and builds in KASLR support. The installed OrbStack Helper contains a Rust Virtio network backend and direct Apple hypervisor calls. A new Micropod prototype exercised one part of that design space on Gamma. Batching eight descriptors per guest-to-host notification reduced the median time to consume 257 descriptors from **212.0 µs to 31.7 µs** in a single-vCPU hardware VM. The benchmark measures the device notification path. [Installed artifacts](installed.json) · [Individual hardware runs](device-pairs.json)

## What REA found in the installed app

REA 6.4.0 inspected both Mach-O executables in `/Applications/OrbStack.app`. The accompanying replay checks each observation against the executable's current SHA-256. The complete REA bundle contains the two original observations, including tool provenance and import-coverage limits. [REA evidence](native-rea.json.gz) · [Local replay](inspect_local.py)

| Component | Observation |
| --- | --- |
| Main GUI, SHA-256 starting `48e096f30954` | Loads Virtualization.framework and imports `VZVirtualMachine`. Its recorded framework dependencies include no direct Hypervisor.framework load. |
| OrbStack Helper, SHA-256 starting `9898a51367c3` | Loads both frameworks. REA found `hv_vm_create`, `hv_vm_map`, `hv_vcpu_create`, and `hv_vcpu_run`, as well as `VZVirtualMachine.start`, the VZ Linux boot loader, and VZ Virtio network and socket device classes. |
| Rust paths in the same helper | Contains `src/vmm/src/device_manager/hvf/mmio.rs`, `src/devices/src/virtio/net/worker.rs`, `net/dgram.rs`, and `virtio/vsock/tcp.rs`. These identify several possible network paths. Selecting the one serving a published port requires runtime evidence for that connection. |
| Packaged guest | The arm64 Image identifies itself as `7.2.12-orbstack-00394-gbecdd6130068`. The archived OrbStack arm in the November 21 peer comparison reported that exact release string. The archive lacks the OrbStack kernel image digest needed to establish byte identity. |
| Guest NIC | The local VM boot log records `virtio_net virtio10 eth1`. The packaged guest contains the Linux Virtio network and MMIO driver paths. This establishes a binding on one interface. The boot log does not identify the interface used by the scored traffic. |

OrbStack documents an Apple Silicon KASLR enhancement that avoids KPTI overhead. Its developer describes a custom Rust virtualization stack and gives file sharing as an example of a custom protocol. The local observations support the presence of that stack. They also show that the shipped helper retains VZ VM lifecycle code. The active backend for a particular benchmark run remains unverified. [Architecture](https://docs.orbstack.dev/architecture) · [Developer account](https://news.ycombinator.com/item?id=48470145)

## Syscall cost

The Micropod Image digest and the decompressed embedded configuration both match the fixture's boot receipt. The installed OrbStack Image exposes 455 Kconfig entries. A missing key in that subset has unknown value. [Boot-bound Micropod fixture](../disposable-local-fixture/20261124T090510Z-local-d0y_1j57/baseline/receiver/fixtures.json) · [Extracted options and digests](installed.json)

| Build option | Micropod 7.3.5 | Packaged OrbStack 7.2.12 |
| --- | --- | --- |
| `CONFIG_RANDOMIZE_BASE` | Enabled | Unreported |
| `CONFIG_UNMAP_KERNEL_AT_EL0` | Explicitly disabled | Unreported |
| `CONFIG_CPU_MITIGATIONS` | Enabled | Unreported |
| `CONFIG_VIRTIO_NET` | Enabled | Enabled |

That Micropod build has no arm64 KPTI switch overhead to remove. The vendor's alternative protection and its boot-time state cannot be identified from the packaged config. The new static Linux arm64 diagnostic measures checked raw `getppid`, one-byte `read` and `write`, an empty `epoll_pwait`, and `accept4` on an empty nonblocking listener. It rotates operation order and reports wall time, thread CPU time, kernel release, boot ID, and probe digest. The probe built and passed `go vet`. OrbStack's local Docker socket returned `EPERM`. A separate attempt to boot the exact Micropod Image with a temporary diskless VZ configuration failed at VZ configuration validation, so there are no new Linux timing samples. [Syscall probe](../../../../scripts/netbench/syscallcost/main_linux.go) · [Linux arm64 option definition](https://linux.googlesource.com/linux/kernel/git/torvalds/linux/+/bfe8eb3b85c571f7e94e1039f59b462505b8e0fc/arch/arm64/Kconfig)

## What the public guest source establishes

The public `mac-pub` head inspected here is the Linux **6.3.9** snapshot `308681584a45dba25ebd45499136bfec1b829468`, squashed in June 2023. Its network driver has concrete differences from upstream 6.3.9. One adds a host notification when TX cleanup leaves too few free descriptors to wake the queue. Others change receive-header handling and offload feature assumptions. The ring and MMIO transport files below match upstream byte for byte. The version suffix in the installed guest cannot establish how many commits implement drivers. [Published snapshot](https://github.com/orbstack/linux-macvirt/commit/308681584a45dba25ebd45499136bfec1b829468) · [OrbStack network driver](https://github.com/orbstack/linux-macvirt/blob/308681584a45dba25ebd45499136bfec1b829468/drivers/net/virtio_net.c) · [Upstream network driver](https://github.com/gregkh/linux/blob/v6.3.9/drivers/net/virtio_net.c)

| File | OrbStack Git blob prefix | Upstream v6.3.9 Git blob prefix |
| --- | --- | --- |
| `drivers/net/virtio_net.c` | `f7f760aa8f6d` | `c40fc1e304f2` |
| `drivers/virtio/virtio_ring.c` | `7a78ff05998a` | `7a78ff05998a` |
| `drivers/virtio/virtio_mmio.c` | `3ff746e3f24a` | `3ff746e3f24a` |
| `drivers/char/virtio_console.c` | `d5ac4d955bc8` | `d5ac4d955bc8` |
| `fs/fuse/virtio_fs.c` | `de9fa9512279` | `4d8d4f16c727` |

## Measured guest-to-host notification cost

The original prototype uses a bare-metal arm64 producer, one shared descriptor page and two memory-mapped notification registers. The Rust host runs the vCPU through Apple's public Hypervisor API and validates the sequence number in every eight-byte descriptor. The native control runs the same arm64 producer with a synchronous callback. The hardware trial uses real MMIO exits. [Rust host](../../../../scripts/relaybench/hvf_tx_probe/main.rs) · [Guest producer](../../../../scripts/relaybench/hvf_tx_probe/guest.S) · [Apple Hypervisor](https://developer.apple.com/documentation/hypervisor)

| Hardware result | One descriptor per notification | Up to eight per notification |
| --- | ---: | ---: |
| Ordered descriptors verified per arm | 257 | 257 |
| Data notifications | 257 | 33 |
| Completion notifications | 1 | 1 |
| Median elapsed time | 212.0 µs | 31.7 µs |

Each arm used a fresh one-vCPU VM. Timing started immediately before guest entry and ended on the completion notification. One warmup per arm preceded 12 balanced-order pairs. Batching finished faster in 12 of 12. The median within-pair elapsed-time ratio was 0.151. The fixture transfers sequence numbers and measures neither network payload throughput nor latency for a fresh TCP connection. [Raw windows, tool versions and source hashes](device-pairs.json)

For the 32-stream workload, the next discriminating measurement is TX notifications per delivered GiB, queue stalls and fresh-request tails on the same published connection path. Preserve negotiated checksum and segmentation offloads. In an earlier two-attempt-per-setting Micropod screen, turning guest TCP segmentation off moved median notifications from 72 to 4,064 per interface GiB and throughput from 6,026 to 516 MiB/s. The segmentation change affected both packet size and notification count, so that result cannot isolate the cost of a notification. The revised Micropod baseline measured 6,573.34 MiB/s in one window. A fresh matched OrbStack comparison is still outstanding. [Segmentation screen](../tso-driver-work.json) · [Revised baseline](../disposable-local-fixture/post-restart/baseline-host-work.md)

## Follow-up on the installed host and measured guest

REA also verified the helper's signing identity, `dev.kdrag0n.MacVirt.vmgr`. The same binary has the Hypervisor, Virtualization and vmnet entitlements and imports `vmnet_read`, `vmnet_write`, and the checksum and TCP segmentation offload keys. These observations leave the selected backend and negotiated feature values for a published connection open. [Helper evidence](helper-network-evidence.json) · [Apple vmnet constants](https://developer.apple.com/documentation/vmnet/vmnet_constants)

The earlier four-vCPU guest exposes one TX queue on `eth1`. The aggregate driver kicks matched that queue in every snapshot. Matching the driver counts to receiver payload gives the following clean-attempt medians. [Six attempts and boundary timestamps](delivered-tx-kicks.json) · [Replay](../../../../scripts/relaybench/delivered_tx_kicks.py)

| Guest TCP segmentation | Clean attempts | Kicks per delivered GiB | Kicks per interface GiB | Receiver MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Enabled | 2 of 2 | 73.5 | 72.4 | 6,025.5 |
| Disabled | 2 of 2 | 4,920.3 | 4,064.5 | 516.4 |
| Restored | 1 of 2 | 74.8 | 73.7 | 6,314.9 |

The five clean attempts have matching guest and host boundary timestamps at one-second resolution. The failed restore had 145 failed fresh requests, 25 bulk reopens, and its final driver snapshot preceded the post-run host sample by 26 seconds. Its delivered-GiB ratio is withheld. The revised November 24 baseline sampled the service's macvlan bytes. It lacks a timed parent NIC kick counter. A host exit cost per delivered GiB remains unmeasured on that build. [Driver kick accounting](https://code.googlesource.com/linux/torvalds/linux/+/a33ab3f94f510b5bc6b74b2d1e9bc585391c2861/drivers/net/virtio_net.c#3104)

## Local Micropod VM comparisons

Each scored window used 32 bulk streams and 240 fresh arrivals in six seconds. Both comparisons used a four-vCPU guest, 256 KiB relay reads, a 128-event callback budget, verified published route, and the same kernel and service image. Each comparison alternated timed arms across two disposable VMs. The kernel lacks the socket diagnostic needed to read the accepted socket's congestion controller. Medians below are per arm. Process CPU samples include setup and drain.

| Comparison and arm | Clean attempts | Receiver MiB/s | Fresh p95 | Fresh p99 | Relay CPU-s/GiB | VMM CPU-s/GiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Worker count, 2 workers | 4 of 4 | 6,504.7 | 6.194 ms | 10.499 ms | 0.194 | 0.401 |
| Worker count, 4 workers | 4 of 4 | 5,845.0 | 6.637 ms | 9.769 ms | 0.278 | 0.431 |
| Host role, Standard with 2 workers | 8 of 8 | 7,934.1 | 10.187 ms | 11.122 ms | 0.224 | 0.347 |
| Host role, Interactive with 2 workers | 8 of 8 | 6,294.1 | 6.357 ms | 11.469 ms | 0.199 | 0.411 |

Four workers lost throughput in every pair, with a median paired change of −10.11%. Interactive lost throughput in all eight pairs against Standard, with a median paired change of −20.70%. Interactive's median fresh p95 was 3.83 ms lower. Each role occupied a separate VM throughout that run, and Standard's VM started first. The benchmark now supports starting Interactive first while preserving A = Standard and B = Interactive in scoring. The launch record binds each successfully provisioned arm to the digest of its guest facts. [Worker comparison](../disposable-local-fixture/20261124T100302Z-local-ul3niw24/receiver/summary.json) · [Initial host-role comparison](../disposable-local-fixture/20261124T100757Z-local-zw8k9wvr/receiver/summary.json)

The Interactive-first replication verified the pinned offline inputs and entered the normal disposable-VM launcher. macOS returned error 5 from `launchctl bootstrap` on the first arm. The launcher recorded zero ready VMs and zero scored windows, and its cleanup record has no retained scope or errors. The role-order comparison therefore remains open. The local fixture passed 65 regression tests, including the default order, reversed order and partial boot receipt. [Launch order](../disposable-local-fixture/20261124T101830Z-local-daw4aokt/launch-order.json) · [Bootstrap result](../disposable-local-fixture/20261124T101830Z-local-daw4aokt/b/bootstrap.json) · [Cleanup](../disposable-local-fixture/20261124T101830Z-local-daw4aokt/cleanup.json)

## Relay handshake experiment

The opt-in `MICROPOD_BENCH_ONESHOT_CONNECT=1` build registers a one-shot Darwin write watch while the nonblocking connection to the guest is pending. On successful asynchronous setup with individual filter submissions, the relay issued five filter-change calls per flow against six for stock. With batched changes on a dedicated owner both issued four calls, and the candidate submitted one fewer filter. The socketpair fixture exercised delayed delivery, backpressure in both directions, retries, revocation, failed registration and FIN ordering. All 16 AddressSanitizer and UndefinedBehaviorSanitizer configurations passed. [Candidate source](../../../../Sources/CPublishedTCP/PublishedTCP.c) · [macOS kqueue manual](https://man.freebsd.org/cgi/man.cgi?manpath=macOS+26.7&query=kqueue&sektion=2)

In 12 balanced-order pairs, each arm verified 512 immediate and 512 asynchronous connections per pair. Median paired asynchronous setup CPU increased 1.13% and lifecycle CPU increased 4.57%. The candidate used less lifecycle CPU in four pairs. Keep the stock handshake. This component result covers real Darwin stream I/O and event delivery with substituted guest connect outcomes. The mixed TCP workload ran on the existing relay build. [Per-pair CPU and qualification results](oneshot-connect.json)

## Reproduction

From the performance checkout on Apple Silicon, the hardware commands build and sign only a temporary probe. The tests and native control require no VM. The Linux diagnostic uses the same executable in each guest. Comparing its time per call with the benchmark also requires counts for the service's actual syscall mix during the transfer.

```sh
python3 -B docs/benchmarks/2026-11-24/orbstack-rea/inspect_local.py \
  --boot-log "$HOME/.orbstack/log/vmgr.log"
sh scripts/relaybench/hvf_tx_probe/run.sh --test
sh scripts/relaybench/hvf_tx_probe/run.sh --native
sh scripts/relaybench/hvf_tx_probe/run.sh --hvf
sh scripts/relaybench/hvf_tx_probe/run.sh --paired
python3 -B scripts/relaybench/delivered_tx_kicks.py
python3 -B scripts/relaybench/check_oneshot_connect.py
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath \
  -ldflags='-s -w -buildid=' -o /tmp/syscallcost-linux-arm64 scripts/netbench/syscallcost/main_linux.go
```

The reversed-start VM study uses the benchmark's existing local inputs, host-idle checks and automatic cleanup.

```sh
python3 -B docs/benchmarks/2026-11-24/disposable-local-fixture/local_terminal.py \
  --mode host-role --host-role-first Interactive --socket-evidence route --idle-wait-seconds 60 --run
```
