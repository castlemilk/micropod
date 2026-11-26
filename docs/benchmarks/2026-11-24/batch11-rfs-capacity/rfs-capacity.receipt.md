### 24 November 2026 · 237.05 · Double the global Linux receive-flow steering table

**Verdict.** Keep the 32,768-entry control for a future RFS trial. Doubling the table preserved the intended socket-flow entry for 125 additional lookups out of 32,768 in this fixture. In 904 of 1,024 paired hash populations, the larger table recovered zero lookups. Before timing a larger table, establish that bulk sockets frequently miss this lookup on the guest under the scored workload.

| Global RFS table | Bulk socket lookups | Socket-flow entry had been overwritten | Fallback selected a CPU different from the last reader |
| --- | ---: | ---: | ---: |
| 32,768 entries | 32,768 | 251 (0.766%) | 190 |
| 65,536 entries | 32,768 | 126 (0.385%) | 97 |

**Source/fixture.** The sole change was the global socket-flow table size. Each deterministic population inserted 32 bulk sockets with fixed last-reader CPUs, then 240 fresh sockets, then looked up all 32 bulk sockets once. No bulk socket refreshed its slot during those 240 inserts. The 1,024 pairs used identical distinct nonzero pseudorandom 32-bit hashes within a pair. The kernel's pinned global table match and four-CPU RPS fallback branches ran in C. The fixture stops immediately after a global hit or fallback. A hit supplies a desired CPU to the later per-device RFS logic. Actual CPU migration, enqueue and backlog draining were outside the fixture. The raw masks identify each affected bulk socket.

The mean reduction in lookup misses was 0.381 percentage points, with an approximate 95% interval of 0.316–0.447 points across these hash populations. Actual boot hashes, connection lifetimes, active background flows and reader CPUs were unmeasured. No packets were sent. Delivered MiB/s, packet drops, fresh p95/p99, CPU/GiB and runnable time are unmeasured.

**Control provenance.** The archived steering driver at `47a01af326b712ed25482b86fa1de569f020d73a` requested 32,768 entries in both the global and per-device tables. All six saved RFS settings readbacks report a four-CPU steering mask and 32,768 per-device slots. The script's readbacks during those six arms omit the global size, so the fixture uses the requested historical value. The 32 bulk and 240 fresh flow counts come from the separate host-published workload at `b30c57f8c97d112fb57dfd5588b6e8da9601e583`. The simulated hashes are fresh fixture inputs.

**Reproduction.** Micropod base `2e9b37c1e68334c443d71b729f0bd6334d824ddd`, Linux 7.3.5 `net/core/dev.c` SHA-256 `8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274`. The checked-in source excerpt has SHA-256 `2fe96717d91d02259049dfced5c1e246cffb8a6023f7634fb3c36e41e60c2e7a`. Raw local report `hashed-first.json`, SHA-256 `bac38de1e8a8737c6cbb8d95776b73504b54d0c75b30a1f830e3170751432a4b`. The independent slot-owner lookup verified all 65,536 arm decisions. A second build and execution reproduced the first results byte-for-byte.

```sh
python3 -B reproduce.py /tmp/rfs-capacity-replay.json
cmp hashed-first.json /tmp/rfs-capacity-replay.json
```
