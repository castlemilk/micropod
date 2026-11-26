**24 November 2026 · 231.01 · Receive offload on the service bridge veth**

Archived VM measurements, raw-verified offline. Changed only generic receive offload on the worker-side veth, off to on. Same four-vCPU Linux 6.18.35 worker, bridge, service and relay. Original study parent `47a01af326b712ed25482b86fa1de569f020d73a`, archive revision `4f887ba5d28f47fa37d4bd0a2d89cd0914d74754`. All twelve first attempts had effective ethtool readbacks. Six alternating pairs each opened 32 simultaneous connections and received 8 MiB per connection.

Throughput medians were 2,983 and 3,278 MiB/s. The median paired change was +13.84%, with a descriptive 95% whole-pair bootstrap interval of −10.25% to +34.58% and 4/6 wins. All 192 downloads per arm completed with zero reconnects. Median per-burst completion p95/p99 went from 85.75/85.96 to 76.80/78.19 ms. Those tails describe downloads. Independent fresh GET latency, packet drops, per-process CPU/GiB and runnable time were unmeasured.

Inconclusive. Keep stock. Consider a mixed-traffic repeat only if the revised same-kernel comparison retains the bridge. Raw source `gamma-vnic.json.gz`, 48 underlying records. Offline report `veth-gro.md` and replay `veth_gro.py`, output `veth-gro.json` SHA-256 `d9a83a32c7b4e045762fae2aa858fb0f3b94041922e992109880ca733a7cb044`.
