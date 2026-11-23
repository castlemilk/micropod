# Guest NIC flush timeouts at fixed IRQ deferral

In the archived eight-block guest screen, **100 µs lost throughput to 20 µs in seven of eight CUBIC pairs**, with a median paired change of −24.1%. Both settings used two deferred polls. Median paired fresh p95 rose by 10.4 ms even as NIC IRQs per GiB fell by 21.3. The Reno arms produced a smaller and inconclusive difference. [All 48 attempts and six contrasts](guest-gro-timeouts.json) · [Original crossover and rotation](../2026-11-21/gamma-vm-scheduling.json.gz)

| Accepted TCP controller | GRO flush timeout, µs | Clean pairs | Faster pairs | Median paired throughput change | Median paired fresh p95 change |
| --- | --- | ---: | ---: | ---: | ---: |
| Reno | 20 → 50 | 6 | 5 | +10.3% | +0.4 ms |
| Reno | 20 → 100 | 7 | 3 | −6.5% | +5.1 ms |
| Reno | 50 → 100 | 7 | 3 | −2.5% | +2.2 ms |
| CUBIC | 20 → 50 | 8 | 4 | −6.2% | +1.2 ms |
| CUBIC | 20 → 100 | 8 | 1 | −24.1% | +10.4 ms |
| CUBIC | 50 → 100 | 8 | 4 | −5.5% | +20.9 ms |

Each block used 32 ongoing streams and 240 scheduled fresh requests per arm. The replay checks the image, VM description, boot policy, controller on the accepted socket and original clean-round rule. Each timeout used its own warm VM. Two Reno attempts failed. At 20 µs block 5 logged one error. At 50 µs block 3 logged 229 error entries and four bulk reopens. The zero-timeout arm also changed IRQ deferral, so it cannot isolate the timeout. These comparisons come from the same selection screen. The stock published route uses Reno. [Replay script](../../../scripts/relaybench/guest_gro_replay.py)

The publication NIC collector now reads the virtio-net TX NAPI module parameter and both interface-level deferral controls, retaining a separate exit status for each read. Linux 7.3.5 initializes new send queues from the module parameter and allows ethtool settings to change their weights later. Interface defaults can also differ from per-NAPI overrides. An independent test of TX completion needs queue-level evidence on the same boot. The current collector accepts the original capture format as well. [Collector](../../../scripts/relaybench/guest_nic_capture.sh) · [Decoder and units](../../../scripts/relaybench/guest_nic.py)
