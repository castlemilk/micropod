# Changing virtio-net TX completion polling on a serving link

24 November 2026 · 231.03 · Source/fixture. The stock Linux 7.3.5 driver's per-queue ethtool setter returned EBUSY for both directions of a TX polling change with the interface up. Each unchanged request succeeded. A separate down-interface fixture accepted both changes and the driver getter returned the new value. The stock control and candidate therefore cannot share an already-serving link through a live ethtool toggle. Keep this tuning behind separately provisioned scopes with queue-level readbacks after the link comes up.

| Interface flag | Initial TX weight | Control: same request | Candidate: flip polling | Final candidate weight |
|---|---:|---|---|---:|
| Up | 64 | success | EBUSY | 64 |
| Up | 0 | success | EBUSY | 0 |
| Down | 64 | success | success | 0 |
| Down | 0 | success | success | 64 |

Each cell ran once against the original setter, getter and validation helpers. The fixture models a single virtio TX queue without negotiated per-queue notification coalescing. It fixes the RX frame setting at 1 and all usec settings at zero. For each initial state the only change is the requested TX frame setting, 0 or 1. Setting the interface flag in a fresh userspace struct exercises the driver branch without touching a live interface. The fixture did not move packets. Throughput, drops, fresh p95/p99 and process costs require a later VM workload.

The local stock kernel is 7.3.5-micropod, with CONFIG_VIRTIO_NET=y and image SHA-256 7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd. Original source tar SHA-256 8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990. Linux driver SHA-256 d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace. The build used four functions verified byte-for-byte against that driver. The capture, C harness and exact contents of the functions accompany this report. Run `python3 napi_tx.py` and, to repeat extraction verification, pass `--source /path/to/linux-7.3.5/drivers/net/virtio_net.c`.
