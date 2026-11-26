# Published TCP on Gamma with a per-container macvlan and Linux 7.3.5

The release crossover measured 3,238 MiB/s for Micropod and 3,815 MiB/s for OrbStack. Micropod's median within-round throughput difference was **−11.2%** in 10 common successful rounds. The fresh-request p95 was **73.2 ms** on Micropod and **1,007.8 ms** on OrbStack. Against its own bridge on the same kernel, the direct path measured **+25.2%**. The validation criteria for parity across the two series were not met. The earlier release-engine crossover on this shared Mac measured −30.1% against OrbStack, followed by −4.1% in the immediate alternating repeat.

An additional 12-block test on newly started services ran because the release comparison fell short of OrbStack. It used the installed host and guest binaries with full or lazy preemption, Reno for both services, the lazy-kernel bridge, and OrbStack. The decision rule was recorded during the earlier release series and before collecting this additional sample. Gamma’s qualified profile is **Full preemption, Reno**. On this additional comparison it was −9.5% relative to OrbStack, with a median fresh p95 of 68.9 ms against 696.0 ms. The two series did not establish repeatable parity.

## Workload and controls

Gamma was a physical 18-core M5 Max with 128 GiB RAM running macOS 26.5.1 (25F80). Both VMs advertised four CPUs. Guest-visible memory was 4,116,488,192 bytes for the full-preemption Micropod worker and 4,180,480,000 bytes for OrbStack. The same Linux/arm64 server binary ran with a quota of four CPUs (`400000 100000`), effective CPUs 0–3, 1 GiB memory and 512 PIDs. The native engine used containerd 2.4.2 and crun. OrbStack’s engine reported Linux 7.2.12-orbstack-00394-gbecdd6130068 and Docker 29.8.2. Both host endpoints were Docker-published IPv4 loopback ports.

The Mac client first proved each service’s unique identity, then kept 32 HTTP/1.1 download connections moving through verified-length 8 MiB responses. It scheduled 240 separate TCP connections at 25 ms intervals over six seconds. Each checked the expected container marker. Fresh latency starts at scheduled arrival and includes dispatch delay. A valid sample requires all 32 original downloads to move bytes, their sum to equal the byte counter, the declared arrival count and interval to match, and zero client errors or reopened bulk sockets. Timing used the same Go executable across all arms. The image configuration was `80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889` and its executable was `11616563078329f6d13d5c3b50628c57b431537c2fbd05dda7d8136d5f4572ba`.

The first crossover used 12 balanced four-engine blocks, followed by 10 alternating two-engine blocks. A second crossover screened four combinations of scheduler preemption and TCP congestion control against OrbStack in 10 balanced five-engine blocks. The final series ran an independent 12-block, three-engine crossover using every permutation twice, with the release CLI and guest binary rebuilt from the checked-in implementation. A local bundle verification was attempted around the start of the series. Excluding its first block gives −7.4% for Micropod versus OrbStack in 9 common rounds. The final release also adds confirmation before the Mac may finish a port bind. The program that times downloads and the packet path were identical across those two control-protocol revisions.

## Paired measurements

Throughput and fresh p95 are medians on common successful rounds. The percentage is the median of the ratios within those rounds. The paired change compares engines under each block’s host conditions. The interval resamples entire paired rounds 10,000 times with a fixed seed. Rounds share a physical host, and the interval is descriptive. Each cell with two values lists Micropod first and the comparison engine second.

| Comparison | Valid / attempted | Bulk MiB/s | Paired change | 95% bootstrap interval | Faster rounds | Fresh p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Release direct / OrbStack | 12/12 · 10/12 | 3,238 · 3,815 | −11.2% | −54.8% to +20.0% | 4/10 | 73.2 · 1,007.8 |
| Release direct / Linux 7.3.5 bridge | 12/12 · 12/12 | 3,238 · 2,496 | +25.2% | +8.7% to +51.1% | 9/12 | 73.2 · 114.2 |
| Tuning crossover, selected direct / OrbStack | 10/10 · 10/10 | 5,192 · 5,192 | +4.2% | −2.0% to +19.3% | 6/10 | 35.5 · 1,004.8 |
| First crossover, direct / OrbStack | 12/12 · 11/12 | 2,033 · 3,142 | −30.1% | −37.1% to −26.0% | 0/11 | 115.9 · 1,005.8 |
| First crossover, direct / Linux 7.3.5 bridge | 12/12 · 12/12 | 2,038 · 2,117 | +5.1% | −7.3% to +15.2% | 7/12 | 114.9 · 124.6 |
| First crossover, direct / Linux 6.18.35 bridge | 12/12 · 12/12 | 2,038 · 2,179 | +4.7% | −11.3% to +13.7% | 8/12 | 114.9 · 112.4 |
| Bridge only, Linux 7.3.5 / 6.18.35 | 12/12 · 12/12 | 2,117 · 2,179 | +0.3% | −17.6% to +7.7% | 6/12 | 124.6 · 112.4 |
| Two-engine repeat, direct / OrbStack | 10/10 · 9/10 | 4,766 · 5,335 | −4.1% | −21.2% to +10.3% | 4/9 | 39.1 · 1,005.7 |
| Installed full preemption / OrbStack | 12/12 · 12/12 | 3,440 · 3,543 | −9.5% | −16.2% to +10.6% | 4/12 | 68.9 · 696.0 |
| Installed lazy preemption / OrbStack | 12/12 · 12/12 | 2,576 · 3,543 | −8.2% | −49.6% to +9.3% | 4/12 | 74.7 · 696.0 |
| Installed lazy / full preemption with Reno | 12/12 · 12/12 | 2,576 · 3,440 | −20.4% | −47.0% to +17.6% | 4/12 | 74.7 · 68.9 |
| Installed lazy direct / same-kernel bridge | 12/12 · 12/12 | 2,576 · 2,628 | +10.0% | −10.9% to +28.8% | 7/12 | 74.7 · 121.9 |

## Kernel and TCP selection

Both 7.3.5 images use the same Apple-compatible base, performance-oriented compiler configuration, 250 Hz tick, virtio-net, nftables ingress/egress and fq. Full and lazy preemption are fixed at build time. Only the gateway /32 route for the direct service changes between Reno and BBR. The readback includes the route and the congestion controller reported by an accepted TCP socket. The final image and alternate config are recorded by SHA-256. [Upstream Linux archive and checksums](https://cdn.kernel.org/pub/linux/kernel/v7.x/)

| Direct configuration vs full preemption with Reno | Valid / attempted | Bulk MiB/s | Paired change | 95% bootstrap interval | Faster rounds | Fresh p95 ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Full preemption, BBR | 10/10 · 10/10 | 3,660 · 5,192 | −30.2% | −54.0% to −13.2% | 0/10 | 17.6 · 35.5 |
| Lazy preemption, Reno | 10/10 · 10/10 | 5,845 · 5,192 | +10.3% | −15.5% to +20.7% | 6/10 | 26.9 · 35.5 |
| Lazy preemption, BBR | 10/10 · 10/10 | 3,896 · 5,192 | −27.6% | −35.6% to −14.0% | 1/10 | 14.8 · 35.5 |

The selection rule was written before sampling. A challenger needed at least eight common successes, at least a 3% median paired throughput gain, wins in two thirds of common rounds, no extra failed attempts and median paired p95 within 5% of full preemption with Reno. Lazy preemption with Reno gained 10.3% and won 6/10. The rule required 7/10. Both BBR arms reduced latency and gave up bulk throughput. The final comparison therefore used **Full preemption, Reno**.

The one-minute Mac load average ranged from 23.9 to 176.0 during sampling. Kernel and release compilation finished before sampling. Packet capture and profiling were confined to separate diagnostic runs. Other users’ workloads ran concurrently. Over the valid final Micropod samples the VMM averaged a median 1.42 CPUs, and its runnable threads waited off-CPU for 1.97 thread-seconds per second. The Mac relay used 0.88 CPUs. The same-kernel bridge showed 2.31 VMM runnable off-CPU thread-seconds per second. Across the 12 successful direct rounds the rank correlation between VMM runnable wait and throughput was -0.96. This association does not establish which macOS scheduling decision caused each delay. These counters cover the client process lifetime per sample, including the wind-down after the six-second byte window. The raw record includes per-round load and the before/after task counters. [Apple scheduler accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/thread.c)

## Ownership and paths

The ordinary Docker API creates the listener. A unique kernel-reserved guest port selects the owner’s private macvlan MAC on the dedicated worker NIC. Pod-local connection tracking translates it to the service’s Docker IP, so explicit application binds work. The container gets an addressless interface and a single route back to the Mac gateway. A two-step broker admission records pending ownership before bind, and a release acknowledgment fences the listener and all its accepted connections. An ambiguous bind or release keeps the guest port reserved while the worker reconciles with the Mac.

The live containment test ran two isolated internal networks serving the same container port. It checked concurrent starts, two bindings on one service, fixed-port collision rollback, an explicit-IP service, an unpublished sibling listener, blocked access to a Mac-side test listener, immediate port reuse, old keep-alive revocation, deleting the old owner and stop/start. The final worker recorded zero ports waiting for reconciliation after qualification and benchmarking. A separate test removed just the test service’s gateway neighbor entry. All four subsequent Mac requests succeeded and the neighbor returned to REACHABLE. All 27 selected macOS tests and all 12 regular Linux unit tests passed. The separate opt-in Netavark benchmark was skipped. The isolated Linux regression exercised a lost bind confirmation, an abandoned preparation, a negative revocation fence, and reuse after a positive fence.

In the instrumented path check, 41,803,565,633 bytes left via the new container interface and the ordinary Docker interface’s TX counter increased by 280 bytes. The counters for the final release service increased by 244,082,976,085 and 350 bytes respectively. The direct NIC had no IP addresses in each scored direct service. The preliminary path check preceded suppression of the generated IPv6 link-local address. No tracing ran on the packet path during the scored series. The raw guest-process numbers in the preceding receipt used a different kernel and session. This run supplies no new hardware maximum. [Previous raw guest and loopback measurements](gamma-mixed-path.md)

## Reproduction

Use the native worker instructions to select the newer kernel, macvlan and the throughput relay. Build the Linux image on ARM64 Linux. Supply the matching Apple base config from the receipt. `ci/build-worker-kernel.sh` verifies the pinned source archive digest and writes the bootable Image, configuration, release and hashes. Gamma’s selected image is `/Users/benebsworth/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image` with SHA-256 `7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd`. The alternate lazy image has SHA-256 `3955ba50110de136beed489a4957141442afd2ba565358186b7abd20f5dfabe8`. The selection is per worker. Kernel build metadata can change the binary digest when rebuilding. Gamma also retains the signed host CLI and the matching guest tools under `/Users/benebsworth/.micropod/qualified/direct-dd82f426b8bc-62e29296d035`. [Worker settings and build instructions](../../ci-worker.md#direct-tcp-ports-on-a-native-mac-worker)

The local Docker ownership suite is `ci/runner-macvlan.test.sh`. Set its `DOCKER_HOST` and `MICROPOD_CI_WORKSPACE` to a disposable worker with its Alpine image loaded. For the performance run, use the Go client from `sources["fixed.go"]` in the compressed receipt and call it with the host URL and container marker. Run the same executable and image for each peer. The receipt includes every attempted run, order, failure, worker and cgroup readbacks, kernel configs, build hashes, the local analysis and the network proof. The SQLite importer uses kind `published_ports` and run `gamma-direct-macvlan-20261121`. All qualification ran locally on Gamma. [Raw measurements and fixtures](gamma-direct-macvlan.json.gz)


## Run the installed build on Gamma

The signed CLI discovers its adjacent guest tools. This starts a separate worker with the recommended kernel and the same publication policy used in the comparison.

```sh
export PATH="/Users/benebsworth/.micropod/qualified/direct-dd82f426b8bc-62e29296d035:$PATH"
export MICROPOD_CI_HOME="$HOME/.micropod/ci-direct"
export MICROPOD_CI_ENGINE=containerd MICROPOD_CI_PORT_RELAY=kqueue-throughput
export MICROPOD_CI_PUBLISHED_PATH=macvlan
export MICROPOD_CI_KERNEL="/Users/benebsworth/.micropod/kernels/7.3.5-micropod-7e3713940eec/Image"
micropod ci runner-start
```


## Failed rounds

confirmation / orb / 2 (EOF) · confirmation / orb / 8 (EOF) · matched / orb / 9 (EOF) · repeat / orb / 5 (EOF)