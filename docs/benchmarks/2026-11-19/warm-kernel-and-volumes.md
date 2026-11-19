# Warm Linux kernel and macOS storage measurements

19 November 2026. Each container measurement starts with a running Docker daemon and a locally available native Alpine image. These are reference machines for the live-rig comparison. A Micropod-owned physical ARM64 allocation has yet to produce a receipt for this workload.

## Verified warm containers

Median batch wall time in seconds. Five blocks per client level and 145 attempted containers per environment. Every timed container reports its kernel boot ID, prints separate stdout and stderr tokens and exits with status 23. Two additional overlapping containers verify PID and mount isolation and cgroup limits. Failed blocks are excluded from medians and counted separately. Retrieval, VM provisioning and image pulls are outside the clock.

| Execution environment | 1 client | 4 clients | 8 clients | 16 clients | Verified attempts |
|---|---:|---:|---:|---:|---:|
| GitHub Ubuntu ARM64, Docker 28.0.4 | 0.122 | 0.181 | 0.304 | 0.599 | 145/145 |
| GitHub Ubuntu x86-64, Docker 28.0.4 | 0.131 | 0.231 | 0.458 | 0.900 | 145/145 |
| OrbStack 1.5.1, hosted Intel macOS, Docker 25.0.5 | 6.810 | 19.406 | 36.772 | 65.049 | 143/145 |

Both original Ubuntu runners used four vCPUs and an Azure Linux kernel. The ARM64 control completed 26.72 jobs/s at 16 clients and the x86-64 control completed 17.78 jobs/s. The OrbStack daemon reported four vCPUs and 4.47 GiB. Its client ran on a hosted Intel Mac with nested virtualization. Its 16-client throughput was 0.246 jobs/s. Image architecture, host virtualization, kernel, daemon versions, memory and client paths differ across these environments. The numbers do not isolate a product overhead or predict Gamma's performance.

Two fresh, four-vCPU Ubuntu runners repeated all 145 attempts on each architecture with zero failures. Replicated ARM64 medians were 0.127, 0.201, 0.340 and 0.590 s. Replicated x86-64 medians were 0.083, 0.132, 0.243 and 0.483 s. That x86-64 allocation reported an AWS kernel, while both ARM64 runs reported Azure kernels. A hosted runner label can span different machines. [Linux replication jobs](https://github.com/castlemilk/micropod/actions/runs/44518987247) · [ARM64 raw](live-kernel-arm64-repeat.json) · [x86-64 raw](live-kernel-amd64-repeat.json).

Two OrbStack attempts failed the exit/stream check in the first four-client block. Four complete four-client blocks contribute to that median. The first receipt preserves both failures. An independent three-block run passed 83 of 87 container executions. Three failed during the OCI initialization hook with Docker exit 125. A fourth timed out during cleanup and the final check found benchmark containers remaining. That run has a failed qualification and its receipt is retained. [OrbStack primary](https://github.com/castlemilk/micropod/actions/runs/44514975826/job/135528514782) · [Independent OrbStack run](https://github.com/castlemilk/micropod/actions/runs/44517057176) · [ARM64 job](https://github.com/castlemilk/micropod/actions/runs/44513262129/job/135522615276) · [x86-64 job](https://github.com/castlemilk/micropod/actions/runs/44514975826/job/135528515091).

OrbStack 2.2.5 build 21124 was also checksum- and code-signature-verified on the hosted Intel Mac. At startup OrbStack rejected the hypervisor's CPU model (family 6, model 58). It emitted no container timings. The physical Apple Silicon mode uses the installed OrbStack release. [2.2.5 startup log](https://github.com/castlemilk/micropod/actions/runs/44518109438/job/135539319835).

[Raw ARM64 JSON](live-kernel-arm64.json) · [Raw x86-64 JSON](live-kernel-amd64.json) · [Raw OrbStack JSON](live-kernel-orbstack-intel.json) · [Raw OrbStack replication](live-kernel-orbstack-replication.json).

## Cache sharing on the physical Gamma Mac

On Gamma-128GB, macOS 26.5.1 ARM64 and pnpm 11.23.0, real offline pnpm installs imported a deterministic 8 MiB package containing 32 files into 16 independent workspaces. Each import policy used its own warmed store on the same filesystem. Installs ran one at a time, alternating the order of the two policies. All installed bytes were hashed. Inode identities cover only the package payload in the store and selected workspaces.

| Workspaces | Distinct payload inodes, copy | Distinct payload inodes, hard link | Unique logical MiB, copy | Unique logical MiB, hard link |
|---:|---:|---:|---:|---:|
| 1 | 64 | 32 | 16 | 8 |
| 4 | 160 | 32 | 40 | 8 |
| 8 | 288 | 32 | 72 | 8 |
| 16 | 544 | 32 | 136 | 8 |

Across the 16 timed installs, median elapsed time was 0.722 s with explicit copy and 0.716 s with explicit hard links. The demonstrated benefit is reuse of the same inodes. APFS can share physical extents across distinct inodes through cloning. These logical sizes cannot establish physical bytes reclaimed by the migration, or the performance of pnpm's automatic import policy. The rig's projects, package-manager configuration and existing stores were outside the fixture. [Raw times and file counts](pnpm-gamma.json) · [Reproduce the offline installs](../../../scripts/bench_pnpm_storage.py).

## APFS migration and metadata workload

The production Micropod CLI created a sibling APFS volume inside a disposable macOS disk image. It verified source copies before switching paths, preserved a pnpm hard link spanning both source trees, created a new link after migration, remounted by volume UUID and restored post-migration edits and deletions. Open-file and working-directory checks stopped a busy migration. The qualification also reran migrate and restore.

Four alternating blocks ran 64 verified 4 KiB file create, rename, read and delete sequences per client. These median batch seconds come from the production CLI qualification with unencrypted fixture data.

| Clients | Disposable control volume | Development volume |
|---:|---:|---:|
| 1 | 0.024 | 0.026 |
| 4 | 0.096 | 0.096 |
| 8 | 0.173 | 0.227 |
| 16 | 0.409 | 0.358 |

Spotlight already reported indexing disabled on the control volume. The development volume reported indexing and searching disabled. This setup verifies the volume policy and file operations but cannot establish a speedup from turning indexing off. [APFS job](https://github.com/castlemilk/micropod/actions/runs/44514662054/job/135527418983) · [APFS samples and checks](development-volume-macos.json) · [Provisioning, cold unlock and restore qualification](https://github.com/castlemilk/micropod/actions/runs/44518987247).

A second production CLI run used encryption throughout. It passed all 21 checks, including encrypted provisioning, interactive remount, explicit cold lock and unlock, and restore. With the compiled CLI cache hit, the real end-to-end step took 50 seconds and the entire job took 70 seconds. This workflow is manually dispatched. [Encrypted run](https://github.com/castlemilk/micropod/actions/runs/44518987247/job/135542379607) · [Raw encrypted receipt](development-volume-encrypted-macos.json).

## Physical Micropod and OrbStack comparison

Run `--engine rig-pair` on an idle physical Apple Silicon Mac with two already-running, distinct engines. Micropod targets an existing rootless allocation. OrbStack targets its Mac-local Docker socket. The harness alternates engine order, uses the Mac's monotonic clock for both client paths and records CPU and memory for each engine. All measured Micropod containers must share the independently inspected Micropod allocation's boot ID. A separate guest-clock mode helps quantify the Mac-to-allocation transport. [Commands and prerequisites](../../development-volume.md#measure-a-persistent-linux-kernel).

Earlier physical Gamma-64 qualification timed the whole rootless allocation fixture at 6.26, 5.81 and 5.71 s. That included Docker setup, an image pull, network checks and teardown. The earlier test on Gamma-128 took 5.42 s for a private Docker fixture. Neither series measured warm inner container launches at these concurrency levels. [Original native receipts](../../../ROOTLESS-SANDBOX-VALIDATION.md).
