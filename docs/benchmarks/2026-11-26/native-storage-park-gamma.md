# Idle storage workers and mounted CI on Gamma

Micropod's native HVF engine used 36% less host CPU while eight containers were idle after the block and VirtioFS workers began sleeping until a queue notification. The warm 1,058-file Git/build/test job took 912 ms with either VMM. OrbStack completed the same job in 665–666 ms. The two results measure different parts of a CI runner's workload. [Scorecard](native-storage-park-gamma.json) · [Raw measurements, source patches and cleanup](native-storage-park-gamma-receipts.tar.gz)

## Idle worker cost

The managed machine had four vCPUs, a 4 GiB guest, two VirtioFS threads and one block thread. Each arm started eight identical, network-disabled Alpine sleepers and sampled the VMM over three consecutive eight-second windows. Host CPU idle was 90.0% on the control and 89.3% on the candidate. The figures below are medians of the three rates. Each column describes one running VMM. [Sampler, Mach clock calibration and per-window counters](native-storage-park-gamma-receipts.tar.gz)

| Host measurement per second | 5 ms timer | Event-driven wait |
|---|---:|---:|
| VMM context switches | 994.94 | 572.40 |
| VMM Unix system calls | 1,295.49 | 889.00 |
| VMM Mach system calls | 141.61 | 141.70 |
| VMM interrupt wakeups | 842.80 | 420.30 |
| VMM host CPU time | 11.041 ms | 7.071 ms |
| CPU time on the three named storage threads | 2.521 ms | 0.000 ms observed |

The block and filesystem workers formerly set a 5 ms deadline each time they waited on an empty queue. Both already enable guest kicks, issue a full memory barrier and read the available index again before sleeping. The MMIO kick handler sets the pending flag under the same mutex as the condition-variable wait. The candidate removes the idle deadline and keeps the active spin periods of 30 µs for block and 150 µs for VirtioFS. Queue setup, snapshot resume and shutdown signal the workers. A native regression test submits 96 requests to each backend, including after idle gaps and across snapshot pause/resume, and verifies the returned block data or FUSE reply. All 50 Virtio tests passed. [Block transport and regression test](../../../vmm/crates/vmm-virtio/src/lib.rs) · [VirtioFS worker](../../../vmm/crates/vmm-virtio/src/virtiofs.rs) · [Virtio split-ring notification ordering](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)

XNU reports task CPU in Mach absolute ticks and individual thread CPU in nanoseconds. On Gamma the task conversion was 125/3 ns per tick. A separate 75.001 ms process CPU measurement yielded 75.040 ms after conversion. The raw sampler's top-level `cpu_ns` field contains the original task ticks. The values in the table include the conversion. [XNU task and thread accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c) · [Calibration and raw samples](native-storage-park-gamma-receipts.tar.gz)

## Active CI and wakeup checks

Each VMM used the same signed CLI, Linux 7.3.5 kernel with the splice backport, initrd, a8a2 native containerd runner and checkout image. Both arms enabled the gated live-read policy for the writable host workspace. The public Docker socket ran stock Git, a Go build and three uncached test subprocesses on a raw host bind with two CPUs and 1,536 MiB per job. Each arm ran four alternating pairs against OrbStack. Times sum measured work inside the guest. Host CPU idle during scoring was 79.69% and 79.50% respectively. These are ambient samples. [Workload and per-pair receipts](native-storage-park-gamma-receipts.tar.gz)

| VMM | Warm HVF / OrbStack | After a host edit, HVF / OrbStack | HVF paired wins, warm / edited |
|---|---:|---:|---:|
| Timer, 08ad6edf752e | 912.5 / 665.3 ms | 2,109.9 / 2,017.8 ms | 0/4 · 0/4 |
| Event-driven, 4b25f7d3ae9a | 912.2 / 666.2 ms | 2,088.7 / 1,958.2 ms | 0/4 · 0/4 |

In the event-driven arm, warm Git alone took 176.9 ms on Micropod and 54.3 ms on OrbStack. Warm build medians were 402.4/356.2 ms and test medians were 328.6/250.9 ms. Each phase has its own median. On the control VMM, Git's trace assigned 128.5 ms of a 155.7 ms status invocation to the index refresh and recorded 1,058 content scans. The opt-in parallel clean check has its own workload and measurements. [Git index diagnosis and CI helper](mounted-git-status.md)

Both VMMs passed all 16 host-edit observations and eight post-idle I/O bursts. Each burst verified bytes in both directions over the bind and wrote and synchronized 2 MiB on the guest ext4 disk. The first burst followed five idle seconds. The qualification also exercised held read, splice and sendfile, binary PID 1 attachment and scoped container removal. The previously observed stale prefaulted guest shared mapping remains a release gate for external Mac writes. [Held-mapping matrix](core-pid1-and-mutable-gamma.md#matched-linux-splice-backport) · [Hardware receipts](native-storage-park-gamma-receipts.tar.gz)

### Opt-in Git check inside the complete build

On the b7d78d2b guest, four alternating pairs per mode used independent build caches and verified the source, output binary and test results on both engines. The opt-in helper uses four stock Git processes to check disjoint tracked paths and falls back to full stock status when it finds a change. It preserves NUL-delimited porcelain for CI callers. The stock benchmark continued to use its original Git command. CPU idle across these jobs was 79.88%. [CI invocation](../../../ci/git-parallel-status.md) · [Exact driver, samples and dirty controls](mounted-git-status.md)

| Guest Git, build and test | Micropod stock | Micropod helper | OrbStack stock | OrbStack helper |
|---|---:|---:|---:|---:|
| Warm clean | 915.1 ms | 850.4 ms | 664.1 ms | 650.8 ms |
| After a host source edit | 2,109.1 ms | 2,146.1 ms | 1,994.1 ms | 2,017.2 ms |

The helper won all four warm Micropod pairs, with a median paired saving of 61.9 ms. It won one of four after an edit. On isolated dirty checks, a same-size binary edit at either end of the file or an added untracked file cost an extra 91–99 ms on Micropod. The helper is suitable for a CI checkpoint that usually expects a clean tree. Stock Git remains the default for a live workspace. [Paired results and scope](mounted-git-gate.json)

### Eight simultaneous Git checks

On guest `9a9594fc5d3a`, eight containers each had half a CPU, 256 MiB and their own copy of the Mac-authored index. They checked the same 1,058-file bind. All eight commands overlapped in each of the 16 scored waves. All 128 status results were correct. Host idle averaged 62.83% over complete sampling intervals inside the timed window. [Density study and raw receipts](mounted-git-gate-density.md)

| Median for eight clean checks | Micropod stock | Micropod helper | OrbStack stock | OrbStack helper |
|---|---:|---:|---:|---:|
| First guest start to last finish | 350.00 ms | 318.53 ms | 138.62 ms | 214.72 ms |
| CPU per job | 53.49 ms | 84.57 ms | 62.79 ms | 102.28 ms |

Micropod finished sooner with the helper in all four paired waves and used 58% more median CPU per job. OrbStack stock Git won all four of its pairs. This workload times clean status only. The full checkout/build/test measurements above used guest `b7d78d2bac1f`. The final image-recovery guest below received correctness and API qualification. [Per-job distributions and run chronology](mounted-git-gate-density.json)

## Native Docker image history, lookup and tagging

The stock Docker client on Gamma used API 1.47 on the managed native socket. Guest `b7d78d2bac1f` added image history and local tagging to the a8a2 runner. The first history-only guest returned 404 for a repository digest that its own image inspection advertised. The revised resolver checks both the descriptor digest and its repository in containerd. It can then recover the CRI config ID for an imported image whose original alias used another spelling. Inspection, history and tagging resolved the advertised reference, and a fresh repository name paired with the same digest returned 404 in all three operations. [Repository lookup](../../../guest/runner/docker_image_resolve_linux.go) · [History implementation](../../../guest/runner/docker_image_history_linux.go)

History returns newest-first OCI creation commands, comments and timestamps. Empty-layer entries have zero size. For filesystem entries, the engine reads the committed overlay snapshot's usage by chain ID. The stock reference and Micropod returned the same ordered metadata and DiffIDs for Alpine and a two-layer import with two tags. Physical layer sizes differed on the two storage stacks. On the controlled import, newest-first sizes were 0, 16,384, 0 and 8,192 bytes on Micropod and 0, 12,288, 0 and 4,096 bytes on OrbStack. Alpine's corresponding totals were 9,310,208 and 10,285,056 bytes. Older rows without a known parent image carry Docker's `<missing>` ID. [Moby's containerd-backed history](https://github.com/moby/moby/blob/v27.5.1/daemon/containerd/image_history.go) · [Differential qualifier](../../../scripts/qualify_docker_image_history.py)

The tag route creates or changes one containerd reference and waits for the native runtime to resolve it before replying to Docker. Stock and raw requests covered a tag name, full and abbreviated IDs, a repository digest, default `latest`, an idempotent update and an existing tag moving to a different image. A container created before the retag still started from its original image. All four concurrent writes to a single test tag returned 201 on Micropod. Two returned 500 in the recorded OrbStack concurrency run. Both original images remained available after test cleanup. This test used only local image records. Registry authentication and push require their own qualification. [Tag implementation](../../../guest/runner/docker_image_tag_linux.go) · [Scoped stock-client transactions and event responses](native-storage-park-gamma-receipts.tar.gz)

The expanded native API 1.47 inventory matched 13 of 24 case groups and exercised 38 of the 107 specified operations. Twelve of the original 23 groups now match, up from eleven on the preceding guest. The added group checks tag, immediate inspect, scoped untag and preservation of the source image. Remaining group differences cover version negotiation and ping headers, Swarm-related endpoints, and plugins. An earlier native worker passed a two-stage Buildx load. This 1.47 run used the engine-only profile. Authenticated registry publication, live network attachment, a clean signed installation and sustained Buildx/Testcontainers workloads remain release gates. [Final 1.47 inventory](native-docker-api-v1.47-image-recovery.json.gz) · [First tag-capable guest](native-docker-api-v1.47-image-history-and-tag.json.gz) · [Previous inventory](native-docker-api-v1.47.json.gz)

### Restart after the last named tag moves

Docker permits a hexadecimal repository name such as `face`. The native engine now resolves an existing named repository before trying a short config ID. The tag path verifies that the CRI result and the containerd descriptor identify the same source before writing. The tests include an OCI index and a single manifest that share a platform config ID. [Source identity checks](../../../guest/runner/docker_image_tag_linux.go) · [Index and tag tests](../../../guest/runner/docker_image_tag_linux_test.go)

A separate stock-client test imported an image with a unique config, created a stopped container and moved the image's only named tag. The container still had its original config ID. On guest `9a9594fc5d3a`, starting it failed when containerd looked up the normalized repository digest that CRI advertised. Containerd had stored the imported reference under its original spelling. The same sequence succeeded on OrbStack. [Containerd 2.4.2 image lookup](https://github.com/containerd/containerd/blob/v2.4.2/internal/cri/server/helpers.go#L167) · [CreateContainer lookup order](https://github.com/containerd/containerd/blob/v2.4.2/internal/cri/server/container_create.go#L130)

Guest `5de5611a7371` passed the exact sequence, including attached output from the retained container, inspection by its original config ID, untagging the bare hexadecimal name and short-ID lookup. After this specific pre-create error, the engine checks the advertised repo digest, the config-ID record and the existing immutable repository alias. It creates the verified canonical alias and retries container creation once. Healthy starts continue to issue one CRI create. Stock tag, retag, four concurrent writes, history and the 24-group differential all passed their image checks again. The full Linux runner suite passed 143 top-level tests and 187 subtests. Three top-level tests and two subtests skipped for mount permissions or standalone network fixtures. The complete 85-file module, test logs, failed predecessor and successful replay are in the archive. [Recovery implementation](../../../guest/runner/docker_image_start_linux.go) · [Failure and recovery receipts](native-storage-park-gamma-receipts.tar.gz)

## Fixture cleanup and preserved baseline

All six workers shut down cleanly and released their supervisor locks. The staging volume and six worker volumes each passed a read-only APFS remount check with Spotlight disabled and zero FSEvents journal files or bytes. All seven disk images, the staging directory and the fixture's OrbStack tag and builder were removed. The signed VMM and three measured or qualified guest binaries were retained. The final archive contains 370 individually verified files and has SHA-256 `c9cf3081b8268cde9a5b22e8ad53027e43ff091f020eac8fc776d77b59d9dce4`. [Cleanup and artifact identities](native-storage-park-gamma.json) · [Raw evidence](native-storage-park-gamma-receipts.tar.gz)

All 24 original November 24 baseline files and all 24 preserved copies match their recorded SHA-256 values. The controlled published-TCP result remains 7,934.1 MiB/s at Standard QoS and 6,294.1 MiB/s at Interactive. Interactive reduced fresh-request p95 from 10.187 to 6.356 ms. With Interactive fixed, two relay workers delivered 6,504.7 MiB/s and four delivered 5,845.0 MiB/s. [Controlled and ambient results](../2026-11-24/gamma-qos-and-workers/results.md) · [B3 three-way scorecards](../2026-11-25/phase-b3-results.md) · [B4 and B5 production plan](../../research/2026-11-25-phase-b4-plan.md)
