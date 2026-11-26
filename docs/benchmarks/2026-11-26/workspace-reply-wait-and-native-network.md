# Native Docker bridge membership and mounted CI on Gamma

Micropod's managed HVF runner `4d0fb3989ee4` supports a second named IPv4 bridge through the ordinary Docker socket. Stock Docker and Testcontainers reached the same service through either bridge, and the service could reach peers on both. After powering off the worker and restarting its supervisor on the original disk, the client recovered the same containers, address reservations and writable service data. [Gamma scorecard](workspace-reply-wait-and-native-network-gamma.json) · [Exact sources, commands and raw receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

The final locally signed package combines VMM `c129d373975c`, B8 kernel `da6da0bae1db` and runner `4d0fb3989ee4`. The public CLI installed and started it with its bundled assets. In four alternating pairs per workload, this combination finished ahead of OrbStack in every pair below. None of the final windows passed the 90% pre-start idle threshold. The 4-vCPU, 4-GiB worker and signed binaries were held fixed. [Final package attestation and timings](workspace-reply-wait-and-native-network-gamma.json)

| Median on Gamma, current load | Micropod | OrbStack | Host CPU idle during run |
| --- | ---: | ---: | ---: |
| Eight named services through verified HTTP | 439.46 ms | 1,195.57 ms | 1.34% |
| Same services through cleanup | 779.63 ms | 1,923.83 ms | 1.34% |
| Eight overlapping stock Git jobs, guest wave | 295.86 ms | 329.92 ms | 2.15% |
| Eight overlapping stock Git jobs, host wave | 310.30 ms | 345.48 ms | 2.15% |
| One warm Git, Go build and tests | 702.74 ms | 744.63 ms | 52.75% |
| Same job after a host edit | 2,028.07 ms | 2,224.55 ms | 52.75% |
| Host edit through verified build | 2,099.96 ms | 2,334.37 ms | 52.75% |

This package passed strict host mutation, held and prefaulted mapping, splice/sendfile and ordinary container PID 1 checks before scoring. All 32 DNS redirect installations succeeded. The standalone archive weighs 122,727,344 bytes and has SHA-256 `f351455b4830a1a105b2440b461c93a1d649b61da355fbcff217fcaf66bf8085`. A fresh extraction matched all 46 entries and their permissions. Both macOS executables passed strict signature verification, and the extracted CLI ran. [Binary, source and extraction manifests](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

The November 25 B3 scorecard remains the direct-HVF comparison. B4 subsequently demonstrated zero-`vmnet` egress and measured 26,452 MiB/s for six-GiB IPvlan transfers with cubic/fq. B5 measured a median 10.68 ms from VMM spawn to a successful restored Docker ping. B7 ran a real PostgreSQL/HTTP Compose integration and persistent BuildKit caches. This qualification targets the managed native engine, its installable runtime and shared CI jobs. [B3](../2026-11-25/phase-b3-results.md) · [B4](../2026-11-25/phase-b4-results.md) · [B5](../2026-11-25/phase-b5-results.md) · [B7](phase-b7-real-ci-and-caching.json)

## Stock Docker networking

| Public operation on API 1.47 | Micropod result |
| --- | --- |
| Connect a created container, then start | Both endpoint aliases and published HTTP worked |
| Connect while running | Primary gateway and published port survived the live join |
| Create with two endpoints in one stock CLI request | Container and network inspection agreed with live traffic |
| Disconnect and rejoin | The old address stopped serving and the secondary alias disappeared. The primary stayed reachable. A second restart kept the detached state |
| Eight racing calls for one live endpoint | One HTTP 200 and seven HTTP 403 responses, matching OrbStack |
| Seven different concurrent joins | Seven HTTP 200 responses. All nine members, including the observer and the contended winner, had distinct addresses |
| Named network isolation | Single-network peers could resolve only their own aliases. Native also blocked direct numeric HTTP to an unpublished service on the other bridge. On this OrbStack installation the same numeric requests reached the service in both directions |
| Application DNS ports | A real application bound IPv4 wildcard TCP and UDP port 53 and exchanged the expected bytes while the embedded resolver served both networks |

The stock client stopped and restarted the same service while its peers remained running. Each scenario checked full-ID filters, aliases, connected subnets, published HTTP with a unique body, and removal by exact run label. The separate Testcontainers-go v0.40.0 two-network fixture used the stock Docker SDK. A genuine Ryuk v0.13.0 run removed an abandoned application, network and volume and preserved another session's control resources. Final labelled inventories were empty. [Stock CLI cases](../../../scripts/qualify_docker_network_membership.py) · [Stock Go fixture](../../../scripts/testcontainers-fixture/main.go) · [Qualification receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

Three runner builds isolated two defects missed by the initial Linux tests. Runner `61d200769f21` created a veth and then could not verify its ownership tag. Runner `e3a054c12172` verified both ends in the pinned pod network namespace and explicitly tagged the host interface. Its secondary stayed reachable, but its primary interface changed MAC on restart while keeping the same IP. DNS still answered, and the running peer retained the old MAC in its ARP table. The final runner uses a stable IPv4-derived MAC for the named primary and secondary. Separate captures verified both MACs and live HTTP before and after restart. The final Linux suite passed 590 cases, with five environment skips. Its 57 focused cases also passed. [Bridge data plane](../../../guest/runner/docker_bridge_sandbox_linux.go) · [Durable endpoint transactions](../../../guest/runner/docker_endpoint_mutation_linux.go) · [ARP and Linux evidence](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

For the whole-worker test, three containers were stopped before the old supervisor exited. The new supervisor opened the same four-GiB ext4 disk, device 16777264 and inode 54. The two network IDs, three container IDs, published HTTP, saved service bytes and both reserved addresses survived. All five fixture objects were removed after verification. [Restart fixture](../../../scripts/qualify_docker_network_restart.py) · [Reboot and traffic receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

This release slice covers automatically addressed named IPv4 bridges in the native runner. Built-in/default-primary joins, primary disconnect, static IPv4, IPv6, custom MACs, rootless or mixed-driver attachment, and network lifecycle events remain open. [Phase B4/B5 production plan](../../research/2026-11-25-phase-b4-plan.md)

The pinned API 1.47 replay passed 16 of 27 strict comparison groups and exercised 39 operations. Four differences reflect version discovery and negotiation, six are Swarm routes and one is plugin listing. The first replay's isolated Docker configuration lacked the Compose and Buildx plugins. A fresh run with both stock plugins reproduced all 27 previous group outcomes. The new successful network-connect and disconnect cases bring cumulative coverage to 49 distinct operations out of 107 in Moby 27.5.1. This count includes partial operations. Both engines' labelled inventories were empty after the audit. [Pinned audit and cleanup](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

Review found a read-only container could give up its named primary IP after a port teardown error while its former CRI pod still owned that address. Runner `4d0fb3989ee4` persists the exact pod owner before creating port forwards and releases the guard after successful CRI removal. The Linux suite passed 593 tests with five environment skips. The 60 focused tests include injected failures for explicit removal and automatic removal, a failed first recovery, reload and successful retry. The frozen build contains 116 source files with four changed from `3d0a9a9154a0`. Concurrent work on BuildKit, HTTP, metrics and the reaper in the working directory was excluded from this binary. [Ownership and recovery](../../../guest/runner/docker_endpoint_mutation_linux.go) · [Failure tests](../../../guest/runner/docker_endpoint_mutation_linux_test.go) · [Exact sources and executions](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

On the recovery build, all three stock attachment paths, eight concurrent clients, the official SDK and genuine Ryuk passed again. The same-disk restart retained three containers and both networks with working DNS and published traffic. A stale test-helper import interrupted the first verification after restart. Correcting the driver let it verify the already restarted worker and clean the same resources. The pinned API run reproduced all 27 previous comparison outcomes and left both scoped inventories empty. The current 118-file runner tree also cross-compiled and passed vet on Linux/arm64, including four concurrently modified files and two additional observability files. Its before/after source hashes matched. [Pinned Docker audit](native-docker-api-v1.47-secondary-networks.json.gz) · [Final stock, reboot, and build receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

## Eight jobs on one named bridge

Each wave launched eight Alpine containers through the stock CLI, with half a CPU and 256 MiB per job. Every service fetched a unique HTTP body from its neighbour by DNS alias. Four alternating pairs ran on each runner with the same repository manifest digest and uncompressed image layers on both engines. Docker configuration-ID and manifest-ID reporting differs between these engines. The driver preserves each engine's reported identity before and after. [Named bridge CI driver](../../../scripts/bench_named_bridge_ci.py) · [Four-pair measurements](workspace-reply-wait-and-native-network-gamma.json)

| Host clock, median ms | Earlier runner / OrbStack | Runner `3d0a9a9154a0` / OrbStack |
| --- | ---: | ---: |
| Eight stock CLI launches complete | 216.94 / 559.59 | 170.82 / 416.35 |
| All eight alias HTTP requests verified | 250.59 / 623.19 | 196.26 / 482.88 |
| Through verified scoped cleanup | 493.64 / 1,132.94 | 372.73 / 882.90 |

Runner `3d0a9a9154a0` installed 32 sandbox DNS redirects with zero errors. Their summed setup time was 56.60 ms, or 1.77 ms per container. The clocks overlap in each eight-container wave. Host load differed between the two runner windows. The same-window comparisons establish the advantage over OrbStack on this workload. [DNS counters and host load](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

## Installing the native runtime

The production CLI now discovers the signed VMM alongside its executable and the kernel, initrd and OCI tools in the app's Resources directory. The standalone CLI resolves the same payload beside itself. Explicit asset flags take precedence. A settings-only reinstall keeps installed runtime files, and first install still requires a disk source. All 61 managed-machine Swift tests passed, including app discovery through a linked CLI, standalone overrides, preservation of installed bytes and rejection of a package link escaping its distribution. [Machine installer](../../../Sources/MicropodRuntime/HVF/HVFMachineInstaller.swift) · [Installer tests](../../../Tests/MicropodRuntimeTests/HVFMachineTests.swift)

The release packaging script accepts an explicit `MICROPOD_HVF_DISTRIBUTION` containing the four built payloads. The signed release repack exports the app's VMM and data into the standalone tarball, and the Developer ID signing path supplies the VMM's hypervisor entitlement. Gamma exercised the staging helper on a private copy of the B7 app with the current production CLI and final guest. The five runtime role hashes matched the flat distribution. The standalone CLI installed four matching payloads and cloned a separate four-GiB disk. The app's CLI then ran a fresh `micropod machine install` with the disk source and worker settings, discovered all four runtime assets, and booted the worker. Eight stock Docker clients joined a named bridge and completed mixed teardown with zero leftovers. The local app passed strict deep signature verification with an ad-hoc identity. Provisioning the qualified payload on release CI and a clean Developer ID installation remain release gates. [Distribution staging](../../../scripts/stage_hvf_assets.sh) · [Release repack](../../../.github/workflows/release.yml) · [Private package install and smoke receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

The release workflow can fetch a pinned native payload from a successful Actions run for the release commit. It verifies the source repository and commit, the operator-supplied tarball SHA-256 and the VMM's signature and hypervisor entitlement. A local download fixture supplied the complete 218 MiB runtime, produced matching hashes for all four installed roles and rejected a wrong commit and a wrong digest. The hosted download and Developer ID/notarization path still need a real release qualification. [Release fetch](../../../scripts/fetch_hvf_distribution.sh) · [Release inputs](../../../.github/workflows/release.yml)

## Raw mounted checkout

The raw benchmark used stock Git, Go and the existing 1,058-file Mac-authored checkout. The single-workspace VMM was `f0747277714e`. The 4-vCPU, 4-GiB guest retained asynchronous RELEASE. The new Linux Image `0e05ac3442a2` optionally lets one foreground LOOKUP, OPEN or READ submitter poll the completion flag for up to 16 µs. The existing completion worker owns validation and wakeup in both settings. The ordinary product configuration keeps polling off. [Previous matched workload](mounted-checkout-concurrency-and-native-compat.md) · [Pinned patch, build and guest receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

| Mixed-load median, four pairs per window | Retained Linux, Micropod / OrbStack | New Image off, Micropod / OrbStack | Same Image on, Micropod / OrbStack |
| --- | ---: | ---: | ---: |
| Warm Git, Go build and tests | 1,046 / 773 ms | 1,170 / 916 ms | 853 / 735 ms |
| After a host edit | 2,288 / 2,339 ms | 2,624 / 2,617 ms | 2,055 / 1,993 ms |
| Eight overlapping stock Git jobs | 357 / 149 ms | 434 / 157 ms | 330 / 146 ms |

Host idle during the full checkout changed from 43.70% in the off window to 59.44% in the on window. The paired median ratio for the edited job rose from 0.983 to 1.034. The eight-job ratio improved from 2.761 to 2.320 in these first windows. The enabled kernel still trailed OrbStack on the raw warm and eight-job workloads. Both settings passed host-edit, held-read, splice, cancellation, queue-full and remount checks. Pressure runs recorded 408 queue-full retries off and 286 on. [Per-pair timings, pressure and host telemetry](workspace-reply-wait-and-native-network-gamma.json)

A follow-up ran four fresh eight-job comparisons per arm, in off/on/on/off order on the same Image. The last two arms both met the pre-start idle criterion of two consecutive samples at or above 90%. Their median waves were 315.07 / 135.02 ms on and 307.72 / 134.74 ms off, Micropod / OrbStack. Across all arms the median paired ratios were 2.308 on and 2.083 off. The bounded foreground wait stays off. [All sixteen pairs and idle samples](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

An unscored function and FUSE trace matched 3,585 main-thread poll intervals. The FUSE request-end tracepoint fell strictly inside 123 intervals, shared a timestamp with the boundary in 738 and followed the return in 2,724. The median interval was 16 µs. The tracepoint follows the kernel's finished-bit update, so the equal-timestamp observations cannot establish which happened first. [Matched request and poll events](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

In an unscored native syscall trace, stock Git opened all 1,058 tracked paths. Reads covered 932 files and 5,940,230 bytes. The other 126 files accounted for 13,386,313 mapped bytes. Opening and reading tracked paths took 33.72% of the 197.686 ms command. File-backed faults occur after the mapping syscall returns. Of the main thread's 1,131 FUSE READs, 169 arrived outside the observed syscalls while a tracked mapping was live. That timing establishes overlap with mapped files, without identifying which inode caused each fault. The trace ran during an independent compiler job. [Raw event and file-descriptor attribution](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

## Phase B8 checkout comparison

The separately packaged B8 build couples a notification-enabled VMM and kernel. The VMM retains cached read pages when host size, mtime and ctime agree. Live host notifications invalidate directory entries and file data. Its five-round 1,317-file benchmark reports 516 / 665 ms for warm Git, build and tests, 1,138 / 1,362 ms after an atomic host edit, and 133 / 169 ms for eight overlapping stock Git jobs, Micropod / OrbStack. It also reports a slower warm 16 KiB open/read/close at 11.42 / 8.88 µs. The earlier managed measurements above used a different VMM and guest. The B8 checkout also uses a single Go test invocation and its runner measures engine blocks in a fixed order. [B8 benchmark and implementation](phase-b8-virtiofs-notify-and-keep-cache.md) · [B8 published measurements](phase-b8-virtiofs-notify-and-keep-cache.json)

Gamma independently booted the distributed B8 VMM `dae33067a0f2` and Image `da6da0bae1db` with the new Docker runner `3d0a9a9154a0`. The guest confirmed the notification queue, EVENT_IDX, asynchronous RELEASE, inline completion and compact requests. Stock Git used independent Mac-authored indexes and all 1,058 canonical tracked paths. The worker passed exact-mtime edits, held reads, mmap, splice/sendfile, atomic replacement and the stock container PID 1 checks. Each engine ran four paired waves. [Attestation, correctness and timed receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

| Managed checkout median, mixed load | Micropod B8 | OrbStack |
| --- | ---: | ---: |
| Eight stock Git jobs, guest-clock wave | 137.13 ms | 147.32 ms |
| Eight stock Git jobs, host-clock wave | 143.53 ms | 157.36 ms |
| One warm Git, Go build and tests | 746.07 ms | 742.18 ms |
| Warm Git component alone | 114.22 ms | 60.27 ms |
| One edited Git, Go build and tests | 2,358.78 ms | 2,413.31 ms |
| Host edit through verified build | 2,437.15 ms | 2,552.06 ms |

B8 won three of four eight-job pairs and two of four pairs in each full build-and-test comparison. The density window averaged 57.83% host idle and the full checkout window averaged 62.78%. The concurrent Git advantage reproduced here. The full warm checkout was effectively even across these four pairs. [Independent matched scorecard](workspace-reply-wait-and-native-network-gamma.json)

The B8 VMM previously enabled its 60-second metadata lifetime as soon as the guest negotiated the notification queue. A failed kqueue or FSEvents startup could therefore leave positive and negative directory entries cached for up to a minute. VMM `c129d373975c` enables the longer lifetime only once the queue and both watchers are ready. If either watcher cannot start, fresh replies use the 20 ms fallback. The VMM clears watcher-dependent state when suspending or disabling the queue and sends an epoch invalidation on re-arm. The macOS test suite passed all 56 Virtio device tests, including a deterministic failed FSEvents start, recovery, snapshot and restore with existing handleless directories. [VMM implementation and tests](../../../vmm/crates/vmm-virtio/src/virtiofs.rs) · [Build and test receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

## Benchmark storage and original baseline

Each disposable APFS volume was created with `.fseventsd/no_log` and `.metadata_never_index`, and Spotlight indexing was disabled for that volume. The B8 filesystem uses a live FSEvents subscription to invalidate guest caches. Persistent event journaling and the live subscription are separate macOS facilities. [Volume provisioning code and disk policy receipts](workspace-reply-wait-and-native-network-gamma-receipts.tar.gz)

Final cleanup opened each of the 17 worker volumes and the staging volume read-only. All 18 had Spotlight disabled and zero FSEvents journal files or bytes. All images, sockets and scoped processes were gone. The temporary OrbStack tag and builder were removed and four pre-existing image digests matched. The raw archive contains 907 individually verified receipt hashes. The preceding 38 recorded products and all retained executable signatures and digests also passed verification. [Cleanup and manifest](workspace-reply-wait-and-native-network-gamma.json)

The November 24 resume guard detected an existing timed QoS pair. Its original baseline remains 6,573.34 MiB/s. All 24 originals and all 24 preserved copies matched their SHA-256 manifest. The completed controlled schedules measured 7,934.1 / 6,294.1 MiB/s for standard / interactive QoS and 6,504.7 / 5,845.0 MiB/s for two / four relay workers. Controlled fresh p95 was 10.187 / 6.356 ms for the two QoS settings. Under ambient load the same throughput pairs were 7,777.2 / 6,264.7 and 6,413.5 / 5,774.7 MiB/s. [QoS, worker schedules and cleanup](../2026-11-24/gamma-qos-and-workers/results.md)

## Branch consolidation

The local branch `integration/native-engine-convergence-20261126` joins the managed-machine and host-scheduling histories. Its engine source commit is `041776a41d59`. The exact 116-file Linux runner and its test executable rebuilt byte-for-byte from the consolidated checkout. A fresh macOS release CLI built from that checkout, and its 85 XCTest and 32 Swift Testing cases passed. The timed package used the earlier recorded CLI `c0e937a02335`. The merged Swift binary has its own digest in the verification record. [Consolidation verification](native-engine-convergence-verification.json)

The Rust workspace passed 104 tests with one hardware test skipped. One initial test timed out after its simulated guest consumed all four notification buffers. The VMM had queued both expected rename invalidations. Updating the test guest to replenish receive buffers reproduced the production Linux behavior. The test then passed 20 consecutive runs and three parallel library runs. The signed VMM bytes stayed fixed. [Test diagnosis and checks](native-engine-convergence-verification.json)

The default-branch integration reconciles the seven CI follow-ons with the managed machine’s BuildKit and job caches. Docker’s session and build requests share one HTTP route. A successful image load binds the exported image ID, and cache-backed archive operations retain their directory handles through the request. The guest applies cache ACLs for jobs running as different users. Read-only VirtioFS metadata expires after one second including time already spent in the cache. Writable metadata retains its 20 ms fallback until the notification queue and both host watchers are ready. [Guest runner](../../../guest/runner/) · [VirtioFS](../../../vmm/crates/vmm-virtio/src/virtiofs.rs) · [Cache configuration](../../../README.md)

The combined ARM64 runner passed 667 Linux tests and subtests with six skips. The Rust workspace passed 106 tests with one hardware-only skip, and 70 guest-init tests and subtests passed on Linux. The release CLI built successfully. Its focused Swift suites passed 153 XCTest cases and 32 Swift Testing cases. The timings at the top of this report apply to the earlier signed package identified there. The separate B9 report covers the stock Testcontainers and Ryuk matrix and its PostgreSQL comparison. [Testcontainers and Ryuk](testcontainers-ryuk-and-observability.md)

On the combined worker, stock Docker ran a cache writer as UID 11001 and read its bytes back as UID 11002. Stock Buildx used its Docker driver to load an offline image, identify it by the emitted image ID and reuse the cached step. A Docker image save returned the expected layer bytes. The first test driver mishandled an untagged image during its cleanup check. The fixture was removed by its recorded ID, and the corrected driver passed with empty inventories. After shutdown, a read-only audit of the disposable APFS volume found Spotlight off and zero persistent FSEvents bytes. [Integration receipt](native-engine-landing-verification.json)
