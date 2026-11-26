**24 November 2026 · 230.10 · Does doubling the guest-facing relay receive window preserve delivery?**

Archived VM screen, original 21 November first attempts verified offline. The only requested tuning change was the value passed to Darwin SO_RCVBUF before connecting the relay to the guest, 524,288 → 1,048,576 B. Original launch files, sampling records and option-setting code verified. Both arms ran the same relay binary (SHA-256 `d44dfba4b80542aeebcce8c8dd403ce4de02eb4f312b9085bae6b67e7efc055b`) on separate warm four-vCPU Interactive Micropod workers with Linux 7.3.5, Reno, four-CPU service quota and one ARM64 image. Original study source `b30c57f8c97d112fb57dfd5588b6e8da9601e583`. The requests are known; effective per-socket windows were unrecorded.

Five rotating blocks, ten first attempts for these two arms. Each attempt offered 32 continuing 8 MiB downloads and 240 fresh HTTP requests at 25 ms intervals over six seconds. The original four-arm order included two other window sizes. This comparison preserves positions and uses only the 512 KiB control and 1 MiB candidate.

| Observation | 512 KiB | 1 MiB |
| --- | ---: | ---: |
| Delivery-clean attempts | 4/5 | 1/5 |
| Delivery clean and fresh p95 ≤75 ms | 3/5 | 1/5 |
| Failed fresh requests / offers | 240/1,200 | 462/1,200 |
| Bulk stream reopens | 0 | 40 |
| Bulk transfer errors | 0 | 75 |
| Median fresh p95/p99 on each arm's clean attempts, ms | 67.7 / 123.3 | 27.0 / 35.0 |

The 1 MiB arm delivered 4,339 MiB/s in its only clean attempt, block 5. The 512 KiB control failed all 32 bulk setup identities and all 240 fresh requests in that block, scoring zero body bytes. In blocks 1–4 the control delivered cleanly while the candidate failed. **There were zero common clean pairs**, so a paired throughput effect, latency change and interval are unavailable. Dirty-attempt percentiles include zero placeholders for failed identities. Endpoint error counts describe failed application operations. Packet loss was unobserved. Per-process CPU/GiB and runnable time are preserved by attempt where defined; host samples include setup and drain.

**Verdict.** Keep 512 KiB as the control. The 1 MiB candidate failed the delivery gate in four of five attempts. A clean-only peak cannot justify its use to close the OrbStack gap. Check receiver delivery and effective queue occupancy on the revised stock VM before spending another window on a larger receive-buffer request. This older Micropod-only screen does not estimate peer throughput.

Raw-verified report `window-screen.receipt.md`. Source archive `gamma-vcpu-priority.json.gz` SHA-256 `066cd4071f3f926a228d87310f6d7b6f361c38f07c7a8240aa09a57f03f201e4`. Local first-attempt replay `window-screen.json` SHA-256 `fb5837c475950e053460082350ca66723ed70a3815769b9398001cb737a2f4d8`. A second replay reproduced the JSON byte-for-byte. Run `python3 -B window_screen.py` from the report directory. Image digest and all launch, replay, client and source identifiers are recorded locally in the JSON or its companion `window-launch.json`.
