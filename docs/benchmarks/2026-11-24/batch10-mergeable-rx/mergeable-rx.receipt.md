# 239.03 · Mergeable virtio receive buffers at fixed posting depth

24 November 2026 · Source/fixture · Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd` · Linux 7.3.5 `drivers/net/virtio_net.c` SHA-256 `d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace`. Existing [direction 239.03](https://github.com/castlemilk/micropod/issues/239#issuecomment-7091859108) covers packed rings and mergeable RX buffers. The earlier receipt established the negotiated feature bits on the old stock guest.

Change only the negotiated `VIRTIO_NET_F_MRG_RXBUF` bit from clear to set. Both arms model modern virtio with a 12-byte header, guest TSO4, MTU 1500, 4 KiB pages, 17 maximum skb fragments, no XDP, no page-pool DMA premapping, and a receive-length moving average of 4,096 B. That average makes each mergeable allocation exactly one page. The driver sees a 256-entry configured ring and a fixture budget of 32 logical chain posts. The transport mock accepts all 32 posts and records every scatterlist before the next post. It does not simulate packed-ring layout or direct-versus-indirect descriptor exhaustion. The control's 608 scatter-gather elements would exceed 256 entries on a direct-only ring.

| Result | Clear | Set |
| --- | ---: | ---: |
| Chains posted, original driver | 32 | 32 |
| 4 KiB backing pages requested across all chains | 576 | 32 |
| Scatter-gather elements offered across all chains | 608 | 32 |
| Bytes of writable capacity per chain, including header | 73,708 | 4,096 |
| Chains needed for a 1,514 B incoming frame, modeled | 1 | 1 |
| Chains needed for a 64,512 B incoming aggregate, modeled | 1 | 16 |

The driver took the large-buffer path in the control and the mergeable page-pool path in the candidate. Counted page requests include pages that a real allocator could recycle. The two frame examples use the measured posted capacity and one virtio header per frame. No device delivered either example. No packets were offered, so delivered MiB/s, loss, fresh p95/p99, process CPU/GiB and runnable time are unmeasured.

**Verdict.** Enabling mergeable buffers reduced backing demand per outstanding post. A large incoming aggregate then consumed sixteen times as many posts in this model. Keep the live stock baseline ahead of this change. For a future matched-device test, verify both endpoints' negotiated features and count posted and consumed RX chains, receive sizes, refill failures, and drops. The main bulk response travels in the guest TX direction.

**Reproduction.** One deterministic first evaluation per arm, with all 32 post lengths and fragment counts retained. A separate compilation and execution reproduced the raw bytes. Independent arithmetic cross-checked all 64 rows. There is no timing distribution. Run `python3 -B reproduce.py /path/to/linux-7.3.5/drivers/net/virtio_net.c` in this directory. The harness extracted the original guest GSO decision, receive queue refill and SG submission branches. The recorded run used Apple clang 21.0.0.

| Local file | SHA-256 |
| --- | --- |
| observations.json | `0899faf21a98b669ea74aabd8918a90b9535c38d4a8759a2520e2a679a35733a` |
| reproduce.py | `fb91254ffb5b2885f5dd905358b053ad9534c1172668aef15a50dccffdccf459` |
| fixture.c.in | `a0f6dc83ef863fd98f3aad566f3528df7530fa2102291195a8679efb60cc73b8` |
