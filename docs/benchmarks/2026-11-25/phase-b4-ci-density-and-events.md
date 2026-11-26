# Managed Docker events and CI density on Gamma

Stock Docker and Compose now receive native container and exec events through both managed backends. The 32-compiler comparisons below measure foreground networking and completed CI work together. [Scorecard](phase-b4-ci-density-and-events.json) · [Raw measurements and logs](phase-b4-ci-density-and-events-receipts.json.gz) · [Frozen source and harnesses](phase-b4-ci-density-and-events-sources.tar.gz) · [Earlier B4 results](phase-b4-managed-performance.md)

On the final 60 GiB run with the compiler inside the image, HVF led in 3 of 4 pairs with a median paired change of +3.04%. With the compiler on a host share and default CPU placement, the 6 GiB run recorded -5.96% against OrbStack. A 512-file open/read/hash took 48.60 ms on the 8 ms HVF configuration and 6.61 ms on OrbStack.

## Docker compatibility

Each client watched the same uniquely labelled service through two starts, graceful exits, stops and removal. An exec returning 23 and another returning 0 each produced a create, start and exit event with the same exec ID and the right exit code. Time-bounded queries reproduced the filtered events, including 12 exec records, and excluded an unrelated label. [Stock-client qualification](../../../scripts/qualify_docker_events.py) · [Docker event semantics](https://docs.docker.com/reference/cli/docker/system/events/)

| Final socket | Before / subscribed / closed | Time to release | Guest tests |
|---|---:|---:|---:|
| HVF | 0 / 2 / 0 | 0.066 s | 16 |
| VZ | 0 / 2 / 0 | 0.060 s | 16 |
| Full snapshot branch, normal HVF boot | 0 / 2 / 0 | 0.061 s | 16 |
| OrbStack | 3 / 5 / 3 | 23.382 s | — |

The native daemon retains up to 256 recent events within an estimated 8 MiB and admits up to 64 concurrent subscriptions. The history is local to the running daemon. An acknowledged explicit SIGKILL publishes a kill event. CRI’s ordinary stop reply supplies no signal number. Compatibility work remains for image, network and volume events, interactive stdin/TTY, archive copy, live network attachment and broader API version coverage. Signed installation on a clean Mac remains a release gate. [Event service](../../../guest/runner/docker_events.go) · [Native routes](../../../guest/runner/docker_events_linux.go)

Both native workers read and wrote a host directory whose name contained spaces and double quotes. A Linux process synced a file, renamed it, synced its parent directory and returned the expected content hash to the Mac. HVF startup verifies the digest of an encoded workspace against the running guest. Pairing the new launcher with the old initrd failed admission with the expected diagnostic. The VMM now checks the opened handle and propagates errors for file and directory sync. Rust tests exercised the error path with a real failing host descriptor. [Launcher](../../../Sources/MicropodRuntime/HVFWorker.swift) · [Guest workspace setup](../../../vmm/guest-init/workspace.go)

## Sibling TCP while 32 CI containers compile

Both engines had four vCPUs and approximately 4 GiB. Each of 32 Alpine containers had 128 MiB and 1/16 CPU and repeatedly compiled the same Go source using the same ARM64 compiler. Each transfer used 32 established TCP connections. All scored arms verified the workload bytes, CUBIC on every accepted socket and zero reopens. Controlled runs began after two host samples at or above 90% idle. The order of engines alternated across pairs. “Change” is the median of within-pair percentage changes. [Network harness](../../../scripts/bench_engine_tuning.py) · [Compiler telemetry](../../../scripts/sibling_dense_load.py)

| Compiler and profile | Transfer | HVF MiB/s | OrbStack MiB/s | Change | HVF wins |
|---|---:|---:|---:|---:|---:|
| Initial image, default | 6 GiB | 11,051 | 11,469 | -3.66% | 1/4 |
| Initial image, default | 60 GiB | 12,338 | 12,081 | +2.24% | 4/4 |
| Image, wakeup co-location disabled | 60 GiB | 11,962 | 12,140 | -0.37% | 2/4 |
| Image, 32 ms quota period | 6 GiB | 10,533 | 11,129 | -2.51% | 1/4 |
| Image, 32 ms quota period | 60 GiB | 12,043 | 12,027 | +0.12% | 2/4 |
| Image, explicit round-robin | 6 GiB | 11,999 | 11,756 | +4.45% | 3/4 |
| Image, explicit round-robin | 60 GiB | 11,926 | 12,191 | -2.52% | 1/4 |
| Initial host share, default | 6 GiB | 10,270 | 10,501 | -1.55% | 1/4 |
| Initial host share, explicit round-robin | 6 GiB | 10,604 | 11,642 | -8.59% | 0/4 |
| Integrated image, CI groups | 6 GiB | 11,264 | 11,808 | -4.75% | 1/4 |
| Integrated host share, default | 6 GiB | 9,804 | 10,856 | -5.96% | 1/4 |
| Integrated host share, CI groups | 6 GiB | 10,606 | 11,859 | -11.79% | 0/4 |
| Snapshot branch on normal boot, image, default | 60 GiB | 11,723 | 11,550 | +3.04% | 3/4 |

The 6 GiB burst and 60 GiB transfer produced different rankings. The integrated CI-group run used a distinct `io.micropod.ci.cpu-group` label for each network-isolated job. Micropod assigned the CPUs. OrbStack received explicit round-robin CPU masks. Inspect and in-guest readback confirmed the 32 native workers’ identities, process generations, CPU masks, quotas and absence of `eth0`. Eight ran on each vCPU. Explicit placement remains optional. Previous B4 figures use an earlier build and a different sampling protocol. [CPU-group admission](../../../guest/runner/docker_config_linux.go) · [Worker guide](../../ci-worker.md)

Each successful compile produced a timestamp inside its own cgroup. The following rates bound completions reported by the shell during foreground TCP. The JSON also contains conservative bounds on actual compiler exits and CPU time, and the individual records for each worker. Shorter transfers have wider bounds. [Raw observations](phase-b4-ci-density-and-events-receipts.json.gz)

| Workload | HVF reported compiles/s | OrbStack reported compiles/s |
|---|---:|---:|
| Initial image, default, 60 GiB | 166.0–167.1 | 165.4–166.8 |
| Integrated host share, default, 6 GiB | 119.9–131.3 | 152.9–165.9 |
| Integrated host share, CI groups, 6 GiB | 114.0–123.5 | 156.5–166.9 |
| Snapshot branch on normal boot, image, default, 60 GiB | 161.9–162.7 | 158.3–160.7 |

With native CI groups, the integrated image-resident compiler reported 156–163 completions/s. Running that compiler from the host share yielded 114–124/s. In both cases the generated source and object lived in guest scratch space. This isolates toolchain location for the fixture. A full checkout build has a different I/O pattern.

A separate ambient run started at 69.77% host idle with another reference container already running. Its two shared-compiler pairs gave +112.29% and −7.98% in foreground TCP. Those observations have a different load condition from the controlled comparison. [Ambient receipt](phase-b4-ci-density-and-events.json)

## Mutable workspaces and Hypervisor.framework

Each pass walked 512 source files and hashed 20,772 bytes in lexical order. Each edit fixture tested six resizes, six held-descriptor overwrites, six atomic replacements and six unlinks. After an atomic replacement the held descriptor had to keep reading the original file. The read figure is the median across fixture medians, with three timed reads per fixture. [Workspace gate](../../../scripts/bench_workspace_edits.py)

| Source or reference | Completed scan fixtures | Median open/read/hash | All edit checks passed |
|---|---:|---:|---:|
| Initial HVF | 4 | 52.55 ms | 4/4 |
| Small-packet reuse candidate | 4 | 52.18 ms | 4/4 |
| Initial HVF, later crossover | 2 | 50.31 ms | 2/2 |
| Integrated HVF, 20 ms | 2 | 49.03 ms | 2/2 |
| Fixed code, 20 ms | 2 | 46.26 ms | 2/2 |
| Fixed code, 8 ms | 2 | 48.60 ms | 2/2 |
| OrbStack | 2 | 6.61 ms | 0/2 |

The isolated small-packet reuse candidate moved the four-fixture median from 52.55 to 52.18 ms. A later directory-descriptor implementation superseded it in the outer VMM tree. OrbStack read the verified tree faster. Its atomic-replace checks exposed either replacement bytes through the held descriptor or a transient missing pathname after host rename. Two reference attempts ended before the tree scan. The updated harness preserved the edit failure and independently completed the scan, checking both the path and data digests. [Source snapshots](phase-b4-ci-density-and-events-sources.tar.gz)

On the same VMM code, the 8 ms attribute lifetime acknowledged a held-descriptor overwrite in 11.90 ms versus 24.04 ms at 20 ms. The corresponding 512-file read medians were 48.60 and 46.26 ms in two fixtures per setting. All 96 edit acknowledgements across the two settings passed. These measurements cover this source tree and this host.

A concurrent snapshot-branch change initially failed stable Rust compilation on the ARM64 SIMD vector ABI. The corrected C bridge uses the Apple SDK declarations. A signed Gamma test created a VM and vCPU, round-tripped distinct 128-bit Q0 and Q31 values through unaligned Rust buffers and released both. The full frozen snapshot-branch checkout also passed 31 workspace tests. That SIMD probe covered individual registers. The subsequent B5 fork runs checked VM restore correctness, clone isolation, time to Docker readiness and process retirement. [Apple SIMD register API](https://developer.apple.com/documentation/hypervisor/hv_vcpu_get_simd_fp_reg%28_%3A_%3A_%3A%29) · [Hardware probe output](phase-b4-ci-density-and-events-receipts.json.gz)

## Cleanup and reproduction

All 82 disposable APFS volumes in these receipts had Spotlight indexing disabled, the FSEvents no-log marker present and zero persistent journal files at read-only remount. Every measured worker released its process group and disk handles. The 24 original baseline files and their 24 preserved copies still match their recorded SHA-256 values. [Original controlled and ambient QoS and worker results](../2026-11-24/gamma-qos-and-workers/results.md)

An initial unbounded reference event probe closed both CLI processes. OrbStack continued to report two additional listeners on its shared daemon. Later reference probes supplied an expiry and returned to their starting count. The native backends released their listeners on disconnect.

During staging, a symlink caused writes to three files in Gamma’s qualified tool installation. The three files were restored from hash-identical copies. All 37 guest files and both host binaries were checked. An unpinned Rust version probe refreshed the `stable` alias to 1.100.0. The existing fixed toolchains and project configuration retained their original state, and the full snapshot-branch build used pinned Rust 1.99.1.

The source archive pins the VMM versions, final managed sources and diagnostic harnesses. The raw receipts identify the CLI, kernel, initrd, runner and probe bytes for each native performance attempt.

Run the stock-client gate against a selected private worker with Alpine 3.23 preloaded. The dense harness expects Linux ARM64 network probes and a compiler in the shared workspace. It also accepts a preloaded fixture image with those executables under `/mpw`. Choose a fresh result path.

~~~sh
python3 -B scripts/qualify_docker_events.py --host "$DOCKER_HOST"
python3 -B scripts/bench_engine_tuning.py live-siblings \
  --hvf-socket /path/to/worker/docker.sock --workspace "$MICROPOD_CI_WORKSPACE" \
  --dense --compiler-spread-cpus 0,1,2,3 --native-compiler-groups \
  --pairs 4 --bulk-bursts 24 --out native-ci-groups.json
~~~

## Managed checkout, Docker archives and HVF retirement

Subsequent direct B5 runs measured snapshot restore, fork isolation and process retirement. The managed follow-up exercised host-mounted single and eight-job Go builds, the vendored runner checkout, Docker copy, and event and lifecycle regressions. [Measurements and qualification](phase-b5-managed-checkout-and-archive.md)
