# Protected worker drives and HTTP handoffs on Gamma

Each new Micropod worker in the Gamma benchmark gets its own sparse APFS image. The 64-container suite places its configured 6 GiB Linux disk on a 16 GiB host volume. The engine-tuning launcher now places both its Virtualization.framework (VZ) and direct Hypervisor.framework (HVF) disks on separate 32 GiB host volumes. The VZ tuning worker requests a 16 GiB guest disk and the direct HVF launcher copies a 4 GiB ext4 seed. [Suite drive provider](../disposable-local-fixture/local_worker_drive.py) · [VZ and HVF launcher](../../../../scripts/bench_engine_tuning.py)

The provisioner creates `.fseventsd/no_log` and `.metadata_never_index` on the volume, issues a volume-scoped Spotlight request, remounts and verifies the status with `mdutil`. A protected volume with any journal file now fails the check, including a zero-byte file. On shutdown the launcher waits for its process group and disk holders to exit. A read-only remount checks the APFS identity, worker disk inode and size, policy markers, journal contents and Spotlight state before removing the backing image. An unexpected disk identity preserves the detached image. [Provisioner](worker_apfs_drive.py) · [Apple’s per-volume FSEvents logging control](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/FileSystemEventSecurity/FileSystemEventSecurity.html)

A separate filesystem check created, synced, renamed and deleted 64 files on a fresh volume. The journal had zero files and zero bytes after this work and on the read-only remount. Another real VZ boot verified that the Apple VMM held the dedicated disk even when the caller supplied conflicting home and backend values. A cross-volume copy check preserved an existing destination and matched the seed bytes at a new destination. [Filesystem check](sibling-drive-zero-journal-verification.json) · [Live VZ and copy checks](sibling-tuning-drive-override-smoke.json)

## Container lifecycle on the protected disks

Each engine started and removed 32 Alpine containers at eight-way concurrency in each round. The three-round repeat also exercised internal IPvlan, quiet HTTP, 32-client DNS, a 6 GiB transfer and a deliberate guest memory-limit check. All three engines reported the expected OOM exit code of 137. The two Micropod workers used four vCPUs and 4 GiB RAM. Both verified ready-to-retirement disk identity and recorded an empty holder set at shutdown. The HVF launcher verified the copy against the full SHA-256 of the opened seed before starting its VMM. Provisioning through Docker readiness took 3.35 s on VZ and 5.72 s on HVF, including the new volume and the HVF seed check. [Three-round receipts](sibling-tuning-worker-drives-final.json) · [Independent drive and binary verification](sibling-tuning-worker-drives-final-verification.json)

| Measurement | Micropod VZ | Micropod direct HVF | OrbStack |
| --- | ---: | ---: | ---: |
| 32-container lifecycle, median | 1.304 s | 1.102 s | 1.785 s |
| Quiet HTTP on a pinned guest CPU, p95 | 17.42 µs | 18.54 µs | 15.67 µs |
| Bulk transfer between two containers in one VM | 18,256.5 MiB/s | 18,879.3 MiB/s | 23,606.3 MiB/s |

The rounds reused one boot per native backend and ran the engines in a fixed order. An earlier one-pass drive qualification recorded 2.406 s on VZ, 17.427 s on HVF and 4.472 s on OrbStack for the lifecycle workload. Its cause is unresolved. The repeat establishes a lifecycle lead on these boots. OrbStack led pinned HTTP and bulk transfer in the repeat. [Earlier receipts](sibling-tuning-worker-drives.json) · [Repeat measurements](sibling-tuning-worker-drives-final.json)

## Guest scheduling with 64 live containers

Four fresh VZ workers crossed the Linux scheduler migration-cost setting between 500 µs and 62.5 µs. Keep the 500 µs default. Eight concurrent two-revision Go builds ran while 32 client and service pairs offered 96,000 HTTP requests per engine window. Across 3,072,000 requests, 256 build jobs and 4,096 workload test passes, cutting the setting increased the median paired native scheduled p95 by 135 µs, scheduled p99 by 743 µs and post-dispatch p95 by 83 µs. Eight-build time improved by 16 ms with four wins in eight. [Scored crossover](sibling-migration-cost-results.json) · [Independent raw replay](sibling-migration-cost-independent-replay.json)

| Default setting, median across eight windows | Micropod VZ | OrbStack | Micropod wins |
| --- | ---: | ---: | ---: |
| Scheduled HTTP p95 | 1.166 ms | 3.074 ms | 8/8 |
| Scheduled HTTP p99 | 3.366 ms | 5.885 ms | 7/8 |
| Post-dispatch HTTP p95 | 0.459 ms | 0.245 ms | 0/8 |
| Eight-build completion | 2.822 s | 2.874 s | 7/8 |

The first candidate boot had two unusually slow native windows. OrbStack also slowed in the first of those windows. The primary comparison retains both. Omitting any one matched window still leaves all three native HTTP tails worse. The reverse-order seed alone also showed increases for all three. Three additional attempts detected unrelated OrbStack work, retired their disks and were repeated. [Per-seed and per-window data](sibling-migration-cost-results.json) · [Retired scopes](sibling-handoffs-and-drives-cleanup.json)

## Where the remaining HTTP gap occurs

A separate 64-container VZ boot added three timestamps to the same Go HTTP method. Across 768,000 completed offers the replay matched identical request ordinals in each client's near-p95 band, with equal weight per slot and wave. The mean Micropod excess was 89.6 µs. It comprised 5.3 µs through the first-byte callback, 38.5 µs from that callback to `Client.Do` returning, and 45.8 µs from there to `io.ReadAll` returning. Close and final validation together contributed less than 0.1 µs in magnitude. [Boundary measurements](sibling-http-client-boundaries-results.json) · [Independent matching and additive phase means](sibling-http-client-boundaries-independent.json)

One further boot traced a builder client and an HTTP-only client on each engine. All four traces passed a channel-wake control and were bound to their actual issuing thread, warmed socket and monotonic gate. The first replay required a 2 µs margin and missed handoffs where the caller returned in under 150 ns. Requiring a unique possible phase within the recorded clock uncertainty recovered 12,000 EOF acknowledgments and 11,986 header handoffs across 12,000 calls. On matched offers in either engine’s slowest 5%, Micropod’s excess for the builder included 113–122 µs waiting for the EOF acknowledgment and 67–75 µs runnable in Go after it. For the HTTP-only client the ranges were 53–61 µs and 45–53 µs. Traced clients had higher p95 than same-role siblings on the same vCPU. Attributing Go runnable time to Linux or host scheduling requires an overlapping kernel trace. [Strict replay](sibling-http-runtime-handoff-results.json) · [Clock-bounded overlap and matched offers](sibling-http-runtime-handoff-overlap.json)

The audit covered 15 new volumes, including the separate filesystem check. All 15 had zero FSEvents journal files or bytes, disabled Spotlight and successful ejection. Across the accumulated studies, the audit checked 56 volumes. All 24 original baseline files and their preserved copies matched. The original stock throughput was 6,573.34 MiB/s. [Host audit](sibling-handoffs-and-drives-cleanup.json) · [Controlled and ambient QoS and worker results](../gamma-qos-and-workers/results.md)
