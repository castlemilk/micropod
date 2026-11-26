# Bounded handoff and queued reads

The two-descriptor candidate halved the dispatch submissions for 32 simultaneously pending connections, from 32 to 16. Across all 33 insertion positions, a readable callback on an existing socket saw at most one additional adoption ahead of it on its worker. The earlier unbounded coalescer could move 15 additional adoptions ahead in the same two-worker scenario. [Bounded results](fixture-evidence/bounded-dispatch-orders.json) · [Earlier unbounded study](../batch07-relay/handoff.receipt.md)

| Pending fresh accepts per worker before release | Stock submissions for 240 fresh accepts | Bounded-two submissions |
| ---: | ---: | ---: |
| 1 | 240 | 240 |
| 2 | 240 | 120 |
| 3 | 240 | 160 |
| 8 | 240 | 120 |

Each workload first released two preflight connections and 32 bulk connections. The table counts only the following 240 fresh connections. The driver selected each pending group size and drained both workers between groups. The live distribution of group sizes is unknown. At an evenly spaced 40 accepts/s in rotation across two workers, the next accept for the same worker arrives 50 ms later. Only accepts that overlap on that worker can share a dispatch. The timed trial should compare the existing post-initial dispatch counter with fresh-request p95/p99 and receiver throughput before promoting the candidate.

The fixture compiled the staged Swift handoff fragment with and without `BATCH_TWO`, used real Darwin serial dispatch queues and verified marker delivery and EOF on unnamed Unix socketpairs. Both repetitions matched for every observation. Each policy delivered 4,304 handoff echoes and 132 replies on existing sockets. No VM or TCP throughput and no elapsed callback latency were measured. Gamma’s managed shell denied a fresh IPv4 loopback listener, which the separate six-pair TCP throughput trial requires. [Reproduction driver](dispatch_orders.py) · [Staged TCP trial](study.py)
