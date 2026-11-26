### 24 November 2026 · 231.01 · Double the guest publication NIC's TX ring depth

**A 512-entry TX ring is ineligible on the recorded device.** The control requested its current 256 entries and succeeded. Changing only TX to 512 returned Linux `-EINVAL` before any resize or reset. RX and TX remained at 256 in both arms. The four successful stock and restored-stock `eth1` readbacks each reported a 256-entry maximum in both directions. They came from the same Linux 7.3.5 virtual machine.

**Source/fixture.** The comparison compiled the original Linux 7.3.5 virtio-net ring getter and setter, supplied each archived device's current and maximum entries, and intercepted requests at the first hardware resize. With that same initial ring and an artificial 512-entry maximum, the positive check reached the TX resizer once and the RX resizer zero times. This validates the boundary of the fixture. The positive check does not measure a functioning larger ring.

One deterministic control/candidate pair per archived readback, all eight outcomes retained. All four raw inputs exposed identical limits. No statistical interval applies. No packets were offered. Receiver MiB/s, drops, fresh p95/p99, CPU/GiB and runnable time are unmeasured. A larger host-advertised TX ring on the revised publication NIC would change eligibility. Check its current and maximum sizes on the actual boot before spending a timed arm on a guest request.

**Local reproducibility.** Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`; source study `b30c57f8c97d112fb57dfd5588b6e8da9601e583`, boot `F9796107-C413-486E-88AA-864386E5B923`. Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`, `drivers/net/virtio_net.c` SHA-256 `d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace`. Source readback archive `tx-offload-bql-readbacks.json.gz`, SHA-256 `1ade90ef711545a7ad913c8bd8725cd7fe999dd3da985944f978cd72d0265fc0`. All raw outcomes verified locally in `ring-first.json`, SHA-256 `901575855c738b4d76b21f1a328b65b013e117deda82f617586d04d2f976d667`. A second compilation and run reproduced it byte-for-byte.

```sh
python3 -B reproduce.py /path/to/linux-7.3.5/drivers/net/virtio_net.c /tmp/ring-replay.json
cmp ring-first.json /tmp/ring-replay.json
```
