**24 November 2026 · 231.14 · Reusing a 512-byte DNS-over-TCP request buffer**

Compared the stock length-prefixed request reader with a 512-byte scratch buffer reused for one connection. Source/fixture evidence on Darwin/arm64, Go 1.27.2. Both readers came from `guest/runner/docker_dns_linux.go` at `7d9b565173a901cb18942e00384838da96e0ba98`. The candidate file’s SHA-256 is `62d559fef3cdc07507e9e6d05306fd510bde7584ce3be81a55cc2115e403cbdb`.

Six order-balanced pairs per workload. Both arms decoded all 31,584 queries byte-for-byte across 1,776 in-memory streams per arm and agreed on all six malformed inputs. For 32 short queries, allocations fell from 66 to 35 per stream and allocated bytes fell from 1,152 to 640. Fragmented EDNS streams fell from 5,504 to 640 bytes. A single short query rose from 98 to 578 bytes, and two maximum-length frames rose from 131,140 to 131,652 bytes. All six repetitions agreed. There was no timed network workload. Packet loss, fresh p95/p99, throughput and CPU/GiB remain unmeasured.

Keep the stock reader until the guest’s distribution of queries per TCP connection and frame sizes warrants the fixed cost. This result measures DNS allocation and gives no estimate of the bulk published-port gap.

Raw-verified local report `dns-tcp-request-buffer.md`. Replay with `python3 -B docs/benchmarks/2026-11-24/batch05-fixture/reproduce.py`. Raw first attempts in `batch05-fixture/raw.json`, SHA-256 `ad293c9f15d4e00ef19c9cb65fac722118c06732ccc08b81b1e51e3d2d994d55`.
