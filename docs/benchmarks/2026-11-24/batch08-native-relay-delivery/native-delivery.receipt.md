**24 November 2026 · 230.07 · Can relay backpressure counters distinguish a stalled consumer?**

**Local/host-only.** Darwin 25.5.0 arm64, Apple clang 21.0.0. Compiled the unchanged production `PublishedTCP.c` and its public header from Micropod `7bec8a7246f30e1a275f5d2c8568c53566d91490`. Source SHA-256 `f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee`. The client connected to the private IPv4 listener returned by `mp_tcp_listen`. The profiled serial kqueue owner forwarded to a second, separately bound loopback TCP service. A verified one-byte request triggered a deterministic 16 KiB response. The service held its write half open.

At the same observed boundary in every arm, the client's kernel receive queue held all 16,384 bytes and the application had made zero reads. The only change was whether the client consumed and checked the response before closing. The control read and compared every byte. The paused client made zero receive calls. Both set and read back abortive close, closed the socket and observed guest-side EOF before collecting the public relay statistics. Four randomized counterbalanced pairs, eight first attempts, zero retries. Seed 2300724 placed the consuming arm first twice and the paused arm first twice.

| Per connection | Consuming control | Paused client |
| --- | ---: | ---: |
| Relay download bytes | 16,384 | 16,384 |
| Application bytes read | 16,384 | 0 |
| Unread client socket bytes at close | 0 | 16,384 |
| Blocked writes / pending allocations / copied bytes | 0 / 0 / 0 | 0 / 0 / 0 |
| Stream errors / forwarded resets | 1 / 0 | 1 / 0 |

Every pair had the same 16,384-byte difference in application reads and zero difference in the listed relay counters. All 65,536 consumed bytes matched the offered payload across the controls. Equally many bytes reached the paused clients' kernel queues and were discarded unread on intentional close. The fixture measures byte accounting on this teardown and supplies no estimate of natural drop rate, delivered throughput, fresh p95/p99, CPU/GiB or runnable time.

**Verdict.** Zero pending-copy bytes can coexist with a fully unread client response. The relay counters measure writes accepted by its destination socket and retained relay buffers. For the next VM diagnostic, pair these per-lease counters with verified response completions, client bytes and errors from the same window before deciding whether to optimize relay allocation.

Raw-verified local report `native-delivery.receipt.md` and raw `native-delivery.json`, SHA-256 `cba650a94ea26f7fa1cc1215221f694502e1092eccc3bd548691b7ec4ceb3f1d`. Raw data preserve every first-attempt stdout, stderr, status, queue observation and build identity. From the report directory use `python3 -B run_delivery.py /tmp/native-delivery-new.json` with a new output filename.
