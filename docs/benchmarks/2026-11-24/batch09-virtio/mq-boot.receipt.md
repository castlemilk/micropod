### 24 November 2026 · 239.02 · Does the Linux boot channel count prove the device accepted four queue pairs?

**Source/fixture.** Hold four online CPUs, four advertised queue pairs, negotiated MQ and a control queue fixed. Disable RSS in both arms. Model an initially single-pair backend. Change only its response to the driver's four-pair startup command, from acceptance to refusal. Compiled the original Linux 7.3.5 queue setter and ethtool getter, with the original queue-count initialization, Linux RX/TX count assignments and unchecked boot call in driver order. The harness supplies the backend and netdev plumbing; it exercises these branches outside a VM.

| Backend response | MQ commands | Mock backend pairs after request | Linux RX / TX / ethtool combined |
|---|---:|---:|---:|
| Accept | 1 | 4 | 4 / 4 / 4 |
| Refuse | 1 | 1 | 4 / 4 / 4 |

One first evaluation per arm, both retained. Deterministic branch result, no sampling interval. A refusal returns an error inside the driver, but the boot caller discards the result after Linux's counts are set. The modeled refusal left guest-visible counts unchanged. This does not establish that an actual device refused or that any four queues carried traffic. No traffic was offered; delivered MiB/s, loss, fresh p95/p99 and process cost are unmeasured.

**Verdict.** A boot-time guest channel count alone can misclassify the multi-queue candidate. For a future authorized comparison, verify device-side active pairs or successful command completion, then check activity across the intended queues during delivery. This check stands separately from the interactive ethtool set-channels path.

**Locally verified.** Report mq-boot.receipt.md, observations.json SHA-256 f0813ab72f6b8c95868d4d9c34f73f38ee88b870522572a358495360392a5f7a. Micropod analysis base 2e9b37c1e68334c443d71b729f0bd6334d824ddd. Linux 7.3.5 drivers/net/virtio_net.c SHA-256 d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace. reproduce.py SHA-256 db44cde6d352307edc4fa2b9b3fa6d195289ec207593f578a48b17a0f7c48886; fixture.c.in SHA-256 58561ad185df9a0189a848993be01336d2ac8bfd5b7e03bae86a588d8a544c73. Reproduce with `python3 -B reproduce.py /path/to/linux-7.3.5/drivers/net/virtio_net.c` in the report directory.
