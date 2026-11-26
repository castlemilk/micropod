### 24 November 2026 · 231.08 · Disable Linux congestion-window reduction after idle

**Source/fixture.** Changed only `tcp_slow_start_after_idle` from the Linux 7.3.5 stock value of 1 to 0. Compiled six unchanged functions from the pinned stock source, including the send-side restart check and post-send validation, and supplied socket state at their boundaries. Twelve deterministic paired cases, six per arm order, with all 24 first invocations retained. Each invocation starts from a new state. The initial congestion window is 10 segments, the established window is 64 segments, and the retransmission timeout (RTO) is 100 fixture clock ticks. The fixture uses Reno-style congestion control for the principal cases. It also covers a controller that provides its own congestion-control hook.

| Returning or sending socket | Stock window, segments | Disabled, segments |
| --- | ---: | ---: |
| New socket | 10 | 10 |
| Returning to a drained established socket at exactly one RTO | 64 | 64 |
| Returning just after one / two / five RTOs | 32 / 16 / 10 | 64 / 64 / 64 |
| Established socket already at its initial window after five RTOs | 10 | 10 |
| Fully utilized window at post-send validation | 64 | 64 |
| Underfilled window carrying eight outstanding segments at one RTO, with send-buffer space | 37 | 64 |
| Same underfilled window just before one RTO, with an exhausted send buffer, or with a dedicated congestion-control hook | 64 in each case | 64 in each case |
| Pre-send check with 32 segments outstanding after a long gap | 64 | 64 |

**Verdict.** Disabling the policy preserved a larger window in four of twelve states. The strongest signal for the continuous-download workload is the underfilled-window case. An established connection can lose congestion-window capacity without ever becoming fully idle. The new connection and fully utilized bulk cases gained no window. The gaps and socket states were supplied. No delivered MiB/s, packet loss, fresh p95/p99, CPU/GiB or runnable time was measured. The deterministic results have no sampling interval.

**Next check.** In an authorized diagnostic on stock Reno, count per-bulk-socket reductions and the window before and after, distinguishing idle restarts from application-limited validation. Keep the stock setting until the actual path shows reductions during the scored interval. Any subsequent comparison needs receiver delivery, drops and fresh tails.

Micropod analysis base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`. The Linux 7.3.5 archive SHA-256 is `8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990`. From this directory, run `python3 -B replay.py /path/to/linux-7.3.5.tar.xz`. Apple clang 21.0.0, separate supplied route, socket and timer state, no live socket. Raw first attempts and exact input, compiler, fixture and replay identities are in `idle-cwnd-first.json`, SHA-256 `f3687ddf4b6ba384e02f8d9ea884b2430202ee186b23a40060836d832fb59766`. All private files remain local.
