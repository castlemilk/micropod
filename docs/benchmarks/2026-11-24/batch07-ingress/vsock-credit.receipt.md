**24 November 2026 · 232.04 · How early should a bulk vsock receiver return credit?**

Source/fixture. Compiled the original Linux 7.3.5 virtio-vsock stream dequeue, sender credit reservation, free-space check and header credit accounting. The candidate changed only the receiver's credit-update condition to send an update on every read that fully reclaimed at least one packet. The modeled sender always filled its available credit. The consumer copied and verified one fixed 1 MiB stream in each case, with immediate control-message delivery and no reverse data to carry credit updates.

| Fixed window / packet / read (KiB) | First credit after receiver read, stock → eager (KiB) | Update messages per delivered MiB, stock → eager |
| --- | ---: | ---: |
| 64 / 4 / 4 | 4 → 4 | 256 → 256 |
| 256 / 4 / 4 | 196 → 4 | 6 → 256 |
| 256 / 16 / 4 | 208 → 16 | 5 → 64 |
| 256 / 16 / 64 | 256 → 64 | 4 → 16 |

Four deterministic first-attempt pairs. Both arms delivered and verified all 4 MiB, emptied every queue and returned final credit for every byte. Reading part of a 16 KiB packet did not free its buffer. The fixture exercised compiled code with in-memory queues and a serial sender/receiver. The results give byte and message counts. They provide no timing interval, actual packet loss, fresh p95/p99, CPU/GiB, runnable time or observed explanation of the historical resets.

Keep stock. Before an alternative bulk-vsock trial, capture the actual credit window, packet size, consumer read size, outstanding bytes and interval between credit updates together with receiver progress. Eager updates have little to offer at the smaller tested window and can be expensive in message count at the larger one.

Raw-verified report `vsock-credit.receipt.md`. Raw `vsock-credit.json` SHA-256 `fd8af61dc12e0d2e6e1a5b471d89ae1e1c99e29c57dc8008e1e87e42d451b162`. Micropod checkout `a60d203b16b24abd857e1b5c9e817636b241f850`. Pinned kernel member `net/vmw_vsock/virtio_transport_common.c`, SHA-256 `fc75cae32ca8ed49e55a59523601d2a8ddab1a52bc0aab8b99750a4ab3d77614`. The original and changed compiled function text and harness hashes are in the raw output. Reproduce with `python3 -B reproduce.py vsock PATH_TO_LINUX_7_3_5`.
