# Gamma published TCP filter batching

An opt-in Micropod build halved the kernel calls needed to pause and resume a download after a blocked write. It also submitted the three filter changes at asynchronous connection completion in one call. The fixed-work check uses the production Darwin relay and counts calls to `kevent` on connected local sockets. The throughput and latency effect through a VM is still open. [Fixed-work receipt](gamma-filter-work.json)

| Filter-update syscalls per operation | Parent | Current default build | Batched build |
|---|---:|---:|---:|
| Finish connecting on a dedicated relay worker | 3 | 3 | 1 |
| Pause a reader after a blocked or partial write | 2 | 2 | 1 |
| Resume the reader after flushing its pending bytes | 2 | 2 | 1 |
| Forward an unblocked 32 KiB bulk payload | 0 | 0 | 0 |

These counts cover filter updates only. The pause/resume cycle applies four individual filter changes in all three builds. Batching uses the same queue, payload size and event order. The default build and the relay that separates interactive and bulk traffic onto two kqueues kept their original counts. In an archived VM profile of roughly 8 GiB, only 12 of 35,821 writes were short or blocked. That bounds the opportunity for this part of the change on that particular transfer. [Archived bulk and fresh profiles](../2026-11-21/gamma-published-profile.md)

## What limits the current comparison

Across the original four-vCPU holdout, Micropod's slowest eight of 32 downloads delivered **24.74%** of the bytes in the median clean round. Their share ranged from **24.38% to 24.86%**. OrbStack's corresponding share was **20.97%**, ranging from 20.20% to 21.71%. Equal shares give 25%. The aggregate throughput gap on this single port therefore persisted even when Micropod's connections progressed at very similar rates. The archive records stream bytes without the relay worker assignment or time series for each stream. [Original per-stream measurements](../2026-11-21/gamma-vcpu-priority.json.gz)

| Four-vCPU end-to-end holdout, before this change | Micropod | OrbStack |
|---|---:|---:|
| Bulk throughput, MiB/s | 2,710 | 3,010 |
| Fresh p95 / p99, ms | 35.2 / 58.1 | 220.3 / 1,027.4 |
| Clean rounds / attempted | 16 / 16 | 15 / 16 |
| Failed fresh requests / offered | 0 / 3,840 | 1 / 3,840 |
| Reopened bulk connections | 0 | 0 |
| Measured runtime processes, CPU-s/GiB | 0.956 | 1.074 |
| Measured runtime processes, runnable thread-s/s including execution | 4.680 | 8.845 |

The table uses each runtime's clean medians and counts failures over every attempt. Across the 15 common clean pairs, the median Micropod throughput difference was **−14.6%**, with a paired bootstrap interval of **−29.1% to +25.9%**. The host rows sum Micropod's VMM and relay within each clean round before taking the median. The OrbStack rows cover its helper process. The sampler brackets client setup, the six-second transfer and drain. The CPU cost denominator is scored payload bytes. [VM throughput graph](gamma-end-to-end-vm.png) · [Host relay throughput graph](gamma-host-relay-gains.png) · [Per-process counters and counting rules](gamma-tcp-contrasts.md)

## Reproduce the fixed-work check

The implementation is `32c02970ceca807f850d8be314f5c47b22b0a81f` on the local `perf/worker-cpu-and-bridge` branch. Both current builds compile the same C source. The candidate adds `-DMICROPOD_BATCH_STREAM_FILTERS=1`. The parent control uses `86ca2713a0791d26c137e9a8c6385e1b6bd04ebb`. The receipt includes source, fixture and binary hashes, compiler flags, actual submitted filters, syscall counts and partial-write length. [Relay implementation](../../../Sources/CPublishedTCP/PublishedTCP.c) · [Fixed-work fixture](../../../scripts/relaybench/filter_work.c)

```sh
python3 -B scripts/relaybench/check_filter_work.py
python3 -B scripts/relaybench/test_gamma_pilots.py -v
```

All 16 cases passed across the parent, current default, batched and AddressSanitizer/UndefinedBehaviorSanitizer builds. Each case checked 131,075 delivered payload bytes, including markers. The blocked cases wrote zero bytes on the first attempt. The partial cases wrote 16,384 of 32,768 bytes and then delivered the remaining suffix. Checks covered a FIN behind pending bytes, a reply in the other direction, partial registration failure, fresh data from the server, and revocation with a pending write. Both release-mode pilot binaries also exercised lease revocation across two dispatch workers, a sibling stream and reuse with zero timed rounds. Nine pilot tests passed. Clang static analysis reported the same diagnostic on both revisions in the existing close logger, where `getsockname` can receive a negative descriptor.

To reproduce the stream shares from the checksum-pinned VM archive, run this from the benchmark checkout.

```sh
python3 -B - <<'PY'
import sys
from statistics import median
sys.path.insert(0, "scripts/relaybench")
from gamma_contrasts import VM, clean_client, read_receipt
data = read_receipt(VM, "066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4")
for arm, rounds in data["phases"]["grace-holdout"]["runs"].items():
    clients = [row["client"] for row in rounds.values() if clean_client(row["client"])]
    shares = [100 * sum(sorted(c["per_stream_bytes"])[:8]) / c["bytes"] for c in clients]
    print(arm, len(shares), min(shares), median(shares), max(shares))
PY
```

## Next reserved run

The 23 November follow-up adds the four-vCPU VM test that isolates two versus four host relay workers. It uses the same 128-event callback on both arms after the shared stock baseline. [Commands, Gamma availability and peer holdout criteria](../2026-11-23/gamma-throughput-gap.md)

At 23:53 AEDT on 22 November the Mac had 6/6 leases and the isolated Linux runner had 1/1. At 00:11 AEDT on 23 November the Mac had 1/6 and Linux still had 1/1. The warm-CI reply gives the four-vCPU TCP baseline priority in the first released window. All four complete fixture records in the handoff directory, including the old peer pair, carry retirement markers. The owner had yet to designate a live fixture and an exclusive window. This pass ran the fixed-work socket checks without contacting either VM.

The smallest shared VM baseline uses the already-prepared driver on an owner-designated four-vCPU, 4 GiB direct-Reno Micropod worker with the stock two-worker relay. It uses one six-second warmup and one six-second scored interval. The paired VM sizing pilot now requires effective CPUs **0–3** inside both service containers, including on the six-vCPU VM. The four-CPU quota alone would have allowed a second variable to change. Reuse the existing listener and worker pilots independently. [VM baseline command and inputs in the sibling study checkout](../../../../kernel-path-20261122/docs/benchmarks/2026-11-22/kernel-path/README.md#run-in-a-released-slot) · [VM and relay pilot commands](gamma-tcp-contrasts.md#smallest-owner-run-tests)

For a **separate** filter-batching pilot, this command prints the host-only schedule. Both arms use two workers, one logical port, the staggered listener policy, 128 events per callback, 32 continuing downloads and 240 fresh probes at 25 ms intervals. Both enter the production asynchronous completion path from an already-connected descriptor. The only arm difference is compilation with the batching flag. With the seed below the scored orders are BA and AB. In a released window, adding `--run --out "$NEW_FILTER_RESULTS"` executes three warmup pairs and two scored pairs, for 60 seconds of offered load. Each arm records throughput, scheduled-arrival p95/p99, submitted and completed probes, CPU-s/GiB and process runnable time. [Paired host driver](../../../scripts/relaybench/gamma_relay_pilot.py)

```sh
python3 -B scripts/relaybench/gamma_relay_pilot.py filters --ports 1 --seed 34201
```

Once the owner confirms restored OrbStack access and supplies two live four-vCPU fixtures, this checks their identity, limits, loopback mapping and host counters with zero timed load.

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode peer \
  --a "$SCOPE4" --b "$ORB4" --check --out "$NEW_PREFLIGHT_RESULTS"
```
