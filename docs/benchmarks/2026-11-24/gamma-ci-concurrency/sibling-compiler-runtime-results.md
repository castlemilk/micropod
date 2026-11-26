# Longer compiler time slices on the signed 250 µs CI worker

Giving only Micropod’s compilers a 2.1 ms ordinary Linux scheduler slice reduced its scheduled HTTP p95 and dispatch-to-response p95 in all eight matched windows, by paired medians of 19.76% and 26.08%. The eight builds took 0.24% longer in the paired comparison. With the longer slice Micropod won scheduled p95 in all eight windows and finished the build batch ahead of OrbStack in three. OrbStack still finished the median batch first on both seeds. The packaged 250 µs setting remains the choice validated for general use in this series. [Full replay and seed medians](sibling-compiler-runtime-results.json) · [Earlier packaged-worker holdout](sibling-ci-dispatch-and-scratch-results.md#fresh-holdout-of-the-final-worker)

## What ran

Each engine ran 32 job networks, 64 containers and eight concurrent two-revision Go builds on four vCPUs and 4 GiB. Each of 32 warmed clients offered 3,000 requests over 1.5 seconds. Both the compiler and the service/HTTP tasks of a given job stayed on their home guest CPU. Each builder retained its one-CPU quota. In the control, Micropod’s ordinary processes inherited 250 µs. For the candidate the native launcher requested 2.1 ms through Linux `sched_setattr`, and the build dispatcher and its descendants inherited the setting. OrbStack’s measured resident, HTTP and build tasks inherited 2.1 ms in every boot. The image, signed worker, ext4 cache and native per-builder 128 MiB tmpfs matched the previous affinity trial. These runs used the production Linux worker backend on Apple Virtualization.framework. [Fixture](sibling_compiler_runtime.py) · [CPU affinity comparison](sibling-compiler-affinity-results.md) · [Linux EEVDF scheduler](https://docs.kernel.org/scheduler/sched-eevdf.html)

The two seeds reversed the order of the two treatments. Each fresh Micropod boot provided four paired windows, with each engine going first twice. OrbStack stayed on one guest. Gamma measured 86–93% idle before the four boots. The verifier checked the ordinary slice on all resident processes before and after the run, the actual HTTP issuing threads in every window, each timed dispatcher and its child, and all observed threads of a genuine Go driver and compiler in an independent compile. The latter also verified executable hashes, parentage, network identity, the cgroup limits and successful object creation. [Runtime verifier](sibling_compiler_runtime_results.py) · [Real compiler proof](20261125T033948Z-sibling-compiler-runtime-_upj8ow5/compiler-runtime-tools.json)

## HTTP and build performance

The table gives the median of eight per-window values for each engine. Paired percentage changes compare individual matched windows. The two statistics can differ.

| Native compiler slice | Scheduled p95, Micropod / OrbStack | Scheduled p99, Micropod / OrbStack | Dispatch-to-response p95, Micropod / OrbStack | Eight builds, Micropod / OrbStack | Both scheduled p95 and build time lower on Micropod |
| --- | ---: | ---: | ---: | ---: | ---: |
| Inherit 250 µs | 2.353 / 3.288 ms | 5.854 / 7.066 ms | 830 / 272 µs | 2.910 / 2.886 s | 1/8 |
| Request 2.1 ms | 1.682 / 3.050 ms | 5.792 / 6.085 ms | 636 / 247 µs | 2.920 / 2.881 s | 3/8 |

The native median build times on the long-slice seeds were 2.943 s and 2.901 s, against 2.883 s and 2.874 s for the peer. Against its own matched control, Micropod’s scheduled p95 improved 29.75% on one seed and 18.37% on the other. Build time moved +0.51% and −0.14%. OrbStack also recorded a 12.36% lower paired scheduled p95 and a 0.15% longer build time between these boots with its policy fixed. Taking the median of the eight changes in the Micropod-to-OrbStack p95 ratio gave an 11.22% reduction. Micropod’s paired scheduled p99 fell 0.81%, while the peer’s fell 23.03%. [Per-window measurements](sibling-compiler-runtime-results.json)

Across both engines, all 3,072,000 scheduled requests completed on 1,024 warmed connections. The 256 builds produced 512 revisions and passed 4,096 workload tests. Every response finished while all eight builds were still in progress, with a minimum margin of 1.151 s. In the longer-slice arm 44 of 64 individual Micropod jobs finished their work in less time than their matched peers. The last two Micropod jobs shared one home CPU in all eight windows. No tracked cgroup reported quota throttling across 13,321 observed periods. The median paired increase in the last finisher’s excess over the typical job duration was 7.5 ms. [Individual build timelines and cgroup accounting](sibling-compiler-runtime-tail.json)

## Host instructions and cycles

On both engines the Mac profiler read XNU’s per-thread retired-instruction, cycle and execution-time counters around the build waves. After all timed work, a pinned guest program ran a fixed 18-instruction arm64 loop with two iteration counts in reversed order. The long loop added exactly 283,115,520 instructions over the short one. Across eight engine/boot combinations, the corresponding host vCPU counters reported 93.37–107.78% of that difference. A separate SHA-256 workload checked the guest-to-host thread numbering on all four CPUs in each boot. These calibration results allow the counters to describe work on the vCPU threads, which includes guest workloads and VMM overhead. [Assembly loop](vcpu-instructions/work_arm64.s) · [Calibrated host measurements](sibling-compiler-runtime-host-vcpu.json) · [Apple XNU resource accounting](https://github.com/apple-oss-distributions/xnu/blob/main/doc/observability/recount.md)

The four Micropod vCPU threads together used 11.406 CPU-seconds and retired 117.69 billion instructions in the median inherited-slice bracket, versus 11.423 CPU-seconds and 118.31 billion instructions with long compiler slices. The comparable OrbStack figures were 11.390 / 11.364 CPU-seconds and 116.50 / 116.87 billion instructions. These brackets include launch and drain. Micropod’s median instruction count and total vCPU time both stayed within 1% of their control values while its HTTP latency fell. Attributing retired instructions to individual Go processes would require per-process guest counters. [Host replay](sibling_compiler_runtime_counters.py)

## Running the compiler setting as an ordinary user

The same static Linux arm64 launcher that ran the timed builds is available in the local worktree. Its SHA-256 is `d6831d27afcb8d60c605fc2b03912a06d6219926db2b0a9254365cce4d09a5a8`. Package it in the job image or mount it read-only at `/mpcheck/compiler-runtime`. Prefix the build command to limit the custom slice to that process tree. [Local binary and source receipt](sibling-compiler-runtime-launcher.json) · [Measured launcher source](20261125T033948Z-sibling-compiler-runtime-_upj8ow5/sibling_compiler_runtime_linux.go)

```sh
/mpcheck/compiler-runtime -policy normal -build-slice-us 2100 /usr/local/go/bin/go build ./...
```

Two additional disposable workers verified the setting as UID 65534. The four UID fields matched, effective, permitted and ambient capabilities were zero, and `NoNewPrivs` was set. On the second boot the launched shell and its separately identified child each read back `SCHED_OTHER`, nice 0 and exactly 2,100,000 ns from the kernel. The ordinary control, invoking shell and resident service read 250,000 ns. All observations used the same container cgroup, CPU mask and one-CPU quota. The pinned image’s util-linux 2.38.1 rejected `chrt -o -T 2100000` with exit 1 because it restricts that option to deadline scheduling. [First ordinary-user check](20261125T035539Z-sibling-cgroup-y8fy3c8u/cgroup-hierarchy-stock.json) · [Separate shell and child readbacks](20261125T035821Z-sibling-cgroup-zcu8b52w/cgroup-hierarchy-stock.json)

## CPU sharing across job pairs

The two untimed workers also exposed the live cgroup v2 tree. These boots used the native CPU-group label to assign a singleton CPU set to each container. The eight builders in the timed slice study had a four-CPU cgroup with their processes pinned to their home CPU. Both arrangements kept the one-CPU limit. The diagnostic matched all 64 container-local cgroup inodes to distinct leaves in the worker’s cgroup mount, then verified the resident processes by start time, PID namespace and command. All 32 service/client pairs shared the same direct scheduler parent, `/k8s.io`, which had weight 100 and no local quota. Each measured container leaf had weight 100 and `cpu.max` of `100000 100000`. The parent had 128 direct children in the snapshots. The identity checks covered the 64 workload leaves. The CPU-group label gave job partners a common vCPU with eight pairs and two builders assigned per CPU. [First topology](20261125T035539Z-sibling-cgroup-y8fy3c8u/cgroup-hierarchy.json) · [Second worker’s raw tree and CPU limits](20261125T035821Z-sibling-cgroup-zcu8b52w/cgroup-hierarchy-tree.json)

## Failures, review and cleanup

The first setup’s observer rejected a dispatcher parent PID of zero. The container PID namespace hid its external supervisor. Both engines’ real Go and compiler processes had the required positive parent IDs and exact child links. All 16 original witnesses passed the corrected observer. That setup produced zero timed windows and its owned worker resources were removed. Another attempt detected an unrelated OrbStack workload before allocating a worker. The series resumed at the original seed. A separate review altered copies of real receipts in memory. The scorer rejected a short-slice compiler child, an explicit peer request equal in value to its inherited slice, a 1 ns change to the offered schedule, a missing response and an ordinary service taking the compiler slice. [Rejected setup](20261125T033447Z-sibling-compiler-runtime-qwzxfnny/status.json) · [Admission refusal](20261125T033650Z-sibling-compiler-runtime-4tcvqvun/status.json) · [Adversarial replay](sibling-compiler-runtime-adversarial-review.json)

The cleanup audit checked 220 allocated worker scopes after the timing runs and 222 after the ordinary-user and hierarchy checks. It found zero owned worker directories, launchd jobs, OrbStack containers, volumes or networks. All 24 original baseline files and 24 preserved copies verified against their original SHA-256 hashes. [Timing-run cleanup](sibling-compiler-runtime-cleanup.json) · [Final cleanup and baseline audit](sibling-cgroup-hierarchy-cleanup.json)

Replay the four scored archives from this directory with

```sh
python3 -B sibling_compiler_runtime_results.py \
  20261125T033812Z-sibling-compiler-runtime-7d1adf08 20261125T033948Z-sibling-compiler-runtime-_upj8ow5 \
  20261125T034123Z-sibling-compiler-runtime-jyeuc83r 20261125T034257Z-sibling-compiler-runtime-bs0ctd63
```
