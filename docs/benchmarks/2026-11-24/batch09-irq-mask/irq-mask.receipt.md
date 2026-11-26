### 24 November 2026 · 237.05 · Can a broader guest NIC IRQ mask distribute work across four CPUs?

All **3,053** publication NIC interrupts in the CPU-0 control and all **4,823** after requesting CPUs 0–3 were delivered on CPU 0. The observed mask change provided no distribution across vCPUs on this boot. This contrasts the width of the requested mask on the same single-queue device. The earlier CPU-3 pin moved the interrupt to a different target CPU.

**Archived VM, raw-verified.** Four first attempts from 21 November, two sequential attempts per arm on one four-vCPU Linux 7.3.5 Reno VM. The sole change was writing 0 versus 0–3 to the publication IRQ affinity list. Both writes succeeded. Snapshots bracketed each client invocation and provided actual per-CPU interrupt deltas. Both settings retained TSO and a 65,536-byte GSO cap. Each attempt used the same published endpoint, 32 bulk streams, 240 fresh connection offers at 25 ms intervals, and a six-second receiver byte window.

| Requested CPUs | Delivered bulk, MiB/s, attempts 1 and 2 | Fresh GET errors out of 480 | Bulk reopens | TX timeouts | Interface RX / TX drops |
|---|---|---:|---:|---:|---:|
| CPU 0 | 268.0, 9.6 | 468 | 26 | 8 | 0 / 0 |
| CPUs 0–3 | 320.1, 3,286.5 | 322 | 19 | 4 | 0 / 10 |

**Zero of two attempts were clean in either arm.** The archived client left failed fresh requests at zero when sorting its latency array. Its p95/p99 cannot qualify latency here. No clean throughput estimate, paired uncertainty or end-to-end cause of loss can be inferred. The RX/TX drop counters cover the guest publication interface over each surrounding interval.

**Verdict.** Keep stock IRQ policy. A broad affinity request did not spread interrupts on this single-queue NIC even in the highest-throughput attempt. In an admitted diagnostic, verify actual per-CPU interrupt deltas and link health before selecting an IRQ pin or attributing throughput to IRQ distribution.

**Evidence.** Local report `irq-mask-delivery.json` SHA-256 `79ff1cd60c65e0b5c8d0bcdc01f481af37508084b13c88734990f031745a9314`. Recording base `b30c57f8c97d112fb57dfd5588b6e8da9601e583`, archive revision `ad0646d6292076b6ddf7647f2dc806d785d8f8fb`, `gamma-vcpu-priority.json.gz` SHA-256 `066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4`. Existing readback supplement `0855463378443a2ab07bd4bc04905d433bddc0aa53baa26ee6b74448667dde48`; additional private control snapshots `first-cpu-readbacks.json.gz` SHA-256 `9871a79f7245bbf356f73af0d3cec9c50db2d0c93e07aa6b8c02d49939edf4f6`. Analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Execute `python3 -B replay.py` from the report directory with replay SHA-256 `ac418f9a2d6c0e9b81227f40e711bdf2080ad1ff014cb5a131273f97ee51e2ad`.
