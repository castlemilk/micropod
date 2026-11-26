## 24 November 2026 · 233.04 · Can the publication RX queue accept an io_uring memory provider?

**Verdict.** Keep device-bound io_uring zero-copy receive out of the stock virtio-net throughput trial. Linux 7.3.5’s virtio-net driver supplies no queue-management operations. With a DMA-capable parent, the stock lower still fails both the physical queue leasing check for a netkit peer and the inner direct memory-provider admission check. The earlier 233.04 fragment-copy experiment starts after provider binding.

**Source/fixture evidence.** Compiled five unmodified functions from Linux 7.3.5 covering DMA-device selection, netkit queue creation eligibility, physical lower queue leasing eligibility, inner provider admission and driver queue reconfiguration. The sole change within each pair was the physical lower’s queue-management operations pointer, from the stock null value to a fixture table supplying allocate/free/start/stop callbacks. The same peer advertised queue creation. Both present lower arms used queue 0, no existing provider, no XDP attachment, default buffer size, enabled TCP data splitting and a zero split threshold. The last two are favorable fixture conditions. No running worker readback is implied.

| Parent DMA mask | Stock lower | Same lower with callback table |
| --- | --- | --- |
| Present | DMA device found. Netkit lower lease eligibility failed. The direct provider check returned Linux −95 (EOPNOTSUPP). Zero driver allocation calls. | Lower lease eligibility passed. The direct provider check dispatched one allocation call with the provider visible. The callback deliberately returned Linux −11 (EAGAIN). |
| Absent | No suitable DMA device. Zero driver allocation calls. Lower lease eligibility failed. | No suitable DMA device. Zero driver allocation calls. Lower lease eligibility passed. |

Two deterministic first-attempt pairs, four cases. All ended with no provider installed. The second pair verifies that passing the lease eligibility check alone cannot establish DMA or registration. Linux’s netlink queue-create handler maps a failed lower lease eligibility check to EINVAL. For an unleased physical RX queue, DMA lookup falls back to the parent when the driver supplies no DMA getter. The fixture exercised the lower’s provider-check helper directly after DMA selection. Earlier outer checks or actual hardware may reject sooner. The sentinel avoids claiming successful binding or data transfer. Targeting a verified eligible lower, observing provider setup success, and confirming payload on the bound queue are the next checks.

**Throughput and guardrails.** This admission test sends zero packets. Delivered MiB/s, drops, fresh p95/p99, CPU/GiB and runnable time are unmeasured. There is no statistical interval for deterministic branch outputs.

**Provenance.** Analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`, Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. Archived full kernel config SHA-256 `a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c` enables VIRTIO_NET, NETKIT and IO_URING_ZCRX and disables XDP_SOCKETS. The reproducer checks the virtio-net allocation, parent and missing operations assignment, netkit’s operations table and the io_uring registration call order. Raw-verified [zcrx-bind-first.json](zcrx-bind-first.json), SHA-256 `d2d4e9cd707b29a49422f248821b4a2729c6c3e95ac81691404cd99f9757edb5`, includes exact source, fixture and compiler identities. An independent invocation reproduced its bytes. The earlier construction fixture used a sentinel at reconfiguration entry. Its inputs and first outputs are preserved in `initial-dispatch-fixture.zip`; it adds no experiment to the count.

Reproduce from this directory with the unpacked Linux 7.3.5 source and a new output path.

```sh
python3 -B reproduce.py /path/to/linux-7.3.5 /tmp/zcrx-bind-replay.json
cmp zcrx-bind-first.json /tmp/zcrx-bind-replay.json
```
