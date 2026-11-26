# Scheduled HTTP and build scratch on a dense Gamma worker

Each engine ran 32 client containers and 32 service containers on four vCPUs and 4 GiB. Eight of the clients built, tested, vetted and ran two Go revisions at ordinary priority. During each 1.5-second offer window the clients scheduled exactly 96,000 HTTP calls across 32 warmed sockets and retained every late response. The worker used the 16 KiB Linux Image, internal IPvlan networking, high-resolution scheduler ticks and next-buddy wakeups. OrbStack used the same container images and per-job CPU assignments on its warmed four-vCPU guest. The tables give Micropod first and OrbStack second. [Benchmark client and clocks](sibling-wakeup-and-offered-load-results.md#matching-the-offered-request-rate)

## Guest CPU slice and response time

A longer Linux fair-scheduler slice let the HTTP exchanges that had already started finish more quickly. The waiting clients on the same vCPU could fall far behind their assigned send times. With a 2.1 ms base slice, Micropod’s measured dispatch-lateness p95 reached 279.35 ms. Counting time only after dispatch produced a p95 of 62 µs. Each row below has eight paired windows from two fresh Micropod boots. The 125 µs and 2.1 ms pair and the 500 µs and 1 ms pair ran in separate counterbalanced sequences.

| Setting | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| 125 µs | 1.41 / 3.22 | 4.94 / 8.14 | 675 / 253 | 3.081 / 2.898 |
| 500 µs | 9.95 / 3.14 | 28.52 / 6.32 | 224 / 255 | 2.908 / 2.920 |
| 1 ms | 34.88 / 3.16 | 72.14 / 6.31 | 121 / 254 | 2.833 / 2.862 |
| 2.1 ms | 279.86 / 3.26 | 378.23 / 6.99 | 62 / 268 | 2.594 / 2.890 |

The 125 µs setting beat OrbStack on scheduled arrival p95 in all eight windows. The 2.1 ms setting beat OrbStack on call p95 in all eight and build completion in seven. Relative to Micropod’s 125 µs setting, the 2.1 ms setting shortened the build makespan by a median paired 18.1%. The individual high-resolution tick and next-buddy settings, the guest and kernel, and all other plan fields were checked across the two arms. [125 µs and 2.1 ms replay](sibling-paced-native-base-slices.json) · [500 µs and 1 ms replay](sibling-paced-middle-base-slices.json)

## Separate internal networks for 32 CI jobs

Both engines used the same reserved IPv4 range. The control put all 64 containers on one /23. The other arm gave each job its own /28, internal IPvlan network and exactly two endpoints. The inventory checked every network ID, subnet, container, interface type and assigned IP against Docker inspect and guest netlink. The measured requests used the private service IP and verified its response marker. Native placement still assigned eight pairs and two builds per vCPU. The two engines mirrored each assignment within a boot. Between network configurations, nine pair assignments changed vCPU on one seed and ten on the other.

| Setting | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| One network | 1.61 / 3.49 | 6.17 / 7.79 | 715 / 275 | 3.097 / 2.908 |
| 32 job networks | 1.70 / 3.53 | 5.46 / 8.77 | 710 / 280 | 3.093 / 2.919 |

On 32 job networks, Micropod won scheduled arrival p95 and finished draining the calls sooner in all eight windows. OrbStack had lower post-dispatch p95 in all eight and finished the builds sooner in seven. Comparing only Micropod, the change in topology moved arrival p95 and p99 in each direction in four of the eight paired windows. Creating the 32 networks sequentially took 0.464 s on Micropod and 0.709 s on OrbStack, medians of the two host-side CLI timings per engine. [Network replay and placement by boot](sibling-paced-job-networks.json) · [Network membership check](sibling_topology.py)

## Shortening only the HTTP clients’ CPU slices

The services, listeners and builders used the 2.1 ms base slice on both engines. Only Micropod’s HTTP clients requested the shorter slice. The observer recorded the issuing Linux thread ID before each timed gate, verified every client thread’s affinity and slice, and read the build dispatcher and child scheduler state. The underlying Go HTTP request and pacing loop were identical in the two arms. [Issuing-thread proof](sibling_client_slice.py)

| Setting | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| Inherit 2.1 ms | 252.82 / 3.46 | 385.43 / 8.18 | 75 / 291 | 2.642 / 2.943 |
| Micropod HTTP clients at 250 µs | 1.95 / 3.80 | 6.38 / 10.91 | 549 / 316 | 3.083 / 3.073 |
| Micropod HTTP clients at 500 µs | 3.57 / 3.55 | 16.51 / 8.24 | 389 / 299 | 2.953 / 2.976 |
| Micropod HTTP clients at 750 µs | 19.97 / 3.47 | 49.81 / 7.71 | 277 / 289 | 2.881 / 2.980 |

Micropod’s 250 µs HTTP clients beat OrbStack on arrival p95 and p99 in all eight windows. The two engines split build completion four to four, and OrbStack had lower dispatch-to-response p95 in all eight. The shortest observed gap between the last HTTP completion and the first build exit was 1.298 s in this arm. [Matched client-slice replay](sibling-paced-native-client-slices.json)

The 500 and 750 µs client slices ran as a second matched pair. At 750 µs Micropod finished builds first in all eight windows and had lower call p95 in five. Its scheduled-arrival p95 and p99 were higher than OrbStack's in all eight. These per-process settings were exercised by the benchmark HTTP client. The packaged worker's scheduler setting applies across the guest. [500 and 750 µs replay](sibling-paced-longer-native-client-slices.json)

## Native compiler scratch

The previous signed worker rejected `micropod ci run --scratch-mib 128` with Docker exit 125. With the updated Linux runner, the same Mac executable and CLI command returned zero, ran a program from a private 128 MiB tmpfs at `/tmp` and removed the one-shot container. The native worker now adds a typed tmpfs mount to the new container's OCI specification between CRI create and start. It checks the container ID, sandbox and spec type, and updates only the spec field. The bundled containerd task service reads the stored spec when it creates the task. [Previous worker](sibling-native-scratch-previous-worker.json) · [Package identities](sibling-native-scratch-product.json) · [Public command and result](20261125T013856Z-sibling-65h3k62p/go-scratch-cli.json) · [Pinned containerd task service](https://github.com/containerd/containerd/blob/b7a25261e029d68978bbf290df0a62fc819b3c51/plugins/services/tasks/local.go#L160)

Two starts of the same container each saw an empty directory, enforced read-only and no-exec mounts, and charged at least 4 MiB of written pages to that container's memory cgroup. Leaving a mount's size unspecified gave it half the guest's reported memory to within one guest page. In the timed scratch arm all eight builds had their own 128 MiB tmpfs, a 512 MiB container limit, and the same persistent ext4 compiler cache mounted at `/cache`. OrbStack used its ordinary writable layers and shared cache in every arm. [Restart and memory measurements](20261125T013856Z-sibling-65h3k62p/go-scratch-restart.json) · [Live builder mounts](20261125T013856Z-sibling-65h3k62p/go-scratch-before.json) · [Docker tmpfs options](https://docs.docker.com/engine/storage/tmpfs/)

One 250 µs overlay boot failed to start the second HTTP client's `docker exec` before its third dense window. The other 31 clients warmed their sockets and waited for the gate. Zero timed requests ran in that window. Containerd logged the error in crun's exec startup pipe, and the resident container continued running until explicit cleanup 34 seconds later. The retained log omits the pipe read's return value and errno, leaving the underlying cause unresolved. A fresh boot completed that same treatment and seed. The fixture now records the first observed pre-gate failure and retains every response. [Incident and cleanup evidence](20261125T014608Z-sibling-cy8pkcep/startup-incident.json) · [Replacement result](20261125T014950Z-sibling-ctwv8j9_/status.json) · [Barrier regression test](test_sibling_ci_gate.py)

## Packaged worker on 32 job networks

Four seeds rotated all four configurations through the boot order. Each configuration started four fresh Micropod VMs, with four paired HTTP and build windows per boot. Within each boot, each engine ran first twice. The same signed Mac executable, native guest runner, 16 KiB kernel, images and workload served all four configurations. OrbStack stayed on one warm guest with overlay scratch. The rows show medians across the 16 paired windows for each configuration.

| Guest CPU slice and native build scratch | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| 125 µs, overlay | 1.952 / 3.558 | 6.341 / 7.696 | 809 / 298 | 3.234 / 2.989 |
| 125 µs, tmpfs | 1.803 / 3.546 | 5.313 / 7.328 | 760 / 309 | 3.147 / 2.992 |
| 250 µs, overlay | 1.878 / 3.598 | 5.320 / 7.587 | 666 / 299 | 3.068 / 3.005 |
| 250 µs, tmpfs | 1.892 / 3.388 | 4.786 / 6.659 | 716 / 294 | 3.043 / 2.993 |

At 125 µs, putting only the eight compilers' scratch on tmpfs cut Micropod's paired build time by 2.5%, arrival p95 by 12.5% and arrival p99 by 21.7%. Builds finished sooner in 13/16 windows and all four seed medians improved. At 250 µs the same scratch change cut paired build time by 0.5%, with nine wins in 16 windows. [Tmpfs at 125 µs](sibling-paced-packaged-go-scratch-125us.json) · [Tmpfs at 250 µs](sibling-paced-packaged-go-scratch.json)

With tmpfs fixed, increasing the slice from 125 to 250 µs cut Micropod's paired build time by 3.3% in aggregate and shortened it in every window. Against OrbStack, the 250 µs tmpfs worker won arrival p95 in 16/16 and p99 in 12/16. OrbStack had lower call p95 in all 16 and finished the builds first in 12. On overlay alone, changing the slice cut paired Micropod build time by 5.3%, with faster builds in three of four seed medians. [Slice change on tmpfs](sibling-paced-packaged-250us-tmpfs.json) · [Slice change on overlay](sibling-paced-packaged-250us.json)

The two engines mirrored CPU assignments within each boot. On each vCPU there were eight pairs and two builds. Across treatments, 8–22 individual pair assignments changed vCPU. Before-boot host idle ranged from 79% to 91%. OrbStack's median of boot-level arrival p95 values was 3.448 ms in the first half and 3.447 ms in the second. Across the 64 paired windows, Micropod won scheduled-arrival p95 in 63 and p99 in 53. OrbStack won dispatch-to-response p95 in all 64 and builds in 59. Even the last response preceded the first of the eight builds finishing by at least 1.24 s. [Placements, boot order, build overlap and paired scores](sibling-paced-packaged-250us.json) · [Tmpfs placements and paired scores](sibling-paced-packaged-250us-tmpfs.json)

## Fresh holdout of the final worker

Review found that a Docker stop waiting on one container runtime could follow the same container into its next start. The runner now follows the exit count of the generation it first observed. A deterministic Linux regression held the original stop open across a restart and checked that the replacement kept running. The only inputs that changed from the factorial package were the runner's Docker engine and its test. The signed Mac executable and guest startup script matched byte for byte. All four holdout VMs passed the generation regression and the three scratch tests. [Final package receipt](sibling-native-scratch-holdout-product.json) · [Tests on a real ARM64 Linux guest](20261125T020606Z-sibling-apbjlovh/linux-docker-scratch-tests.txt)

Two new seeds reversed the order of the 125 µs overlay and 250 µs tmpfs treatments. Each row has eight paired windows across two fresh Micropod boots.

| Final worker configuration | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| 125 µs, overlay | 1.851 / 3.496 | 5.435 / 7.002 | 763 / 317 | 3.223 / 2.973 |
| 250 µs, tmpfs | 1.902 / 3.266 | 5.421 / 6.185 | 685 / 297 | 3.033 / 2.976 |

The combined change cut paired Micropod build time by 5.66%, improving every matched window. Within Micropod its arrival p95 split four windows each, with a median paired change of −0.09%. Against the contemporaneous OrbStack peer, the 250 µs tmpfs worker won arrival p95 in all eight windows and p99 in five. OrbStack won post-dispatch p95 in all eight and build time in seven. [Holdout replay, job outputs and paired results](sibling-paced-native-scratch-holdout.json)

Micropod recorded shorter individual job durations in 38 of the 64 matched slots. The median of the eight within-window median job durations was 2.903 s for Micropod and 2.956 s for OrbStack. Micropod also started the eight jobs closer together, with an 8 ms spread versus 15 ms. The spread between the first and last finishes was 176 ms versus 30 ms, and six different Micropod job slots finished last across the eight windows. The last finisher's own duration exceeded the median job's by 118 ms on Micropod and 18 ms on OrbStack. Build outputs, tool counts and vCPU assignments matched slot by slot. The cgroup CPU counters also include the concurrent HTTP workload, so the cause of the longer finishing tail remains open. [Per-job timestamp replay](sibling-native-build-tail-holdout.json) · [Arithmetic and slot checks](sibling_build_tail_results.py)

In all eight Micropod windows the two last jobs shared one guest vCPU. That occurred in six OrbStack windows. Averaging each vCPU's two finish times and then comparing the fastest and slowest vCPU gave a median spread of 132 ms on Micropod and 25 ms on OrbStack. Three of the four Micropod vCPUs finished last at least once. These are guest CPU assignments. The captures did not record which physical Mac core ran each vCPU. [Finishing pairs and vCPU counts by seed](sibling-native-build-tail-holdout.json)

The same combined change in the earlier four-seed factorial cut paired build time by 5.0% in 16/16 windows. Its scheduled-arrival p95 split eight wins each and changed by −0.4% on the paired measure. A subsequent four-boot study compared fixed and pooled compiler CPU placement while measuring the Mac's vCPU threads. [Combined factorial comparison](sibling-paced-packaged-combined.json) · [Compiler CPU affinity and host execution](sibling-compiler-affinity-results.md)

The full Linux runner test binary matched the SHA-256 recorded in all four holdout VMs. In an isolated ARM64 Linux container it passed 47 tests by default and 48 with its local port-recovery fixture enabled. The separate Netavark fanout benchmark requires its own disposable network fixture. [Full runner suite and binary identity](sibling-final-linux-runner-tests.json)

To reproduce the final holdout comparison from this directory, run

```sh
python3 -B sibling_paced_results.py --contrast scheduler-and-scratch \
  --compare-to 20261125T020730Z-sibling-x58wry_k 20261125T020854Z-sibling-iuewn64t \
  --pool 20261125T020606Z-sibling-apbjlovh 20261125T021018Z-sibling-obzjjzpy
```

## Where requests spent their time

For each socket, the replay split a request's scheduled latency at the previous response's completion, actual dispatch, connection acquisition, request write, first response byte and completion. It checked that those intervals added to the observed latency for every request, including calls that finished after the 1.5-second offer window. Across the two global 2.1 ms boots, 99.73% of elapsed time in Micropod's slowest 1% of responses came from the preceding request still occupying the socket at the new request's due time. This percentage is the median of eight window-level time shares. The median window maximum for additional wait after the socket became available was 4.98 ms, while scheduled-arrival p95 was 279.86 ms. [Per-call accounting and tail shares](sibling-paced-dispatch-delay-breakdown.json) · [Replay implementation](sibling_paced_delay_results.py)

On the final 250 µs tmpfs worker the same carryover accounted for 89.2% of elapsed time in Micropod's slowest 1% and 83.4% of OrbStack's. For requests issued by the eight compiling containers, arrival p95 was 2.37 ms on Micropod and 5.71 ms on OrbStack. For the other 24 clients it was 1.77 and 2.36 ms. The median window's worst individual client p95 in those respective groups was 4.63 and 3.52 ms on Micropod, versus 6.77 and 2.78 ms on OrbStack. [Separate replay for build and non-build clients](sibling-paced-dispatch-delay-breakdown.json)

Across the 40 scored boots in the scheduler, network and scratch studies, both engines together completed all 30,720,000 offered requests, 2,560 two-revision Go jobs and 40,960 workload tests. Across all 320 engine windows, the smallest gap between the last response and the first build exit was 162 ms. Gamma's observed idle level before these boots ranged from 78% to 94%. The measurements used the persistent CI worker on Apple Virtualization.framework. [Coverage by boot](sibling-ci-dispatch-scratch-coverage.json) · [Separate Hypervisor.framework transport measurement](results.md#hypervisorframework-with-32-independent-receivers)

## Issuing-thread scheduler trace

Two additional instrumented boots followed one compiling client and one ordinary client in the full 32-pair, eight-builder workload. The first capture attempt per profile wrote clock markers but matched zero scheduler events. The worker's procfs and ftrace expose different numeric thread IDs across the outer PID namespace. The corrected capture gave each traced issuing thread a unique Linux task name, verified its identity through procfs, and independently resolved its kernel trace ID from scheduler events. Both traces used the guest monotonic clock at 1 µs output resolution and reported zero dropped events and zero buffer overruns on all four vCPUs. [Initial captures](sibling-dispatch-trace-initial-attempts.json) · [Corrected capture and replay](sibling_dispatch_trace.py) · [Verified scheduler intervals](sibling-paced-issuing-thread-states.json)

Of 2,999 due times after startup, the compiling client already had a prior response outstanding at 2,914 on the 2.1 ms worker and 1,218 on the 125 µs worker. For the ordinary client those counts were 1,590 and 939. The largest fresh dispatch delay after startup on the coarse worker was 518 µs for the compiling client, including 461–465 µs runnable, and 645 µs for the ordinary client, including 586–590 µs runnable. The shorter-slice worker still had an individual fresh dispatch as long as 1.52 ms. The trace observes wakeups and scheduling state. Which fair-scheduler rule selected a competing task and whether the waiting thread was eligible for that selection remain open. [Raw 2.1 ms trace](20261125T022107Z-dispatch-trace-2307mi1s/dispatch-trace.ftrace.gz) · [Raw 125 µs trace](20261125T022200Z-dispatch-trace-m2igqyp0/dispatch-trace.ftrace.gz)

## Filesystem block size for the compiler cache

Four fresh boots compared 4 KiB and 16 KiB ext4 blocks under the common `/cache` on Micropod. Both formats used private 512 MiB loop-backed volumes on the same type of 4 KiB guest root disk, a 16 MiB journal, ordered writes and ordinary flushes. Both arms ran the 125 µs CPU slice and overlay scratch. Creating the CPU groups in a fixed order also kept every job mapped to the same vCPU across treatments and engines. Two separate one-wave smoke boots verified the filesystems first. The selected formats produced identical Go artifacts, compile/vet/link action counts and 603 final Go cache data objects containing 114,963,231 logical bytes. [Paired smoke boots](sibling-compiler-cache-blocksize-smoke.json) · [Full cache, loop and cgroup measurements](sibling-compiler-cache-blocksize.json) · [Guest formatting and retirement](sibling_ext4_cache_guest.sh)

| Native cache format | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) |
| --- | ---: | ---: | ---: | ---: |
| 4 KiB blocks | 3.344 / 3.978 | 12.851 / 9.889 | 955 / 418 | 3.492 / 3.186 |
| 16 KiB blocks | 2.283 / 3.936 | 8.775 / 10.815 | 894 / 370 | 3.401 / 3.153 |

Micropod's paired build time fell 2.92% across eight windows, with six wins and improvements of 2.95% and 2.92% in the two seed medians. The reference engine's paired build time fell 1.45% across those same boots. Micropod's arrival p95 fell in six windows, a median paired 31.6%. Its p99 also fell in six windows but varied by seed, improving 60.0% in one and worsening 8.0% in the other. The 16 KiB Micropod cache kept arrival p95 below OrbStack's in seven windows, and OrbStack finished builds sooner in all eight. [Measured window pairs](sibling-compiler-cache-blocksize.json)

The wider blocks reduced measured system CPU in the eight builder containers by a paired 5.22%, including their HTTP client and listener work. The same logical cache occupied about 174.3 MiB at 16 KiB versus 141.5 MiB at 4 KiB, 23.2% more allocated space. Through clean unmount, cumulative writes to the virtual loop device increased from 136.8 to 193.7 MB in one seed and from 136.4 to 201.6 MB in the other. These include delayed writeback and filesystem metadata. Physical Mac storage traffic was outside the loop counters' scope. [First 16 KiB superblock](20261125T022629Z-sibling-ext4-lqkrpudi/ext4-cache-final-superblock.txt) · [Matched 4 KiB superblock](20261125T022458Z-sibling-ext4-zu1_22iu/ext4-cache-final-superblock.txt) · [All four loop, sync and unmount counters](sibling-compiler-cache-blocksize.json)

Two early attempts contributed no scores. The first frozen benchmark bundle omitted the Go affinity helper. The next attempt completed its workload, but the controller still held the private communication mount during teardown. The corrected fixture snapshots its Python, Go and shell sources together, waits for the controller to exit and verifies unmount and loop-device retirement. Both early workers were removed. [Missing-source receipt](20261125T021513Z-sibling-ext4-p08lk59a/status.json) · [Teardown receipt](20261125T021550Z-sibling-ext4-kwc6gjxf/status.json)

## Compiler-cache block size with the 250 µs worker and private scratch

Four more fresh boots repeated the loop-backed comparison on the final 250 µs worker. Each Micropod builder had its own executable 128 MiB tmpfs, a 512 MiB memory limit and access to the same persistent compiler cache as its seven siblings. OrbStack kept its ordinary scratch and cache. Independent replay matched the same 603 final Go data objects, totaling 114,963,231 bytes, under both formats on both engines. All 3,072,000 offered requests completed with all eight builds still running. The smallest gap from the last response to the first build exit was 1.254 s. Before-boot host idle ranged from 84% to 89%. [Plans, images and window results](sibling-compiler-cache-blocksize-250us-tmpfs.json)

| Native cache format | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) | Windows with Micropod ahead on both builds and arrival p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 4 KiB blocks | 1.727 / 3.554 | 4.429 / 7.159 | 689 / 289 | 3.056 / 3.002 | 2/8 |
| 16 KiB blocks | 1.868 / 3.201 | 4.626 / 6.731 | 715 / 280 | 3.032 / 2.970 | 1/8 |

Increasing the block size cut Micropod’s paired build time 1.30%, with five wins in eight windows. The seed medians fell 1.56% and 0.73%. The reference engine built 0.86% faster between the same boots. Dividing each Micropod-to-peer build ratio at 16 KiB by the matched ratio at 4 KiB yielded a median improvement of 0.23%. Micropod’s own scheduled p95 rose 6.26%, worsening on both seeds. Its p99 rose 10.95%. The larger blocks occupied 23.2% more space in both seeds. Writes through unmount rose from 136.6 to 195.9 MB in one seed and from 135.5 to 198.2 MB in the other. The wider cache remains a fixture option. The production worker and ordinary cache volume were measured separately, with different job assignments and storage instrumentation. [Matched cache and CPU measurements](sibling-compiler-cache-blocksize-250us-tmpfs.json) · [Ordinary-volume holdout](#fresh-holdout-of-the-final-worker)

To replay the combined cache comparison from this directory, run

```sh
python3 -B sibling_ext4_cache.py compare \
  20261125T023826Z-sibling-ext4-x1h12ief 20261125T023955Z-sibling-ext4-u8fd2p_c \
  20261125T024124Z-sibling-ext4-isrs1ele 20261125T024253Z-sibling-ext4-vr48o_9m
```

The Apple Containerization version used by the worker also supports mounting a separate host-backed ext4 image on a virtio block device. Its integration suite exercises this attachment. A Micropod trial would require a worker-owned image whose identity and contents survive a normal stop and restart. The block-size measurements above used a guest loop device on the existing worker disk. A separate virtio attachment has no measured Micropod performance result here. [Worker VM setup](../../../../Sources/MicropodRuntime/SandboxVM.swift) · [Pinned Apple integration suite](https://github.com/apple/containerization/blob/c0185aea5c04fcd4d1cfe9359e0066a380835403/Sources/Integration/ContainerTests.swift) · [Apple virtio block device](https://developer.apple.com/documentation/virtualization/vzvirtioblockdeviceconfiguration)

## A 350 µs guest CPU slice on the ordinary compiler cache

The signed worker started with its 250 µs setting and next-buddy wakeups in all four fresh boots. Before serving jobs, a trusted fixture wrote either 250,000 or 350,000 ns to the guest scheduler and read it back. A read-only probe confirmed the same value, boot and scheduler features after the last window. The 32 client–service pairs kept the same vCPU assignments in both treatments and engines. Eight builders used private tmpfs scratch and the worker's ordinary named cache. Gamma was 85–94% idle before these boots. All 3,072,000 offered requests completed at least 1.140 s before the first build exited in their window. [Worker, scheduler, placement and paired results](sibling-native-base-slice-350us.json) · [Trusted readback fixture](sibling_slice_350.py)

| Effective guest CPU slice | Scheduled arrival p95 (ms) | Scheduled arrival p99 (ms) | Dispatch to response p95 (µs) | Eight builds (s) | Windows with Micropod ahead on both builds and arrival p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 250 µs | 1.379 / 3.090 | 5.231 / 6.051 | 492 / 248 | 2.861 / 2.821 | 2/8 |
| 350 µs | 2.169 / 3.069 | 12.710 / 6.238 | 284 / 254 | 2.867 / 2.884 | 4/8 |

The 350 µs worker won five of eight paired build windows and six of eight scheduled-p95 windows. It won both metrics in one of four windows on the first seed and three of four on the second. Before the trial, the criterion for adding a packaged 350 µs setting was beating the peer's median on both metrics for both seeds. The first seed's build medians were 2.866 s for Micropod and 2.852 s for OrbStack. The second seed's were 2.888 s and 2.911 s. The 350 µs setting remains experimental. [Both seeds and simultaneous wins](sibling-native-base-slice-350us.json)

Comparing the two Micropod treatments within matched windows, the 350 µs slice reduced post-dispatch p95 by 43.3%. Scheduled p95 rose 32.3% and p99 rose 137.5%. Build time rose 0.33%, while the reference engine's build time rose 2.59% across the same boots. Pooled engine medians alone would overstate the benefit of the longer slice. [Raw-replay scoring and paired ratios](sibling_slice_350_results.py)

At 350 µs, 56 of 64 individual Micropod jobs took less time than their matched OrbStack jobs. The median paired advantage was 109 ms. Micropod's first and last job finishes were separated by 164 ms versus 43 ms for OrbStack. Against Micropod’s own 250 µs control, the typical job shortened by a paired 44 ms. The spread between the mean finish times on the four guest vCPUs increased in all eight matched windows, while the spread within each vCPU's pair decreased in all eight. At 350 µs, the final two Micropod jobs shared one vCPU in every window. [250 µs job timelines](sibling-native-build-tail-knee-250us.json) · [350 µs job timelines](sibling-native-build-tail-knee-350us.json)

The first control attempt ended before a timed wave because the minimal HTTP image lacked `cat`. The fixed observer reads the boot ID from the existing static netbench probe mounted in each client. The failed VM and all four scored VMs were removed. [Pilot failure](20261125T025432Z-sibling-slice350-r7xxsz1u/status.json) · [Pilot cleanup](20261125T025432Z-sibling-slice350-r7xxsz1u/cleanup.json) · [All audited worker scopes and baseline hashes](sibling-ci-dispatch-scratch-cleanup.json)

To replay the four boots from this directory, run

```sh
python3 -B sibling_slice_350_results.py \
  20261125T025758Z-sibling-slice350-v3yjhpq1 20261125T025921Z-sibling-slice350-_jxmsarh \
  20261125T030047Z-sibling-slice350-dcnyt1po 20261125T030213Z-sibling-slice350-da3ouh_n
```
