### 24 November 2026 · 231.08 · Can the direct publication interface offload 20 µs of fq pacing?

**Source/fixture.** On the stock Linux 7.3.5 macvlan path the control request of 0 µs succeeded. Changing only the request to 20 µs returned EINVAL. The effective offload horizon stayed **0 ns**. A positive control advertising 20,000 ns accepted the same request. One deterministic invocation per setting, including the separate positive control. No statistical interval applies.

Micropod revision `2e9b37c1e68334c443d71b729f0bd6334d824ddd` creates the private `mppub0` macvlan and requests fq on its implicit noqueue. The fixture compiled the offload-horizon configuration branch from the pinned kernel. The device allocator zeroes the capability field. In the kernel archive's C, header and Rust sources, its only references were the declaration, a netlink readout and fq's admission check. This concerns the device's ability to accept future-dated packets. The tested variable was independent of fq timer slack and its maximum allowed packet timestamp.

**Verdict.** Skip this setting on this stock path. Revisit with a serving device reporting at least 20,000 ns of pacing offload capability. There were zero network trials. Delivered MiB/s, packet loss, fresh p95/p99, CPU/GiB and runnable time remain unmeasured.

Raw-verified locally. Report `fq-offload-horizon.receipt.md`, raw `batch10-fq-horizon/observations.json` SHA-256 `94d867b9b491c3886150a2a55c19268d436b55e67efe548f7ec9f32b8d27c1c6`. Reproduce with `python3 -B reproduce.py /path/to/linux-7.3.5.tar.xz`. Kernel archive SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`.
