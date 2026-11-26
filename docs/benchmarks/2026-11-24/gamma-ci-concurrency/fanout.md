# Published traffic across 32 CI services on Gamma

In the two original mixed-CI pairs, every Micropod stream delivered fewer bytes per second than every OrbStack stream in the same pair. All 32 resident services were running when the benchmark released the CI jobs. The downloader kept 32 streams active and offered 40 fresh identity requests/s. Both engines completed all 480 fresh requests and reopened zero bulk connections. [Original mixed-workload study](results.md) · [Per-stream replay](fanout-historical-streams.json)

| Paired batch | Micropod stream range, MiB/s | OrbStack stream range, MiB/s | Receiver throughput gap, MiB/s | Gap if every Micropod stream reached its fastest observed rate, MiB/s |
| --- | ---: | ---: | ---: | ---: |
| Micropod first | 140.04–186.94 | 198.30–278.44 | 2,040.91 | 1,154.88 |
| OrbStack first | 127.90–188.48 | 188.79–256.22 | 2,180.03 | 1,190.77 |

The bottom eight streams carried 22.57–22.97% of Micropod’s bytes and 22.76–22.97% of OrbStack’s. The last column takes each Micropod batch’s fastest observed rate, multiplies it by 32, and compares the result with OrbStack’s actual aggregate. A change that lets every stream exceed its previously observed fastest rate could deliver more. This calculation puts a scale on the observed imbalance. [First pair, Micropod](20261124T112552Z-churn-tncpeyjp/churn-0-A.json) · [First pair, OrbStack](20261124T112552Z-churn-tncpeyjp/churn-0-B.json) · [Second pair, Micropod](20261124T112552Z-churn-tncpeyjp/churn-1-A.json) · [Second pair, OrbStack](20261124T112552Z-churn-tncpeyjp/churn-1-B.json)

## What the network clock includes

Both engines created and inspected all 32 one-shot job containers before starting the fixed client. Four dispatch slots then released builds, tests, an expected failure and an expected cancellation. The six-second scored window starts inside the client after each bulk stream completes an 8 MiB warmup response. Removing the job containers and checking the surviving services happen after the network run. Provisioning through cleanup has its own duration. The original 5,069 vs 7,180 MiB/s comparison therefore measures delivery during job execution and exit. [Job barrier and lifecycle](churn.py) · [Client timing](../../../../scripts/netbench/offered/main.go)

## One service versus all 32

Keep the same 32 resident service containers on both engines for all four conditions. Each service has its own published port, one CPU of quota, 512 MiB of memory and a 192-PID limit. Traffic sent to a single service uses one service cgroup. Spreading traffic can use more service cgroups within the four-vCPU VM. This is an application-level comparison of service distribution, which includes that difference in usable CPU. A per-listener explanation would require a further control with the same service and CPU capacity behind the different listener layouts. [Tenant resource checks](qualify.py) · [Linux cgroup CPU bandwidth](https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu)

| Scheduled traffic | No CI jobs | Four build slots |
| --- | --- | --- |
| All traffic to one resident service | 32 streams and 240 fresh requests to a single verified marker | Same traffic while 32 pre-created jobs are released and exit |
| Traffic spread across 32 services | One continuing stream per port, with fresh requests round-robin | Same traffic and job workload together |

Four blocks balance every condition across all four positions. Each engine runs first twice per condition. The same single-service ordinal serves both one-port conditions and both engines within a block, then rotates in the next block. Each engine uses the same Linux workload image and revisions. The verifier retains receiver bytes by stream, scheduled p95/p99, host process CPU per full-invocation bulk GiB, runnable wait and CI completion. It checks the registry of resident containers before and after each window, the actual client arguments and cardinality, the digest of the invoked multi-port manifest, and matching artifacts across engines. Job receipts also bound the scored time that overlapped released healthy jobs and verify the four-slot limit. The interaction is the ratio of throughput retained under CI with all 32 destinations to throughput retained under CI with one destination, computed within each block. [Collector and scorer](fanout_ci.py) · [Offline regression cases](test_fanout_ci.py)

## Linux file delivery during the same kind of CI load

On the stock Micropod worker, serving the same 8 MiB file through Linux `sendfile` delivered 5,864 MiB/s. Reading and copying that file in userspace delivered 5,000 MiB/s. The file-backed path won all four blocks and gained 17.17% in median paired throughput. Service CPU per delivered GiB fell 52.0%. A memory-backed response delivered 5,033 MiB/s, with a separate paired difference of +18.01% for the file-backed path. Guest tracing counted 8,388,096 positive return bytes for the file path in preflight. The corresponding memory and explicit-copy probes recorded zero sendfile returns. [Kernel study plan](20261124T115609Z-kernel-de4uwit3/kernel-plan.json) · [Trace proof](20261124T115609Z-kernel-de4uwit3/sendfile-proof.json) · [Kernel study replay](low_level.py)

Excluding the NIC interrupt vCPU from build affinity reduced throughput by 6.17% across the four paired file-delivery blocks and lost all four. The observer counted all 769,629 timed interrupts for that device on vCPU 3. For file-backed artifacts, test the service’s delivery method before restricting the build CPU set. [CPU placement and measurements](kernel_ci.py) · [Observer and byte attribution](low_level.py)

## File-backed delivery on both engines

Four further balanced blocks compared both engines and both response sources at the original four-vCPU budget, with 32 services and 32 pre-created jobs. All 3,840 fresh requests completed. Both engines produced the same 480 build outputs by revision across the matched cases. [Frozen conditions](20261124T120649Z-file-peer-oxnf4_xc/file-peer-plan.json) · [Replayed engine and source comparisons](low-level-summary.json)

| Median by arm | Micropod memory | Micropod file | OrbStack memory | OrbStack file |
| --- | ---: | ---: | ---: | ---: |
| Bulk MiB/s | 5,046 | 5,956 | 7,104 | 7,798 |
| Fresh p95, ms | 57.75 | 55.27 | 42.39 | 52.68 |
| Fresh p99, ms | 85.83 | 99.92 | 75.17 | 73.34 |
| Last job, s | 14.53 | 14.24 | 13.54 | 13.30 |

File-backed serving raised median paired throughput 18.73% for Micropod and 10.14% for OrbStack. Both improved in all four blocks. Micropod’s median paired throughput deficit against OrbStack was 28.51% for memory responses and 22.61% for file responses. Its median fresh p99 increased on the file path. This result supports using the real artifact-serving path in workload comparisons and measuring both short-request tails before a product change. [Four-block verifier](low_level.py)

## Device notification batching

A separate 32-endpoint test used an HVF producer and the existing Linux published sockets. Grouping up to eight scalar refill requests reduced median hardware data exits from 512 to 302 per 256 MiB. Median paired throughput changed +0.98% and favored grouping in 6/10 blocks. The 95% paired bootstrap interval was −11.03% to +9.59%. The data show fewer exits. They leave the throughput effect uncertain. [Grant schedule](20261124T120138Z-grants-juej_gda/bridge-plan.json) · [Grant comparisons](low-level-summary.json)

An eight-block follow-up kept the grouped producer’s socket buffers at 512 KiB and raised the Darwin write-ready threshold from its observed 2 KiB default to 128 KiB. Send calls fell 10.7% and polls fell 22.1% at the paired median. Throughput fell 4.51% at the paired median (3/8 wins, 95% interval −15.79% to +7.11%). All 1,056 build jobs and 5,619 fresh probes completed. Fewer wakeups alone did not establish a throughput advantage. [Per-socket readbacks and controls](low-level-results.md) · [Replayed comparisons](low-level-summary.json)

## Live fanout admission

At 23:11 AEDT on 24 November the previous file-delivery study finished and the fanout driver acquired the existing fixture lock. The worker and workload inputs passed their checks. macOS denied this session’s read of the OrbStack Docker socket at the admission request for its running-container inventory. The driver stopped before creating a worker or timing a client. The one-port/32-port interaction remains unmeasured. [Attempt and status](20261124T121152Z-fanout-791jb_6f/status.json)

## Reproducing the comparison

From this directory, `python3 -B fanout_ci.py --historical 20261124T112552Z-churn-tncpeyjp` recalculates the per-stream table. `python3 -B fanout_ci.py --plan` prints the 16 engine-pair conditions without opening a socket or starting a VM. `python3 -B -m unittest -v test_fanout_ci` exercises balanced order, fixture identity, byte accounting and rejection of mislabeled windows.

The disposable-host entry point is `python3 -B qualify.py --profile fanout`. It uses the existing local fixture lock, admission checks, private resources and cleanup. `python3 -B replay.py RUN_DIRECTORY` verifies a completed run and reports the four per-engine medians, per-block interaction and peer ratios.
