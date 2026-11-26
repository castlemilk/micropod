# Managed Docker engine qualification on Gamma

On 25 November 2026 the source-built Micropod CI worker ran a stock Docker client, a Compose service and the Micropod `ci` runtime on both Apple virtualization backends. The direct Hypervisor.framework worker also pulled an uncached public image, built an image with BuildKit, and ran 32 simultaneous CI containers. These results apply to the development checkout. [Qualification receipt](managed-engine-compatibility.json) · [Full per-run receipts, including disk teardown](managed-engine-compatibility-receipts.json.gz)

The subsequent Gamma run covers Docker and Compose event streams, workspace admission and 32 active compilers, including short and sustained transfers. [Follow-up scorecard](phase-b4-ci-density-and-events.md)

## Where B3 ends

The B3 bridge receipt measures 8,699 MiB/s of published TCP and 3.041 ms fresh p95 on direct HVF. Its IPvlan receipt measures 1.018 s for 32 ephemeral containers with at most eight active launches. B3 exported its test images from OrbStack and started the Rust VMM directly. Its readiness clock excludes disk preparation. The separate 64-container experiment used VZ and measured scheduling tails and real Go builds. Each remains a reference for its own workload. [B3 scorecards](phase-b3-results.md) · [Dense VZ results](../2026-11-24/gamma-ci-concurrency/sibling-response-handoffs-and-worker-drives.md)

The managed path enters through `micropod ci serve`. For the native containerd engine, `runner-docker-endpoint` verifies the worker and instance on `docker.sock`, `runner-endpoint` returns the job protocol on `oci.sock`, and `runner-buildkit-endpoint` opens the worker's BuildKit socket. The registered `ci` runtime now uses the Docker socket for container operations and verifies the worker without launching a VM during discovery. Gamma's installed desktop shim serves Apple Container on its own socket. The release bundle still needs the signed VMM, matching initrd, kernel and worker tools. [Worker guide](../../ci-worker.md) · [HVF launcher](../../../Sources/MicropodRuntime/HVFWorker.swift) · [Release packaging](../../../scripts/package_app.sh)

## What the managed tests exercised

| Surface | Observed behavior |
|---|---|
| Backend selection | On the original HVF worker a client explicitly requesting VZ received working OCI and Docker sockets. The revised supervisor reports the actual VMM and rejects requests to start, join or stop the other backend. Old sessions and registered launchd configurations have regression coverage. |
| Published ports | The original `docker port` returned a live loopback mapping while `docker ps` showed an empty field. Stock Docker now lists the allocated port, HTTP returns the test container's unique response, and Compose reports the same publisher. Inspect shows an exposed-only UDP port as `null` on a running bridge container. The managed HVF worker also published the image's Dockerfile `EXPOSE 9090/tcp` with `docker run -P`. |
| Micropod CI runtime | `micropod run --runtime ci`, list, inspect and remove operated on the same container that stock Docker inspected. The harness used private client settings and isolated unrelated runtime discovery. |
| Disk ownership | A second process could not obtain an exclusive lock on the writable ext4 image while either backend held it. It acquired the lock after shutdown. VZ owns its lock through the framework attachment. Direct HVF locks the opened writable file descriptor through teardown. |
| Guest clock and egress | The previous HVF container returned Unix time 1. The matched VMM/initrd initialized UTC at boot. The container clock matched Gamma to the resolution of `date +%s`. A fresh worker pulled Alpine 3.23, resolved the package mirror, installed curl and fetched a public HTTPS resource with certificate validation enabled. |
| BuildKit and CI | Stock Buildx built and loaded a two-stage Alpine/GCC image in 8.73 s. A repeat took 1.23 s, reused three steps and produced the same image ID. Eight clients started 32 containers on a four-vCPU HVF worker. All 32 reached a shared barrier before any compilation began. Each compiled and ran a C program with a different input under `--network none`, wrote its expected result to a named volume and exited zero. These are single-run build times. |
| Image cleanup | The first Buildx test reached cleanup and received HTTP 501 from `docker image rm`. On the revised worker a stock client removed the primary tag and immediately inspected the same image by its alias. A retained container blocked removal of the last tag. Removing the container then its tag succeeded. A final query verified that the tagged build images, labeled containers and named test volume were gone. |

Each of the 12 disposable APFS worker volumes, including the diagnostic runs, was remounted read-only before ejection. Spotlight reported indexing and searching disabled, the `.fseventsd/no_log` marker persisted, and every volume had zero FSEvents journal files and bytes. Both final workers released the ext4 lock and completed the public stop command before the supervisor's parent reaped the process. All 24 original baseline files and their preserved copies matched their recorded hashes. [Qualification receipt](managed-engine-compatibility.json) · [Original QoS and relay worker results](../2026-11-24/gamma-qos-and-workers/results.md)

The portable published-port check accepts an explicit context or socket. `--check-http` verifies the response when the Docker host publishes on the machine running the check. It uses a preloaded Alpine image and removes its labeled test container. [Qualification script](../../../scripts/qualify_native_worker.sh) · [Docker port publishing](https://docs.docker.com/engine/network/port-publishing/)

```sh
endpoint="$(micropod ci runner-docker-endpoint)"
bash scripts/qualify_native_worker.sh --published-ports --host "$endpoint" --check-http
bash scripts/qualify_native_worker.sh --published-ports --context orbstack --check-http
```

Select a dedicated native worker through `MICROPOD_CI_HOME` and make Alpine 3.23 available on it. The Buildx check requires the Docker Buildx client plugin and public registry access. On a second fresh HVF worker, this command took 9.75 s for the initial build and 1.13 s for the cached build. It verified all 32 outputs and finished with zero labeled containers, volumes or test tags. [CI build check](../../../scripts/qualify_ci_build.py)

```sh
docker --host "$(micropod ci runner-docker-endpoint)" pull alpine:3.23
bash scripts/qualify_native_worker.sh --buildx-ci
```

## Release gates

The follow-up source build closed the original writable-layer and restart failures below. It also corrected the entrypoint PID and qualified direct HVF recovery after an abrupt supervisor exit. The original failing commands remain part of this qualification record. [Follow-up measurements and release status](phase-b4-managed-performance.md)

1. The original build lost the writable container filesystem across stop/start. On a fresh HVF worker, stock Docker wrote and read a marker under `/root` outside a volume. Both `docker stop` and `docker start` succeeded on the same container ID, but the marker had disappeared. `docker restart` returned an unsupported-operation error. That CRI lifecycle removed the per-launch snapshot. [Observed commands and exit status](managed-engine-compatibility.json)
2. Stock Docker and Compose passed the follow-up wire tests for container and exec events. Extend coverage to image, network and volume events, archive copy, interactive attach/TTY, live network connect/disconnect and API negotiation. Named image untagging now uses an exact containerd reference and verifies its target at deletion. Image-ID and digest deletion, image pruning and complete layer reclamation remain open. The native worker advertises API 1.44–1.47. The distributed Docker shim, native CI worker and full dockerd worker need distinct results. [Event qualification](phase-b4-ci-density-and-events.md)
3. Package and sign the matched worker artifacts in a reproducible release checkout. The Swift and Go changes are in the Phase 0 checkout. The tested Rust VMM and guest init live in the outer checkout's untracked `vmm/` tree. The receipt records the tested sources and binary hashes. Verify installation on a clean Mac, shutdown after guest flush, recovery following supervisor loss, long-running clock behavior, and sustained multi-job workspace builds. UDP lifetime, network isolation and behavior across host-network changes have separate acceptance criteria.
4. Keep B4 throughput and B5 snapshot targets attached to their own measurements. Recheck clock and disk isolation after snapshot restore. Benchmark volumes keep Spotlight indexing and persistent FSEvents logging disabled. The proposed workspace watcher has a separate host-edit coherency test. [B4/B5 plan](../../research/2026-11-25-phase-b4-plan.md)

## Managed checkout, Docker archives and HVF retirement

Archive uploads, downloads, HEAD, ownership preservation and read-only image downloads now have stock-client checks on both managed backends. The follow-up also covers stopping a job during an upload, fresh restores and host-mounted CI builds. [Source-build qualification](phase-b5-managed-checkout-and-archive.md)

## Follow-up on 26 November

Managed HVF and VZ now pass stock-client interactive exec and early-output checks. The follow-up compares job-local and host-mounted checkouts, times eight overlapping CI jobs, and examines the identity and workspace of managed snapshot restores. [Gamma follow-up and raw receipts](managed-ci-git-and-exec.md)
