# Closing the single-port throughput gap on Gamma

The 23 November research also has a separate four-vCPU pilot comparing launchd Standard and Interactive with the same relay build and socket settings. [Host scheduling experiment and source audit](../../research/2026-11-23-apple-silicon-performance-optimization.md)

The last four-vCPU VM holdout delivered 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. Closing that difference between clean medians takes an 11.1% lift. The median Micropod/OrbStack ratio across the 15 common clean pairs was 0.854, with a 95% paired bootstrap interval of 0.709–1.259. Recovering that paired point estimate would take a 17.1% lift. The comparison that decides which runtime is faster is a fresh paired holdout. [VM throughput graph](../2026-11-22/gamma-end-to-end-vm.png) · [Original per-round data](../2026-11-22/gamma-tcp-contrasts.json)

## Which change to test first

| Isolated change | Evidence on the same one-port topology | Next decision |
| --- | --- | --- |
| Two to four host relay workers | Three clean host-only pairs, two seconds per arm, fixed 128-event callback. Paired throughput rose 63.9%, fresh p99 went from 19.5 to 18.4 ms. | Take this into a four-vCPU VM first. Measure whether enough of the gain survives the guest path. |
| Listener distribution | Both layouts already split 32 flows 16/16 on one port. The measured change was +4.7%, interval −3.9% to +8.7%. | Use one listener policy throughout the worker test. The 78.5% gain belongs to 32 separate ports. |
| Batching filter updates | The bulk profile recorded just 12 short or blocked writes out of 35,821. | Keep this build option off during the worker test. |
| Register read filters after the guest connection completes | The opt-in relay used four kqueue submissions during asynchronous setup, down from six. In a local stream fixture, relay CPU across each fresh flow fell 2.52% over 16 paired blocks. | Reserve this candidate for a separate connection-churn screen after the fixed-worker comparison. |

The deferred-registration result corresponds to a median paired saving of 0.49 µs of relay CPU per asynchronous fresh flow. At the holdout's 40 fresh requests per second, the same per-flow effect would save about 20 µs of CPU per second. This arithmetic only scales the direct cost observed in the local fixture. Bulk-stream delivery and scheduling in the VM still need measurement. [Confirmation samples](relay-handshake-reads-confirmation.json)

Both one-port and 32-port fixtures can report a 16/16 flow split across two workers. The host scorer now checks the port count, client buffer size, profiling mode and minimum elapsed time in the raw output. The earlier scorer accepted the first clean 32-port candidate sample, 11,011.66 MiB/s, when asked to score one port. All 71 clean rates across the 72 original attempts reproduce at their recorded settings. [Scorer regression](../../../scripts/relaybench/test_compare.py)

[Host relay graph](../2026-11-22/gamma-host-relay-gains.png) · [Workload and host figures](../2026-11-22/gamma-tcp-contrasts.md) · [Filter call counts](../2026-11-22/gamma-filter-work.md)

## Relay copies when a receiver falls behind

The stock relay attempts one write for each ready endpoint. If that write sends only part of a new read, the relay allocates space for the unsent bytes and copies them. A second short write from the same buffer advances an offset. It needs no new allocation. This distinction matters in the two Gamma profiles below. Both combine uploads and downloads over a complete lease. Their historical counters bound the bytes that could have been copied.

| Archived VM workload | Short or blocked writes / attempts | Maximum bytes copied at 256 KiB per event |
| --- | ---: | ---: |
| Bulk-only lease, 8.00 GiB forwarded | 12 / 35,821 | 3 MiB (0.037%) |
| Uncapped service, 12 rounds of 32 downloads with 240 sequential fresh requests per round, 302.42 GiB forwarded | 153 / 1,476,438 | 38.25 MiB (0.0124%) |

The second lease includes warmup and drain. The four-vCPU, 40-arrivals-per-second OrbStack holdout did not collect these counters. A separate diagnostic run on the revised relay can report actual `pending_allocations` and `pending_copy_bytes` on lease release with `MICROPOD_CI_PORT_PROFILE=1`. Measure uninstrumented throughput separately. [Bulk profile](../2026-11-21/gamma-published-profile.json.gz) · [Mixed profile, record `uncapped-eof/relay`](../2026-11-21/gamma-mixed-path.json.gz) · [Worker profiling fields](../../ci-worker.md)

A local candidate lent the consumed read buffer to one stalled direction per owner when at least 64 KiB remained. A second 256 KiB buffer let the owner keep serving other flows. Four established streams shared the owner with short request/reply exchanges. Each arm verified 3 GiB of bulk data in each condition across 16 paired blocks. The fixture ran on anonymous macOS sockets, with a 32 KiB downstream buffer for the pressure case and 1 MiB for the freely draining control. The timing includes the staged short exchanges and verification. [Source and reproduction driver](../../../scripts/relaybench/check_suffix_loan.py) · [All measurements and sanitizer checks](relay-suffix-loan-offline.json)

| Local result | Stock | Buffer loan | Median paired change (95% interval) |
| --- | ---: | ---: | ---: |
| Copied bytes per 96 MiB of pressured bulk data | 90 MiB | 67.5 MiB | −25% in every sample |
| Verified throughput under pressure | 1,823 MiB/s | 1,801 MiB/s | −0.44% (−3.15% to +1.73%) |
| Fresh p95 under pressure | 73.3 µs | 72.6 µs | −4.62% (−8.79% to +2.87%) |
| Owner CPU per GiB under pressure | 0.2140 s | 0.2081 s | −4.25% (−5.63% to −2.62%) |
| Owner CPU per GiB, freely draining | 0.1311 s | 0.1246 s | −4.23% (−6.35% to −1.76%) |

Both builds copied zero suffix bytes in the freely draining control. Within each block, dividing the pressured candidate/control CPU ratio by the freely draining ratio gives a median change of −0.11% (95% block bootstrap −2.21% to +3.00%). The pressure trial shows fewer copies, with no resolved throughput or pressure-specific CPU gain. In a second set of 16 paired blocks, both arms used the same binary and toggled lending. Under pressure it again copied 25% fewer bytes. Owner CPU per GiB changed −0.65% (95% interval −3.94% to +0.53%), throughput −0.45% (−3.35% to +2.09%) and fresh p95 +6.85% (−3.58% to +11.62%). Keep the prototype in the benchmark fixture. Use the actual copy counters if a slow-consumer workload warrants another trial. [Same-binary confirmation](relay-suffix-loan-attribution.json)

## Relay read size at fixed queue topology

The archived Linux 6.18.35 mixed-load trial contained a 256 KiB control with the same flat relay queue as its 512 KiB candidate. Comparing within seven blocks, 512 KiB won six and gained 11.9% in median paired throughput (95% interval +1.2% to +22.2%). One round at each size exceeded the 75 ms fresh p95 target, reaching 87.2 ms at 512 KiB and 128.9 ms at 256 KiB. In an earlier three-burst workload, 512 KiB won two of six pairs and delivered 0.661× the paired 256 KiB throughput. Queue topology, callback policy and offered work differed between studies. [Archive replay and per-block results](relay-chunk-replay.json) · [Replay source](../../../scripts/relaybench/chunk_replay.py)

After the four-vCPU worker comparison, build stock and `-Xcc -DMICROPOD_BENCH_512K_READS=1` arms from the same revision with the selected worker count and identical callback settings. The switch doubles scratch capacity per relay object from 256 to 512 KiB. It changes the maximum read on both directions for fresh and established streams. With two data owners and an accept owner, the larger setting adds 768 KiB of scratch capacity. A Darwin socketpair check delivered 786,449 queued bytes in four reads at 256 KiB and two at 512 KiB. Both builds served a newly readable 17-byte reply before the next ready bulk read. [Fixed-work regression](../../../scripts/relaybench/test_relay_read_size.py)

Keep socket windows, one-write-per-ready-endpoint service and guest limits fixed. Record throughput and every round’s fresh p95, p99, loss, CPU/GiB and runnable wait. The historical result qualifies this comparison for a new trial on the revised relay.

## First released window

At 16:11 AEDT on 23 November the project volume showed 173 GiB available. Cuttlefish reported four of six slots leased on the Mac and one of one on the isolated Linux runner, whose displayed state was online. The four earlier scopes were retired. The storage update and request for an existing baseline or a released and provisioned scope were placed in the warm-CI handoff. [Fleet observation](gamma-fleet-1611-aedt.json)

The paired driver accepts the hosted Cuttlefish runners-list JSON for the `cuttlefish` project as well as the native fleet export. Preserve the service timestamp and both heartbeat times when refreshing it. For the stock pilot in the sibling checkout, `python3 -B scripts/relaybench/gamma_fleet.py "$HOSTED_SNAPSHOT"` prints its native fleet format. A busy, stale or otherwise ineligible lane remains ineligible after conversion. The owner handoff and effective disk clearance are separate inputs.

The warm-CI owner's first priority is the shared stock baseline. Reuse its receipt if available. Otherwise the designated direct-Reno four-vCPU, two-worker scope gets one six-second warmup and one six-second scored interval. At 10:21 and 10:34 AEDT on 23 November the isolated Gamma Linux runner held 1/1 leases and the Mac agent was draining. All four previous peer fixture records were retired. The worker comparison needs its own two serving scopes and a released window. [Baseline command and fixture requirements in the sibling checkout](../../../../kernel-path-20261122/docs/benchmarks/2026-11-22/kernel-path/README.md#run-in-a-released-slot)

An ordinary build gives two workers 128 events per callback and four workers 24. To isolate the worker count, build one benchmark binary for both disposable supervisors. The following build option makes both use 128. The local Darwin fixed-work fixture actually forwarded 128 and 24 one-byte reads with the ordinary binary and 128 and 128 with the benchmark binary. Both preserved the full payload and order. [Fixed-work program](../../../scripts/relaybench/check_callback_budget.c)

```sh
swift build -c release --product micropod -Xcc -DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1
```

Use the isolated benchmark jobs' normal signing and launch procedure for that binary. Set `MICROPOD_CI_PORT_RELAY=kqueue-interactive` on both and `MICROPOD_CI_PORT_RELAY_WORKERS=2` on A and `4` on B. Keep relay profiling off. Both VMs use four vCPUs, 4 GiB RAM, the stock 7.3.5 kernel, the same direct macvlan/Reno route and a 512 KiB guest-facing receive buffer. The service uses CPUs 0–3, a four-CPU quota, 1 GiB of memory and 512 PIDs. The pilot verifies the original image configuration digest, control binaries, actual boot-session worker count and callback budget, mapped supervisor executable, and configured kernel image. It checks fixture identity again after timing. [Paired VM driver](../../../scripts/relaybench/gamma_pilot.py)

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202 \
  --a "$SCOPE_4V_2W" --b "$SCOPE_4V_4W" --fleet "$FLEET" --release "$RELEASE" --check --out "$NEW_WORKER_CHECK"
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202 \
  --a "$SCOPE_4V_2W" --b "$SCOPE_4V_4W" --fleet "$FLEET" --release "$RELEASE" --run --out "$NEW_WORKER_RUN"
```

The first command prints the schedule offline. The second verifies already-serving endpoints with zero timed load. The last runs three warmup pairs and two scored pairs with opposite orders, 60 seconds of offered load including warmup. Each arm keeps 32 bulk downloads active and schedules 240 fresh requests at 25 ms intervals. Record MiB/s, fresh failures and reopens across all attempts, scheduled-arrival p95/p99, CPU-s/GiB and runnable thread-s/s. Sum Micropod's VMM and supervisor within each round. The corresponding OrbStack process is its helper.

## What to do with the result

1. If both scored orders show a gain with clean requests and acceptable tail latency and CPU cost, carry that worker count and callback budget into the next comparison. The short screen selects a candidate. A four-worker result at 128 events qualifies that setting only. Changing it to the ordinary four-worker budget of 24 needs a separate callback-only test.
2. If the worker gain disappears inside the VM, compare the same server on the same boot through the published port and directly through guest ingress. One earlier six-round series measured 2,839 MiB/s published and 3,282 MiB/s through guest DNAT. A repeat can locate a host-publication bottleneck or point toward guest/VMM work. [Prior path measurements](../2026-11-21/gamma-mixed-path.md)
3. For a four- versus six-vCPU comparison use `--mode size --relay-workers "$WORKERS" --seed 34204`. Fix the selected worker count, 128-event callback and effective service CPUs 0–3 on both arms. A six-vCPU candidate needs a six-vCPU OrbStack comparison.
4. Once the owner confirms restored OrbStack socket and loopback access, run the preflight below against two dedicated scopes. For the independent timed holdout replace `--check` with `--run` and choose a fresh output directory. Use the same Micropod executable digest as the selected candidate. Compare 16 scored pairs with balanced randomized ordering, preceded by three warmup pairs. Retain every dirty attempt. Require clean Micropod rounds, zero fresh losses and bulk reopens, and a lower 95% paired throughput bound above 1 before reporting a throughput win. Compare the tails, cost and runnable time with the contemporaneous control.

The peer holdout uses the fixed-load client that records scheduled-arrival p50, p95 and p99. Build the pinned tools offline into a new directory before preflight. [Build procedure and toolchains](../../research/2026-11-23-apple-silicon-performance-optimization.md#reproduce-offline)

```sh
python3 -B scripts/relaybench/build_host_role_tools.py "$NEW_TOOLS"
python3 -B scripts/relaybench/gamma_pilot.py --mode peer --holdout --seed 34203 --tools "$NEW_TOOLS" \
  --relay-workers "$WORKERS" --peer-vcpus "$VCPUS" \
  --a "$SCOPE_MICROPOD" --b "$SCOPE_ORBSTACK" --fleet "$FLEET" --release "$RELEASE" \
  --check --out "$NEW_PEER_CHECK"
```

After a timed holdout, score the local receipts against the executable digest recorded when the candidate was selected. The scorer requires a complete schedule, at least 15 common clean pairs, every Micropod round clean with fresh p95 ≤75 ms, and a lower paired throughput bound above parity. Its exit status is 0 for a qualifying comparison, 1 for a completed comparison that missed the criteria, and 2 for incomplete or invalid evidence.

```sh
python3 -B scripts/relaybench/peer_verdict.py --run-directory "$NEW_PEER_RUN" --candidate-sha256 "$SELECTED_CLI_SHA"
python3 -B scripts/relaybench/peer_verdict.py --archive
```
