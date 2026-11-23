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
