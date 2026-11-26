### 24 November 2026 · 231.07 · CUBIC and the slowest eight downloads under stock polling

**Keep Reno as the throughput control.** CUBIC delivered 5,793.7 MiB/s versus 5,111.5 MiB/s with Reno by arm median. It won five of eight paired blocks, below the original two-thirds requirement. The median paired gain was 10.25%, with a descriptive 95% interval from −50.79% to +22.92%. CUBIC improved the mean rate of the eight slowest downloads in five blocks. Their share of the total fell in all eight. Blocks 5 and 8 lost 65.6% and 59.8% respectively on that group.

| Receiver measure | Reno | CUBIC |
| --- | ---: | ---: |
| Median mean rate of the eight slowest downloads, MiB/s per stream | 157.0 | 174.4 |
| Median share delivered to those eight downloads | 24.58% | 24.08% |
| Fresh p95 / p99, median of round percentiles, ms | 45.29 / 86.56 | 33.64 / 55.72 |
| Complete attempts passing the 75 ms fresh-p95 limit | 6/8 | 8/8 |
| Completed fresh requests / offered | 1,920/1,920 | 1,920/1,920 |
| Application errors / bulk reopens | 0 / 0 | 0 / 0 |
| VM process / relay CPU seconds per delivered GiB, arm medians | 0.419 / 0.269 | 0.421 / 0.273 |
| VM process / relay runnable thread-seconds per sample second, arm medians | 3.549 / 1.866 | 3.511 / 1.891 |

**Batch accounting.** The original VM scheduling report already scored the 0 µs Reno/CUBIC comparison. This replay adds the slowest-quarter delivery analysis and counts as zero new experiments.

**Archived VM.** This analysis measures the distribution of receiver bytes when only the service TCP algorithm changed on the stock-polling boot. One four-vCPU Linux 7.3.5 CUBIC-capable VM had zero deferred polls and zero GRO flush timeout. Matched services had distinct source addresses, the same image and CPU, memory and PID limits. Accepted socket and gateway route readbacks identified each algorithm. Both arms retained 32 original streams, 240 scheduled fresh requests at 25 ms intervals and a six-second window. The eight-block Williams design placed each arm first relative to its paired arm four times. NIC packet drops and retransmissions were unavailable for these intervals. The archived CPU/process samples include setup and drain.

Each block ranked its own stream byte counts and selected the eight lowest. Different ranks may identify different sockets across services. The median paired change in the mean rate of these eight was +7.37% (95% paired-block bootstrap −59.82% to +22.31%). Their median within-pair share difference was −0.61 percentage points. The 16 first attempts all passed the original delivery rule. Each set of 32 stream counts sums exactly to the reported bytes. No arm, failed attempt or block was replaced. The archived 20 µs/two-deferred-poll CUBIC comparison belongs to a separate condition. For another controller trial, retain the revised four-vCPU two-worker baseline, verify the accepted sockets and record same-window retransmits and NIC drops alongside per-stream bytes.

**Exact inputs.** Micropod fixture base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. Recorded source `7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9`. Kernel Image SHA-256 `5a3cb6b86c7bdf12edf034a6fcacf54e02fca88d21d0eff42b1870413a757735`. Service image config `80996a25c9c753fcaf3f421a3f61557497b8ab539bdd68076074d181cfa71889`. Client binary `a1e2609f9d052b2765dc717fac1b227a8247aa9e73364bf3962168c30c8ffc53`. Source archive `gamma-vm-scheduling.json.gz`, SHA-256 `29f33979ca570117e54addabfe07aecb452ab23af7f0b9e039c996dbb9611e51`. Raw-verified `stock-cubic-first.json`, SHA-256 `ed98c79f13367063504e8bb689bce6b1069f86b3aff15809bf38f46a580eb47b`, includes the original client rows, all 512 stream byte counts, verified routes and per-process measures. The seed is 20261124 for 10,000 matched-block resamples. An independent invocation reproduced the evidence byte-for-byte.

```sh
python3 -B reproduce.py /tmp/stock-cubic-replay.json
cmp stock-cubic-first.json /tmp/stock-cubic-replay.json
```
