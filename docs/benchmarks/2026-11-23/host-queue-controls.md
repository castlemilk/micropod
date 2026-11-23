# VM queue and latency activity on the Gamma host

The November 21 host screen offers a direct comparison between two independent Interactive launchd jobs, `mac-interactive` and `mac-hinted`. Both used four vCPUs, Linux `7.3.5-micropod`, Reno, an identical service image and a four-CPU container quota. The treatment combined a higher-priority Swift boot task with a scoped Foundation activity. Among the three rounds both workers completed cleanly, the hinted arm delivered less bulk throughput in all three. The archive cannot isolate either hint or establish its effect on vCPU priority. [Raw scheduling records](../2026-11-21/gamma-vm-scheduling.json.gz)

## Who owns each queue

Micropod and the original benchmark baseline `7a4eb51a` both pin Apple Containerization 0.42.0 at `c0185aea5c04fcd4d1cfe9359e0066a380835403`. In that revision, `LinuxContainer.create()` asks its VM manager to create the instance and then awaits `vm.start()` (lines 641–645). The manager constructs `VZVirtualMachineInstance` (line 61). Its initializer creates a private, serial `DispatchQueue(label:)` and supplies that queue to the VZ framework. The installed macOS Swift Dispatch interface, line 148, gives this overload the defaults `qos: .unspecified`, `attributes: []` and `target: nil`. The backing thread’s effective QoS and the helper’s vCPU priorities require runtime measurements. [Queue creation and VZ initializer](https://github.com/apple/containerization/blob/c0185aea5c04fcd4d1cfe9359e0066a380835403/Sources/Containerization/VZVirtualMachineInstance.swift#L118-L140)

The pinned boot helper synchronously dispatches the call that begins VZ startup, then resumes a Swift continuation from VZ’s completion callback. A higher-priority calling task therefore reaches a synchronous handoff during startup. This call site supplies no evidence of a sustained change to the vCPU threads during the later workload. [Pinned boot helper](https://github.com/apple/containerization/blob/c0185aea5c04fcd4d1cfe9359e0066a380835403/Sources/Containerization/VZVirtualMachine%2BHelpers.swift#L67-L79)

| Scope | Archived baseline and treatment |
| --- | --- |
| launchd supervisor | Both jobs directly ran the selected binary with `ci serve` and reported `spawn type = interactive (4)`. The trial supplied its own plist. The candidate’s generated-plist change and detached `Process.qualityOfService = .userInitiated` path were bypassed in this pair. |
| Swift boot task | The treatment wrapped `prepared.container.create()` in a task-group child with `priority: .userInitiated`. The control called it directly. |
| Foundation activity | The treated supervisor began one activity with both `.userInitiatedAllowingIdleSystemSleep` and `.latencyCritical` on the first published listener using the parallel relay, ending it when the last listener was removed. Scope followed the listener lifetime across requests. |
| Relay and VM threads | In both arms, the relay’s accept queue and two data-owner queues already requested `.userInitiated`. Neither arm explicitly set the VZ queue QoS, retargeted its queue, or assigned a QoS to an individual vCPU. |

The original retained host plan records the changes in `host-change.py` lines 12–45, SHA-256 `4333f2b5ccab3647fba5b25e3a09c81834c8739aba0f843160964405dae57791`. Its `prepare-host.sh` lines 5–8 chose the binaries and launch roles, SHA-256 `63cc42db3a31f416631b4d953cc62017b28f16c37321366b9d564a706bdb5585`. The committed archive includes the launch script at `files.launch-owned.py`, observed roles at `scopes`, and signed host binary hashes at `sha256.stock_host` and `sha256.host_hints`. The `ship-detached` experiment in that archive used a separate launch path and binary.

## Direct comparison within the same launch role

Recomputed from `records.host-screen`, pairing by round number and retaining an arm only when its recorded `valid` flag was true. The control passed 5/8 rounds and the hinted treatment passed 6/8. Rounds 3, 4 and 7 were the only common clean rounds.

| Round | Bulk control, MiB/s | Bulk hinted, MiB/s | Fresh p95 control, ms | Fresh p95 hinted, ms |
| ---: | ---: | ---: | ---: | ---: |
| 3 | 6,840 | 6,619 | 21.626 | 41.193 |
| 4 | 6,180 | 5,578 | 31.574 | 55.922 |
| 7 | 6,136 | 6,062 | 34.582 | 26.081 |

Using unrounded readings, the median within-round hinted/control ratio was **0.968 for bulk** and **1.771 for fresh p95**. The latter worsened in two of three common clean rounds. Both VM homes recorded endpoint repairs. The small intersection of successful rounds, separate VM instances and concurrent boot and activity changes limit interpretation. Testing #228.02 still requires independently varying the VZ queue. Testing #228.03 requires holding that queue and the boot task fixed while varying the activity and collecting its effective-priority and energy measurements.
