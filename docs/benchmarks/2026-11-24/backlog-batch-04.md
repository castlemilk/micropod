# Micropod published TCP · Batch 4

24 November 2026 · 10 new comparisons, 40 across four batches. Six comparisons used archived VM workloads, one varied scheduler sampling cadence against archived VM observations and three used local fixtures. Every selected comparison kept its original first attempts or fixed-work cases. The new read-only queue collector, test assertions and byte-for-byte replays contribute zero additional experiments. [Previous batch](backlog-batch-03.md) · [GitHub register](https://github.com/castlemilk/micropod/issues/227#issuecomment-7118736270)

## What the scheduling trace resolves

The last scored four-vCPU holdout had 16 attempts per engine and 15 jointly clean pairs. The median Micropod/OrbStack throughput ratio was 0.854 (95% paired interval 0.709–1.259). Its process counters alone could not distinguish vCPUs waiting for a core from vCPUs with no work ready to run. This batch inspected a **separate four-pair diagnostic series** for which per-vCPU state observations, cumulative CPU counters, client score endpoints and byte counts survived. [Historical holdout](../2026-11-22/gamma-tcp-contrasts.md#end-to-end-vm) · [Diagnostic inputs and results](vcpu-sample-cadence.json)

| Diagnostic pair | Fresh delivery | Excess Micropod nonrunnable time at original cadence, summed over four vCPUs (thread-s/wall-s) | Range across all nine combinations of sampling cadence |
| --- | --- | ---: | ---: |
| 1 | Both clean | +0.553 | +0.452 to +0.624 |
| 2 | One OrbStack fresh EOF | +0.513 | +0.450 to +0.604 |
| 3 | Both clean | +0.403 | +0.228 to +0.587 |
| 4 | Both clean | +0.644 | +0.569 to +0.713 |

In all three clean pairs, Micropod’s vCPUs collectively spent more time **without work ready to run**. The reported differences use state samples inside the scored window. CPU counters bound running time at the window edges. Thinning the observations reversed the dominant off-CPU state in 2/16 individual Micropod vCPU windows and 3/16 OrbStack windows. The ranges above are sensitivity to measurement cadence, not confidence intervals. A nonrunnable observation can reflect an idle guest, a lock, an I/O wait or another wait. A separately admitted trace matching a guest wakeup to a NIC completion, relay readiness and receiver byte progress can distinguish those explanations. [Per-vCPU observations and limitations](vcpu-sample-cadence.json)

## Ten comparisons

| # | Existing direction | Evidence tier | Result and decision | Evidence |
| --- | --- | --- | --- | --- |
| 1 | 228.02 · vCPU scheduling trace | Archived VM trace | Micropod’s four vCPUs spent an estimated 0.40–0.64 more thread-seconds per second nonrunnable than OrbStack’s across the three jointly clean diagnostic pairs. The sign survived both offsets at half cadence. | [Data](vcpu-sample-cadence.json) · [Issue](https://github.com/castlemilk/micropod/issues/228#issuecomment-7118710055) |
| 2 | 231.08 · 512 KiB TX queue ceiling | Archived VM | The verified ceiling cut throughput in 8/8 pairs on Linux 6.18.35. A separate trace found backlog accumulating upstream. Keep stock and verify the limit on the revised path. | [Data](bql-effective-ceiling.json) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7118711909) |
| 3 | 231.07 · CUBIC vs Reno | Archived VM | CUBIC met the latency and delivery guardrails 8/8 versus Reno’s 5/8. Its median throughput advantage was 0.85% among the five pairs where both passed. Keep Reno as the baseline. | [Data](cubic-fixed-gro20.json) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7118714079) |
| 4 | 231.08 · 256-segment congestion window | Archived VM | The clamp reduced retransmissions but cost 11.9% throughput and lost all eight rate comparisons. The control already met the latency target every time. Keep it uncapped. | [Data](reno-flight-cap-loss.json) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7118715951) |
| 5 | 231.08 · fq_codel vs pfifo_fast | Archived VM | fq_codel won three of six pairs. Peak sampled queue backlog rose from 68 KB to 4.31 MB. Keep the stock queue discipline. | [Data](qdisc-backlog-progress.json) · [Issue](https://github.com/castlemilk/micropod/issues/231#issuecomment-7118717563) |
| 6 | 237.05 · CPU 3 interrupt affinity | Archived VM | Pinning the interrupt won 2/4 throughput pairs with stock queues and 2/4 with fair queues. Its latency effect changed direction. Keep stock affinity. | [Data](irq-cpu3-crossover.json) · [Issue](https://github.com/castlemilk/micropod/issues/237#issuecomment-7118719079) |
| 7 | 230.14 · Wait for a readable client | Host-only fixture | Waiting for readiness saved one empty read in four late-arrival cases. It cost a poll in every already-buffered case. Keep the speculative read. | [Data](handshake-ready-only.json) · [Issue](https://github.com/castlemilk/micropod/issues/230#issuecomment-7118720725) |
| 8 | 230.07 · Reuse a pending-write buffer | Host-only fixture | Eight repeated 32 KiB stalls needed one buffer allocation instead of eight. Copied bytes stayed constant, and a worker could retain 64 KiB while idle. Keep this opt-in. | [Data](spare-suffix.json) · [Issue](https://github.com/castlemilk/micropod/issues/230#issuecomment-7118722443) |
| 9 | 230.15 · Paired fresh-request timestamps | Source/fixture | Two streams of 240 observations had identical scheduled p95 and launch-delay p95 yet had 60 versus 90 ms p95 after launch. The read-size client can now retain the evidence needed to distinguish them. | [Data](paired-fresh-clock.json) · [Issue](https://github.com/castlemilk/micropod/issues/230#issuecomment-7118724269) |
| 10 | 232.04 · Bulk virtio-vsock concurrency | Archived VM | Sustained vsock delivered 768 MiB over 32 streams with zero reopens. Synchronized workloads reset at 12, 24 and 32 streams. Stream count alone does not explain the failure. | [Data](vsock-stream-envelope.json) · [Issue](https://github.com/castlemilk/micropod/issues/232#issuecomment-7118726348) |

## Two kernel decisions

**Transmit queue ceiling.** On the older healthy 6.18.35 eth0 path, every arm recorded the numeric ceiling and every request completed. Reducing the ceiling to 512 KiB cost a median 32.5% throughput. In separate profiles on that setup, the upstream queue contained backlog at 494 of 502 samples with transmit progress. On the later 7.3.5 eth1 path in batch three, requesting 512 KiB improved delivery from 0/4 to 4/4 clean attempts, but the effective value was missing. These are different operating conditions. Keep stock for the revised baseline and capture the queue identity, actual limit and in-flight bytes on its publication NIC before advancing the reliability lead. [Healthy path](bql-effective-ceiling.json) · [Later lossy path](bql-requested-ceiling.json) · [Read-only collector](../../../scripts/relaybench/bql_capture.sh)

**CUBIC.** At a fixed 20 µs GRO timeout, CUBIC met clean delivery and 75 ms p95 in 8/8 rounds versus Reno’s 5/8. The paired throughput advantage was 16.0% over seven clean pairs and 0.85% over the five where both arms also passed latency. The latter interval was −17.2% to +24.4%. Keep Reno for the control. CUBIC remains eligible for its own replication after the mandated baseline and worker comparison. [All first attempts, interrupt cost and latency](cubic-fixed-gro20.json)

## Resume and reproduce

The read-only Cuttlefish snapshot at **11:52 AEDT** showed 0/6 leases on Gamma-128GB.local and 1/1 on its isolated Linux runner. The warm-CI checkout and owner handoff contained no newly qualified revised stock receipt or released mode, serving scopes and current effective disk clearance. The batch ran entirely offline with zero live VM attempts and no peer endpoint probe.

The next live measurement is the revised four-vCPU, two-worker stock baseline, reusing the owner’s qualified receipt if available. Next change only two to four relay workers with four vCPUs and 128 callback events. Listener distribution, bridge/direct, read size and four versus six vCPUs each retain their own comparison. The new paired-clock observer belongs only to the separately released read-size diagnostic. The independent randomized matched OrbStack holdout and the throughput, latency and loss verdict remain pending. [Live fixture requirements](../2026-11-23/gamma-throughput-gap.md#first-released-window)

Evidence and analysis revision `84771b74a0912f4bc42ed47c0b5823a430981576` in the performance worktree. Run `python3 -B scripts/relaybench/<command>` from its root. The Go fixture uses the existing Go 1.27.2 Darwin/arm64 toolchain and Xcode command-line tools. To build the diagnostic observer alone, use `python3 -B scripts/relaybench/build_host_role_tools.py --paired-fresh NEW_TOOLS_DIR`. The regular build continues to produce the original control checksum.

| Direction | Replay command | Local JSON SHA-256 |
| --- | --- | --- |
| 228.02 | `vcpu_sample_cadence.py` | `c393403df97e79d807d722f75f70b3f36ef0bd085f6b582adf3851475f50249b` |
| 231.08 | `guest_tx_policy_replay.py bql` | `3cd0262f1e7a75f8bf0a1c8ac31eccdbad811a70226af111d4b7f4d2c3f8bb9b` |
| 231.07 | `guest_tcp_flight_replay.py cubic` | `4e13e40c776bc7c90190d71e858eab58247058a912bbf52e003c6dd5dcc3ea7c` |
| 231.08 | `guest_tcp_flight_replay.py flight` | `b8a8706062282de5f08871ffd87633678876df870a1a1bcc4e597338bd3fe37a` |
| 231.08 | `guest_tx_policy_replay.py qdisc` | `767bb2894c4f7a049357d9a3bf60f9eb4e8eedd0e70a5358b19008ca08a2e135` |
| 237.05 | `irq_affinity_crossover.py` | `1dd61ff92d413391566d2bd0951ef8dcf587e0d114bc2a8652a7caf39d680977` |
| 230.14 | `relay_buffer_policies.py handshake_ready_only` | `26e3066eabf7681692e73c5f1886997863663e8a1ab8e123ae5df6c6fce6933a` |
| 230.07 | `relay_buffer_policies.py spare_suffix` | `f7f7624774e8f82e35d4803a98afcc8be8f49d0bbe277b7a404c87327549e36a` |
| 230.15 | `check_fresh_samples.py` | `6c45e2cb027293da6f6d57112dd1316c9619e88f2006ad17a5673bf88ada9466` |
| 232.04 | `vsock_stream_envelope.py` | `2266bfab0b40e48e5abfae55cb07e75b967a16a6f11bbfbb5a612c1d5275aee6` |
