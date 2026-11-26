# Interactive Docker sessions and mutable CI on Gamma

The public Micropod HVF machine ran the stock Docker CLI against the container's initial process and the native Micropod CLI against interactive exec processes. The raw mounted checkout still favors OrbStack. These tests extend B4.4 and B4.5 with a stock-client compatibility gate and a checksum gate for host edits. The B3 measurements remain the direct-VMM networking reference. [B3 scorecards](../2026-11-25/phase-b3-results.md) · [B4 and B5 production plan](../../research/2026-11-25-phase-b4-plan.md)

## Native terminal exec

The ad-hoc-signed Swift release `31c78102d9a1` accepted `micropod exec -it build-1 sh`. It relayed early output, merged guest stderr on the PTY, passed literal guest flags and sent terminal resizes. The qualifier observed the initial 31×97 and final 42×113 dimensions. Ctrl-D returned the guest's exit 37. A guest trap received Ctrl-C and exited 42. Sending SIGTERM to the host CLI returned 143. Closing the receiving end of the host output pipe returned 141. Both host-side exits restored the terminal. Output-only `-t` preserved a binary payload resembling a Docker multiplex frame. Detached `-dit` returned immediately and the guest verified its own PTY. [Native terminal qualifier](../../../scripts/qualify_native_exec_tty.py) · [Docker exec options](https://docs.docker.com/reference/cli/docker/container/exec/)

Eight distinct containers on each engine each received a unique input, terminal size and exit status. A barrier held all eight open before input was sent. Stock Docker passed six case groups per endpoint and the Micropod release passed eight, including its two host-failure cases. All 16 containers from each two-endpoint qualification were removed. An initial single resize signal raced the stock CLI on OrbStack. The qualifier records each signal and retries after half a second. The Micropod CLI accepted the first signal on both endpoints. [Native receipts](native-terminal-gamma.json)

The final qualifier kept a second slave descriptor open through client exit. Its negative control deliberately exited in raw mode, and the observer detected the bad state. The same observer saw the original terminal settings after normal exit, a remote interrupt, SIGTERM and a broken output pipe. [Terminal receipts and negative control](native-terminal-gamma.json)

| Eight 2 MiB uploads and echoes, median wave | Micropod HVF | OrbStack | HVF paired wins |
|---|---:|---:|---:|
| Micropod release CLI | 696.8 ms | 787.7 ms | 4 of 4 |
| Stock Docker CLI | 751.7 ms | 839.8 ms | 4 of 4 |

These four counterbalanced non-TTY rounds exercised 128 scored execs, with distinct binary input and exit status for every job. Both engines also returned matching 32 MiB output hashes for both clients. All 16 containers were removed. The transfer test measures exec and stream handling under concurrency. The mounted-checkout measurement below exercises the filesystem and build tools. [Per-job checks and timing](native-terminal-gamma.json)

The release came from an isolated SwiftPM package at outer commit `76a329b6e464`. Building the initial source reconstruction identified two missing volume/image store dependencies from the previous change archive. The new patch includes both and reproduces all 600 captured package files. Its guest diagnostic overlay also records the SHA-256 of all 77 files in that separate Go build. All 372 selected release-mode XCTest cases passed, including command parsing, runtime and machine behavior, and the Docker shim. [Patch and source manifests](native-terminal-sources.tar.gz) · [Test receipts](native-terminal-gamma.json)

## Stock Docker attachment to PID 1

The original guest rejected interactive create requests. The corrected guest starts the original image command as PID 1 under its OCI credentials. A short launcher supplies the container's PTY or pipes. A temporary mount in the generation's private `/dev` tmpfs carries the launcher handshake. The guest verifies the peer against the running task reported by containerd, then closes the listener before executing the command. The container's stopped writable archive contained no launcher mountpoint. [Guest and stock-client evidence](core-pid1-and-mutable-gamma-receipts.tar.gz)

Stock `docker run -it` displayed the prompt before input, resized and returned the guest's exit status. The binary pipe fixture delivered 524,294 bytes with separate stderr. A client that closed its write half still received delayed output and another attachment could write to the same running process. Concurrent attach, keyboard detach and reattach, `start -ai` and four generations passed. A shell-free, read-only scratch image preserved UID 1234, GID 5678, the working directory, arguments including an empty string, and the image environment. Only stdin, stdout and stderr survived exec in the descriptor probe. The ordinary CRI path and launch failures 126 and 127 were also exercised. This guest still used an 8 MiB per-container output bound. [Gamma scorecard](core-pid1-and-mutable-gamma.json) · [Docker attach semantics](https://docs.docker.com/reference/cli/docker/container/attach/)

Docker CLI 29.7.2 returned status 1 and `read escape sequence` on keyboard detach on both engines. The sibling attachment and the guest command stayed live. Guest `89d4b15421ac` lets buffered output drain for as long as the spool makes progress. A paced 2.46-second pipe test detected the former fixed two-second cutoff. This guest returned all 8,257,536 bytes and exit 23 just below the retained-log cap. At 8,519,680 requested bytes the spool limit instead put the container into the dead state with exit −1. This failure became the verbose CI regression fixture. [Drain, detach and output-limit receipts](core-pid1-and-mutable-gamma-receipts.tar.gz)

## Verbose Docker jobs

The native Docker guest `dda4c5e3bd23` captures ordinary PID 1 output through pipes and retains complete stdout/stderr frames on the guest disk. A retained generation syncs its completed log before recording the offset. Each reader tracks its own position. The Linux tests cover an interrupted frame, recovery of legacy data and a failed write with the real exit code intact. An ordinary container that replaces its own `/dev` uses the CRI log path. The standalone job API keeps its original output limit. Docker log rotation, alternate drivers and time/tail queries remain outside this implementation. [Stock client qualifier](../../../scripts/qualify_docker_logs.py) · [Docker logging defaults](https://docs.docker.com/engine/logging/drivers/json-file/)

Stock Docker 29.7.2 received 16,777,236 stdout bytes and 8,388,628 stderr bytes from `docker run` with exit 23. Both streams matched OrbStack byte for byte in the foreground and from `docker logs`. A short job completed while the producer was writing. A deliberately slow reader received the full original generation after removal, while later generations had already completed. Across `start -a` and restart, retained replay returned 31,457,400 bytes with matching stream hashes. The ordinary non-root scratch image also preserved its original argv, environment, working directory, closed stdin semantics and separate output pipes. All 35 focused Linux tests passed. [Actual streams, exit codes and cleanup](core-pid1-and-mutable-gamma-receipts.tar.gz)

Twelve short starts on the previous guest took a median 108.2 ms, compared with 111.3 ms on the disk-backed guest. These were sequential groups on separately booted workers. The 2.9% observed increase has no counterbalanced estimate. The Micropod default retains data until removal. Gamma's OrbStack installation had a local 20 MiB × 5 rotation setting. [Both lifecycle series and configuration](core-pid1-and-mutable-gamma.json)

## Attached builds exiting 137

The archived guest aborted the same stock attached build both directly and through an observing proxy. Containerd's shim sent SIGKILL to the traced exec PID in both cases. A runner `ppoll` returned a kernel restart status 0.46–0.50 ms before each signal. The proxied client had half-closed stdin normally and held its read side open through server EOF. PID 1 remained running, the memory cgroups recorded zero OOM kills, and the trace reported zero lost events. The old runner treated an interrupted local poll as a client disconnect. [Correlated event, signal, socket and cgroup receipts](core-pid1-and-mutable-gamma-receipts.tar.gz)

The revised runner retries transient polling failures and records the reason when it successfully requests termination of a disconnected exec. An independently built guest `155046d80368` completed the cold primes and both alternating warm/edited pairs through each transport. Its Linux regression tests exercised half-close, full disconnect and transient poll errors. This replay observed no Python SIGKILL. The old trace identifies the sending shim and timing. It does not record the final userspace errno on the old worker. [Source overlay](native-terminal-sources.tar.gz) · [Replay receipts](core-pid1-and-mutable-gamma-receipts.tar.gz)

## Mutable host checkout

Each engine received an independent, byte-identical 1,058-file checkout and two CPUs with 1,536 MiB. Each host publication had to become visible to the guest by SHA-256, each Git status had to match the expected edit, and the built binary had to match across engines. The guest clock sums Git status, Go build and three uncached Go test subprocesses. The inclusive clock starts at the host edit and ends after the verified build. Separate detached stock Docker execs kept this timing independent of the old guest's attached-build failure. [Measurement receipts](core-pid1-and-mutable-gamma.json)

| Ambient baseline, median of four alternating pairs | Micropod HVF | OrbStack |
|---|---:|---:|
| Warm Git, build and test | 894.3 ms | 654.4 ms |
| Edited Git, build and test | 2,038.1 ms | 1,897.8 ms |
| Host edit returned through matching guest bytes | 15.9 ms | 37.5 ms |
| Host edit began through verified build | 2,118.5 ms | 2,014.2 ms |

Across the warm pairs, the median HVF deficit was 234.0 ms. Git status alone accounted for a median 130.1 ms difference. The edited pairs had a 125.3 ms median Git difference. These observations put mutable Git metadata and content revalidation ahead of interrupt timing as performance targets. [Per-phase timings](core-pid1-and-mutable-gamma.json)

Advancing the first VirtioFS completion interrupt during a queue drain produced 14,697 acknowledged early interrupts. In the same-binary control and enabled arms, the warm HVF/OrbStack medians were 890.7/653.7 ms and 1,132.5/769.7 ms. Weighted host idle fell from 76.7% to 56.6% between arms. The observed pairs do not establish a performance gain. The switch defaults off. [Per-arm timings and interrupt counters](core-pid1-and-mutable-gamma.json)

All 16 ordinary edit checks passed on both interrupt settings. A stricter test held a guest file descriptor open, changed bytes through a writable **host** mapping on the same inode, and restored the original modification timestamp to the nanosecond. The frozen VMM and both IRQ arms returned the old bytes from the open guest descriptor. Reopening a path is a different test. Freshness of ordinary reads, file-to-pipe transfers, and already-faulted **guest** mappings is tracked separately. [Strict matrix and source](core-pid1-and-mutable-gamma-receipts.tar.gz) · [Linux FUSE I/O modes](https://kernel.org/doc/html/latest/filesystems/fuse/fuse-io.html)

The separate VMM `400ee99ae3b9` negotiated FUSE direct I/O with shared mapping support for regular files on the mutable workspace. Ordinary reads on both held descriptors saw the host edit. Old descriptors continued to reference the old inode after replacement. Private mapping and guest shared writes passed, and a newly faulted shared mapping saw the host edit. On Linux 7.3.5, a prefaulted guest mapping, `sendfile` and `splice` still returned old bytes. The option defaults off. [Per-interface observations](core-pid1-and-mutable-gamma-receipts.tar.gz)

A brief concurrent Go compile overlapped the first direct-I/O scoring window. The clean four-pair repeat recorded 79.3% host idle. Warm Git/build/test took 898.4 ms on HVF and 654.4 ms on OrbStack. Edited runs took 2,103.8 and 1,956.4 ms. The edited bytes became visible after 13.2 and 31.9 ms, and the full edit-to-verified-build clocks were 2,173.0 and 2,061.0 ms. The direct-I/O candidate improved the correctness of ordinary reads. These measurements retain OrbStack's warm-checkout lead. [Both scoring windows](core-pid1-and-mutable-gamma.json)

### Matched Linux splice backport

Two Linux 7.3.5 kernels used the same source, B5 configuration, toolchain, signed VMM and guest runner. The rebuilt stock image `ae067356ec5e` differs bytewise from the historical B5 binary. The paired patch image `dba972178942` adds upstream commit `10bd6b329652`, which directs FUSE file-to-pipe reads through the negotiated direct-I/O path. The untouched-file control checked offsets, short reads and EOF on both images. [Upstream commit](https://kernel.googlesource.com/pub/scm/linux/kernel/git/tip/tip/%2B/10bd6b32965265688fa277d166ab224de8e86eb2) · [Matched source, flags and probes](core-pid1-and-mutable-gamma-receipts.tar.gz)

| Same host rewrite and restored mtime | Rebuilt stock B5 with direct I/O | B5 with direct I/O and splice backport |
|---|---|---|
| Ordinary read on an open descriptor | Fresh | Fresh |
| `sendfile` on an open descriptor | Stale | Fresh |
| `splice` on an open descriptor | Stale | Fresh |
| Newly faulted shared guest mapping | Fresh | Fresh |
| Already-faulted shared guest mapping | Stale | Stale |
| Atomic replacement, guest shared write, private mapping | Passed | Passed |

Applications that rely on a resident shared mapping reflecting external Mac edits still have a correctness gap. The gated candidate and the published baseline remain identifiable by their separate digests. [Full matrix](core-pid1-and-mutable-gamma.json)

The four alternating pairs on the patched kernel measured 905.3/646.6 ms for warm Git/build/test and 2,083.1/1,970.7 ms after an edit, in HVF/OrbStack order. Returning verified edited bytes took 13.2/32.3 ms. The full edit-to-build clock was 2,152.1/2,069.1 ms at 80.0% measured host idle. [Source-matched kernel build](../../../ci/patches/build-virtiofs-splice-kernel.sh) · [Per-pair measurements](core-pid1-and-mutable-gamma.json)

## Combined public machine and eight CI containers

The signed VMM `08ad6edf752e` also clears negotiation state when restoring an older snapshot. Only a writable share named `workspace` can recover the direct-I/O setting. Replaying the change reproduced all 42 captured VMM source files, and all 49 Virtio device tests passed. The public machine used this VMM with the patched kernel, guest `89d4b15421ac`, signed CLI `31c78102d9a1` and the existing initrd. The ordinary-read option was explicitly enabled for this run. [Source manifest and hardware checks](core-pid1-and-mutable-gamma.json)

Stock Compose brought up two services on their project network. A service resolved its peer, consumed its HTTP response and exposed its logs. Compose exec and teardown completed. A separate terminal run on the same machine passed all six stock-client groups and eight native-client groups and removed all eight test containers. [Compose commands and teardown](core-pid1-and-mutable-gamma-receipts.tar.gz) · [Terminal assertions](native-terminal-gamma.json)

| Median time to finish eight parallel jobs | Micropod HVF | OrbStack | HVF paired wins |
|---|---:|---:|---:|
| Warm checkout | 394.6 ms | 417.0 ms | 3 of 4 |
| First build after host edit | 669.6 ms | 705.0 ms | 4 of 4 |

Each container ran Git, compiled the seven-file Micropod guest helper and reran its five Linux tests. The guest cgroups enforced 0.5 CPU and 384 MiB per job. Every timed wave had eight jobs simultaneously in measured subprocesses, and all output binaries matched. The clock spans the first Git start to the last test completion on each engine. Weighted host idle was 80.5% over the run. All 16 containers were removed. The 1,058-file checkout above remains the reference for repository-size scaling. [Per-container limits, job overlap, digests and cleanup](core-pid1-and-mutable-gamma.json)

## CI density on the disk-backed logging guest

Both engines reported four CPUs and about 4 GiB of memory. Each job had a separate build cache and mounted the same source read-only. The workload was the seven-file helper and its five uncached tests. Every timed wave overlapped across all jobs. All matching cross-engine builds produced identical binaries. These four-pair ambient runs recorded 80.8% whole-host idle for eight jobs and 81.7% for sixteen. [Individual job clocks and hardware state](core-pid1-and-mutable-gamma.json)

| Concurrent jobs | CPU and memory per job | Wave | Micropod HVF | OrbStack | HVF paired wins |
|---:|---|---|---:|---:|---:|
| 8 | 0.5 CPU, 384 MiB | Warm | 384.3 ms | 434.2 ms | 3 of 4 |
| 8 | 0.5 CPU, 384 MiB | After edit | 653.2 ms | 723.6 ms | 4 of 4 |
| 16 | 0.25 CPU, 384 MiB | Warm | 832.6 ms | 837.3 ms | 3 of 4 |
| 16 | 0.25 CPU, 384 MiB | After edit | 1,360.4 ms | 1,557.8 ms | 3 of 4 |

The first sixteen-job run launched sixteen cold Go compilers with a 256 MiB limit per container. The Micropod kernel recorded one whole-VM OOM selection and nine memory-cgroup OOM selections for `compile`. The Docker event stream recorded OOM events for thirteen containers. The benchmark failed during cold preparation. Both engines removed their sixteen containers. [Kernel, events and failed preparation](core-pid1-and-mutable-gamma-receipts.tar.gz)

For the successful sixteen-job run, each container received a 384 MiB limit and each engine prepared its sixteen independent caches in two groups of eight. Preparation took 67.4 seconds on HVF and 71.5 seconds on OrbStack, including the group barriers. Scoring then released all sixteen together. The shortest interval with all sixteen doing timed work was 684.7 ms across the warm waves and 1,149.7 ms after an edit. Both the memory limit and cold concurrency changed in the retry. The benchmark driver controls cold admission explicitly. Arbitrary Docker workloads on a four-GiB machine can still exhaust memory. [Cold and timed phase receipts](core-pid1-and-mutable-gamma.json) · [Benchmark entry point](../../../scripts/bench_workspace_checkout.py)

## Native Docker Engine API contract

The earlier 36-operation comparison used dockerd with Engine API 1.56. For this audit the HTTP requests and stock Docker CLI both use the native engine's advertised maximum of 1.47. The qualifier validates the checksum of Moby's matching specification. It exercised 36 of its 107 operations in 23 case groups. A match means the observed responses agreed within that probe. For example, the info probe checks HTTP status and response shape. [Version-pinned qualification](../../../scripts/qualify_engine_api.py) · [Moby 1.47 specification](https://github.com/moby/moby/blob/v27.5.1/api/swagger.yaml)

On guest `dda4c5e3bd23`, ten groups matched OrbStack. The volume and network lifecycles, container name-conflict and exit handling, retained logs, filtered container events, archive round trip and stock attach/exec passed. Both clients observed the expected streams and exits 23 and 41 in the last two groups. Thirteen groups differed. These included advertised versions, ping headers, Swarm/plugin responses and image inspect/history. On the same Alpine ARM64 image, the native inspect reply omitted `RootFS`. OrbStack returned the uncompressed layer digest under `RootFS.Layers`. Every scoped container, volume and network was removed on both endpoints. [Observed responses and scope checks](core-pid1-and-mutable-gamma.json)

Guest `a8a2da8b20a7` now reads uncompressed diff IDs from the OCI config and returns them in layer order. The exact same 1.47 audit on a fresh public worker matched eleven groups. Image inspect was the only group that changed, and every OrbStack reference observation reproduced. Stock Docker returned the expected Alpine digest, architecture, working directory and command. A separate image verified eight ordered diff IDs. Nine focused Linux cases exercised shape and lookup errors. Image history, plugins and Swarm responses still differ, and the engine advertises versions 1.44–1.47. The CI timings above use the earlier `dda4` guest. [Pinned 1.47 responses](native-docker-api-v1.47.json.gz) · [Image inspection implementation](../../../guest/runner/docker_http_linux.go) · [Focused regression cases](../../../guest/runner/docker_image_inspect_linux_test.go)

## Distribution signing

The release scripts now apply the project-owned `com.apple.security.hypervisor` entitlement when re-signing the bundled VMM and check it after the app seal. The headless archive copies staged VMM, initrd, kernel and OCI assets from the sealed bundle. A private ad-hoc signing fixture used the measured VMM, synthetic guest assets and four package layouts. The archived VMM matched its app counterpart byte for byte. Removing the entitlement from an otherwise valid sealed app failed the check. The fixture did not exercise a Developer ID signature, notarization or startup after a clean installation. [Signing check](../../../scripts/make_dmg.sh) · [Release archive assembly](../../../.github/workflows/release.yml) · [Source and replay receipts](core-pid1-and-mutable-gamma-receipts.tar.gz)


## Drive cleanup and the preserved baseline

All fifteen worker disks and their shared staging drive were disposable APFS images. Each worker shut down cleanly and released its machine lock. Read-only remounts verified the suppression markers, disabled Spotlight indexing and zero FSEvents journal files or bytes. Cleanup removed the backing images, test image tag and private staging directory. The archive contains 581 individually verified receipts. [Machine and drive audit](core-pid1-and-mutable-gamma.json) · [Raw receipt archive](core-pid1-and-mutable-gamma-receipts.tar.gz)

The original 6,573.34 MiB/s baseline and its preserved copy each matched all 24 manifest entries. The resumed suite detected the existing QoS pair and stopped before duplicating it. Independent controlled schedules measured 7,934.1/6,294.1 MiB/s at Standard/Interactive QoS and 6,504.7/5,845.0 MiB/s with two/four relay workers. Interactive lowered fresh-request p95 from 10.187 to 6.356 ms. The corresponding ambient throughputs were 7,777.2/6,264.7 and 6,413.5/5,774.7 MiB/s. [Original QoS, worker and cleanup results](../2026-11-24/gamma-qos-and-workers/results.md)
