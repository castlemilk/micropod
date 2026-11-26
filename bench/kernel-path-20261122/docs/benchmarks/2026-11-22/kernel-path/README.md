# Gamma published TCP, 22 November 2026

**After handoff, run** one warm six-second interval and one scored six-second interval on the four-vCPU Micropod scope with the revised relay, stock fair scheduling and the qualified direct Reno path. A single result establishes current provenance and client correctness. The paired test after that changes the publication path between bridge and direct.

At **18:21 AEDT (07:21 UTC)** the isolated Gamma Linux runner still held **1/1 leases**. Its latest heartbeat was at 07:21:03 UTC. The Mac agent showed 0/6 leases and 43.0% host CPU. The 07:02 UTC check had also shown 1/1 on Linux. The TCP-owner handoff left the existing reservation in place. A reply requested a reusable receipt or an explicitly released scope/window. Neither a release nor a current-relay VM receipt was available. This study made zero live endpoint calls and zero new timed attempts. [Latest fleet observation](admission-latest.json) · [Earlier observation](admission.json)

[Research hypotheses and decisions](hypotheses.md) · [Raw round records](rounds.jsonl) · [Archive and image hashes](index.json) · [Replayed comparison and per-pair spread](summary.json) · [Offline validation](validation.json)

At **22:01:59 AEDT (11:01:59 UTC)** Cuttlefish still showed **1/1** leases on the isolated Linux runner and **0/6** on the Mac. The checkout's APFS Data volume reported 42,755,132 KiB available (40.8 GiB, 98% capacity). Reading the host's effective memory pressure via `sysctl -n kern.memorystatus_vm_pressure_level` returned `Operation not permitted`. The warm-CI owner had not released an isolated slot. Both revised-relay plans below have zero live attempts in this pass. [Admission observations](admission-cpu-attribution.json)

## What Gamma already measured

| Archived arm | Clean / attempts | Bulk MiB/s | Fresh p95 / p99 ms | VMM / relay CPU-ns per byte | Failed fresh / offered | Bulk reopens |
|---|---:|---:|---:|---:|---:|---:|
| Full 7.3.5, bridge | 12/12 | 2,496 | 114.2 / 170.4 | 0.531 / 0.284 | 0 / 2,880 | 0 |
| Full 7.3.5, direct macvlan | 12/12 | 3,238 | 73.2 / 130.4 | 0.443 / 0.277 | 0 / 2,880 | 0 |
| Earlier four-vCPU Micropod holdout, qualified direct | 16/16 | 2,710 | 35.2 / 58.1 | 0.564 / 0.324 | 0 / 3,840 | 0 |
| OrbStack in that holdout | 15/16 | 3,010 | 220.3 / 1,027.4 | 1.000 / unavailable | 1 / 3,840 | 0 |

The first crossover used the same full-preemption kernel image on two separate boots with 4 vCPUs, 4 GiB, the same native service image, CPUs 0–3, a four-CPU quota, 1 GiB and 512 PIDs. On the six-second offered workload, direct won 9/12 common pairs. The median paired change was **+25.2%** with a descriptive paired bootstrap interval of **+8.7% to +51.1%**. The earlier same-image series gave **+5.1% [−7.3%, +15.2%]**. The separate lazy-preemption crossover gave **+10.0% [−10.9%, +28.8%]**. The bridge-only comparison of the 6.18.35 and 7.3.5 kernel builds gave **+0.3% [−17.6%, +7.7%]**. Their configs differed. [All six reproducible series](summary.json)

Both confirmation routes pinned Reno and a locked 20 ms minimum retransmit timer, with the same QuickACK and route MTU fields. The direct service's dedicated interface transmitted 244,082,976,085 bytes across the series while its ordinary interface transmitted 350. The bridge's ordinary interface transmitted 210,679,795,243. Only the direct arm archived a congestion-controller readback from an accepted probe socket. The new pilot opens a single allowlisted loopback identity request and verifies the congestion controller on the actual service socket on **both** paths before loading either. These observations put part of the historical CPU saving in the VMM process. They do not isolate guest NAT cost, host virtual networking, VM exits or physical packet loss. [Route readbacks](index.json)

The peer holdout predates the revised relay. Micropod's paired throughput difference was **−14.6% [−29.1%, +25.9%]** across 15 common clean pairs. OrbStack round 12 lost a fresh `GET /id` to EOF. Micropod's published guest-interface RX and TX drop counters stayed flat across its 16 measured intervals. The peer lacked that counter and the bridge/direct crossover lacks per-round device drops. End-to-end fresh failures, bulk reconnects, interface drops, TCP retransmissions and physical packet loss have different denominators. [Per-round raw evidence](rounds.jsonl)

Medians in the table use each arm's clean rounds. Fresh p95/p99 are medians of six-second windows' scheduled-arrival percentiles. They do not estimate a stable service-wide tail. Paired differences resample whole clean blocks with 10,000 bootstrap draws, seed 7317. The CPU numerator is Darwin user + system ticks over the client invocation, including setup and drain. The denominator is scored application payload bytes. The median counter windows were 6.465 s for bridge and 6.299 s for direct. Process CPU excludes the load client and other host processes. Some source rounds participate in two archival comparisons, so pooling rows as independent observations would double-count work.

## CPU cost per byte and occupied host cores

The new `cpu-attribution` replay answers two questions for each matched block. How much VMM and relay CPU did each delivered bulk byte cost? How many host cores did those two processes occupy on average during the sampling interval? It sums the two processes within each arm and subtracts bridge from direct in the same block. The table gives medians of those signed differences. One mean host core equals one CPU-second per wall-second between the Darwin snapshots. The workload also serves fresh requests during that interval. [Per-block receipt with order, tails, failures and spread](cpu-attribution.json)

| Older-relay comparison, 12 pairs each | CPU ns per bulk byte, direct − bridge | Pairs with lower cost on direct | Mean host cores, direct − bridge | Pairs with higher occupancy on direct |
|---|---:|---:|---:|---:|
| Full kernel, VMM | −0.08074 | 11/12 | +0.11901 | 9/12 |
| Full kernel, relay | −0.00643 | 9/12 | +0.17529 | 9/12 |
| Full kernel, both processes | **−0.08618** | **11/12** | **+0.27644** | **9/12** |
| Lazy kernel holdout, both processes | −0.07561 | 11/12 | −0.01889 | 6/12 |

In the full-kernel crossover the combined difference ranged from −0.23081 to +0.02174 ns/byte and from −2.454 to +1.628 mean cores. Direct carried more bytes in 9 of 12 pairs. The host process counters locate most of the per-byte difference in the VMM. Guest NAT, host networking and VM exits still share that process-level measurement. The earlier `path-first` rounds lack process counters and return `null` for cost, occupancy and win counts. Interface drops are also `null` where a counter was unavailable.

The following commands run entirely from saved data. The stock plan uses the revised two-worker relay, four vCPUs, 4 GiB and the qualified direct path. Its single scored interval gives an **absolute** observation. The independent path plan keeps the same kernel in both arms and scores direct/bridge followed by bridge/direct. The two directories contain only plans. An interrupted pilot retains attempted failures and missing-arm states. Its aggregate is withheld until the driver's final identity check completes.

```sh
cd /Users/benebsworth/projects/micropod/bench/kernel-path-20261122
RELAY=/Users/benebsworth/projects/micropod/bench/worker-performance
DATA=docs/benchmarks/2026-11-22/kernel-path
python3 -B scripts/gamma_path_study.py cpu-attribution --series path-confirmation | cmp - "$DATA/cpu-attribution.json"
python3 -B scripts/gamma_path_study.py cpu-attribution --series path-holdout-lazy
python3 -B scripts/gamma_path_study.py cpu-attribution --series path-first
python3 -B scripts/gamma_path_pilot.py baseline --relay-checkout "$RELAY" | cmp - "$DATA/dry-stock-relay/plan.json"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$DATA/dry-stock-relay"
python3 -B scripts/gamma_path_pilot.py path --seed 34199 --relay-checkout "$RELAY" | cmp - "$DATA/dry-bridge-direct/plan.json"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$DATA/dry-bridge-direct"
```

## Replay and dry run

Set `RELAY` to the TCP owner's **existing source checkout**, containing commit `86ca2713a0791d26c137e9a8c6385e1b6bd04ebb`. All commands below use that exact commit's blobs. The current relay implementation was introduced at `2ee6f14375781702107dafc43322334fabf49e73`. The `Sources`, `guest` and `Package.swift` trees match at those two commits. This study sits on the separate warm-CI branch at `a182ecb9744c7914a7d64d375bc458267c53536f`. The driver applies its path-inspection extension only to a temporary copy of the two original helper modules.

```sh
RELAY=/Users/benebsworth/projects/micropod/bench/worker-performance
DATA=docs/benchmarks/2026-11-22/kernel-path
python3 -B scripts/gamma_path_study.py replay --series path-confirmation
python3 -B scripts/gamma_path_pilot.py baseline --relay-checkout "$RELAY"
python3 -B scripts/gamma_path_pilot.py path --seed 34199 --relay-checkout "$RELAY"
scratch=$(mktemp -d)
python3 -B scripts/gamma_path_study.py extract "$RELAY" "$scratch/from-archives"
cmp "$scratch/from-archives/rounds.jsonl" "$DATA/rounds.jsonl"
cmp "$scratch/from-archives/index.json" "$DATA/index.json"
python3 -B scripts/gamma_path_study.py replay --from-dir "$scratch/from-archives" > "$scratch/replay.json"
cmp "$scratch/replay.json" "$DATA/summary.json"
MICROPOD_RELAY_SOURCE="$RELAY" python3 -B scripts/test_gamma_path.py -v
```

`rounds.jsonl` preserves the offered-order records, client-reported tails, per-stream bytes, all saved client errors and the original host counter readings for the selected arms. The three compressed source hashes resolve in the locally pinned relay tree. Regenerating the extract excludes other engines from the path contrast. The table above counts failures before applying the clean-pair mask.

## Verifying the scored stock baseline

At `ed8bb626`, the pilot checked the mapped relay executable, the session's two data workers, the service image and the booted kernel. The baseline completion file recorded two clean attempts. It could accept the same host-counter interval and client stdout twice, once as warmup and once as scored. The original offline integration fixture exercised exactly this case. [Before/after exit codes, input hashes and test output](stock-baseline-validation.json)

The stock baseline now records the observed supervisor executable digest and mapped device/inode against the trusted build revision. It rechecks that mapping after the run. Each invocation records the active session's worker count, instance and supervisor PID, the running service ID, boot and both process birth times. The scored counter window must start after warmup ends. The client start and finish must fall between its own counter samples. The completion receipt binds the plan, fixture, both original attempts and the scored stdout by SHA-256. These hashes allow a reader to detect substituted files relative to the producer's completion receipt.

Fresh loss must be known and zero for acceptance. Both completion and dispatch timings must fit the measured invocation. A request can finish after the six-second offered interval while the client drains. The pinned client reports window-level percentiles and a failure list. Individual arrival timestamps are unavailable. Older completed baselines remain readable with an `unqualified legacy baseline` status and a null aggregate. The paired bridge/direct driver retains its independent plan and acceptance rules.

| Offline fixture | `ed8bb626` replay | `2be5d091` result |
|---|---|---|
| Distinct warmup and scored intervals | — | Complete, with a scored-window receipt |
| Warmup copied into the scored slot, retaining the completion file | Complete, exit 0 | Rejected, exit 1 |
| Duplicate encountered while capturing the baseline | — | Pilot exits 1 and retains the failed scored first attempt and `stop.json` |

At **23:11 AEDT on 22 November** Gamma's isolated Linux lane still held **1/1** leases. APFS reported **39.24 GiB** available and **98%** capacity. An effective disk-gate clearance and explicit warm-CI release were unavailable. The fixture archive contains simulated worker observations and saved client data. This validation made zero live attempts. [Regression fixtures](stock-baseline-fixtures.zip)

```sh
cd /Users/benebsworth/projects/micropod/bench/kernel-path-20261122
RELAY=/Users/benebsworth/projects/micropod/bench/worker-performance
DATA=docs/benchmarks/2026-11-22/kernel-path
work=$(mktemp -d)
mkdir "$work/parent"
python3 -B -m zipfile -e "$DATA/stock-baseline-fixtures.zip" "$work/cases"
git archive ed8bb626129adb8dd339804def0ea5b1dcd2a983 scripts/gamma_path_study.py "$DATA/index.json" | tar -x -C "$work/parent"
python3 -B "$work/parent/scripts/gamma_path_study.py" cpu-attribution --pilot-dir "$work/cases/reused"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/control"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/producer-stop"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/legacy-ed8bb626"
MICROPOD_RELAY_SOURCE="$RELAY" python3 -B scripts/test_gamma_path.py -v
# This last command must exit 1 with “scored host window overlaps or precedes warmup”.
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/reused"
```

### Binding the stock kernel configuration to one boot

At `2be5d091`, a guest inventory containing two captures passed the stock pilot. Boot `retired` supplied the expected kernel configuration digest. The simulated running boot `B` reported a different digest under the same kernel release. The pilot found both expected strings in the combined file and completed two simulated attempts. Its replay also produced an aggregate. [Mixed input](stock-guest-mixed.txt)

Version 2 reads the owner export once. The pilot saves those bytes as `guest-A.txt` and uses them for the boot checks before and after each client invocation. It requires exactly one matching boot ID, kernel release, machine architecture and configuration digest. The fixture and scored completion include the SHA-256 of the raw export. Replay checks the file against both the recorded identity and its digest. A version 1 completion still exposes its original scored-window evidence with status `unqualified legacy baseline` and a null summary.

| Offline case | Result |
|---|---|
| Valid inventory, owner export removed after the first read | Capture and replay completed from the saved bytes |
| Two boots in one inventory | Capture stopped before warmup, with zero client calls |
| Same mixed inventory with recomputed fixture and completion hashes | Replay rejected the duplicate boot ID |
| Valid inventory with only its line endings changed after capture | Replay rejected the digest mismatch |

The fixtures use simulated worker observations and archived client output. [Fixture archive](stock-guest-inventory-fixtures.zip) · [Commands, exit codes, hashes and test output](stock-guest-inventory-validation.json)

```sh
DATA=docs/benchmarks/2026-11-22/kernel-path
work=$(mktemp -d)
python3 -B -m zipfile -e "$DATA/stock-guest-inventory-fixtures.zip" "$work/cases"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/v2-control"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/v2-mixed-stop"
# Both replays below exit 1.
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/v2-resealed-mixed"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$work/cases/v2-detached"
```

## Run in a released slot

The stock pilot and its offline replay check both the warmup and scored downloads against the raw service-interface TX counters. The increase on `mppub0` for direct publication or `eth0` for bridge must cover the bulk payload. The snapshots bracket setup and drain, so a higher total is expected. Four historical direct service captures met this lower bound across 56 rounds. Each capture covers a group of rounds.

At least 13 of the 240 requests must reach the reported p95. With arrivals 25 ms apart, p95 can be at most the full client duration minus 300 ms. For p99 the same calculation uses three requests and 50 ms. Both bounds include drain time. [Offline regression cases, archived byte counts and test commands](stock-window-and-worker-checks.json)

Version 3 of the stock baseline records the owner's effective disk clearance. Include an `effective_disk_gate` object in the owner-issued `RELEASE` JSON with `passed` set to `true`, a nonempty `source` identifying the effective observation, and timezone-qualified `checked_at` and `expires_at` timestamps. The disk clearance and exclusive reservation must both be current. The example below shows the fields only. The source and times come from the actual observation.

```json
{"passed": true, "source": "<owner's effective disk observation>", "checked_at": "<timestamp with UTC offset>", "expires_at": "<timestamp with UTC offset>"}
```

The pilot validates the clearance before probing the fixture and during each client. A client stops at its opening disk deadline even if a replacement clearance arrives later. Replay checks the initial handoff in `admission.json` and the opening and closing admission on both the warmup and scored attempts. It verifies their owner, reservation, fixture scope, validity periods and client timestamps. Earlier stock receipt versions retain their recorded evidence and return `unqualified legacy baseline` with a null aggregate.

Start only after the warm-CI owner explicitly releases an isolated slot and names the canonical disposable scope directories. Obtain a fresh read-only fleet export and verify available APFS space and effective host pressure before load. The driver checks fleet admission and CPU idle. APFS and effective pressure clearance require separate current observations. Hold the published-TCP reservation first. If the owner already has the exact revised-relay baseline on hand, reuse its receipt. Use the following inputs.

| Input | What to supply |
|---|---|
| `FLEET` | Full JSON returned by `cuttlefish_fleet_summary`, or the two unchanged Gamma runner rows and `generatedAt`. The operator refreshes it atomically while the slot is held. The driver checks both heartbeats, online states and lease counts before each arm, during the client, and after it. Exports and heartbeats expire after 90 seconds. |
| `RELEASE` | Owner-issued JSON with `owner`, `reservation`, `host` (`Gamma-128GB.local`), `exclusive` (`true`), `starts_at`, `expires_at` (timezone-qualified), `modes` (e.g. `["baseline","path"]`), and `scopes` (canonical paths). The owner must actually hold the exclusive time and path reservation. A file created by the benchmark operator cannot grant it. |
| `DIRECT4`, `BRIDGE4` | Original `WORK/data/<fixture>` records with `base`, `id`, `name`, `addr`, `vmm` and `relay`. Each scope's worker serves one dedicated fixture on an IPv4 loopback publication. The two arms use separate already-running workers because publication is selected per worker. All timed clients run serially. |
| `BUILD` | Existing trusted build record with `source_revision` and `worker_executable_sha256`. The pilot checks the live supervisor's mapped executable vnode and file digest, session/socket/VM identity, launchd role, two data workers and actual Linux image. The pinned C revision fixes the 128-event budget and the Interactive mode fixes the guest receive buffer at 512 KiB. |
| `DIRECT_FACTS`, `BRIDGE_FACTS` | Run `sh guest-facts.sh` from the supplied script inside **each already-authorized Linux guest's network namespace**. Save stdout to the corresponding owner file. It reads the real boot ID, config digest and flags, command line, virtio driver/queues, offloads, supported ethtool diagnostics, steering masks, interrupts, softnet, drops, TCP counters and PSI. Service veth state alone cannot supply this evidence. The driver joins the inventory to the current native OCI boot and verifies stock scheduler and kernel/config hashes. |
| `TOOLS`, `SS` | Directory containing the hash-pinned Mac `fixed` and `rusage` executables (historically `/tmp/mp-priority.b3sbI7ym`). `SS` is existing iproute2 `ss` in the disposable service or its authorized read-only probe mount. `/mpcheck/check` and `/mpcheck/pathproof` are the original fixture probes. Missing read access is a stop condition. |
| `OUTPUT` | An existing local directory for new receipt directories. The program refuses to overwrite previous attempts. |

After those conditions are satisfied, run the following from the study checkout. The first command has **12 seconds of offered load**, six scored. This baseline uses the qualified direct Reno route from the previous TCP holdout. “Stock” here means the normal fair scheduler on the pinned worker kernel. To baseline the product's ordinary bridge on an explicitly reserved bridge scope, use `--baseline-path bridge` and supply that scope's facts.

```sh
common=(--relay-checkout "$RELAY" --fleet "$FLEET" --release "$RELEASE"
        --build "$BUILD" --tools "$TOOLS" --ss "$SS")
python3 -B scripts/gamma_path_pilot.py baseline "${common[@]}" \
    --a "$DIRECT4" --facts-a "$DIRECT_FACTS" --run --out "$OUTPUT/baseline"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$OUTPUT/baseline" > "$OUTPUT/baseline-host-cpu.json"
```

The second pilot uses 32 persistent 8 MiB downloads and 240 independent identity requests every 25 ms per arm. Three warm pairs and two scored pairs give **60 seconds of offered load**, of which 24 are scored, plus setup and drain. With seed 34199 the scored order is direct/bridge then bridge/direct. Prior to release, the same command without `--run` prints the order offline.

```sh
python3 -B scripts/gamma_path_pilot.py path "${common[@]}" --seed 34199 \
    --a "$BRIDGE4" --b "$DIRECT4" --facts-a "$BRIDGE_FACTS" --facts-b "$DIRECT_FACTS" \
    --run --out "$OUTPUT/path"
python3 -B scripts/gamma_path_study.py cpu-attribution --pilot-dir "$OUTPUT/path" > "$OUTPUT/path-host-cpu.json"
```

Each arm verifies service identity, pinned config digest, Docker client and daemon, limits, the checked output and socket, route and scoped interface. Before scoring, the Mac must be at least 90% idle and paired starts within five percentage points of each other, using the existing Apple launch-control sampler. The readiness and sampling work sits outside the client's byte window. Every attempt retains stdout/stderr, exit status, offered counts when available, CPU/byte by process, host runnable wait, guest PSI and service-interface deltas. A failure, unexpected work, expired reservation, denied access, changed boot, counter reset, lost request, reconnect or isolation failure ends the pilot. On timeout the fresh-failure count may be unknown. A mid-run lease change stops only this pilot's client. The program does not start workers or provision services. Compare both individual paired ratios and requalify independently before adopting a path.

**Outstanding evidence includes** owner-released scopes, current boot/config/NIC and binary attestations, a current-relay four-vCPU end-to-end baseline, matched bridge/direct CPU, loss and tail measurements, an independently replicated effect, and a live quota/fallback receipt for any scheduler comparison. The old −9.5% and −14.6% figures describe different historical holdouts. PostgreSQL at `2ef1bc4` stays a compatibility check. The database-free Alpine control at `06bfc10` still compares the same stock Docker client at 1 and 16 clients, with `micropod ci run` as a third arm. [Original launch control](../docker-launch-control.md)

### Kernel and scheduler pilots after the route comparison

Each later mode needs its own released window. `kernel` pairs stock 7.3.5 fair with an already-booted `full-scx` build running its default fair policy. `policy` pairs two scopes on that identical candidate Image/config, one fair and one running the qualified `scx_bpfland` build. Both serve the direct path. `CANDIDATE_BUILD` is a trusted JSON record with `release`, `image_sha256` and `config_sha256` from the candidate build. The checks require the `7.3.5-micropod-scx` release. This isolates the cost of making sched_ext available from the effect of selecting a policy. The historical 6.18.35→7.3.5 comparison addresses a different kernel-build question.

```sh
python3 -B scripts/gamma_path_pilot.py kernel "${common[@]}" --candidate "$CANDIDATE_BUILD" \
  --a "$DIRECT4" --facts-a "$DIRECT_FACTS" --b "$SCX_FAIR4" --facts-b "$SCX_FAIR_FACTS" \
  --run --out "$OUTPUT/kernel-fair"
python3 -B scripts/gamma_path_pilot.py policy "${common[@]}" --candidate "$CANDIDATE_BUILD" \
  --quota-dir "$Q" --a "$SCX_FAIR4" --facts-a "$SCX_FAIR_FACTS" \
  --b "$SCX_BPFLAND4" --facts-b "$SCX_BPFLAND_FACTS" --run --out "$OUTPUT/policy"
```

For `policy`, add `current-a` and `current-b` to the [three-phase quota receipt](hypotheses.md#commands-for-the-decisions), with the same file layout as `before`/`active`. Capture the fair job on A and the reattached policy on B, including `current-b/executable.sha256` from the running policy on B. B must be the same boot that rehearsed the return to fair. Its new attach sequence must follow that fallback. The driver verifies the current job quotas and matches both live boot IDs, ops and attach sequences before and after every arm. The owner of the disposable VM controls policy selection and rollback. A missing permission or fallback stops qualification before timing. Neither mode has a live result.
