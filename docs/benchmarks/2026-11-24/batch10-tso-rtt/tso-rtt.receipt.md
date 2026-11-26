## 24 November 2026 · 231.01 · Short-RTT TCP segmentation on the guest sender

Changing Linux `tcp_tso_rtt_log` from its stock value of 9 to 0 left the sender's target at **44 segments per packet in all 320 workload-derived cases**. Slower synthetic senders did respond. At a 128 µs minimum RTT and 8 MiB/s, the target fell from 44 to 5. Keep the stock setting for the next baseline. A live trial would be warranted if sampling finds sustained slow pacing on active bulk sockets and the service's observed segment counts indicate room for a change.

**Source/fixture evidence.** The fixture compiled the original Linux 7.3.5 `tcp_tso_autosize` and `tcp_tso_segs` functions and exercised the sender path that uses the default minimum of two segments. The sole difference within each pair was the network namespace’s RTT scaling setting. Both arms used an MSS of 1,448 B, a socket GSO size limit of 64,512 B, a 64-segment maximum and pacing shift 10. These inputs are explicit fixture assumptions. The functions return the desired segment count before other send-path constraints. With these inputs, a socket pacing at 63 MiB/s already fills the byte allowance in either arm, at any RTT.

The ten full-preemption Reno blocks of `gamma-direct-macvlan.json.gz` on 21 November supplied 32 client byte counts and the measured duration per block. Each block was a six-second test with 32 bulk streams and 240 fresh arrivals. Every first attempt in this historical control completed without client error or reopening. Dividing the per-stream delivered bytes by the window produced 320 rate inputs spanning 109.0–244.8 MiB/s. The fixture substituted each rate for socket pacing and held minimum RTT at 128 µs. Instantaneous sender pacing, per-socket minimum RTT and effective socket GSO limits were unavailable. These 320 inputs reuse ten historical blocks. They are not independent timing observations.

The 24 sensitivity pairs used 8, 32, 64 and 128 MiB/s at 8, 128, 511, 512, 1,024 and 4,096 µs. Ten pairs changed the desired segment count. All 12 at 64 and 128 MiB/s were identical. Each of the 344 pairs ran both settings in deterministic counterbalanced order. The comparisons are deterministic, so there is no sampling interval. The candidate did not send network traffic. Delivered MiB/s, fresh p95/p99, drops, CPU/GiB and runnable time are unmeasured for this change.

**Provenance and replay.** Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Linux 7.3.5 tar SHA-256 `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. TCP source `net/ipv4/tcp_output.c` SHA-256 `b55846bf35be5799cc19318c9215aa1b8a9a4881f8e3794cf5dc08b8aa4ea5b7`. Archive commit `7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9`, recording base `816121afd30fba52bda7828418cd963d4216166b`, archive SHA-256 `cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976`. The reproducer validates those source-file and archive identities, the per-stream sums and every output against an independent calculation. Private raw first outputs remain local in [tso-rtt-first.json](tso-rtt-first.json), SHA-256 `aeb4d933998b78bc2e04f8587963debf310e0d963ab9944edf9cc1186e35432d`. A second invocation using Apple Clang 21.0.0 produced identical bytes.

From this directory, using the unpacked Linux 7.3.5 source tree and a new output path:

```sh
python3 -B reproduce.py /path/to/linux-7.3.5 /tmp/tso-rtt-replay.json
cmp tso-rtt-first.json /tmp/tso-rtt-replay.json
```
