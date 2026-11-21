# Micropod vCPU priority and published-port recovery on Gamma

With 32 sustained downloads and 40 fresh requests/s, Micropod completed **16/16** measured rounds cleanly. OrbStack completed **15/16**. The median paired throughput difference was **-14.6%** (95% paired bootstrap interval -29.1% to +25.9%). Micropod won 7 of 15 common clean pairs. [Raw measurements and traces](gamma-vcpu-priority.json.gz)

| Independent comparison | Clean rounds | Bulk, MiB/s | Fresh-request p95, ms | Client errors | Reopened downloads |
|---|---:|---:|---:|---:|---:|
| Micropod Interactive, sustained-failure check | 16/16 | 2,710 | 35.2 | 0 | 0 |
| OrbStack | 15/16 | 3,010 | 220.3 | 1 | 0 |

Bulk and fresh-request latency in the table are medians over each runtime’s own clean rounds. Each round’s p95 includes dispatch delay from the scheduled arrival time. The paired comparison uses only rounds that were clean on both. Every failed round and per-stream byte count is in the receipt.

On the 15 common clean rounds the median bulk rates were 2,854 MiB/s for Micropod and 3,010 MiB/s for OrbStack. Their corresponding median fresh-request p95 values were 33.5 ms and 220.3 ms.

## What changed between runs

| Micropod configuration, each measured against OrbStack | Micropod clean | OrbStack clean | Common clean pairs | Median paired bulk difference | 95% interval |
|---|---:|---:|---:|---:|---:|
| Previous equal-warmup detached worker | 16/16 | 16/16 | 16 | −33.5% | −50.1% to −20.7% |
| Detached worker on this run | 6/6 | 6/6 | 6 | -37.0% | -47.1% to -4.1% |
| Interactive, first endpoint repair | 12/16 | 16/16 | 12 | -20.2% | -25.7% to -17.2% |
| Interactive, sustained-failure check | 16/16 | 15/16 | 15 | -14.6% | -29.1% to +25.9% |

The two 16-pair studies used separately booted workers. The six-pair detached control used an already warm service. Shared-host load and boot-to-boot variation limit comparisons between studies. [Previous matched run](gamma-vm-scheduling.md)

## Why the vCPUs lost priority

Both VM helpers used Mach timeshare policy 1, base priority 31 and maximum priority 63 for their four vCPU threads. The sampler integrates both endpoints of each interval and computes the share of runnable time below base. A runnable vCPU may be executing or waiting for a core.

The detached worker spent 34.7–95.6% of runnable vCPU time below base in four mixed-load captures. The OrbStack maximum was 0.0%. A CPU-only control used the same ARM64 binary and no benchmark network traffic. Each cell below gives the two repeats.

| Compute workload | Detached Micropod | launchd Interactive Micropod | OrbStack |
|---|---:|---:|---:|
| 1 Go thread | 10.5% / 55.1% | 0.0% / 0.0% | 0.0% / 0.0% |
| 4 Go threads | 37.1% / 12.9% | 0.0% / 0.0% | 0.0% / 0.0% |

The detached helper inherited the caller’s resource coalition, a group macOS schedules and accounts together. Launching Micropod through an independent Interactive launchd job placed it in a separate coalition. XNU adjusts timeshare priorities using recent CPU usage. [XNU priority calculation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/priority.c) · [XNU scheduler groups](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/sched_clutch.c)

A separate control booted the identical release twice using independent launchd jobs. Only the launch process type differed. Launchd confirmed daemon and Interactive spawn types. Each VM had its own resource coalition.

| Independent launchd process type | One compute thread, below base | Four compute threads, below base |
|---|---:|---:|
| Standard | 0.0% / 0.0% | 0.0% / 0.0% |
| Interactive | 0.0% / 0.0% | 0.0% / 0.0% |

Both independent launch roles kept the vCPUs at base in every control. Separating the worker from the caller’s launch context was sufficient for this workload. The data do not identify which private XNU accounting decision produced that difference.

| Separate mixed-load traces | Clean windows used | Median runnable time below base | Estimated vCPU wait, thread-s/s |
|---|---:|---:|---:|
| Micropod first run | 4/4 | 0.0% | 1.12 |
| OrbStack first run | 4/4 | 0.0% | 1.25 |
| Micropod confirmation | 4/4 | 0.0% | 1.32 |
| OrbStack confirmation | 3/4 | 0.0% | 1.64 |

The wait estimate subtracts measured CPU residence from sampled runnable time over the four vCPU threads. The receipt also contains virtual-device groups and the two CPU levels that Gamma reports. Timing rounds ran with the high-frequency sampler off.

During the untraced confirmation, median one-minute Mac load average was 63.4 in Micropod’s clean rounds and 63.5 in OrbStack’s. Within each runtime, higher whole-VM runnable wait tracked lower bulk throughput (Spearman -0.98 for Micropod and -0.94 for OrbStack). These process counters span client setup, transfer and drain. Correlation cannot identify what preempted a vCPU. The Micropod relay used a median 0.90 host CPU-seconds per second.

## Where connections failed

During six failing idle-to-burst runs on the original Interactive worker, 76 of 85 failed Mac-to-guest pings had no matching request in the guest’s published-NIC capture. The guest heartbeat continued through 57 misses. Its separate egress interface answered in 47. The Mac kept the same gateway and neighbor address. Three repairs on that boot took 23.0–24.6 seconds. Packet and ping records are correlated by time.

The Linux virtio-net driver independently reported a transmit-queue-0 watchdog with 25.584 seconds since progress. Testing negotiated event-index suppression and indirect descriptors separately did not remove the stall. Disabling TCP segmentation offload sharply reduced throughput. The runtime keeps the standard Linux 7.3.5 image and offloads. [Linux virtio-net driver](https://code.googlesource.com/linux/torvalds/linux/+/7bcf809b1e7889ab7e75fe1fcf8f1a98332f36d2/drivers/net/virtio_net.c)

In the first independent scored run, rounds 4 and 13 overlapped endpoint repairs of 25.64 s and 24.40 s. Both had zero additional Linux TX watchdog expirations and each reopened four bulk connections. Round 4 also recorded one transmit drop. Those observations distinguish the Linux queue timeout from a second failure pattern in which replacing the Mac endpoint coincided with interrupted TCP traffic. They do not establish which event began those outages.

The revised watchdog restores the guest route immediately, clears suspicion on positive payload or a successful peer check, and requires repeated peer failures over six seconds before replacing the published attachment while its Mac gateway remains present. A replacement first reuses the existing network and verifies it with fresh ARP. The worker can still recreate the network following a failed replacement. Explicit repair requests and a missing Mac gateway trigger immediate recovery.

The six-round screen of 512 KiB on guest-facing relay sockets recorded 6/6 clean rounds and a median of 3,983 MiB/s on those rounds.
The six-round screen of normal macOS receive autotuning recorded 5/6 clean rounds and a median of 6,747 MiB/s on those rounds.

The selected opt-in mode requests 512 KiB of receive space on each guest-facing relay socket before connect. The confirmation used a fresh worker started through the generated Interactive launch agent.

The Linux Docker API exposes bytes, drops, errors and driver watchdog expirations under `network.published_link` on `GET /micropod/metrics`. Each counter belongs to a worker boot. Reading it does not add work to forwarding a packet.

## Growing the receive window on sustained downloads

A separate Interactive candidate let connections negotiate their normal TCP window scale, started the receive buffer at 512 KiB, then requested 2 MiB after a stream delivered 16 MiB. An otherwise identical fresh worker retained a fixed 512 KiB. The test alternated eight rounds per arm.

The growing-window candidate completed 5/8 rounds cleanly and the fixed window completed 8/8. The candidate changed median paired throughput by +47.9% and fresh p95 by +44.6% across 5 common clean pairs.

The growing window missed the preselected qualification criteria. The release candidate retains the fixed window.

## Recovery and ownership checks

Matched scrapes covered 16/16 confirmation rounds. The guest recorded 0 additional TX watchdog expirations and the supervisor recorded 0 new completed published-link repairs between the round boundaries.

First repair on a second worker completed 6/6 idle-to-burst rounds, with 0 reported errors and 0 reopened downloads. After the guest’s published NIC was deliberately brought down, the original service owner answered in 2.47 s. The VM instance was preserved.
Sustained-failure check on a second worker completed 6/6 idle-to-burst rounds, with 0 reported errors and 0 reopened downloads. After the guest’s published NIC was deliberately brought down, the original service owner answered in 2.61 s. The VM instance was preserved.

The Docker integration check exercised concurrent ownership, multiple leases, explicit-IP listeners, private network and host egress isolation, conflict rollback, revocation of live connections, port reuse and restart. The selected worker also passed the isolated Linux port-fence regression.

## Conditions and reproduction

Gamma ran macOS 26.5.1 on an 18-core Apple M5 Max. Both VMs had four vCPUs and 4 GiB configured. Both containers had a 400000/100000 CPU quota, effective CPUs 0–3, 1 GiB memory and a 512-PID limit. Both served the same ARM64 image. Micropod used the direct macvlan path, Reno, containerd and crun on Linux 7.3.5. OrbStack used Linux 7.2.12 and Docker Engine 29.8.2.

For each independent comparison we created fresh service containers on warm VMs, warmed each three times, then alternated 16 scored pairs in AB/BA order. Each round offered 240 fresh, non-reused identity requests at 25 ms intervals over six seconds while 32 established connections downloaded repeated 8 MiB responses. Each stream had to deliver bytes and the per-stream sum had to match the total. Any client error or reopened connection failed the round. Clean-pair intervals resample within-pair ratios with a fixed seed. Other users could run work on Gamma. GitHub Actions stayed off.

The compressed receipt contains the Go load generator, image digest, CPU settings, all scored and warm-up records, link counters and scheduler samples. The SQLite measurement kind is `published_ports` and the run ID is `gamma-vcpu-priority-20261121`. [Worker configuration](../../ci-worker.md#direct-tcp-ports-on-a-native-mac-worker)

## Tested package on Gamma

The signed host binary and its verified guest tools are installed at `/Users/benebsworth/.micropod/qualified/interactive-a41976076b67-2293dd639a7a`. An additional worker launched from that directory completed 3/3 mixed-load smoke rounds with 0 client errors and 0 reopened downloads. The receipt includes SHA-256 hashes for the host executable, OCI client and every guest tool. The package is available for opt-in use under a separate installation name.
