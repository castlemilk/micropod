## 24 November 2026 · 231.03 · Isolate an RX coalescing timer on one publication queue

**Verdict.** Use the per-queue setter if the revised NIC negotiates `VQ_NOTF_COAL` and the experiment is intended to affect just one queue. Capture both directions on the target and sibling queues after the request, including failures. A global fallback can change sibling TX settings during an RX-only test. A per-queue failure can leave the target RX timer changed.

**Source/fixture.** The control used the global ethtool coalescing setter and the candidate used the per-queue setter for queue 0. Both requested the identical numeric change to a 20 µs RX timer. TX remained as requested before, and maximum RX/TX frames stayed at one. The modeled NIC was up with two configured queue pairs, TX NAPI weight 64, adaptive RX disabled and no XSK pool. The fixture compiled 14 original Linux 7.3.5 virtio-net functions, beginning at the stock setters and ending at the outgoing control command. The device response was prescribed, and the driver’s cached state was observed. Each of four capability/response contexts ran both setters once. Counts and results are deterministic and have no sampling interval.

| Fixed context | Global request | Queue 0 request |
| --- | --- | --- |
| Both features, device acknowledges | TX then RX. Target RX 10→20 µs. Sibling RX 80→20 µs and TX 16→8 µs. | RX then TX. Target RX 10→20 µs. Sibling RX stayed at 80 µs and TX at 16 µs. |
| Both features, device refuses TX | Returned Linux EINVAL after its first command. Target RX stayed at 10 µs. | Returned the same EINVAL after its second command. Target RX was already 20 µs. |
| Global notification feature only | Both RX queues changed 10→20 µs. | EOPNOTSUPP, zero commands. |
| Neither notification feature | EOPNOTSUPP, zero commands. | EOPNOTSUPP, zero commands. |

This addresses hardware notification timer programming, separate from software GRO flush/deferred IRQ timing and TX NAPI weight. The revised device’s feature bits and number of active queues remain to be observed on the actual publication interface. No packets were sent. Delivered throughput, fresh p95/p99, loss, interrupts/GiB, CPU/GiB and runnable time are unmeasured. A supported live trial needs traffic on the intended queue, verified final timers and measured interrupt/delivery counters.

**Reproduction.** Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Driver `drivers/net/virtio_net.c` SHA-256 `d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace`. [Raw first attempts](rx-coalesce-first.json) SHA-256 `b80a34f3b3b4f237d16bc39747e587a6e13a0a2e1407827b5c909adccf69879e`, verified locally. A second invocation reproduced the raw file byte-for-byte. From this directory, using the pinned driver source and a new output path:

```sh
python3 -B reproduce.py /path/to/linux-7.3.5/drivers/net/virtio_net.c /tmp/rx-coalesce-replay.json
cmp rx-coalesce-first.json /tmp/rx-coalesce-replay.json
```
