**24 November 2026 · 231.07 · Do fewer service fq pacing deferrals buy receiver throughput?**

**Archived VM.** This diagnostic uses the existing six 21 November timer-slack pairs. The original report already compared throughput and p95. The new analysis matches service queue counters, application delivery and the 75 ms guardrail within each original pair. It adds zero new experiments to the batch.

Micropod source base `4f887ba5d28f47fa37d4bd0a2d89cd0914d74754`. Archive revision `692ace081c989f80fb2bce27a5a13af13098b77c`. The same four-vCPU, 4 GiB VM hosted a four-CPU, 1 GiB service with a Reno route. The fixed-arrival client used 32 bulk streams, 8 MiB response bodies and 240 fresh offers at 40/s over six seconds. Service fq pacing was enabled throughout. The only configured change was its timer slack, from 10 to 100 µs. Both service interface readbacks and the per-arm post-run NIC readbacks agree. The NIC retained fq pacing with 10 µs slack. The control ran first in three blocks and the candidate ran first in three.

| Per arm | 10 µs control | 100 µs candidate |
| --- | ---: | ---: |
| Median service fq throttling events per GiB sent by the service qdisc | 13,084 | 12,394 |
| Median receiver bulk throughput, MiB/s | 4,186 | 4,615 |
| Median fresh p95 / p99 per run, ms | 54.2 / 88.9 | 54.6 / 84.7 |
| Runs with clean delivery and fresh p95 ≤75 ms | 4/6 | 3/6 |
| Fresh offers / recorded fresh errors / bulk reopens / service qdisc drops | 1,440 / 0 / 0 / 0 | 1,440 / 0 / 0 / 0 |

All twelve first attempts had complete results. All 32 positive stream counts sum to each recorded receiver byte total and reproduce the reported MiB/s. Service deferrals per GiB fell in **6/6 pairs**, with a median paired change of **−8.28%** (95% paired bootstrap interval −10.72% to −4.29%). Receiver throughput improved in **2/6 pairs**, with median paired change **−4.30%** (−19.43% to +37.00%). Six blocks give wide throughput uncertainty. Only 2/6 pairs passed both arms' latency guardrail. Two candidate arms lost a passing p95 and one gained it. Qdisc counters span the invocation, and the dataset has no per-arm pre-run NIC drop counter, wire-loss measurement, CPU/GiB or runnable time. A deferral counts a scheduling decision. The counter supplies no waiting duration.

**Verdict.** Retain 10 µs. The kernel deferred paced service flows less often per GiB in every pair, yet this did not reliably improve receiver throughput or fresh latency. Before considering another timer change, measure service-queue work and receiver byte progress over a common interval on the revised stock four-vCPU path.

Raw-verified local report `service-timer.receipt.md`. The original archive `gamma-mixed-path.json.gz` has SHA-256 `09ebe5510401244cd6d299c1d0cf6dd8f88b256bf14b8c2c14f6db3eff61b74a`. Derived `service-timer.json` retains all twelve first-attempt summaries and the before/after service counters, SHA-256 `79f96f2466dd3e8682da24b70c33b709e77341cec42bd40a97c7174200aae198`. From `batch08-service-timer`, run `python3 -B replay.py` and compare stdout with the derived JSON. The fixture uses the existing fq replay's block bootstrap. No new VM or peer run was performed.
