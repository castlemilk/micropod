# TCP MTU probing on an oversized established flow

24 November 2026 · #229.02 · Jumbo path and shared-network MSS clamp · source/fixture, raw verified locally.

**Keep the stock probing policy for throughput qualification.** Changing Linux `tcp_mtu_probing` from 0 to 1 recovered the payload in a deliberately broken DF path model at the first sampled eligible retransmission timeout. At 2,996 ms both arms still selected an 8,948-byte send MSS. Reactive probing can help an established connection survive a hidden lower MTU. Relying on a multi-second timeout cannot qualify a low-latency jumbo path.

| Elapsed from first retransmission | Control 0, send MSS and modeled bytes delivered | Candidate 1, send MSS and modeled bytes delivered |
| --- | --- | --- |
| 0 ms | 8,948 B / 0 B | 8,948 B / 0 B |
| 2,996 ms | 8,948 B / 0 B | 8,948 B / 0 B |
| 3,000 ms | 8,948 B / 0 B | 1,024 B / 17,896 B |

Only the probing sysctl changes between arms. Both use an established IPv4 socket, 8,960-byte peer MSS offer, 20-byte IP and 32-byte TCP headers, 9,000-byte cached PMTU, and a 1,500-byte modeled hop that rejects oversized DF packets and returns no ICMP feedback. The input is two initial jumbo-sized payload segments. The forwarding model retries the same 17,896 bytes independently at each sampled state. At 3,000 ms the control rejected two oversize segments. The candidate admitted all 18 and its reassembled payload matched the sender SHA-256. These are modeled segment dispositions and received bytes.

Micropod base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. The stock Linux 7.3.5 config `a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c` specifies 250 Hz. The fixture compiles the original MSS conversion, MTU initialization and probing functions, the retransmission-timeout check and its established-socket call site. Upstream source blob IDs are in `source.json`. The fixture uses the millisecond TCP timestamp branch, an unchanged route and a large advertised window. It evaluates the timeout handler at chosen timestamps. It does not predict when an actual timer fires. `TCP_RETR1=3` and a 200 ms model base give a 3,000 ms eligibility threshold in this branch, even with a lower per-route RTO minimum.

One deterministic pair, three snapshots per arm, all retained. No sampling interval applies. No timed network runs. Delivered MiB/s, network loss, fresh p95/p99, CPU/GiB and runnable time remain unmeasured. Verify physical frame sizes, peer MSS and complete delivery on the released hop; consider reactive probing as a recovery experiment only if a real oversized-flow stall and missing PMTU feedback are observed.

Reproduce with `python3 -B reproduce.py` in this directory. Raw `first.json`, SHA-256 `1356b75608dea481a6329e46c844f3ff5c82ce05a7b5651d54f7cdfc290dafd9`. Private report and observations retained locally.
