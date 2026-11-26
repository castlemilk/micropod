**24 November 2026 · 231.03 · Changing virtio TX completion polling on a serving interface**

Source/fixture at Micropod `7d9b565173a901cb18942e00384838da96e0ba98`. Compiled the original Linux 7.3.5 virtio-net per-queue setter, getter and guards. Driver SHA-256 `d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace`. Modeled one TX queue without VQ_NOTF_COAL, RX frames fixed at one, coalescing times zero. At each initial state changed only the requested TX frame setting, from its current value to the opposite value.

With the interface marked up, 2/2 unchanged controls succeeded. The two actual polling changes both returned EBUSY and retained the original weights. With the interface marked down in the local positive controls, both changes succeeded and the getter confirmed both new values. Eight deterministic calls in total. This fixture moved zero packets. Throughput, fresh p95/p99, drops, CPU/GiB and runnable time require VM traffic.

A live ethtool flip on this modeled serving queue cannot supply the candidate arm. Use separately provisioned scopes with effective per-queue readback after link-up if TX NAPI is selected later. Raw-verified local report `napi-tx.md`, raw `napi-tx.json` SHA-256 `8f58c6be13bf861e088f183517baf017e1f394a5462f739671853c49da76678d`. Reproduce with `python3 -B napi_tx.py` in `batch05-kernel-path`.
