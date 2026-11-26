# Full sweep of relay handoff positions

Yielding after the current kqueue poll brought the first readable reply forward at 16 of 32 arrival positions. The other 16 tied. The largest backlog seen before the client could read the reply fell from 7.75 to 3.75 MiB.

| When the handoff was queued | Reduction in bulk ahead of handoff entry | Reduction in bulk ahead of a readable reply |
| --- | ---: | ---: |
| After bulk writes 1–8 | 6 MiB | 4 MiB |
| After writes 9–16 | 4 MiB | 2 MiB |
| After writes 17–24 | 2 MiB | 0 MiB |
| After writes 25–32 | 0 MiB | 0 MiB |

The maximum bulk ahead of handoff entry fell from 7.75 to 1.75 MiB. Both arms used two productive callbacks for each handoff trial. With no handoff, both used four nonempty polls in one productive callback. The experiment did not time those callbacks or measure CPU.

Each arm relayed eight established 1 MiB downloads, checked their contents and verified both half-closes on every stream. The fresh connection used a one-byte server-first reply. All 33 cases ran in a seeded order and again with the arrival and arm orders reversed. A 125 ms pause separated the 132 short invocations. Outcomes reproduced exactly across repetitions and matched the independent [initial four-case receipt](receipt.md).

The result covers a fixed 8 MiB burst, a single handoff, staged connected socketpairs and explicitly submitted follow-on callbacks on Darwin. The positions are equally weighted by bulk-write index. Production arrival probabilities, fresh p95/p99 and delivered TCP MiB/s require timed measurements.

Run `python3 -B sweep.py` here to rebuild and repeat. The complete trial sequence and source hashes are in [sweep.json](sweep.json), SHA-256 `14c7b54c4ced55f6d6237eedc960f7e377e2706b58eb06b3bac22d0c57af3db2`.
