# Where Hypervisor.framework can help Micropod on Gamma

**The strongest result was passing mapped guest buffers directly to a Mac TCP socket.** In a one-vCPU hardware VM, this increased median paired throughput **29.8%** (95% paired bootstrap interval **25.4% to 30.7%**) and reduced sender CPU time per GiB **23.0%**. Making a guest notification cheaper saved about **62 ns**. At the Linux worker’s measured notification rate, that second result has little leverage on bulk throughput. [Mapped-buffer comparison](20261124T110148Z-tcp-run-ccek151w/summary.json) · [Notification comparison](20261124T105636Z-hvf-run-o9vnuv96/summary.json) · [Linux worker counters](20261124T105113Z-link-h5htd1g4/summary.json)

## A mapped guest buffer and a real TCP receiver

The bare-metal arm64 guest filled rotating 64 KiB buffers with a unique sequence number and a repeating byte pattern derived from that number. The host serviced the same queue and sent the same bytes over one established Mac loopback TCP connection. The control copied each frame into a host staging buffer before calling `send`. The candidate passed a pointer into the mapped guest page directly to the same system call. The guest could reuse its slots after the host accepted the batch. A receiver on another thread verified the header and every payload byte, then checked EOF. [Guest producer](../../../../scripts/relaybench/hvf_notify/payload.S) · [TCP sender and verifier](../../../../scripts/relaybench/hvf_notify/payload.c)

| Controlled component measurement | Staged copy | Mapped buffer |
| --- | ---: | ---: |
| Median TCP throughput | 8,402 MiB/s | 10,892 MiB/s |
| Median sender CPU-seconds per GiB | 0.122 | 0.094 |
| Median sender + receiver CPU-seconds per GiB | 0.216 | 0.174 |
| Fully verified scored bytes | 4,296,015,872 | 4,296,015,872 |

Mapped buffers won **16/16** pairs. Each window made exactly 4,097 sends and 513 data notifications plus one completion exit. Both arms used the same four-MiB ring, one vCPU, MMIO notification and eight-buffer batch limit. Timing included guest payload generation, host servicing, TCP delivery and receiver verification. VM initialization and socket creation occurred before timing. The controlled schedule started at 94.99% host idle. A separately launched, ungated repetition started at 95.94% idle and returned a **31.2%** paired gain (95% interval **30.1–31.4%**), also in **16/16** pairs. [Controlled windows](20261124T110148Z-tcp-run-ccek151w/windows.jsonl) · [Ungated repetition](20261124T110243Z-tcp-run-r1bozcpa/summary.json)

## Notification cost on the selected Linux worker

The four-vCPU worker from the OrbStack holdout used Standard launchd scheduling and two relay workers. A read-only guest observer matched the service’s macvlan parent ifindex to the single transmit queue on the guest’s `virtio_net` interface. Each pair of driver snapshots bracketed the entire fixed-client invocation, including warmup and drain bytes. The aggregate TX kick counter agreed with the per-queue counter at every sample. The boot inventory reported segmentation and receive offloads enabled. [Fixture and service interface](20261124T105113Z-link-h5htd1g4/fixture.json) · [Driver inventory](20261124T105113Z-link-h5htd1g4/a/guest-facts.txt)

Across four scored invocations, the parent recorded **791–805 TX kicks per delivered GiB**, median **794.85**. Median throughput was **8,226 MiB/s**, fresh p95 **9.56 ms**, and observed VMM CPU **0.3305 CPU-seconds per delivered GiB**. All **960/960** fresh requests succeeded. Every scored window had zero bulk reopens, NIC drops, errors and TX timeouts. This diagnostic used the selected build and a separate, disposable worker. The independent product comparison measured **8,046 versus 7,207 MiB/s** and fresh p95 **9.94 versus 5.24 ms** for Micropod and OrbStack. [Worker measurements](20261124T105113Z-link-h5htd1g4/summary.json) · [Cleanup](20261124T105113Z-link-h5htd1g4/cleanup.json) · [Independent peer result](../gamma-local-peer/results.md)

The direct-HVF probe compared a trapped 32-bit device-register store (MMIO) with a guest hypercall (HVC). Each path published the same shared head, verified every descriptor, acknowledged the same batch and caused the same number of exits. At one descriptor per notification, HVC reduced elapsed time by **9.0%**, saving **64 ns** per notification. At eight descriptors it saved **8.7%**, or **62 ns**. It won all 16 pairs at each depth. A second run admitted at **74.99%** host idle found savings of **63 ns** and **57 ns**, respectively. [Controlled exit timings](20261124T105636Z-hvf-run-o9vnuv96/summary.json) · [Natural-load timings](20261124T105614Z-hvf-run-399gbsxn/summary.json) · [Shared HVF runner](../../../../scripts/relaybench/hvf_notify/vm.c)

If each Linux driver kick incurred one comparable exit, the eight-descriptor experiment’s **61.5 ns** paired sender-thread CPU saving would amount to **48.9 µs per delivered GiB**, about **0.015%** of the measured VMM CPU budget. This is a sizing estimate. The driver exposes guest kick counts, while Apple’s VZ worker owns the host exits. A guest kick count alone cannot establish the VZ exit rate or identify the source of fresh-request latency. [Raw HVF windows](20261124T105636Z-hvf-run-o9vnuv96/windows.jsonl) · [Linux queue readback](20261124T105113Z-link-h5htd1g4/guest-3.txt)

## Product decision

Micropod creates its Linux worker through Apple’s VZ virtual-machine manager. Direct Hypervisor.framework gives a backend ownership of guest mappings, vCPU threads and exit handling. In Micropod’s signed relay revision `86ca2713`, the normal socket path already reads into a worker scratch buffer and writes from that buffer. An explicit user-space copy preserves a suffix on a short write. The prototype’s always-copy control isolates the price of a staging step. Its result identifies an opportunity in the design of a shared-buffer transport. The four-vCPU Linux service and its fresh-request tail still need an end-to-end comparison for that transport. [Worker construction](../../../../Sources/MicropodRuntime/SandboxVM.swift) · [Relay source](../../../../Sources/CPublishedTCP/PublishedTCP.c) · [Apple’s Hypervisor API](https://developer.apple.com/documentation/hypervisor)

Prototype a published-port transport with a bounded virtqueue in each direction and hold guest buffers until the socket accepts their bytes. Exercise backpressure, half-close, disconnect and port revocation before repeating the 32-stream and 240-fresh-request workload. Apple exposes custom Virtio devices, queues and shared memory in Virtualization.framework starting with macOS 27. That provides a route to testing this data path while retaining Micropod’s Linux boot and existing storage, network-management and recovery code. Gamma ran macOS 26.5.1 with SDK 26.5. A macOS 27 trial needs a fresh stock control on the same host. [Apple’s custom Virtio device API](https://developer.apple.com/documentation/virtualization/vzcustomvirtiodeviceconfiguration) · [Apple’s device implementation walkthrough](https://developer.apple.com/videos/play/wwdc2026/224/) · [Micropod integration points](../../../research/2026-11-23-transport-storage-evidence.md)

## Reproduction

The hardware driver records the order, source and binary hashes, compiler, host, idle observation, all first attempts and teardown. It uses one excluded warm-up per condition and 16 scored blocks. Confidence intervals resample whole blocks. Each scored hardware run exited successfully and removed its signed temporary build. The Linux observer and worker were removed with their private scope. From this directory, the saved measurements replay with these commands.

```sh
python3 -B hardware.py --replay 20261124T110148Z-tcp-run-ccek151w
python3 -B hardware.py --replay 20261124T110243Z-tcp-run-r1bozcpa
python3 -B hardware.py --replay 20261124T105636Z-hvf-run-o9vnuv96
python3 -B hardware.py --replay 20261124T105614Z-hvf-run-399gbsxn
python3 -B measure_link.py --replay 20261124T105113Z-link-h5htd1g4
```

To collect fresh hardware samples on Gamma, use `python3 -B hardware.py --payload --run` for mapped TCP and `python3 -B hardware.py --run` for notifications. Both wait for controlled host admission. `--load ambient` records one pre-run idle observation and starts at the load present. For a new Linux queue measurement, use `python3 -B measure_link.py --run`. [Hardware driver](hardware.py) · [Linux measurement and replay](measure_link.py)
