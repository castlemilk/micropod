# Closing the single-port throughput gap on Gamma

The last four-vCPU VM holdout delivered 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack. Closing that difference between clean medians takes an 11.1% lift. The median Micropod/OrbStack ratio across the 15 common clean pairs was 0.854, with a 95% paired bootstrap interval of 0.709–1.259. Recovering that paired point estimate would take a 17.1% lift. The comparison that decides which runtime is faster is a fresh paired holdout. [VM throughput graph](../2026-11-22/gamma-end-to-end-vm.png) · [Original per-round data](../2026-11-22/gamma-tcp-contrasts.json)

## Which change to test first

| Isolated change | Evidence on the same one-port topology | Next decision |
| --- | --- | --- |
| Two to four host relay workers | Three clean host-only pairs, two seconds per arm, fixed 128-event callback. Paired throughput rose 63.9%, fresh p99 went from 19.5 to 18.4 ms. | Take this into a four-vCPU VM first. Measure whether enough of the gain survives the guest path. |
| Listener distribution | Both layouts already split 32 flows 16/16 on one port. The measured change was +4.7%, interval −3.9% to +8.7%. | Use one listener policy throughout the worker test. The 78.5% gain belongs to 32 separate ports. |
| Batching filter updates | The bulk profile recorded just 12 short or blocked writes out of 35,821. | Keep this build option off during the worker test. |

[Host relay graph](../2026-11-22/gamma-host-relay-gains.png) · [Workload and host figures](../2026-11-22/gamma-tcp-contrasts.md) · [Filter call counts](../2026-11-22/gamma-filter-work.md)

## First released window

The warm-CI owner's first priority is the shared stock baseline. Reuse its receipt if available. Otherwise the designated direct-Reno four-vCPU, two-worker scope gets one six-second warmup and one six-second scored interval. At 10:21 and 10:34 AEDT on 23 November the isolated Gamma Linux runner held 1/1 leases and the Mac agent was draining. All four previous peer fixture records were retired. The worker comparison needs its own two serving scopes and a released window. [Baseline command and fixture requirements in the sibling checkout](../../../../kernel-path-20261122/docs/benchmarks/2026-11-22/kernel-path/README.md#run-in-a-released-slot)

An ordinary build gives two workers 128 events per callback and four workers 24. To isolate the worker count, build one benchmark binary for both disposable supervisors. The following build option makes both use 128. The local Darwin fixed-work fixture actually forwarded 128 and 24 one-byte reads with the ordinary binary and 128 and 128 with the benchmark binary. Both preserved the full payload and order. [Fixed-work program](../../../scripts/relaybench/check_callback_budget.c)

```sh
swift build -c release --product micropod -Xcc -DMICROPOD_BENCH_FIXED_RELAY_BUDGET=1
```

Use the isolated benchmark jobs' normal signing and launch procedure for that binary. Set `MICROPOD_CI_PORT_RELAY=kqueue-interactive` on both and `MICROPOD_CI_PORT_RELAY_WORKERS=2` on A and `4` on B. Keep relay profiling off. Both VMs use four vCPUs, 4 GiB RAM, the stock 7.3.5 kernel, the same direct macvlan/Reno route and a 512 KiB guest-facing receive buffer. The service uses CPUs 0–3, a four-CPU quota, 1 GiB of memory and 512 PIDs. The pilot verifies the original image configuration digest, control binaries, actual boot-session worker count and callback budget, mapped supervisor executable, and configured kernel image. It checks fixture identity again after timing. [Paired VM driver](../../../scripts/relaybench/gamma_pilot.py)

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202 \
  --a "$SCOPE_4V_2W" --b "$SCOPE_4V_4W" --check --out "$NEW_WORKER_CHECK"
python3 -B scripts/relaybench/gamma_pilot.py --mode workers --seed 34202 \
  --a "$SCOPE_4V_2W" --b "$SCOPE_4V_4W" --run --out "$NEW_WORKER_RUN"
```

The first command prints the schedule offline. The second verifies already-serving endpoints with zero timed load. The last runs three warmup pairs and two scored pairs with opposite orders, 60 seconds of offered load including warmup. Each arm keeps 32 bulk downloads active and schedules 240 fresh requests at 25 ms intervals. Record MiB/s, fresh failures and reopens across all attempts, scheduled-arrival p95/p99, CPU-s/GiB and runnable thread-s/s. Sum Micropod's VMM and supervisor within each round. The corresponding OrbStack process is its helper.

## What to do with the result

1. If both scored orders show a gain with clean requests and acceptable tail latency and CPU cost, carry that worker count and callback budget into the next comparison. The short screen selects a candidate. A four-worker result at 128 events qualifies that setting only. Changing it to the ordinary four-worker budget of 24 needs a separate callback-only test.
2. If the worker gain disappears inside the VM, compare the same server on the same boot through the published port and directly through guest ingress. One earlier six-round series measured 2,839 MiB/s published and 3,282 MiB/s through guest DNAT. A repeat can locate a host-publication bottleneck or point toward guest/VMM work. [Prior path measurements](../2026-11-21/gamma-mixed-path.md)
3. For a four- versus six-vCPU comparison use `--mode size --relay-workers "$WORKERS" --seed 34204`. Fix the selected worker count, 128-event callback and effective service CPUs 0–3 on both arms. A six-vCPU candidate needs a six-vCPU OrbStack comparison.
4. Once the owner confirms restored OrbStack socket and loopback access, run the preflight below against two dedicated scopes. For the independent timed holdout replace `--check` with `--run` and choose a fresh output directory. Use the same Micropod executable digest as the selected candidate. Compare 16 scored pairs with balanced randomized ordering, preceded by three warmup pairs. Retain every dirty attempt. Require clean Micropod rounds, zero fresh losses and bulk reopens, and a lower 95% paired throughput bound above 1 before reporting a throughput win. Compare the tails, cost and runnable time with the contemporaneous control.

```sh
python3 -B scripts/relaybench/gamma_pilot.py --mode peer --holdout --seed 34203 \
  --relay-workers "$WORKERS" --peer-vcpus "$VCPUS" \
  --a "$SCOPE_MICROPOD" --b "$SCOPE_ORBSTACK" --check --out "$NEW_PEER_CHECK"
```
