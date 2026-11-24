# 231.14 · Reusing a DNS-over-TCP request buffer

24 November 2026 · Source/fixture · Keep the current reader until guest traces establish how many queries actually share a TCP connection. A reusable 512-byte buffer cut allocations for 32-request streams. Reserving it for every connection added 480 allocated bytes to a single ordinary query.

Both arms read the same synthetic A and AAAA service queries from an in-memory byte stream. The control used the actual request reader at `7d9b565173a901cb18942e00384838da96e0ba98`. The one change gave the synchronous service loop one 512-byte buffer per connection. Larger frames still allocate their own payload. The fixture checked every byte before issuing the next read. Go 1.27.2 on Darwin/arm64 used one Go CPU. The test counted heap allocations and allocated bytes across fixed numbers of streams, including identical reader setup in both arms.

| Workload per stream | Streams per arm per pair | Allocations/stream, control → candidate | Allocated bytes/stream, control → candidate |
| --- | ---: | ---: | ---: |
| One 25-byte query | 128 | 4 → 4 | 98 → 578 |
| 32 × 25-byte queries | 64 | 66 → 35 | 1,152 → 640 |
| 32 requests cycling 25, 96, 512 and 25 bytes, reads limited to 3 bytes | 64 | 66 → 35 | 5,504 → 640 |
| 32 requests cycling 25, 513, 96 and 4,096 bytes | 32 | 66 → 51 | 38,528 → 38,016 |
| Two 65,535-byte EDNS queries | 8 | 6 → 7 | 131,140 → 131,652 |

All six order-balanced pairs per workload returned the same allocation totals. Each arm delivered all 31,584 queries across 1,776 streams. Six separate incomplete or invalid frames returned matching errors. Raw first measurements include every block and arm. The deterministic workload counts describe this build. Guest request frequencies and allocation distributions across hosts are unknown. No wall-clock samples, throughput, network loss, fresh p95/p99, CPU/GiB or runnable time were collected. The benchmark's bulk HTTP traffic uses a different path.

Before considering a guest trial, measure offered queries per TCP connection and the fraction over 512 bytes on the actual resolver workload. Then check guest socket delivery and fresh p95/p99 with one and 32 resolvers against stock.

## Reproduction and provenance

From this directory run `GO=/path/to/go1.27.2/bin/go python3 reproduce.py > /tmp/dns-tcp-request-buffer.json`. The driver checks the patch against the pinned original and builds both reader bodies into one binary. Its only dependencies are the Go standard library and the local Git object. An initial mixed Go 1.27.0/1.27.2 build stopped before the fixture ran. All measurements used Go 1.27.2.

| Artifact | SHA-256 |
| --- | --- |
| Original guest source | `8c35dfcae6324973ae6d47ba2da45cd26b50e60630a78a6971d058caef9a9c62` |
| Candidate guest source | `62d559fef3cdc07507e9e6d05306fd510bde7584ce3be81a55cc2115e403cbdb` |
| [Candidate patch](bounded-reader.patch) | `96748ee6ff1712178541c45a50bd48ae3761fa4c0fc72f15b8cbff972d9b4142` |
| [Fixed-work driver](driver.go) | `eb99d7e0487f7aed06fe03d62bd12ee433bd873a2026fdfb4f9afe71ed5f1cce` |
| [Raw measurements](raw.json) | `ad293c9f15d4e00ef19c9cb65fac722118c06732ccc08b81b1e51e3d2d994d55` |
