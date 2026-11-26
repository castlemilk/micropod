# Batch ten · 24 November 2026

Ten distinct experiments take the local register from 90 to 100. Two newly analyzed archived VM comparisons contain receiver throughput. Eight kernel source fixtures checked whether candidate settings reach the intended path. This batch added zero fresh VM or peer samples.

| Ticket receipt | Change | Evidence tier | Delivered MiB/s, control → candidate | Verdict |
| --- | --- | --- | ---: | --- |
| [230.03](https://github.com/castlemilk/micropod/issues/230#issuecomment-7123564418) | [50 µs follow-up relay poll](batch10-relay-archive/hot-wait.receipt.md) | Archived VM | 3,263.8 → 3,714.2 (32-stream bursts) | Keep for mixed-load validation. Five wins in six. Sustained single-stream delivery was inconclusive. |
| [232.01](https://github.com/castlemilk/micropod/issues/232#issuecomment-7123407497) | [Bypass connection tracking on a routed endpoint](batch10-kernel-archive/routed-tracking.receipt.md) | Archived VM | 3,027.3 → 3,302.9 (32 streams plus fresh arrivals) | Keep tracking. The earlier arm won all six pairs. The median paired effect was −1.56%, and fresh p99 worsened. |
| [231.01](https://github.com/castlemilk/micropod/issues/231#issuecomment-7123494373) | [Disable short-RTT TSO sizing bonus](batch10-tso-rtt/tso-rtt.receipt.md) | Source/fixture | Unmeasured | All 320 rate-proxy inputs targeted 44 segments in both arms. Ten of 24 synthetic sensitivity cases changed. Sample real socket pacing first. |
| [231.08](https://github.com/castlemilk/micropod/issues/231#issuecomment-7123410921) | [Request 20 µs of fq pacing offload](batch10-fq-horizon/fq-offload-horizon.receipt.md) | Source/fixture | Unmeasured | The stock direct-interface path rejected the request and kept 0 ns. Skip on this device. |
| [231.08](https://github.com/castlemilk/micropod/issues/231#issuecomment-7123497274) | [Disable slow start after idle](batch10-idle-cwnd/idle-cwnd.receipt.md) | Source/fixture | Unmeasured | Four of 12 socket states retained a larger window. An underfilled sender kept 64 segments versus 37. Look for these reductions on stock bulk sockets. |
| [231.04](https://github.com/castlemilk/micropod/issues/231#issuecomment-7123528567) | [Set guest busy-read to 50 µs](batch10-busy-read/busy-read.receipt.md) | Source/fixture | Unmeasured | Children of an existing stock listener stayed at zero. A new listener enabled one loop entry for an empty nonblocking read with a valid NAPI ID. Verify the effective socket setting. |
| [231.01](https://github.com/castlemilk/micropod/issues/231#issuecomment-7123554053) | [Disable NIC TX checksum offload](batch10-tx-checksum/tx-checksum.receipt.md) | Source/fixture | Unmeasured | It also disabled IPv4 and IPv6 TSO. Both packet cases switched to software segmentation. A measured difference would include both costs. |
| [239.03](https://github.com/castlemilk/micropod/issues/239#issuecomment-7123491498) | [Enable mergeable virtio RX buffers](batch10-mergeable-rx/mergeable-rx.receipt.md) | Source/fixture | Unmeasured | 32 posts requested 576 → 32 backing pages. A modeled 63 KiB aggregate needed 1 → 16 chains. Measure refill pressure before selecting this device change. |
| [233.02](https://github.com/castlemilk/micropod/issues/233#issuecomment-7123499917) | [Use ipvlan L3 in place of private macvlan](batch10-ipvlan/ipvlan-return.receipt.md) | Source/fixture | Unmeasured | TCP reply routing moved to the parent namespace. The candidate dropped the injected gateway ARP. Verify parent route and neighbor recovery. |
| [233.04](https://github.com/castlemilk/micropod/issues/233#issuecomment-7123551240) | [Supply the missing RX queue operations for io_uring zero-copy](batch10-zcrx-bind/zcrx-bind.receipt.md) | Source/fixture | Unmeasured | Stock virtio-net rejected the provider. The fixture with the operations table reached the driver callback. A successful bind needs a capable driver. |

## Throughput and guardrails

The 50 µs relay wait increased 32-stream burst throughput by a median paired **8.08%** across six counterbalanced blocks (descriptive 95% whole-block bootstrap interval **+0.42% to +19.21%**). Each arm delivered all 18 bursts for 4.5 GiB. Sustained single-stream delivery was 1,156.2 → 1,309.6 MiB/s, paired +3.19% (−8.77% to +55.98%). The 600 fresh requests per arm ran before the bursts. Unloaded p95/p99 was 1.037/1.222 → 0.824/0.980 ms. Loaded tails, packet drops and CPU cost remain open.

The routed-endpoint test kept all 12 original attempts. The tracking bypass won 3/6 throughput pairs, precisely the three where it ran first. The paired interval was **−13.34% to +16.39%**. Fresh p95/p99 worsened from 101.74/148.03 to 114.87/246.37 ms. No request errors or reopens were reported in either arm. Packet drops were unavailable.

The historical matched-workload reference remains 2,709.8 MiB/s for Micropod and 3,010.4 MiB/s for OrbStack, with 15 jointly clean pairs from 16 attempts. The burst and routing screens used different fixtures. They do not update that comparison.

## Live measurement status

At 17:01 AEDT both Gamma fleet snapshots were stale. The Mac showed 0/6 leases and isolated Linux still showed 1/1. The ARM64 pool still held one slot. The previously identified GitHub job had failed after losing contact with its runner. The pool record does not identify that job as the current holder. The owner handoff locations contained neither a current released serving scope nor a qualified revised stock receipt. Effective disk clearance for the window and fixture preflight are outstanding. [Local admission receipt](guest-tx-observer/admission-1701-aedt.json)

The next live measurement is the revised four-vCPU/two-worker baseline. The next comparison changes only the worker count from two to four at four vCPUs. Keep the 50 µs wait unchanged in those runs. It needs a separate, subsequent mixed-load trial. The other eight candidates have no measured delivery rate in this batch.
