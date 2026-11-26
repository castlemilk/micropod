**24 November 2026 · 231.08 · Does a 512 KiB transmit byte limit bind with TX NAPI disabled?**

Source/fixture, Micropod `a60d203b16b24abd857e1b5c9e817636b241f850`, pinned Linux 7.3.5 with BQL enabled. Changed only the modeled virtio TX queue's NAPI weight from 0 to 64. The control and candidate ran the original virtio-net transmit function, ring-full checks, network stack byte-queue check and DQL enqueue/availability functions. Each was offered 32 equal-size SKBs on a 256-entry ring with the same 524,288 B initial byte allowance. The logical device withheld completions throughout the observation, each SKB used one ring descriptor, and every send was a batch boundary. The fixture stopped submission when the actual queue state requested it.

| Bytes per SKB | SKBs submitted before stop or end, weight 0 → 64 | Bytes admitted, weight 0 → 64 |
| ---: | ---: | ---: |
| 1,460 | 32 → 32 | 46,720 → 46,720 |
| 16,384 | 32 → 32 | 524,288 → 524,288 |
| 32,768 | 32 → 17 | 1,048,576 → 557,056 |
| 64,512 | 32 → 9 | 2,064,384 → 580,608 |

At weight 0, the BQL queued-byte counter stayed zero in every case. At weight 64 it matched each admitted byte count. The stack stopped the two large-SKB workloads after the submission that exceeded the limit. The ring-full guard never fired. Four fixed workload pairs, 128 SKBs offered per arm. These are driver admission and backpressure observations. The 38 SKBs left upstream in the candidate are not packet drops. No downstream delivery, time, VM throughput, TCP losses, fresh p95/p99, CPU/GiB or runnable time was measured. The harness does not model asynchronous completions, adaptation of the byte limit or multiple descriptors per SKB.

A numeric BQL limit alone does not establish that this driver charged bytes to it. Preserve the revised stock control. In a separately admitted diagnostic, bind effective TX NAPI mode and queue identity to DQL inflight bytes, queue stops and receiver progress. This source result cannot identify the mode in the earlier historical VM comparisons. Raw-verified local result `tx_bql.json` SHA-256 `a180e04e9331a2a4259e843aa96d57a33267b1ce5c994655dcbef4a5103ec77b`. Reproduce with `python3 -B kernel_queue.py LINUX_7_3_5_TREE tx_bql`. The raw file pins the Linux source tar, member hashes, compiled functions, harness and compiler.
