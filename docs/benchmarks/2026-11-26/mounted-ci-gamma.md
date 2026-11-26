# Core Docker compatibility and mounted CI on Gamma

The native Micropod CLI streams binary output during exec, pipes stdin into the guest, preserves stderr and returns the guest exit code. On a raw 1,058-file mounted checkout, OrbStack still completed the warm Git, Go build and Go test sequence sooner. [Core CLI results](core-cli-exec.json) · [Mounted CI results](mounted-ci-gamma.json)

## The public CLI

The supervisor started a private four-vCPU, 4 GiB HVF machine through `micropod machine install` and `machine start`. Stock Docker and Micropod used its published Unix socket. The same Micropod CLI used OrbStack through the generic Docker adapter. The release client and supervisor had separate executable paths and recorded digests. All release client measurements used the ad-hoc-signed Swift release binary `3892941149a6ca89`. The source archive reconstructs the core changes against commit `76a329b6e464`. [Command, signing and machine receipts](mounted-ci-gamma-receipts.tar.gz) · [Reconstructable source](core-engine-sources.tar.gz)

A guest command waited for the host to receive its first output before it could finish. The new client exposed that output immediately, preserved stderr and returned exit 31. Other cases included NUL and invalid UTF-8 on both streams, empty stdin, a slow reader, and a guest exiting while its host stdin remained open. Eight simultaneous execs returned distinct bytes and exit codes. The Micropod release and stock Docker each passed all 15 checks on each endpoint. The previous client buffered the first marker and rejected piped stdin on HVF. [Byte hashes, exit codes and readiness checks](core-cli-exec.json)

### Single-client output

| Endpoint and client | 4 MiB wall | 4 MiB peak RSS | 32 MiB wall | 32 MiB peak RSS |
|---|---:|---:|---:|---:|
| HVF, Micropod release CLI | 20.6 ms | 14.9 MiB | 48.4 ms | 14.9 MiB |
| HVF, stock Docker CLI | 20.3 ms | 26.1 MiB | 54.0 ms | 26.1 MiB |
| OrbStack, Micropod release CLI | 31.4 ms | 14.5 MiB | 54.3 ms | 14.5 MiB |
| OrbStack, stock Docker CLI | 32.4 ms | 26.5 MiB | 67.2 ms | 26.2 MiB |

For the effect of the implementation change, both Micropod binaries below were compiled in debug mode. The comparison includes stdout writes to the host's real null device. Each cell is the median of three rotating client orders. Wall time includes process launch, exec creation, transfer and final exit inspection. RSS is peak host client memory. [Individual observations and executable hashes](core-cli-exec.json)

| Endpoint and client | 4 MiB wall | 4 MiB peak RSS | 32 MiB wall | 32 MiB peak RSS |
|---|---:|---:|---:|---:|
| HVF, previous debug CLI | 53.2 ms | 30.4 MiB | 235.8 ms | 114.2 MiB |
| HVF, current debug CLI | 29.6 ms | 16.5 MiB | 60.4 ms | 16.4 MiB |
| OrbStack, previous debug CLI | 54.0 ms | 29.7 MiB | 233.2 ms | 113.8 MiB |
| OrbStack, current debug CLI | 33.3 ms | 15.9 MiB | 57.1 ms | 15.9 MiB |

### Eight simultaneous CI containers

Each endpoint ran eight distinct Alpine containers, each limited to one CPU and 128 MiB. The harness waited until all eight guest processes reported ready, then sent each a different 2 MiB binary input. Every job returned its exact bytes, stderr marker and exit status. The table gives wall time for all eight jobs, from the first client launch until the last exit. All four engine/client combinations also returned the same 32 MiB SHA-256 digest into a regular host file. [Harness](../../../scripts/qualify_cli_exec_density.py) · [Paired rounds and per-job checks](core-cli-exec.json)

| Same client on both endpoints | Micropod HVF | OrbStack | HVF paired wins |
|---|---:|---:|---:|
| Micropod release CLI | 719.1 ms | 798.1 ms | 4 of 4 |
| Stock Docker CLI | 777.0 ms | 846.6 ms | 4 of 4 |

The four counterbalanced rounds exercised 128 scored attachments, with an additional warmup for each combination. Both engines removed their eight test containers and returned an empty run-label query. The host was 85.0% idle before qualification and 83.3% idle afterward. [Raw timings and cleanup](core-cli-exec.json)

An earlier release candidate measured 579.1 ms on HVF and 571.4 ms on OrbStack with the Micropod CLI. Stock Docker measured 659.8 and 667.1 ms in that window. The change in ordering across builds and ambient windows limits how broadly the final four pairs generalize. [Earlier and final density runs](mounted-ci-gamma-receipts.tar.gz)

### Failure handling and API negotiation

An earlier development build timed out on OrbStack after sending all 32 MiB to the host null device. Its process sample showed a socket read waiting for the peer. The timing wrapper initially left its client alive. The operator identified and retired that client and verified the VM shutdown, released lock and removed socket. The wrapper now terminates its owned process group on timeout. After the HTTP upgrade the client now closes its write half when running output-only, matching the stock client's EOF behavior. The final release finished 24 further 32 MiB transfers on each engine, each with a six-second deadline. The sample identifies where the earlier process waited, but cannot establish what prevented peer EOF. [Original failure, process sample and repeats](mounted-ci-gamma-receipts.tar.gz) · [Stock Docker stream handling](https://github.com/docker/cli/blob/master/cli/command/container/hijack.go)

The generic adapter previously sent API 1.43 to a Micropod daemon advertising 1.44 through 1.47. Its container ownership lookup fell through to the disabled Apple backend. The adapter now negotiates a common API version before the first mutation and honors an explicit `DOCKER_API_VERSION`. Automatic selection and an explicit 1.44 pin both returned stdout `00 ff`, stderr `fe 5a` and exit 29 through the native guest. The runtime also rejects truncated HTTP responses, unfinished execs and malformed exit codes. 102 focused runtime and machine tests and 259 Docker shim tests passed. Native stress tests covered 7,500 output cancellation races and 6,000 input cancellation races while preserving the caller's descriptor flags. [Wire receipts, tests and native stress](mounted-ci-gamma-receipts.tar.gz) · [Docker Engine API versioning](https://docs.docker.com/reference/api/engine/)

## Host-mounted CI

Four alternating pairs ran stock Git, a Go build and an uncached Go test on the same 1,058 tracked files, with two CPUs and 1,536 MiB per job. The observations before and after scoring were approximately 60% host idle. The reported time sums the three commands inside the job. The fresh fixture used the same image on both engines, with a rebuilt image layer compared with the previous day's experiment. [Measurements and scope](mounted-ci-gamma.json)

| Raw mutable workspace | Micropod HVF | OrbStack | HVF paired wins |
|---|---:|---:|---:|
| Warm Git, build and test | 926.8 ms | 825.8 ms | 0 of 4 |
| After a host source edit | 2,490.3 ms | 2,531.9 ms | 3 of 4 |
| Warm Git alone | 143.7 ms | 63.9 ms | |

On both engines, the Darwin-written index caused Git to refresh 1,058 entries. With a guest-written index it still issued 1,058 preload stats and performed zero content refreshes. The separate pinned-checkout helper gives each job its own Git metadata and retains stock Git discovery, including nested repositories. Its worktree must stay immutable for the lifetime of the job. A controlled same-size rewrite with the mtime restored inside the same ctime second left the warmed index clean on Git 2.39.5 even though the guest saw the changed bytes. [Pinned-checkout contract, cold costs and negative control](pinned-checkout.md)

On a fresh worker using the original B5 kernel, private Git metadata improved all four warm pairs on both engines. HVF went from 850.7 to 716.1 ms and OrbStack from 701.1 to 656.3 ms. The measured host bundle took 454 ms to pack. Including first-job setup, the private HVF job took 15.08 s against 14.14 s raw. The corresponding OrbStack measurements were 19.38 and 13.88 s. Each cold cell has one observation. Two earlier raw HVF execs exited 137 while PID 1 remained healthy and the memory cgroup recorded zero OOM events. Fresh direct and proxied runs with signal tracing succeeded. The earlier signal sender remains unidentified. [Cold, warm and failure receipts](pinned-checkout.md)

## Virtiofs completion in the requesting thread

Two fresh workers booted the same kernel image with direct completion disabled and enabled. The enabled kernel completed 148 of 1,350 Git LOOKUPs on the requesting thread. The control completed zero of 1,351 there. Aggregate lookup p50/p95/p99 moved from 9/15/23 µs to 6/16/24 µs. Within the enabled arm, requester completions were 12/18/27 µs and other completions were 6/14/23 µs. Eligibility depends on queue contention. The aggregate median therefore cannot measure the benefit of the shortcut itself. Both workers passed all 16 mutable-workspace observations. [Kernel, ftrace and source review](virtiofs-sync-lookup-kernel.md) · [Paired receipts](mounted-ci-gamma-receipts.tar.gz)

With the switch off, the warm Git/build/test medians were 809.1 ms on HVF and 669.5 ms on OrbStack. With it on, they were 864.5 and 793.0 ms. HVF won all four edited pairs and lost all four warm pairs in each arm. Host idle fell from 84% to 55% across the enabled arm. The experiment establishes the execution path and leaves the switch off by default. [Individual rounds and load samples](mounted-ci-gamma.json)

## Benchmark drive cleanup

All ten managed worker drives and the staging hub used disposable APFS volumes. The read-only remount audit verified Spotlight indexing was disabled, the FSEvents suppression markers persisted, and the journal contained zero files and zero bytes. The holder scan was empty before the hub was detached. Cleanup removed the backing images, temporary staging directory and scoped OrbStack objects. [Volume audit and cleanup](mounted-ci-gamma.json) · [Per-volume receipts](mounted-ci-gamma-receipts.tar.gz)

## Relationship to B3, B4 and B5

The B3 bridge and IPvlan results measured the direct VMM and its network path. B4 already has managed zero-vmnet egress and stock Docker, Compose, Buildx and registry checks. The current measurements extend B4.4 and B4.5 through the public CLI and mounted CI workload. The B5 direct restore and first-container clocks measure different events. Independent restored identities and clean installation of the complete signed distribution remain release gates. [B3 results](../2026-11-25/phase-b3-results.md) · [B4 and B5 plan](../../research/2026-11-25-phase-b4-plan.md) · [Prior managed qualification](../2026-11-25/managed-ci-git-and-exec.md)

Stock Docker's exec PTY and resize passed on the managed HVF socket. This run predated interactive PID 1 attach and native `micropod exec -it`. The subsequent qualification exercised both on the public machine. Native copy/export, broader API conformance and a sustained multi-job soak remain open. [Subsequent public-machine qualification](core-pid1-and-mutable-gamma.md) The original 6,573.34 MiB/s baseline and its preserved copy each verified all 24 manifest entries. The resume guard detected the previously scored QoS pair. The completed comparisons ran as independent schedules. The controlled QoS pass measured 7,934.1 MiB/s at Standard and 6,294.1 MiB/s at Interactive. Fresh-request p95 moved from 10.187 to 6.356 ms. Two relay workers delivered 6,504.7 MiB/s and four delivered 5,845.0 MiB/s. Under ambient load, Standard and Interactive delivered 7,777.2 and 6,264.7 MiB/s, and two and four workers delivered 6,413.5 and 5,774.7 MiB/s. [Original baseline, QoS and worker receipts](../2026-11-24/gamma-qos-and-workers/results.md)
