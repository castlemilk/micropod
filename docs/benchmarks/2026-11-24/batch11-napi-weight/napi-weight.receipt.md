# 231.03 · Does increasing NAPI weight reclaim more completed guest TX buffers?

24 November 2026 · Source/fixture · Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd` · Linux 7.3.5. [Existing kernel networking direction](https://github.com/castlemilk/micropod/issues/231#issuecomment-7091851125).

Raise the virtio-net NAPI weight from **64 to 128**. Keep TX NAPI enabled, one paired RX/TX queue, lock immediately available, and the same initial mock queues on both arms. At the start of a normal RX poll, 96 transmit buffers of 16,384 B each have already completed, and 96 receive buffers of 128 B are ready. There are no new arrivals, XDP/XSK users or callback races. Compile the original Linux TX reclamation, TX completion accounting and budgeted receive functions. The fixture supplies queue entries and records the poll order from the original driver. Linux passes the configured positive NAPI weight to the callback; the driver exposes the module parameter read-only after load.

| Quantity | Weight 64 | Weight 128 |
| --- | ---: | ---: |
| TX buffers reclaimed before the first RX buffer | 96 | 96 |
| TX bytes reported complete during the first poll | 1,572,864 | 1,572,864 |
| RX packets processed during the first poll | 64 | 96 |
| RX packets still ready after that poll | 32 | 0 |
| Poll invocations needed to consume these ready RX buffers | 2 | 1 |

**Verdict.** A higher positive weight let the driver consume more RX buffers per poll. Both weights had already reclaimed every available TX completion before receiving the first packet. Keep the stock weight for a proposed TX reclamation improvement. A later receive-side test needs evidence of RX budget exhaustion on the serving queue and fresh-latency, dropped-packet and CPU measurements. The reported TX bytes represent completed SKBs at the driver, with no client receiver.

Each arm had one deterministic first evaluation; the 96 entries per direction are fixture inputs. A second build reproduced the raw bytes. Independent checks verified the two poll sequences, first-RX boundary, and byte totals. No sampling interval applies. No packets crossed a VM. Delivered MiB/s, drops, fresh p95/p99, CPU/GiB and runnable time are unmeasured.

**Reproduction.** From this directory run `python3 -B reproduce.py LINUX_7_3_5_TREE/drivers/net/virtio_net.c LINUX_7_3_5_TREE/net/core/dev.c`. The original source hashes are `d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace` and `8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274`. The saved first attempts are in `observations.json`, SHA-256 `dd0e1b2cf44d6052a7400b01b8c45e5fac5069fc29bc429c9d5e2eb72afe4fe9`. Fixture `fixture.c.in` SHA-256 `344bcb1d7162aa100f0ef660b65e13bae3a476ae275934381c78262d88795bca`; replay `reproduce.py` SHA-256 `1a227be9399b055e00c92ec185667b5a93697bb6381eeb3dde4fa21187448f8e`.
