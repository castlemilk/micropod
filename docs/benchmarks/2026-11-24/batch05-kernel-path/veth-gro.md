# Service bridge veth receive offload

24 November 2026 · 231.01 · Offline replay of archived VM first attempts, raw-verified. On the older bridged Linux 6.18.35 service path, enabling generic receive offload on the worker-side veth gave a median paired throughput change of +13.8% (95% paired bootstrap −10.3% to +34.6%, 4/6 faster). Burst throughput medians were 2,983 and 3,278 MiB/s. All 192 streams per arm completed on their original connections. The interval includes a regression.

| Per-burst phase from launch, median across six attempts | GRO off | GRO on |
|---|---:|---:|
| First headers, p95 | 6.54 ms | 6.18 ms |
| Completed 8 MiB downloads, p95 | 85.75 ms | 76.80 ms |
| Completed 8 MiB downloads, p99 | 85.96 ms | 78.19 ms |

The owner alternated the order across six pairs. Each attempt synchronized 32 new connections for a single 256 MiB download burst. The same four-vCPU VM, service, relay, bridge peer and resource limits served both arms. The per-attempt ethtool readback confirms the offload setting and the owner recorded its restoration. The experiment did not sample independent short requests, packet drops, per-process CPU/GiB or runnable time. A p99 across 32 downloads is the slowest download. Hold this as a bridge-specific candidate. Test short GETs alongside bulk on a released bridge fixture only if the same-kernel path comparison retains that bridge.

Original study parent `47a01af326b712ed25482b86fa1de569f020d73a`, archived file revision `4f887ba5d28f47fa37d4bd0a2d89cd0914d74754`. Receipt `gamma-vnic.json.gz`, SHA-256 `2d20e203cc135a4a86828b8b365fc7885b225b9b452c276ad1f761fd97556b8f`. All 48 underlying client, stderr, exit-status and setting records are in its `ablation/gro-*` entries. The driver, guest setter and client binary identities are bound in the replay output. Run `python3 veth_gro.py` from this directory and compare its stdout with `veth-gro.json`.
