# Micropod end-to-end and scaling results, 19 November 2026

The Apple Silicon host ran macOS 26.5.1 on an M5 Max with 18 CPU cores, 128 GB of memory and APFS. This was a shared development host with warm file pages. Contenders rotated order within each block. Every measured and warm-up attempt used a new destination. There was no retry of a failed sample.

The standard run passed all 120 measured samples and 24 warm-ups. The 50,000-file case exposed a reliability limit. Across three measured attempts each, native clones and forced copies each finished once inside the 150-second process deadline. Rsync missed the deadline on all three. Every implementation passed its separately recorded warm-up. The successful measured native operation took 127.3 seconds to create the view and 162.7 seconds including verification.

## Distinct filtered host views

Milliseconds from launching the contender process to completion of the last requested view. The validator then re-read every included file and checked the exact tree, link target, executable mode, mtime and xattr. Those reads are included in the second table. These are host file operations. SharedFS daemon and guest engine timings have separate boundaries.

| Source fixture | Distinct clients | Measured blocks | Micropod native, ms | Micropod forced copy, ms | macOS rsync, ms |
| --- | --- | --- | --- | --- | --- |
| 32 × 4 KiB + 1 MiB | 1 | 5 | 143.2 | 133.1 | 313.1 |
| 512 × 4 KiB + 16 MiB | 1 | 5 | 159.9 | 355.5 | 414.3 |
| 512 × 4 KiB + 16 MiB | 4 | 5 | 439.5 | 954.1 | 1,079.6 |
| 512 × 4 KiB + 16 MiB | 8 | 5 | 457.1 | 1,069.6 | 1,624.7 |
| 4,096 × 4 KiB + 16 MiB | 1 | 5 | 1,621.5 | 3,547.7 | 3,708.2 |
| 64 × 4 KiB + 256 MiB | 1 | 5 | 38.6 | 277.2 | 2,180.0 |
| 50,000 × 4 KiB + 16 MiB | 1 | 3 | 127,276.6 (1/3) | 89,811.5 (1/3) | — (0/3 passed) |
| 64 × 4 KiB + 1,024 MiB | 1 | 3 | 158.6 | 4,839.5 | 15,232.6 |

### Including independent verification

Milliseconds to verified results, including launching the contender.

| Source fixture | Distinct clients | Measured blocks | Micropod native, ms | Micropod forced copy, ms | macOS rsync, ms |
| --- | --- | --- | --- | --- | --- |
| 32 × 4 KiB + 1 MiB | 1 | 5 | 160.2 | 151.0 | 338.7 |
| 512 × 4 KiB + 16 MiB | 1 | 5 | 301.9 | 494.2 | 612.5 |
| 512 × 4 KiB + 16 MiB | 4 | 5 | 1,229.7 | 1,673.6 | 1,660.1 |
| 512 × 4 KiB + 16 MiB | 8 | 5 | 2,009.2 | 2,373.2 | 3,313.7 |
| 4,096 × 4 KiB + 16 MiB | 1 | 5 | 2,845.2 | 4,613.5 | 4,574.8 |
| 64 × 4 KiB + 256 MiB | 1 | 5 | 221.6 | 441.0 | 2,346.0 |
| 50,000 × 4 KiB + 16 MiB | 1 | 3 | 162,658.9 (1/3) | 116,841.3 (1/3) | — (0/3 passed) |
| 64 × 4 KiB + 1,024 MiB | 1 | 3 | 878.2 | 5,669.8 | 15,976.2 |

Each source also contained the same number of excluded small files, one empty file, one symlink and the filter file. Values are medians across measured blocks. A fraction indicates successful attempts over total attempts. Medians conditioned on a subset are unsuitable for ranking. A process that exceeded 150 seconds is a failure even if it left some files behind. The large-tree results are evidence for [the metadata scaling backlog](https://github.com/castlemilk/micropod/issues/163).

### Chunk store

The payload repeats every 8 MiB with alternating compressible and high-entropy 256 KiB chunks. The store starts empty per attempt. The timed restore reopens its index and publishes the file. The complete workflow additionally verifies restored bytes and rejects a deliberately corrupted object without replacing a sentinel destination. Stored bytes are encoded object lengths before corruption.

| Payload MiB | Encoding | Blocks | Ingest ms | Reopen and restore ms | Verified including corruption check, ms | Stored MiB |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | raw | 5 | 47.0 | 17.3 | 89.0 | 1.0 |
| 1 | lz4 | 5 | 52.0 | 16.9 | 112.5 | 0.5 |
| 16 | raw | 5 | 97.3 | 47.7 | 184.2 | 8.0 |
| 16 | lz4 | 5 | 101.5 | 49.5 | 199.8 | 4.0 |
| 256 | raw | 5 | 881.8 | 991.1 | 2,034.8 | 8.0 |
| 256 | lz4 | 5 | 889.8 | 901.7 | 1,970.2 | 4.0 |
| 1024 | raw | 3 | 3,829.5 | 4,151.5 | 8,565.2 | 8.0 |
| 1024 | lz4 | 3 | 4,285.0 | 4,320.4 | 7,561.8 | 4.0 |

## Linux engine reference

GitHub-hosted Ubuntu 24.04, native amd64. Docker Engine and rootful Podman loaded one offline guest image. Every run requested one CPU and 64 MiB, with networking disabled. The timer covers the complete batch, requiring exit 23 and exact stdout/stderr for each container. There were three measured blocks per engine and concurrency, after an excluded warm-up.

| Concurrent containers | Docker median, ms [range] | Podman median, ms [range] |
| --- | --- | --- |
| 1 | 85.9 [85.8–88.5] | 74.7 [74.3–75] |
| 4 | 132.7 [128.9–136.3] | 135.2 [130.3–135.4] |
| 8 | 251.9 [245.9–271.3] | 263.3 [259.5–303] |

BuildKit and Buildx ran each case once on the same Linux runner. Completion requires loading and running the exported image, checking the output and matching the actual cache status of the execution step.

| Build case | Validated completion ms |
| --- | --- |
| solver-no-cache | 1072.1 |
| warm | 190.4 |
| edited | 241.1 |
| chmod-only | 251 |
| ignored-only | 188.9 |

The upstream runc bundle create, start, exec, signal, state and delete fixture completed in 200.8 ms. Image load/inspect, read-only binds, named volume persistence, DNS, exec streams, waits, lifecycle cleanup and Compose also passed. [Linux CI](https://github.com/castlemilk/micropod/actions/runs/44469387546/job/135374868084) · [Raw Linux receipt](https://github.com/castlemilk/micropod/actions/runs/44469387546/artifacts/14504071299)

## Native Micropod and CI

The native storage smoke took 22.4 seconds including compilation. The standalone Micropod daemon lifecycle took 1.87 seconds after the shipping binaries were available. The full native CI job took 13 min 57 s excluding queue time, including 380 s for the Swift build and 332 s for XCTest. XCTest reported 1,721 tests, 88 skipped and zero failures. The disposable HFS+ cross-volume workflow passed. The Linux reference took 31.7 seconds including the offline guest build and cleanup. [Native CI](https://github.com/castlemilk/micropod/actions/runs/44469387549) · [Native raw receipts](https://github.com/castlemilk/micropod/actions/runs/44469387549/artifacts/14503843113) · [Native storage smoke](https://github.com/castlemilk/micropod/actions/runs/44469387549/artifacts/14503771499)

| Included small files | Concurrent CLI clients | Measured blocks | Median full lifecycle ms | Min–max ms |
| --- | --- | --- | --- | --- |
| 32-files | 1 | 3 | 186.7 | 177.9–239.8 |
| 32-files | 4 | 3 | 225.2 | 198–263.6 |
| 32-files | 8 | 3 | 289.7 | 288.3–364 |
| 512-files | 1 | 3 | 558 | 527.4–585 |
| 512-files | 4 | 3 | 696.9 | 518.3–1087.6 |
| 512-files | 8 | 3 | 567.2 | 556.8–652.7 |

The client batches share a daemon-backed directory. Each batch checks that all IDs agree, verifies the complete tree, releases every reference, and checks that the final mount disappeared. The full production workflow also checked live create/delete, source protection for read-only clients, explicit sync, restart and GC.

An intermediate shim revision returned the wrong representation length for HEAD. The final HTTP smoke and the existing length regression check both passed after the fix.

The native shim advertised Docker API 1.44 and preserved GET representation length on HEAD. Two probes returned HTTP 501 for rootfs import and post-create network attachment. The hosted Mac exercised the real shim over its Unix socket. Its image did not include the Docker CLI.

## Coverage and reproducibility

The local OrbStack context was absent. The installed Micropod and Docker Desktop engine sockets returned permission denied to the benchmark process. No product guest timings were collected for those three endpoints. The opt-in product workflow runs all three on one prepared Apple Silicon Mac and records endpoint failures. No product-wide speed or compliance conclusion can be drawn from the Linux and host-copy rows.

Still open are full Buildx sessions and exporters, direct Micropod OCI and containerd Runtime v2, guest VirtioFS, Linux machines, Kubernetes, translation and energy. [Qualification matrix](../../../scripts/qualification/README.md) · [Backlog #182](https://github.com/castlemilk/micropod/issues/182)

The two host JSON files preserve warm-ups, individual workers, timings, fixture hashes, logical bytes and failures. The local checkout identifier differs from the published GitHub commit because the changes were committed independently. The receipts include SHA-256 digests of the production storage source files used. The benchmark code and fixes are in [PR #216](https://github.com/castlemilk/micropod/pull/216).

[Standard host samples](host-standard.json) · [Extended host samples](host-extended.json) · [Linux summary](linux-reference-summary.json) · [Native CI summary](native-ci-summary.json) · [Local endpoint probes](local-engine-availability.json)
