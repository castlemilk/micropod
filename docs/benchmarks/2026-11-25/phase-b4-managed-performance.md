# Managed Docker lifecycle and CI performance on Gamma

On 25 November 2026 the source-built Micropod engine preserved a retained container across Docker and Compose restarts on both Hypervisor.framework (HVF) and Virtualization.framework (VZ). A direct HVF worker recovered the same container after a clean shutdown and after its Mac supervisor was killed. On the four-vCPU worker, per-network CUBIC also closed the quiet sibling-bulk gap from B3. Busy CI workloads, interactive Docker operations and signed installation still have open gates. [Scorecard](phase-b4-managed-performance.json) · [Raw observations, hashes and diagnostic sources](phase-b4-managed-performance-receipts.json.gz) · [Frozen VMM source for the three measured builds](phase-b4-vmm-sources.tar.gz) · [B3 report](phase-b3-results.md)

The subsequent Gamma run covers Docker and Compose event streams, workspace admission and 32 active compilers, including short and sustained transfers. [Follow-up scorecard](phase-b4-ci-density-and-events.md)

## Docker behavior

| Check | Observed result |
|---|---|
| Stock Docker and Compose | Both native backends and OrbStack preserved container ID, file contents, mode, uid, gid, mtime, hard links, symlinks, lower-layer deletion and rename. Each restart launched a fresh process. Graceful stop ran the shell's TERM handler. Read-only containers continued to reject writes. |
| Entrypoint and CPU limits | The earlier native worker ran the shell as PID 3 while the CRI pause process occupied PID 1. The updated worker ran the image entrypoint as PID 1, including after restart. Its PID 1 and cgroup both reported CPUs 2–3 and the requested quota of 6,250 µs per 100,000 µs period. |
| Public Micropod client | On HVF and VZ, `micropod runtime ls` advertised restart on the verified native endpoint. `micropod run --runtime ci` followed by `micropod restart` retained a marker written outside any volume. |
| Supervisor loss | Before the parent-process fix, the surviving VMM still held the writable disk after three seconds. The updated VMM released it within the observation window. The recovered record reported `dead`, exit `-1`. Explicit `docker start` recovered both synced files under the original ID across three worker instances. |
| Snapshot removal | On a dedicated HVF worker a read-only `ctr` observer listed five containerd snapshot keys with two stopped containers present, then four and three after their respective `docker rm` calls. Each removal deleted just the corresponding owned key. Both containers shared the same committed image parent. The observer measured removal from the snapshotter catalog. Host sparse-image space recovery needs a separate allocation measurement. |

The guest pins each retained writable snapshot to the container's immutable image parent and saves its attachment intent before starting the CRI task. If containerd loses an allocation or attachment reply, the worker uses the Linux boot identity to fence an uncertain operation before reclaiming the layer. A missing recorded ready layer produces an error. Older containers can acquire a durable layer on their next successful start. An earlier build's already discarded data cannot be recovered. The stock-client gate covers Docker and Compose. Separate checks exercised the public Micropod CLI and ran 17 lifecycle and storage tests in each native Linux guest. [Implementation](../../../guest/runner/docker_rootfs_linux.go) · [Docker/Compose gate](../../../scripts/qualify_docker_restart.py) · [Docker restart semantics](https://docs.docker.com/reference/cli/docker/container/restart/)

## Sibling network under CI load

Each arm transferred exactly 6 GiB over 32 existing TCP connections between two containers. Both endpoints executed matching, hash-verified ARM64 probes. The first BBR/CUBIC A/B recorded the probe’s algorithm check. Direct comparisons record the Linux congestion algorithm for all 32 accepted sockets in every arm. There were zero connection reopens in scored transfers. References used OrbStack 2.2.5, Docker Engine 29.8.2, and the same internal IPvlan topology. Both workers had four vCPUs and approximately 4 GiB of RAM. The B4 kernel includes BBR and CUBIC. In the first matched A/B only the selected internal network requested a route algorithm. The later checkout also requests CUBIC at managed HVF boot. The final HVF guest reported CUBIC as its default, and VZ reported BBR. These tests measure sibling networking inside a VM. B3's host-published TCP results have their own workload. [Network harness](../../../scripts/bench_engine_tuning.py) · [Probe](../../../scripts/netbench/main.go)

| 6 GiB workload | Reference, MiB/s | Micropod CUBIC, MiB/s | Median paired change | Micropod wins |
|---|---:|---:|---:|---:|
| Earlier HVF, BBR reference on same kernel | 19,376 | 26,781 | +38.84% | 4/4 |
| Earlier network changes, quiet OrbStack reference | 24,754 | 26,260 | +6.25% | 6/6 |
| Earlier lifecycle build, quiet OrbStack reference | 24,352 | 26,551 | +5.75% | 5/6 |
| Reconciled checkout, quiet OrbStack reference | 24,832 | 26,631 | +6.85% | 6/6 |
| Earlier build, 32 compilers on the host share | 11,477 | 10,189 | -12.33% | 1/4 |
| Earlier build, same load pinned to guest CPUs 2–3 | 8,340 | 8,529 | +3.97% | 2/4 |
| Reconciled checkout, 32 compilers on the host share | 10,680 | 7,538 | -31.07% | 1/4 |
| Reconciled checkout, 32 compilers in the image | 9,492 | 7,132 | -11.66% | 0/4 |

The paired change is the median of the within-pair ratios. Each dense arm kept 32 Alpine containers continuously compiling the same Go source with the same hashed compiler. The harness verified every job's quota and progress before and after the service tests. Compiler rates in the receipt bound work across the entire counter-reading interval, which includes workload setup and latency probes. Bulk throughput alone cannot establish higher CI job throughput. [Dense workload](../../../scripts/sibling_dense_load.py)

Quiet unrestricted HTTP p50 was 31.42 µs on HVF and 12.58 µs on OrbStack. Pinning the client and service to one guest vCPU gave 13.12 and 11.48 µs. For 32 parallel DNS clients, p95 was 376 and 653 µs. These results leave unrestricted request latency open.

BuildKit took 9.59 s for a fresh two-stage build and 1.15 s for its three-layer cached repeat on another new HVF disk. All 32 C jobs were running together, all exited zero and all outputs matched. Their named volume, containers and tags were removed. This qualification exercises different toolchains and concurrency from the 32-compiler network experiment. [BuildKit and CI workload](../../../scripts/qualify_ci_build.py)

The final sibling comparison loaded the same Alpine OCI manifest into both engines and verified both probe executables in the guest. Two earlier host-mounted attempts on the reference engine failed before scoring. One service exited with the quiet HTTP program’s usage output when the server binary was requested. The immutable fixture removes that ambiguity. Its manifest and config digests link the two image-ID formats returned by the daemons. Both tags were removed after each run.

### Published TCP

Each build received two alternating pairs on one Mac loopback port. Each scored arm mixed 32 bulk streams and 240 fresh requests at 40/s. The table gives the median of the two throughput samples and of the two fresh-request p95 values. Every scored arm completed with zero failures and zero reopens. [Published workload](../../../scripts/netbench/offered/main.go)

| Frozen source on Gamma | HVF bulk, MiB/s | OrbStack bulk, MiB/s | HVF fresh p95 | OrbStack fresh p95 |
|---|---:|---:|---:|---:|
| Build used for the sibling and dense comparisons | 10,529 | 7,491 | 11.44 ms | 5.38 ms |
| Later VMM changes, including a 512 KiB default send buffer | **11,768** | **7,517** | **3.62 ms** | **5.02 ms** |

The later build exceeded OrbStack in throughput and had a lower fresh p95 in both pairs. It also passed the three-instance supervisor recovery test. Its changes include a smaller default host socket send buffer, descriptor reuse and block discard. These measurements cover the combined build. A single-port result of 11,768 MiB/s at 3.62 ms leaves the B4.2 acceptance target of 13,000 MiB/s at 1.2 ms open. The 32-compiler comparisons above used the earlier frozen VMM. [Binary and source hashes for both builds](phase-b4-managed-performance.json)

## Mutable workspace

The guest primed the original eight bytes, then the host resized the file, overwrote it in place, replaced it atomically or unlinked it. The replacement check required a new open to see the replacement while the held descriptor continued reading the original. Times include the host operation, guest observation, and the completion marker's return to the host.

| Median acknowledgement | Previous HVF, 4 repeats | Updated HVF, 6 repeats | OrbStack, 6 repeats |
|---|---:|---:|---:|
| Resize | 1,002.9 ms | 11.4 ms | 2.3 ms |
| Same-size write on held descriptor | 0/4 by 1.8 s | 12.0 ms | 95.9 ms |
| Atomic replacement with old descriptor preserved | 0/4 | 1.9 ms | 0/6 |
| Unlink | 1,002.0 ms | 9.7 ms | 95.5 ms |

All 24 checks passed on the updated HVF worker. Its slowest acknowledgement was 12.62 ms. In this OrbStack fixture the held descriptor returned the replacement bytes on all six atomic saves. The Micropod VMM now revalidates mutable entries at an 8 ms attribute lifetime and gives a replaced host inode a distinct FUSE identity. Review rejected an experimental `KEEP_CACHE` shortcut because two concurrent opens could expose stale pages before the first invalidation completed. Its timing is archived as an excluded experiment. [Host harness](../../../scripts/bench_workspace_edits.py) · [Guest probe](../../../scripts/workspacebench/main.go) · [Linux FUSE I/O modes](https://docs.kernel.org/filesystems/fuse/fuse-io.html)

For 512 files across 32 directories, the three HVF open/read/hash passes took 51.4, 51.9 and 53.3 ms. OrbStack took 10.1, 6.6 and 6.5 ms. All passes verified the same lexical paths and 20,772 source bytes. The latency fix closes the measured host-edit gate. Source-tree reads, Git, tar and full host-mounted builds remain performance work. The old VMM used its matching earlier launcher for this comparison. All three engines ran the same probe. An intermediate HVF comparison also fixed the B4 kernel and guest runner across the old and updated VMMs. It independently passed all 24 edits on the updated VMM. [Full per-pass data](phase-b4-managed-performance.json)

A later asynchronous VirtioFS build also passed all 24 edit checks. Its medians were 11.46 ms for resize, 11.67 ms for a held descriptor, 2.28 ms for replacement and 9.97 ms for unlink. Its three tree reads took 51.4, 50.7 and 48.0 ms. The asynchronous path retained correctness in this fixture and left the source-tree throughput gap open. [Async workspace receipt](phase-b4-managed-performance.json)

## Reproduction and release scope

Run the stock-client gate against an explicitly selected native worker with Alpine 3.23 available. To repeat the paired network comparison, put the Linux ARM64 `netbench-linux` and `quiet-http` probes in the worker's configured workspace. For dense runs also put the ARM64 Go compiler at `compile`. The reference daemon must be able to read the same paths. The harness verifies the binaries inside the containers. To use image-resident probes, preload one Alpine image with the executables under `/mpw` and add `--probe-image TAG`. Use `--compiler-in-image` to select the compiler there. If the daemons report config and manifest digests as their image IDs, `--probe-manifest FILE` accepts the exact OCI manifest bytes linking them. [Worker guide](../../ci-worker.md)

```sh
endpoint=$(micropod ci runner-docker-endpoint)
python3 -B scripts/qualify_docker_restart.py --host "$endpoint" --json
python3 -B scripts/bench_engine_tuning.py live-siblings \
  --hvf-socket "${endpoint#unix://}" --workspace "$MICROPOD_CI_WORKSPACE" \
  --pairs 4 --dense --out dense-siblings.json
```

Each of the 87 disposable APFS volumes in this series passed read-only remount inspection. Spotlight indexing was disabled, the FSEvents journal contained zero files, and the run-owned images and mounts were removed. Every recorded worker stop released its process group and disk handles. All 24 original baseline files and their 24 preserved copies still match their SHA-256 manifest. In the earlier controlled QoS run, Standard delivered 7,934 MiB/s and Interactive 6,294 MiB/s. Two relay workers delivered 6,505 MiB/s and four delivered 5,845 MiB/s. [Original QoS and worker results](../2026-11-24/gamma-qos-and-workers/results.md)

Stock Docker and Compose subsequently passed container and exec event checks on both managed backends. Image, volume and network events, interactive attach/TTY, archive copy, live network connect/disconnect and expanded version negotiation remain open. Native restart supports retained containers and bounded grace periods. Explicit signal overrides support SIGKILL. The Rust VMM is currently an untracked tree in the outer checkout. Release packaging must bring it together with the Phase 0 checkout's CLI, kernel, initrd and guest tools, then qualify a signed installation on a clean Mac. Phase B4.2 published networking, long-running CI and B5 snapshot/restore retain their independent acceptance criteria. [Event and CI results](phase-b4-ci-density-and-events.md) · [B4/B5 plan](../../research/2026-11-25-phase-b4-plan.md) · [Earlier managed qualification](managed-engine-compatibility.md)

The sibling benchmark build passed 24 Rust workspace tests. The published-port follow-up passed 25, including a host APFS hole-punch test. The asynchronous workspace build passed 27. The software checks also passed 38 Swift XCTest cases, 15 Swift Testing cases, the portable Go race suite, Linux ARM64 vet and ten offline Python harness tests. Raw receipts identify each tested artifact. Additional lifecycle coverage should exercise an attached output stream across a rapid restart and stopping the owned task if published-route teardown fails.
