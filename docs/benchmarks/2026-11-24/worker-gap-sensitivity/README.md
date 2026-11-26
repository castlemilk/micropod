# What would four relay workers need to change?

Four workers still merit a VM trial. The one-port host relay delivered 49.2%, 63.9% and 80.8% more bulk bytes per second in three two-second pairs with the callback budget fixed at 128 events. That screen recorded throughput and fresh latency. It lacks the process CPU measurements needed to estimate how much of its gain could carry through the VM. The VM archive has process CPU counters for the older Micropod runtime and OrbStack. Neither archive measures both worker counts through the VM. [Host and VM experiment designs](../../2026-11-22/gamma-tcp-contrasts.md)

The archived Gamma Micropod supervisor used a median **0.348 CPU-s per scored GiB** and the VMM used **0.605**. Two accounting scenarios show the scale of the change the next pilot would have to explain. The first holds total CPU seconds across the supervisor and VMM fixed and holds VMM CPU cost per GiB fixed. The second holds both processes' respective costs per GiB fixed and asks how much more CPU they would have to receive.

| Historical target | Uniform VM throughput gain needed | Supervisor cost needed at fixed total CPU | Extra mean host cores at fixed cost/GiB |
| --- | ---: | ---: | ---: |
| Match the two clean-arm medians, 2,709.8 → 3,010.4 MiB/s | 11.09% | 0.253 CPU-s/GiB, down 27.23% | 0.271 total, split 0.099 supervisor and 0.171 VMM |
| Bring the median common-clean Micropod/OrbStack ratio from 0.854 to 1.000 | 17.09% | 0.210 CPU-s/GiB, down 39.79% | 0.418 total, split 0.153 supervisor and 0.264 VMM |

The first row uses all 16 clean Micropod observations and the 15 clean OrbStack observations for their respective medians. The second uses the 15 pairs with clean delivery on both sides. OrbStack round 12 had one fresh-request failure. The paired ratio's 95% interval was 0.709–1.259. Matching either point estimate would leave an independent holdout to establish a throughput win. Differences between rounded totals and components reflect separate per-round medians. [Per-round results and inputs](result.json)

## Calculation

For each eligible Micropod arm, scale scored bytes by the specified uniform gain factor *g*, retaining the duration of its six-second scoring window and its actual surrounding process-counter bracket. Let *Dr* and *Dv* be the historical CPU seconds per scored GiB for the supervisor and VMM. At fixed total sampled CPU seconds and VMM cost per GiB, the supervisor budget is *(Dr + Dv) / g − Dv* per GiB. At fixed cost per GiB for both processes, the additional average cores required by each process are *(g − 1) × observed process CPU seconds / bracket duration*. All table entries summarize the individual round calculations. In the first scenario, relay-side savings would have to be usable by the VMM.

The numerator includes all supervisor or VMM work across client setup, scoring and drain. The counter cannot isolate relay owner threads or distinguish CPU on the critical path from CPU running concurrently. The exercise assumes proportional work across the larger payload and stable bracket lengths. Setup may impose a fixed cost and drain may change. A VM trial could combine a change in cost per GiB with a change in CPU supplied, so the two scenarios are reference points. The historical process measurements alone cannot determine a serial fraction, scheduling headroom or achievable speedup.

During the four-vCPU, one-port worker trial, compare receiver-delivered MiB/s against the two-worker control and record bracket durations, supervisor and VMM CPU separately, fresh failures, p95/p99, reopens and runnable time. The newer client also records full-invocation bulk bytes, allowing a second denominator aligned with the CPU bracket. A paired peer holdout supplies the comparison to current OrbStack.

## Reproduce

From this directory, replay both checksum-pinned raw archives and compare every output byte with the checked result.

```sh
python3 -B replay.py | cmp - result.json
```
