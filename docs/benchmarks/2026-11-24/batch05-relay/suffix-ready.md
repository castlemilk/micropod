# Resuming a short blocked reply on an established download

24 November 2026 · 230.04 · Local Darwin arm64 host-only, fixed work.

A small pending write can wait behind large downloads even after its client is ready to receive it. At the middle and end of a 16-download ready set, prioritizing the final 17 writable bytes removed 512 KiB and 1 MiB of queued work, respectively. The treatment operates only inside the current poll. When 32 downloads spanned two polls, at least 1.5 MiB still preceded the resumed write. Its frequency in the target VM workload is unknown.

The control used the stock flat data owner at revision `7d9b565173a901cb18942e00384838da96e0ba98` (C source SHA-256 `f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee`). The candidate changed one service rule. A previously bulk-classified, writable endpoint carrying 1–4,096 pending bytes ran after fresh endpoints and before other bulk endpoints returned by that poll. Candidate C source SHA-256 `c10a244865f9bebfbc232df46de7bb697cc6cfc5f428d2e0f3e222171fe984fa`. Both used the same 24-slot poll, 256 KiB read cap, 128-event callback and 64 KiB of offered bulk per other stream.

Anonymous stream socketpairs exercised Darwin kqueue and the real relay pump. The client-side destination first filled until EAGAIN. A 17-, 4,096- or 4,097-byte guest reply and FIN then produced a real pending relay write. The fixture drained the destination at a fixed point among the ready downloads and also offered a new one-byte reply.

| Downloads | Bulk offers before releasing destination | Pending bytes | Bytes served before suffix, stock → candidate | Bytes served before fresh, both |
| ---: | ---: | ---: | ---: | ---: |
| 16 | 0 | 17 | 1 → 1 | 0 |
| 16 | 8 | 17 | 524,289 → 1 | 0 |
| 16 | 16 | 17 | 1,048,577 → 1 | 0 |
| 16 | 16 | 4,096 | 1,048,577 → 1 | 0 |
| 16 | 16 | 4,097 | 1,048,577 → 1,048,577 | 0 |
| 32 | 32 | 17 | 2,097,153 → 1,572,865 | 1,572,864 |

The first large download waited an extra 17 or 4,096 bytes when the smaller pending write overtook it in the same poll. Each arm ran twice in ABBA order. Each repetition verified 7,348,299 scored bytes across 124 streams. All distinct payloads, six fresh replies, forward FINs, reverse markers, reverse FINs and flow retirements passed in each repetition. Both repetitions produced exactly the same counts. No sampling interval applies to these fixed positions. Throughput, scheduled-arrival p95/p99, CPU/GiB and runnable time remain unmeasured.

Keep the stock worker control. Use a separately admitted VM diagnostic to establish how often a short pending write becomes writable behind bulk before spending a timed comparison on this candidate.

Raw-verified local evidence is in `suffix-ready.json` (SHA-256 `4bf99d2d9efded46dc92395065705464cd743e91dd6c840c3a4d7f2c9aeff747`). Reproduce on an authorized Darwin workspace from this directory with `python3 -B run.py suffix_ready --output /tmp/micropod-suffix-ready-new.json`. Choose an unused result filename. The raw file pins all source digests and compiler flags.
