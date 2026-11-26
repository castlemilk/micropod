# Managed CI checkouts, Docker archives and HVF fork retirement on Gamma

Micropod's native containerd worker passed the 12 stock Docker archive checks on HVF and VZ. The same cases passed on OrbStack. The smaller Go checkout favored Micropod, including the median batch of eight concurrent builds. OrbStack led on warm builds of the 1,058-file Micropod engine checkout. A VMM shutdown crash found during fork qualification is fixed in the tested source build. [Scorecard](phase-b5-managed-checkout-and-archive.json) · [Raw receipts and logs](phase-b5-managed-checkout-and-archive-receipts.json.gz) · [Versioned sources and harnesses](phase-b5-managed-checkout-and-archive-sources.tar.gz)

## Stock Docker and container lifecycle

The stock client copied files, directories, empty files and tar streams before first start, during execution and after stop. Checks cover named volumes, a writable host checkout, denial of writes to read-only mounts, HEAD metadata, hard links, relative symlinks, following a link with `-L` and an archive-mode round trip with UID 12345, GID 23456, mode 0641 and mtime 946782245. The 262,176-byte payload has a unique digest in each run. Read-only image downloads passed on a single-layer Alpine image and an eight-layer Debian-based image. Live `--rm --read-only` also passed. [Stock-client fixture](../../../scripts/qualify_docker_archive.py) · [Docker cp documentation](https://docs.docker.com/reference/cli/docker/container/cp/)

| Gate | Managed HVF | Managed VZ | OrbStack |
|---|---:|---:|---:|
| Common archive cases passed | 12/12 | 12/12 | 12/12 |
| Stop during an active retained-container upload | 53.4 ms | 96.1 ms | Outside this native lifecycle check |
| Guest archive regression tests, including detached overlay mounts | 12/12 | 12/12 | — |
| Native Docker and Compose restart and event delivery | Pass | Pass | Earlier reference qualification |

A retained live archive pins its task and the mount descriptors used by that generation. It releases lifecycle admission once the view is pinned so the scheduler can stop the job while a transfer is active. The stock client observed the completed tar member and a failed unfinished member. The guest discarded the partial file. Offline writable views keep their lifecycle lock through cleanup. Before first start or after stop, a read-only image uses a leased, detached read-only view of the immutable parent. Guest containerd snapshot and lease listings matched before and after qualification on each backend. Both event listeners returned from 0 to 2 to 0. [Archive lifecycle](../../../guest/runner/docker_archive_linux.go) · [Read-only image views](../../../guest/runner/docker_archive_readonly_linux.go)

The first multi-layer test failed on both native backends. A long colon-joined overlay lower-directory list exceeded the Linux mount API's single-string limit. The correction supplies each lower directory in order with `lowerdir+` for long lists. An eight-layer regression checks file precedence and rejects writable upper directories. Running the Linux tests on a real guest also exposed invalid test owner IDs. An early OrbStack qualifier misread the file type bits in the HEAD header. The common suite now verifies permissions against the tar header and uses the tar entry to verify file type. The original failures are retained. [OverlayFS lower layers](https://www.kernel.org/doc/html/v6.18/filesystems/overlayfs.html#multiple-lower-layers) · [Linux mount regressions](../../../guest/runner/docker_archive_readonly_linux_test.go)

## Git, Go build and uncached tests on host-mounted checkouts

All times below are milliseconds. Each cell gives **HVF / OrbStack**. Lower is faster. Wins count the paired samples in which Micropod finished first. The single-job times sum the in-guest Git status, build and test intervals. The eight-job figures measure elapsed time from the first scored command to the last job's completion. Both guests proved their source, toolchain and binary identity. Every revised binary was executed and its output checked. [Checkout harness](../../../scripts/bench_workspace_checkout.py) · [Vendored engine harness](../../../scripts/bench_workspace_runner.py)

| Workload | Warm | First build after atomic host edit | HVF wins, warm · edited |
|---|---:|---:|---:|
| One Go file-helper job | 117.2 / 166.5 | 178.3 / 223.6 | 8/8 · 8/8 |
| Eight jobs, 100 ms CPU period | 406.9 / 429.5 | 699.1 / 711.8 | 7/8 · 5/8 |
| Eight jobs, 32 ms CPU period | 413.5 / 425.8 | 684.7 / 737.4 | 2/4 · 3/4 |
| Eight jobs, final managed build at current load | 517.4 / 557.2 | 912.6 / 862.0 | 3/4 · 1/4 |
| Vendored engine, first worker | 740.9 / 630.3 | 1,894.8 / 1,879.8 | 0/4 · 1/4 |
| Vendored engine, corrected VMM | 823.0 / 704.6 | 1,911.8 / 1,994.3 | 1/4 · 3/4 |
| Vendored engine, current host load | 740.9 / 637.7 | 1,895.8 / 1,878.1 | 0/4 · 1/4 |
| Vendored engine, telemetry integration | 956.9 / 784.5 | 2,529.3 / 2,541.0 | 0/4 · 2/4 |

Each native worker had four vCPUs and 4 GiB. Eight simultaneous jobs each received half a CPU, 384 MiB, one Go execution slot and an independently primed cache. Per-job barriers, Linux monotonic clock identity, overlapping scored intervals and cgroup limits were verified. The identical preloaded image supplied Go 1.26.11, Git 2.39.5 and Python 3.12.16. The shared Mac Go caches were used for host builds. Benchmark job caches lived in the guests. Each four-pair block alternated engine order. The first two rows pool two independent blocks for the same workload. The performance trials waited for two successive host-idle readings of at least 90%, except the explicitly labeled current-load trials and the telemetry integration. The corrected VMM started at 89.79% idle and the telemetry integration at 30.95%. The final eight-job worker started at 47.30% idle. These samples characterize admission only.

The vendored checkout contains 19,326,482 bytes. Git status accounted for much of the warm gap. On the corrected VMM, Git took 132.0 ms on HVF and 58.5 ms on OrbStack. The revised full binary and the three native engine tests passed on both. The 32 ms CPU-period experiment includes an eight-job warm sample at 1497 ms on HVF and 404 ms on OrbStack, with 3.11 summed guest-seconds throttled. All eight jobs experienced the stall. These four pairs do not establish a better default period.

## Mutable workspace I/O

On the same VMM binary and kernel, separate fresh workers alternated the default asynchronous FUSE read negotiation and an experimental synchronous setting. Median 512-file read times for the four workers in order were **13.01, 24.04, 23.02 and 13.76 ms**. Each worker passed all 16 host edit checks, including a same-size change seen through an open descriptor and an atomic replacement that preserved the original open inode. The synchronous-read experiment stays out of the production source. The OrbStack reference's median was 6.45 ms. All four of its replacement checks observed the held descriptor change. One native `idle_poll_us=0` worker read the fixture in 18.47 ms. Five-second resting VMM CPU observations on separate workers were 1.20% of one core at zero and 1.60% at 150 µs.

The diagnostic VMM counted about 512 OPEN, READ and RELEASE operations per complete 512-file pass. The three paired close-only trials added 8.56–10.01 ms to RELEASE on the host. Go's final `File.Close()` took 8.60–10.05 ms with the added delay and 16–19 µs without it. One RELEASE crossed a scan-phase boundary. Instrumented scan time includes the cost of tracing, so the A/B result above uses the normal binary. The measurements identify a synchronous round trip. Guest scheduling, interrupt delivery and host handling contribute at different points along it. [Linux VirtioFS design](https://docs.kernel.org/filesystems/virtiofs.html)

A second probe traced the stock guest kernel on the corrected VMM. It paired 5,666 workspace completion work items with a median enqueue-to-execution delay of 1 µs and p95 of 2 µs. Median complete guest request times were 14 µs for OPEN, 10 µs for READ and 7 µs for RELEASE. Per-CPU loss counters were zero. A higher-priority completion queue could only recover the scheduling portion. These observations favor reducing request count while preserving edit visibility over changing the default workqueue priority. The first trace instance failed during setup. The second verified its selected clock and captured the raw timestamps and loss counters.

## HVF restore and teardown

The B5 report already established a 10.68 ms median to Docker ping on its direct VMM harness. The later B6 run qualified guest shutdown persistence, UTC resync, snapshot integrity, DNS and idle/OOM behavior. This follow-up verifies the exit of **every** VMM and checks delayed restore and isolated writes through real containers. Each serial timing below is the median of five dedicated launches. Fan-out ends after every restored VM has run its first container. APFS provisioning and snapshot creation are outside the timers. [B5 results](phase-b5-results.md) · [B6 hardening](phase-b6-production-hardening.md) · [Fork harness](../../../scripts/bench_snapshot_fork.py)

| Build | Serial to Docker ping, ms | Serial to first container, ms | Parallel forks | All first containers, ms | Processes with exit 0 |
|---|---:|---:|---:|---:|---:|
| Original instrumented candidate | 9.43 | 113.39 | 5 | 189.52 | 11/12 |
| First shutdown correction | 10.51 | 120.67 | 5 | 258.37 | 12/12 |
| Integrated VMM, five forks | 10.43 | 114.43 | 5 | 194.67 | 12/12 |
| Integrated VMM, eight forks | 10.64 | 111.99 | 8 | 373.64 | 15/15 |
| Corrected VMM and final archive engine | 11.91 | 132.65 | 8 | 345.86 | 15/15 |
| Concurrent telemetry integration | 13.42 | 164.24 | 8 | 689.14 | 15/15 |
| Telemetry retirement and final archive engine | 17.23 | 180.34 | 8 | 552.24 | 15/15 |

The first run reported success even though a fork terminated with SIGSEGV during shutdown. The OS crash report identified the `vmm-fs-oci-tools` thread polling guest memory while the main thread was unmapping it. The harness now evaluates exit codes and forced kills after cleaning up. The integrated VMM retires vCPUs, watchdog and device workers before destroying the VM or unmapping RAM. It also wakes the network worker with its actual registered event and releases startup and restore waiters on errors. The final eight-way run checked different markers in the same named volume and host workspace path on each fork. A fresh restore retained the source marker and passed the wall-clock check after a five-second delay. These are direct VMM timings. Managed per-job snapshot provisioning and signing a clean distributable remain release gates. [VMM source](../../../vmm/crates/vmm-core/src/lib.rs) · [Exact tested source](phase-b5-managed-checkout-and-archive-sources.tar.gz)

The outer tree gained an optional telemetry service during qualification. The last two fork rows pin that integration and its follow-up. The last managed run paired the updated Swift launcher with the matching VMM, initrd and final native archive runner. Its Unix health and Prometheus endpoints identified the actual disk-owning VMM PID, four online vCPUs and live filesystem counters. Its guest passed the lifecycle matrix and ran eight overlapping checkout jobs. The final Swift build also repeated the archive, event and restart qualification on VZ. The full hashes and command lines are in the receipts.

The final VMM validates CPU and RAM dimensions before creating the VM. Telemetry startup rolls back partial listeners and preserves existing or replaced socket paths. Each OTLP push has a two-second deadline across DNS, connect, write and read, with a separate 500 ms best-effort final trace flush. One outstanding system resolver per exporter can finish after shutdown holding only its hostname and result channel. The native launcher validates the selected socket length before creating its state directory and reports unsupported HTTPS configuration for the VMM exporter before launch. The host tracer retains its separate HTTPS support. All 50 Rust library tests, three parent-process tests and 20 Swift HVF worker tests passed. The pinned Rust toolchain reported a debug-info stripping warning because its `rust-objcopy` could not load `libLLVM`. The release build and strict code-signature verification succeeded.

## State of the production work

The native-worker contract now includes the archive cases above alongside the prior Buildx, Docker and Compose restart, and container/exec event work. Open surfaces include interactive stdin/TTY and attach, live network connect/disconnect, broader image/network/volume event and API-version coverage, and archive handling for xattrs and cross-mount traversal. Sustained CI soak and a clean signed installation remain outstanding. The Rust VMM source was untracked in the outer checkout at qualification. The managed engine lives in the nested Phase 0 repository. The source archive pins the tested Rust and Go variants and the measured driver revisions. The scorecard identifies the tested CLI, guest initrd, kernel and worker hashes. [Production plan](../../research/2026-11-25-phase-b4-plan.md) · [Earlier managed scorecard](managed-engine-compatibility.md)

Run the stock archive qualifier against an explicit socket on a worker with a preloaded Alpine image and a host workspace shared with that worker. Supply an additional layered image containing `/etc/debian_version` for full reproduction.

```sh
bash scripts/qualify_native_worker.sh --archive --host "$DOCKER_HOST" --workspace "$WORKSPACE" --overlay-image "$LAYERED_IMAGE" --native-retirement
```

All 39 disposable APFS volumes were checked live and at read-only remount with Spotlight disabled, the FSEvents no-log marker present and zero persistent journal files. The last managed worker powered off cleanly. The first host disk-holder query timed out during teardown. Recovery verified the stopped instance, released locks, absent VMM, image and mount identities, policy markers and the raw disk inode on read-only remount, then removed the disk. Its initial in-memory drive receipt was unavailable after the orchestrator exited. The harness now retries a timed-out holder query within its cleanup deadline. The worker disks, snapshots, mounts and private OrbStack image tag were removed. The shared qualified installation matched its two executable hashes and all 37 guest files. The 24 original scheduling baseline files and their 24 preserved copies matched their manifest. [Original QoS and worker results](../2026-11-24/gamma-qos-and-workers/results.md) · [Cleanup receipts](phase-b5-managed-checkout-and-archive-receipts.json.gz)

## Follow-up on 26 November

Managed HVF and VZ now pass stock-client interactive exec and early-output checks. The follow-up compares job-local and host-mounted checkouts, times eight overlapping CI jobs, and examines the identity and workspace of managed snapshot restores. [Gamma follow-up and raw receipts](managed-ci-git-and-exec.md)
