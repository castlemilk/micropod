# Apple Silicon performance experiments

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
