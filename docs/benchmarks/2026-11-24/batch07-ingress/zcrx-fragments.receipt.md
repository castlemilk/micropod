**24 November 2026 · 233.04 · Distinguishing copied and provider-backed io_uring receive data**

Source/fixture. Compiled the Linux 7.3.5 io_uring ZCRX receive-SKB, receive-fragment and fallback copy functions. Within each fixed packet layout the sole change was whether its non-linear fragment was an ordinary page or a buffer registered to the same receive queue's provider. The fixture counted bytes at the actual kernel memcpy call, read the kernel fallback copy statistic, and consumed and byte-checked the completion buffers. Four deterministic first-attempt pairs used identical payloads and read ranges.

| Packet layout and read | Actual receive-copy bytes, ordinary → provider | Kernel copy statistic (B), ordinary → provider | Completions in each arm |
| --- | ---: | ---: | ---: |
| All fragment, full 4,096 B | 4,096 → 0 | 4,096 → 0 | 1 |
| 148 B linear plus fragment, full 4,096 B | 4,096 → 148 | 3,948 → 0 | 2 |
| Same split, read 2,000 B starting at byte 84 | 2,000 → 64 | 1,936 → 0 | 2 |
| All linear, full 4,096 B (invariant control) | 4,096 → 4,096 | 0 → 0 | 1 |

Both arms delivered all 14,288 requested bytes into verified completion views. The checks used a modeled page pool, registered buffers, SKB layout and completion queue. Copies are counted only inside the compiled receive operations. The initial fixture setup and independent consumption are outside this count. These fixed cases have no sampling interval. A real netkit/virtio device, DMA, loss, end-to-end throughput, fresh p95/p99, CPU/GiB and runnable time were unmeasured.

The registered-fragment path avoided copies for exactly the fragment bytes. Linear data still copied even when the reported fallback-copy counter was zero. Before attributing a guest throughput change to zero-copy, record SKB linear and fragment bytes, verified provider/queue identity and received payload in the same window. An unchanged completion count or a zero copy statistic alone cannot qualify that attribution.

Raw-verified report `zcrx-fragments.receipt.md`. Raw `zcrx-fragments.json` SHA-256 `feff6e45fb5b3cf45676ed318c9b7b1fa6216cdc31e8f9e03606e0e3b2f0af54`. Micropod checkout `a60d203b16b24abd857e1b5c9e817636b241f850`. Kernel member `io_uring/zcrx.c` SHA-256 `81710ffc59b47cacbcabc7f673d298ab7eff6de7e962b9663c88b8dda4f789c2`. Harness `zcrx_fixture.c` SHA-256 `73d777502e4fb6c1d89eb52ba01c4a5dcc521e60114b1a96156facfbb091a35e`. Reproduce with `python3 -B reproduce.py zcrx PATH_TO_LINUX_7_3_5`.
