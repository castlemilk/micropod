# Compiler CPU affinity under concurrent CI on Gamma

Across 24 earlier Micropod windows, the guest CPU holding the last build also had the highest scheduled HTTP p95 in 17. This trial let the Go processes move while keeping every service and HTTP issuer on its original CPU. Pooling shortened the interval from the first build starting to the last finishing by a paired median of 0.71% on Micropod, with one seed faster and one slower. It increased Micropod's scheduled HTTP p95 by 13.65% and p99 by 21.79%. The worker keeps its existing job placement. [Earlier per-CPU HTTP replay](sibling-pinned-build-http-by-vcpu.json) · [Affinity comparison](sibling-compiler-affinity-results.json)

## Hardware and workload

Each engine hosted 64 containers on four vCPUs and 4 GiB, with 32 internal job networks. Eight client containers compiled, vetted, tested and ran two Go revisions each while 32 clients sent 96,000 requests over warmed sockets in each 1.5-second offer window. Both engines used the same pinned images, program inputs, CPU quotas and clock schedule. Micropod used the signed 250 µs worker with private 128 MiB tmpfs scratch for each builder. OrbStack used ordinary writable layers and its stock 2.1 ms scheduler slice. Both kept their persistent compiler caches. Before-boot host idle ranged from 88% to 94%. [Signed worker and runner](sibling-native-scratch-holdout-product.json) · [First boot plan](20261125T032030Z-sibling-compiler-affinity-ts1qfxzz/plan.json)

Each builder had a one-CPU quota and a four-CPU cgroup mask in every arm. Its resident service and HTTP issuing threads remained pinned to one CPU. The home treatment also pinned the build dispatcher and its descendants there. The pool treatment let only those build processes run on CPUs 0–3. The fixture recorded the actual launch command, kernel mask and ordinary priority on every timed dispatcher and a child. A separate untimed probe held a genuine Go process and its compiler child on a FIFO, verified their executable hashes and observed thread masks, then released the compiler and checked its object. All four Micropod boots used the same signed product. OrbStack stayed on one boot. [Live fixture](sibling_compiler_affinity.py) · [Go tool and thread evidence](sibling_compiler_affinity_evidence.py)

## Performance

The values below are medians of the eight per-engine windows for each treatment. Each seed supplied four pairs of windows. The second seed reversed treatment order. Within a boot each engine ran first twice.

| Compiler mask | Scheduled p95, Micropod / OrbStack | Scheduled p99, Micropod / OrbStack | Dispatch-to-response p95, Micropod / OrbStack | Eight builds, Micropod / OrbStack | Both scheduled p95 and build time lower on Micropod |
| --- | ---: | ---: | ---: | ---: | ---: |
| Home CPU | 2.295 / 3.033 ms | 5.579 / 5.848 ms | 820 / 258 µs | 2.923 / 2.878 s | 1/8 |
| Pool of four | 2.519 / 3.819 ms | 7.336 / 10.953 ms | 613 / 238 µs | 2.902 / 2.876 s | 4/8 |

With pooled compilers, Micropod had lower scheduled p95 in all eight windows and finished the build batch first in four. On the first seed its median build time was 2.891 s against 2.885 s. On the second it was 2.936 s against 2.876 s. Against Micropod's home control, pooling cut paired post-dispatch p95 by 30.69%. Its scheduled p95 rose 35.97% on the first seed and fell 3.35% on the second. Build time rose 1.20% and fell 1.08%, respectively. OrbStack also received the pooling treatment. Its paired scheduled p95 rose 22.88% and its build time rose 0.11%. Both engines together completed 3,072,000 requests, 256 two-revision builds and 4,096 workload tests. Every response finished while all eight builds were still running, with at least 1.035 s to spare. [Raw replay, including same-window and per-seed results](sibling-compiler-affinity-results.json)

## Guest and host CPU accounting

With fixed placement, the final two Micropod jobs shared one home CPU in all eight windows. With pooling, the final two jobs had different recorded home CPUs in all eight windows. The median spread between first and last finishes widened from 179 to 270 ms in Micropod and from 27 to 220 ms in OrbStack. The pooled mask establishes where a compiler could execute. Its home CPU only identifies the resident HTTP workload once the compiler is free to migrate. [Home build timelines](sibling-compiler-affinity-builds-home.json) · [Pool build timelines](sibling-compiler-affinity-builds-pool.json)

Across 512 builder and dependency cgroup observation intervals, the kernel reported zero throttled periods in 13,365 quota periods. Across the eight Micropod builder cgroups, the median summed CPU pressure-stall time classified as `some` fell from 17.29 to 8.90 cgroup-seconds per window. These are overlapping per-cgroup intervals around the builds, and include the associated HTTP work. OrbStack did not expose the corresponding pressure files in this fixture. [Archived counters](20261125T032201Z-sibling-compiler-affinity-obpeb5h0/grouped-0-all-A-compiler-cpu.json) · [Linux cgroup CPU accounting](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu)

On Gamma's M5 Max, an untimed guest workload pinned in turn to each of the four vCPUs identified the corresponding Mac vCPU thread. Each nominated thread accounted for at least 85.9% of the vCPU time in its calibration. In the home treatment the host thread associated with Micropod's last builder had the least credited CPU time in zero of eight windows. Its median time was 4.2% above the median of the other three. Across the four native vCPU threads, the median share of execution on the Mac's Super performance level was 99.53% with home placement and 99.77% with pooling. The host snapshots bracket setup, dispatch and build completion. They can establish total execution time by thread and performance level. Short stalls within a build and execution on individual physical cores remain unresolved. [Host counters and all 32 calibration checks](sibling-compiler-host-vcpu.json) · [Apple XNU counter layout and performance-level mapping](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/proc_info_private.h#L197-L213)

All four physical boots qualified and cleaned up. An audit checked 215 disposable scopes, owned launchd jobs, OrbStack containers, networks and volumes, and the private fixture directories. All 24 original baseline files and 24 preserved copies matched the original SHA-256 manifest. [Cleanup and baseline hashes](sibling-compiler-affinity-cleanup.json) · [Original QoS and relay-worker results](../gamma-qos-and-workers/results.md)

The next four boots held compiler affinity fixed and changed only the native compiler time slice. [Compiler time slices and calibrated hardware counters](sibling-compiler-runtime-results.md)

Replay the four archives from this directory with

```sh
python3 -B sibling_compiler_affinity_results.py 20261125T*-sibling-compiler-affinity-*
```
