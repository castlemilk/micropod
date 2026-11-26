# Guest service DNS question lookup

23 November 2026. The baseline was commit `a79eac4ef7c0171b2bd199dbbd22d5c403d945d3`. Both implementations parsed the same request and returned a full DNS reply. The candidate checks directory membership for queries other than A and ANY and encodes question-only replies without a compression table. It uses the DNS parser’s skip operation when checking for a second question.

Seven pairs ran on an Apple M5 Max, Darwin arm64, Go 1.27.2 and golang.org/x/net v0.48.0. Each process used one Go CPU, a 65 ms benchmark duration per cell and the same binary. Each pair reversed the previous pair’s baseline/candidate order. The timed code includes DNS parsing, name normalization, the real directory and encoder, and metric increments. It replays an internal network’s UDP IN queries for `alias.svc.` with no EDNS option. The zero-address row is an internal miss. “Alternating” sends one A followed by one AAAA repeatedly. At 256 addresses the UDP A reply sets TC.

| Addresses | Question | Median ns/request, base → candidate | B/request | Allocations/request |
| ---: | --- | ---: | ---: | ---: |
| 0 | A | 256.1 → 117.9 | 304 → 32 | 4 → 1 |
| 0 | AAAA | 249.5 → 120.9 | 304 → 32 | 4 → 1 |
| 0 | alternating | 262 → 126.5 | 304 → 32 | 4 → 1 |
| 1 | A | 316.6 → 313 | 320 → 320 | 5 → 5 |
| 1 | AAAA | 276.6 → 119.9 | 304 → 32 | 4 → 1 |
| 1 | alternating | 318.3 → 200.7 | 312 → 176 | 4 → 3 |
| 8 | A | 609.3 → 525.2 | 624 → 624 | 5 → 5 |
| 8 | AAAA | 349.3 → 125.1 | 496 → 32 | 5 → 1 |
| 8 | alternating | 493.8 → 324.8 | 560 → 328 | 5 → 3 |
| 256 | A | 1810 → 1562 | 6832 → 6832 | 5 → 5 |
| 256 | AAAA | 1669 → 129.2 | 6832 → 32 | 5 → 1 |
| 256 | alternating | 1605 → 828.6 | 6832 → 3432 | 5 → 3 |

Single A used the same allocations in both arms. Its timing overlapped across runs. The improvement was largest for AAAA and missing names. Go reports whole allocations per operation for the alternating cases.

The native replay used the baseline and candidate `dnsReply` bodies with the checked-in directory and encoders, an equivalent counter container, and an empty upstream list. Socket I/O, VM scheduling and application-observed latency are outside the measurement. The replay compared exact response bytes and all four DNS counters on 432 cases spanning 0–512 records, mixed-case question names, A/AAAA/ANY, four EDNS configurations, UDP/TCP, and internal/external networks. Additional tests cover TXT, complete and partial extra questions, root and longest legal QNAMEs, and case preservation.

On a Linux guest-runner development host, the checked-in benchmark exercises the production entry point. For a historical comparison use the same benchmark function in both checkouts.

```sh
cd guest/runner
go test -mod=readonly -p 1 -cpu 1 -run '^$' -bench '^BenchmarkServiceDNSQuestions$' -benchmem -benchtime 65ms
```
