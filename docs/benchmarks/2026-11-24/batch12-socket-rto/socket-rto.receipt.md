### 24 November 2026 · 231.08 · Set an 8 ms minimum retransmission timeout on the service socket

**Skip this socket-only tuning on the published route.** Linux accepted the 8 ms option on the modeled Reno service socket. Reading the socket option returned 8 ms. Micropod locks the gateway route's minimum at 20 ms, so the TCP recovery code still used 20 ms. Lowering the socket value did not advance either modeled tail-loss probe.

| Fixed route context | Outstanding segments | Socket readback, control → candidate | Effective floor | Next probe |
| --- | ---: | ---: | ---: | ---: |
| Published gateway, 20 ms locked | 1 | 200 → 8 ms | 20 → 20 ms | 24 → 24 ms |
| Published gateway, 20 ms locked | 2 | 200 → 8 ms | 20 → 20 ms | 4 → 4 ms |
| Positive control, lock clear | 1 | 200 → 8 ms | 200 → 8 ms | 204 → 12 ms |
| Positive control, lock clear | 2 | 200 → 8 ms | 200 → 8 ms | 4 → 4 ms |

**Source/fixture.** Each pair changed only the per-socket `TCP_RTO_MIN_US` setting. The control inherited the Linux 7.3.5 namespace default. The candidate called the socket-option setter with 8,000 µs, two ticks at 250 Hz. The fixture compiled the pinned namespace/socket initialization, option setter/getter, route floor resolution and loss-probe scheduler. It supplied an established SACK-capable connection in open congestion state, 1 ms smoothed RTT, `tcp_early_retrans=3` and a pending retransmission timer 400 ms away. The timer sink records the interval the kernel requests. It models neither packet loss nor wall-clock execution. For two outstanding segments the scheduler adds a fixed 2 ms to twice the RTT.

Four deterministic pairs, eight first outcomes, all retained. No sampling interval applies. Micropod source and an archived accepted-Reno service confirm the locked 20 ms gateway route. The running guest's socket default was unmeasured. The stock default shown in the table comes from the pinned source. The previously scored route-metric trial changed a different control. Next check the actual per-socket destination route and the trace of the effective TCP timer before considering a recovery change. Delivered MiB/s, fresh p95/p99, packet drops, CPU/GiB and runnable time are unmeasured.

**Local reproducibility.** Micropod `2e9b37c1e68334c443d71b729f0bd6334d824ddd`, including the direct-publication route in `guest/runner/docker_port_direct_linux.go`. The route proof is in `gamma-vm-scheduling.json.gz` under `scopes/lab-0/controller_proofs/reno/route`. The release kernel config in `gamma-direct-macvlan.json.gz` records 250 Hz. Linux stable tag `v7.3.5`, release source archive SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. The original source slices in `timers.inc` have SHA-256 `48203cdb3f765ef4712939735249fb48005f1f4f8d39ab49611b2cc084962abd`. `extract.py` pins the complete four upstream files and recreates the slices. The four source files are `include/net/tcp.h` and `net/ipv4/{tcp.c,tcp_ipv4.c,tcp_output.c}`. Raw local observations in `socket-rto-first.json` have SHA-256 `b1458ccf62d095163ee96766e6c034003fbe9213be4bf422edda3f532e4a003b`. A second compilation and run reproduced them byte-for-byte.

```sh
python3 -B reproduce.py /tmp/socket-rto-replay.json
cmp socket-rto-first.json /tmp/socket-rto-replay.json
```
