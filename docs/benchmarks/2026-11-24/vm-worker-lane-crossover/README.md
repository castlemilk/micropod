# Two versus four data workers on a historical four-vCPU Gamma VM

Four workers lost all six fresh-connection pairs and five of six warm pairs in the November 21 single-port prototype. The fresh median paired loss was **8.66%**. Keep two workers as the revised VM baseline and run the planned two-versus-four crossover on the current binary before selecting either configuration. The historical host-only one-port screen favored four workers by 63.9%. [Host screen](../../2026-11-22/gamma-tcp-contrasts.md)

| 32 concurrent 8 MiB downloads | Two workers, median MiB/s | Four workers, median MiB/s | Paired change, four versus two | 95% paired bootstrap interval | Four-worker wins |
| --- | ---: | ---: | ---: | ---: | ---: |
| Fresh connections | 4,222 | 3,883 | −8.66% | −10.90% to −3.92% | 0/6 |
| Warm connections | 4,338 | 3,974 | −9.82% | −18.54% to +2.02% | 1/6 |

All 24 burst records succeeded. Each client received 256 MiB, totaling 6 GiB over the two arms and two cohorts. The client validated each 8 MiB body length and recorded zero unexpected reconnects or initial connection-type mismatches. The replay recomputes throughput from the last completed response. It retains the fresh and warm measurements separately. Each interval uses the nearest-rank percentiles over every ordered bootstrap resample of the six paired percentage changes. The intervals describe variation over these six blocks and do not adjust for order.

The synchronized first-response barrier divides each burst into time to the last stream's first header and the remaining time to the last complete response. Moving to four workers added a median paired **0.42 ms before / 4.64 ms after** the last header with fresh connections and **0.04 / 6.68 ms** with warm connections. The next VM crossover should preserve client phase timestamps alongside receiver bytes. The 75 ms gate concerns independent short requests arriving during sustained traffic. This pilot recorded only synchronized bulk traffic, so neither arm can be scored against that gate.

## Controls and limits

The archived pilot opened one listener per arm on a distinct ephemeral port. Both arms used one accept queue and the same round-robin handoff function, with two or four serial user-initiated data queues pointing to the same primary guest address, gateway, translated port and container. Both ran on the same four-vCPU boot. The driver checked every listener's service marker. Its seven-case rotation placed the two-worker arm first in five of six blocks. Within each arm, fresh always ran before warm. The result describes this historical prototype. The original report compared a single owner with two data workers and separately reported a two-interface setting. [Original report and archive](../../2026-11-21/gamma-vnic.md)

The lane driver scheduled each data owner on its own dispatch queue and called `mp_tcp_relay_drain` on its own relay object. At both the recording parent and archive revision, the integrated relay source uses a per-drain loop threshold of 128 serviced events with bulk pulls of two. The lane prototype calls an intermediate version of the handoff API. Its exact linked relay source and executable digest are absent. The worker count changed the number of independently runnable drain callbacks. The effective per-owner and aggregate processing budgets during the pilot are unknown. The archive supplies the four-vCPU boot readback and marker for the reused container. It lacks a lane-specific service CPU quota readback, host worker/core placement, per-worker CPU time, and independent short-probe samples. The result cannot establish a current-production worker count or an OrbStack comparison.

Run `python3 -B replay.py` in this directory to reproduce the receipt from the pinned archive. [Replay](replay.py) · [Source hashes, all paired rounds and phase durations](measurement.json)
