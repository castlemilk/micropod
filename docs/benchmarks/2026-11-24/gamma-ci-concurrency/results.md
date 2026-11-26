# Mixed CI workloads on Gamma

Gamma sustained **32 published services alongside 32 newly started CI containers** on a four-vCPU, 4 GiB Micropod VM. Each healthy one-shot job built and checked two distinct Go revisions. An intentionally failing test returned exit 1 and a cancelled job returned exit 137 in every batch. Removing a service closed its accepted connection. A replacement then served a new marker on the same port while all 31 siblings remained reachable. [Job and port receipts](20261124T112552Z-churn-tncpeyjp/churn-0-A.json) · [Port replacement](20261124T112552Z-churn-tncpeyjp/port-reuse-A.json)

## How many builds to dispatch

All containers were running and reachable on unique loopback ports before dispatch. Each had a one-CPU quota, a 512 MiB memory limit, a 192-PID limit, its own writable image layer and a distinct cgroup. The offline workload ran Go vet, eight tests with result caching disabled, a build, and a revision check inside Linux. The host downloaded every resulting ELF over the owning job’s port and verified its SHA-256. Micropod and OrbStack produced identical binaries for all 192 revisions per engine. [Live tenant identities](20261124T111925Z-ci-46cje9m5/tenants-A-32.json) · [Workload source](../../../../scripts/bench_go_fanout.py)

| Resident Micropod containers | Active build limit | Batch through last verified download | Fresh-request p95 |
| ---: | ---: | ---: | ---: |
| 16 | 16 | 2.01 s | 20.6 ms |
| 16 | 4 | 2.02 s | 9.1 ms |
| 32 | 32 | 4.15 s | 33.4 ms |
| 32 | 4 | 4.03 s | 11.9 ms |

These are medians of two waves per condition. The client offered 40 new connections per second across the resident containers and timed each from scheduled dispatch. All 987 Micropod probes and all 943 OrbStack probes returned the correct marker. Four active CPU steps left all 32 services available and reduced Micropod’s fresh p95 by 64% at that size. Image import, container startup and priming the common Linux cache preceded these clocks. [32 concurrent builds](20261124T111925Z-ci-46cje9m5/wave-n32r01-A.json) · [Four active builds](20261124T111925Z-ci-46cje9m5/wave-n32r03-A.json) · [Cold cache prime](20261124T111925Z-ci-46cje9m5/prime-A.json)

An independent rerun reproduced the tradeoff. With 32 Micropod containers, four active builds completed in 3.87 s with a 12.3 ms fresh p95. Releasing all 32 took 4.06 s with a 30.7 ms p95. All 192 artifacts again matched OrbStack. Each Micropod cgroup reported zero OOM events and zero OOM kills. The largest individual peak was 316.4 MiB against the 512 MiB limit. [Repeat run and workload inputs](20261124T114020Z-ci-3yt6i2wm/plan.json) · [Per-container memory peaks](20261124T114020Z-ci-3yt6i2wm/memory-A.json) · [Replayed results from all studies](summary.json)

## Container startup, failures and published-port throughput

Each engine ran two batches in opposite order. At each release barrier the engine reported 32 live job IDs and 32 distinct service IDs, plus the private fixture’s control service. Four CPU steps could run at once. Alongside them, the pinned network client kept one bulk download running per published port and offered 240 fresh identity requests over six seconds. The first two jobs exercised the failure and cancellation paths. The other 30 each completed two revisions. The pre-window host idle samples ranged from 88.68% to 90.35%. [Client and release plan](20261124T112552Z-churn-tncpeyjp/churn-plan.json) · [Exact ports and markers](20261124T112552Z-churn-tncpeyjp/targets-A.tsv)

| Median of two batches | Micropod Standard, two relay workers | OrbStack |
| --- | ---: | ---: |
| Published downloads, MiB/s | 5,069 | 7,180 |
| Fresh identity p95 | 54.2 ms | 49.5 ms |
| Release to last CI job | 14.00 s | 13.39 s |
| Provisioning through job removal and sibling checks | 16.11 s | 16.34 s |
| Slowest stream across either window, MiB/s | 127.9 | 188.8 |
| Successful fresh requests | 480/480 | 480/480 |
| Bulk reconnects | 0 | 0 |

OrbStack delivered more bulk data in both mixed-load comparisons. Micropod’s earlier single-service result measured 32 streams to one port on an otherwise idle worker. Here the streams reached 32 independently scheduled services while compilers, linkers and job lifecycles used the same VM. [Micropod first batch](20261124T112552Z-churn-tncpeyjp/churn-0-A.json) · [OrbStack first batch](20261124T112552Z-churn-tncpeyjp/churn-0-B.json) · [Prior single-service comparison](../gamma-local-peer/results.md)

## Relay QoS and worker count under CI load

Both comparisons repeated the full 64-container workload on two private Micropod VMs. Four paired blocks reversed the order twice. Each arm delivered 960/960 fresh requests with zero bulk reconnects, completed all 120 healthy jobs, and reported the four injected failures and four cancellations. Both arms held the callback budget at 128 events and the read cap at 256 KiB. [QoS fixture identities](20261124T113317Z-qos-cjvxdmgu/fixtures-before.json) · [Worker-count fixture identities](20261124T113642Z-workers-n36y_7nc/fixtures-before.json)

| Matched comparison | Median download MiB/s | Median fresh p95 | Median time to last job | Bulk wins |
| --- | ---: | ---: | ---: | ---: |
| Standard QoS, two workers | 5,130 | 61.0 ms | 14.31 s | 4/4 |
| Interactive QoS, two workers | 4,784 | 77.5 ms | 15.42 s | 0/4 |
| Two workers, fixed-budget build, Interactive | 4,796 | 69.2 ms | 14.98 s | 4/4 |
| Four workers, same build and role | 4,606 | 71.3 ms | 15.15 s | 0/4 |

The stock signed worker supplied the QoS comparison. The worker-count comparison used the signed fixed-budget build so four workers retained the same callback limit as two. Standard and two workers led on the capped receive-window configuration tested here. The later [private-link runs](published-link-results.md) measured four workers with automatic receive buffering. Standard stayed below 75 ms fresh p95 in all four matched windows. Interactive exceeded 75 ms in three of four stock-worker windows. Both fixed-budget arms also recorded at least one window above 75 ms. [QoS measurements](20261124T113317Z-qos-cjvxdmgu/churn-plan.json) · [Worker-count measurements](20261124T113642Z-workers-n36y_7nc/churn-plan.json)

## Hypervisor.framework with 32 independent receivers

The experimental producer uses one real HVF vCPU. Each TCP flow has a private eight-frame grant in mapped guest RAM, with at most 512 KiB outstanding in user space. The host polls for writable sockets and retains a tenant’s slot across partial sends. A blocked or reset socket can retire independently. The Linux receiver checks its own cookie, every frame sequence and every body byte. The endpoint that resets first validates one complete frame. [EL1 producer](../../../../scripts/relaybench/hvf_notify/flows.S) · [Host send loop](../../../../scripts/relaybench/hvf_notify/flows.c) · [Linux receiver](tenant.go)

Eight balanced blocks crossed mapped versus staged sends with 64 versus 512 KiB Darwin send buffers. Each measurement delivered 256 MiB to 32 containers during four active Go builds. The end-to-end clock includes launching the signed producer and reading the last verified response. Sender CPU measures the producer thread. Socket preparation and the CI burst have separate clocks. [Experiment design](20261124T112946Z-buffers-zp_2q6l5/bridge-plan.json) · [One full transfer](20261124T112946Z-buffers-zp_2q6l5/transfer-hv31.json)

| Guest buffer path | Socket send buffer | Verified MiB/s | Sender CPU-s/GiB | Send calls per 256 MiB |
| --- | ---: | ---: | ---: | ---: |
| Staged copy | 64 KiB | 2,042 | 0.308 | 4,761 |
| Mapped | 64 KiB | 2,168 | 0.293 | 4,814 |
| Staged copy | 512 KiB | 2,397 | 0.189 | 741 |
| Mapped | 512 KiB | 2,319 | 0.174 | 782 |

On the mapped path, the larger send buffer reduced CPU in all eight blocks. Its median paired CPU reduction was **39.7%** and its median paired throughput gain was **8.2%**, with six throughput wins. At equal 512 KiB buffers, direct mapping used 8.4% less sender CPU by paired median and won throughput in three of eight blocks. The producer now uses 512 KiB per socket in its regular 32-flow run. The Linux worker on Gamma still uses Virtualization.framework. These HVF results cover a separate producer sending through the real container ports. [Producer configuration](bridge.py) · [Running Linux worker](20261124T112946Z-buffers-zp_2q6l5/fixtures-before.json)

In the fault window, one container withheld reads, another reset its connection after the first validated frame, and the other 30 verified their complete uploads before the hold was released at 98.2 ms. The held upload verified at 104.7 ms. Across the 33 transport windows, all 1,056 Go builds completed and all 5,429 fresh probes succeeded. [Fault receipts](20261124T112946Z-buffers-zp_2q6l5/transfer-hv32.json) · [Concurrent CI receipts](20261124T112946Z-buffers-zp_2q6l5/wave-hv32-A.json)

## Reproduction and cleanup

From this directory, run `python3 -B qualify.py --profile ci` for build admission, `--profile churn` for one-shot jobs and service turnover, `--profile qos` or `--profile workers` for matched Micropod VMs, and `--profile buffers` for the transport experiment. The driver uses Gamma’s cached ARM64 CI image and the pinned local worker fixture. Each engine receives a new Linux cache volume shared by the jobs in that run. Each profile writes a separate evidence directory. Run `python3 -B replay.py RUN_DIRECTORY` to verify receipts and recalculate results. [Driver](qualify.py) · [Offline verifier](replay.py)

The first smoke attempt stopped at image verification because Micropod’s Docker API omits the optional RootFS field. The corrected check binds the imported manifest to its hashed image configuration and checks layer IDs when the engine exposes them. The next smoke run passed on both engines. The original 6,573.34 MiB/s baseline and its sealed copy matched all 24 hashes. Cleanup checked the owned containers, cache volumes, launchd jobs and VM disk holders. [First attempt](20261124T111707Z-smoke-lgrx7z1f/status.json) · [Successful smoke check](20261124T111818Z-smoke-51pos730/status.json) · [CI cleanup](20261124T111925Z-ci-46cje9m5/cleanup.json) · [Original baseline manifest](../disposable-local-fixture/20261124T101312Z-local-iad8j2_g/preserved/manifest.json)
