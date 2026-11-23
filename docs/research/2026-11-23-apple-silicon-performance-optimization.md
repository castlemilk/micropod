# Apple Silicon performance experiments

The [optimization register](2026-11-23-optimization-register.md) tracks all 101 research directions and four follow-ons across 13 backlog issues. The follow-ons cover desktop stats, first-build caches, relay read filters and Go suite preparation. Each direction has evidence, a next measurement and an experiment group.

The 23 November blueprint asks whether host scheduling can improve published TCP throughput while keeping fresh requests under 75 ms at p95. The implementation base is the warm-worker performance branch at `2b7fde8ec336c266fc96a1288953303ac5cd69e7`. Its native relay already has a dedicated accept queue, multiple data workers and an opt-in Interactive launchd job.

## Source audit

| Research phase | Existing implementation | Next measurement or dependency |
| --- | --- | --- |
| 0. Host scheduling | [CIWorker.launchAgent](../../Sources/MicropodRuntime/CIWorkerService.swift) chooses the launchd process type. [CIWorkerPortRelay](../../Sources/MicropodRuntime/CIWorkerPorts.swift) chooses the guest-facing socket window and worker count. [NativeLoopbackRelay.Owner](../../Sources/MicropodRuntime/NativeLoopbackRelay.swift) creates user-initiated dispatch queues. [SandboxVM.prepare](../../Sources/MicropodRuntime/SandboxVM.swift) delegates VM creation to Apple's Containerization package. | Compare Standard and Interactive independent jobs with identical relay settings. The pinned dependency constructs its own private VZ dispatch queue. A supervisor Foundation activity or a change to that queue would each need a separate control. |
| 1. Host transport and relay | [SandboxNetwork.workerNetwork](../../Sources/MicropodRuntime/SandboxNetwork.swift) creates the networks. [SandboxVM.prepare](../../Sources/MicropodRuntime/SandboxVM.swift) attaches the dedicated publication network. [PublishedTCP.c](../../Sources/CPublishedTCP/PublishedTCP.c) handles socket events and buffering. | Qualify a host-only MTU change end to end. Measure callback batching, adaptive read thresholds and direct ingress separately. Preserve byte delivery, idle tails, half-close and revocation in each relay experiment. |
| 2. Guest networking and scheduling | [directNetwork.attach](../../guest/runner/docker_port_direct_linux.go) configures direct publication. [workerNetwork.attach](../../guest/runner/docker_links_linux.go) implements container link drivers. [The kernel builder](../../ci/build-worker-kernel.sh) has fair and sched_ext-capable profiles. | Measure interface counters, negotiated offloads and queue state on the actual boot before tuning. Test coalescing, link driver, scheduler and any co-located socket splice independently. |
| 3. Kernel and guest architecture | [The kernel builder](../../ci/build-worker-kernel.sh) selects a profile. [SandboxVM.prepare](../../Sources/MicropodRuntime/SandboxVM.swift) selects the kernel, mounts and VM manager. | Isolate compiler and page-size builds, retain kernel protections, and verify boot, OCI behavior and compatibility before a throughput comparison. Qualify a translation VM separately. |
| 4. Sizing, storage and reclaim | [CIWorkerCPUCount.resolveForBoot](../../Sources/MicropodRuntime/CIWorkerCPUCount.swift) implements fixed and automatic CPU policies. [CIWorker.openDisk](../../Sources/MicropodRuntime/CIWorker.swift) opens the worker disk. [SandboxVM.prepare](../../Sources/MicropodRuntime/SandboxVM.swift) assembles block and shared mounts. | Compare four and six vCPUs at the same service quota. Storage and memory experiments need measured I/O, pressure, recovery and edit latency before adopting a new layout or reclaim policy. |
| 5. Alternative transport or VMM | [SandboxVM.prepare](../../Sources/MicropodRuntime/SandboxVM.swift) passes a VZ-backed manager to LinuxContainer. | Establish a repeatable transport ceiling first. A custom device needs a supported host, measured integrity, backpressure and recovery. A second VMM depends on those results. |

## Baseline evidence

The research's 3,440 and 3,543 MiB/s are medians from an earlier comparison. Its −9.5% is the median of within-pair differences expressed as percentages. The later four-vCPU holdout below predates the revised relay. Each entry is the median over that arm's clean rounds. Runnable wait is the VMM process's runnable time less its CPU time, divided by wall time. [Earlier comparison](../benchmarks/2026-11-21/gamma-direct-macvlan.md) · [Later raw rounds](../benchmarks/2026-11-22/gamma-tcp-contrasts.json)

| Archived arm | Clean rounds | MiB/s | Fresh p95 / p99 (ms) | VMM runnable wait (thread-s/s) |
| --- | ---: | ---: | ---: | ---: |
| Micropod | 16/16 | 2,709.8 | 35.2 / 58.1 | 2.094 |
| OrbStack | 15/16 | 3,010.4 | 220.3 / 1,027.4 | 6.285 |

The 15 common clean pairs gave −14.6% with a 95% paired bootstrap interval of −29.1% to +25.9%. The older CPU-only Standard and Interactive controls both had zero sampled runnable vCPU time below base priority. Those controls did not measure the effect of the role on mixed traffic. [Scheduling samples and qualifications](../benchmarks/2026-11-21/gamma-vcpu-priority.md)

At 13:40 and 14:07 AEDT on 23 November, Cuttlefish reported 1/1 leases on the isolated Gamma Linux worker. The Mac held 1/6 and 2/6 respectively. The shared baseline still requires the warm-CI owner's released slot and fresh effective disk clearance. There is no new main-branch System Trace, taskinfo capture, guest IRQ capture or timed result for this experiment. The first released slot belongs to the revised stock-relay baseline. [Existing benchmark handoff](../benchmarks/2026-11-23/gamma-throughput-gap.md)

## Phase 0 implementation

**Hypothesis.** With identical launchd-managed Micropod workers, the Interactive process type reduces VMM runnable wait and improves mixed published-port throughput. The dry plan fixes four vCPUs, 4 GiB of guest memory, two relay workers, a 128-event callback and the direct macvlan/Reno path. Each client interval offers 240 fresh requests over six seconds beside 32 bulk streams. [Paired driver](../../scripts/relaybench/gamma_pilot.py)

| Arm | Rendered launchd ProcessType | Required live spawn type on Gamma | Relay mode |
| --- | --- | --- | --- |
| A | Standard | `daemon (3)` | `kqueue-interactive` |
| B | Interactive | `interactive (4)` | `kqueue-interactive` |

`micropod ci launch-agent --process-type Standard` and `micropod ci launch-agent --process-type Interactive` render property lists to stdout. The normal service installer retains its existing role selection. Both experiment jobs use independent labels, state directories and log paths. The driver verifies the loaded supervisor PID, spawn type and job environment, compares the remaining job settings, checks the supervisor executable by its mapped file identity and ties the Apple VMM PID to the open worker disk. It rechecks both fixtures after the final interval.

The guest observer reads its own running executable digest from Linux procfs. Both arms use the checksum-pinned probe in their existing read-only `/mpcheck` mount and the original service image. It reads service-interface packets, drops, errors, namespace TCP resets and retransmissions, and guest-wide IRQ and softirq counts. The parent's published-NIC drops, errors and TX watchdog counters come from the worker's metrics endpoint. A masked `/proc/interrupts` can still yield a comparable aggregate interrupt rate through `/proc/stat`. Each rate is named for its source. [Measurement and decision rules](../../scripts/relaybench/host_role.py)

### Reproduce offline

These commands build the observers and print the schedule entirely from this checkout. The qualified compilers are Go 1.27.2 and Apple Clang 21 on macOS arm64. Supply a new directory for the binaries. The build verifies the two Go executables and reproduces the original Mac counter sampler from its archived C source. [Build helper](../../scripts/relaybench/build_host_role_tools.py)

```sh
python3 -B scripts/relaybench/build_host_role_tools.py "$NEW_TOOLS"
python3 -B scripts/relaybench/gamma_pilot.py --mode host-role --seed 34205
python3 -B -m unittest discover -s scripts/relaybench -p 'test_*.py' -v
```

The plan produces three warmup pairs followed by four scored pairs in BA, AB, AB, BA order. Each two-pair block balances the two orders. The `--holdout` option selects 16 scored pairs.

### Reserved Gamma run

After the stock baseline, the owner provisions two dedicated, serving fixtures with the same Micropod executable, kernel image, guest tools and service limits. Both receive the built Linux `netbench` in the read-only probe mount. The observer lives outside the service image. Use the existing fixture directory format described in the [Gamma handoff](../benchmarks/2026-11-23/gamma-throughput-gap.md).

The owner supplies the exclusive release record for both canonical scope paths and the `host-role` mode. It uses the shared stock-pilot fields `owner`, `reservation`, `host`, `exclusive`, `starts_at`, `expires_at`, `modes` and `scopes`. Its `effective_disk_gate` records the actual clearance as `passed`, `source`, `checked_at` and `expires_at`. The fleet input is a refreshed Cuttlefish export. The driver checks the handoff and both runners before probing and during each load client. Losing the window stops that client and retains its partial output.

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode host-role --seed 34205 \
  --tools "$NEW_TOOLS" --a "$STANDARD_SCOPE" --b "$INTERACTIVE_SCOPE" \
  --fleet "$FLEET" --release "$RELEASE" --check --out "$NEW_PREFLIGHT"
```

The preflight verifies both running fixtures with zero timed load. In the released measurement window, use the same arguments with `--run` and a fresh output directory. Each attempt records the raw client output, process counters, guest counters and admission observation. CPU and packet counters cover client setup and drain around the six-second offered window. Runnable wait is measured for the whole VMM and supervisor separately. Per-vCPU wait, core placement, negotiated offloads and hardware performance counters require a separate diagnostic capture on the same identified boots. Keep trace overhead outside the scored intervals. [Thread sampler](../../scripts/profile_vm_scheduler.c) · [Trace summary](../../scripts/summarize_vm_scheduler.py)

### Decision

Every scored arm must account for all requests and streams, with zero resets, interface errors, drops and queue timeouts. Every Interactive p95 must be at most 75 ms. The median paired throughput change must be positive, median paired VMM wait must fall, and median paired combined VMM-plus-supervisor wait must hold or fall. The receipt includes median and quartiles for throughput, fresh p50/p95/p99, CPU per GiB, wait and comparable packet/IRQ rates. Missing interrupt coverage gives an inconclusive result. A failed arm remains in the decision even if the surviving pairs are faster.

Passing this screen qualifies the role for an independent confirmation. A performance decision on Gamma is pending. The matched OrbStack holdout, MTU change and relay tuning each retain their own experiment. [Offline verification](../benchmarks/2026-11-23/host-role-verification.json)

## GitHub backlog and implementation

The [tracking issue](https://github.com/castlemilk/micropod/issues/227) links all 13 experiments. The first implementation work is available below. Tests with recorded or simulated observations establish how the tools handle evidence. The next live result depends on a released stock-relay fixture. [Test runs, artifact digests and historical replay](../benchmarks/2026-11-23/research-backlog-verification.json)

| Experiment | Work started | Next evidence |
| --- | --- | --- |
| [#228 Host scheduling](https://github.com/castlemilk/micropod/issues/228) | The [role comparison](../../scripts/relaybench/gamma_pilot.py) isolates Standard and Interactive launchd scheduling. | Four-vCPU baseline and two serving role fixtures. |
| [#229 Jumbo MTU](https://github.com/castlemilk/micropod/issues/229) | The [path check](../../scripts/relaybench/mtu_path.py) rejected the historical 1500-byte host route in a nominal jumbo trial. | Confirm DF in each direction on the host-only hop, TCP MSS and payload delivery on the service path. |
| [#230 Relay workers](https://github.com/castlemilk/micropod/issues/230) | The [paired screen](../../scripts/relaybench/gamma_pilot.py) compares two and four workers with a fixed callback budget. | Revised-relay baseline followed by a worker-only comparison. |
| [#231 Guest NIC tuning](https://github.com/castlemilk/micropod/issues/231) | A [worker collector](../../scripts/relaybench/guest_nic_capture.sh) and [decoder](../../scripts/relaybench/guest_nic.py) record negotiated features, queues and driver settings on the same boot. | Capture the real publication NIC and vary one supported setting. |
| [#232 Direct ingress](https://github.com/castlemilk/micropod/issues/232) | [Replay of six historical pairs](2026-11-23-guest-paths.md) found three direct-ingress rounds above 75 ms fresh p95. | Compare the same service and boot through the revised relay and direct ingress. |
| [#233 Guest link driver](https://github.com/castlemilk/micropod/issues/233) | The [interface check](../../scripts/relaybench/guest_link_path.py) connects the claimed link kind with byte counters in the service namespace. | Bind those counters to a timed macvlan-versus-ipvlan or netkit interval. |
| [#234 Socket splicing](https://github.com/castlemilk/micropod/issues/234) | The [socket check](../../scripts/relaybench/guest_paths.py) identifies two established sockets owned by one forwarder. The current kernel publication path has no such process. | Qualify a separate userspace forwarding fixture and observe actual splice calls and body integrity. |
| [#235 Compiler variants](https://github.com/castlemilk/micropod/issues/235) | The [compiler audit](../../scripts/relaybench/kernel_compiler.py) recovered GCC 15.2.0 with LTO disabled from the stock build. | Reproduce the control, then make a single compiler or LTO change and qualify the image. |
| [#236 Native and translated guests](https://github.com/castlemilk/micropod/issues/236) | The [kernel builder](../../ci/build-worker-kernel.sh) has an opt-in 16 KiB profile. The [image verifier](../../scripts/relaybench/kernel_candidate.py) checks hashes, the binary page size and additional config changes. | Build both images on ARM64 Linux, boot and run native OCI checks. Qualify 4 KiB translation independently. |
| [#237 CPU sizing](https://github.com/castlemilk/micropod/issues/237) | The [size screen](../../scripts/relaybench/gamma_pilot.py) changes four to six vCPUs with fixed service quota and relay worker count. | Measure host headroom and tail latency at both sizes. |
| [#238 Storage and reclaim](https://github.com/castlemilk/micropod/issues/238) | A [file replacement workload](../../scripts/relaybench/volume_durability.py) syncs the file, renames it, syncs its directory and verifies the reopened payload. [Reclaim measurements](2026-11-23-transport-storage-evidence.md) identify guest and host counters. | Compare matched guest volumes, verify acknowledged writes after restart and measure host memory recovery separately. |
| [#239 Custom virtio](https://github.com/castlemilk/micropod/issues/239) | The [SDK and dependency audit](2026-11-23-transport-storage-evidence.md) identified the extension point and macOS 27 dependency. | A supported test host and a same-host stock control. |
| [#240 Second VMM](https://github.com/castlemilk/micropod/issues/240) | The [backend audit](2026-11-23-transport-storage-evidence.md) identifies VZ-specific networking recovery and the upstream alternative's Linux-only implementation. | Decide on a prototype once the preceding work isolates a repeatable ceiling and quantifies the benefit needed. |

The following commands print balanced pilot plans without contacting a runtime. The live forms require `--fleet` and `--release` for the selected mode, two dedicated fixtures, and the checksum-pinned clients built above.

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --scored-pairs 4 --seed 34202
python3 -B scripts/relaybench/gamma_pilot.py --mode size --scored-pairs 4 --relay-workers 2 --seed 34204
python3 -B scripts/relaybench/kernel_compiler.py --gamma-stock
```
