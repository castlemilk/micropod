# Guest cgroup weights with uneven runnable placement

24 November 2026 · #231.10 · Compiled Linux 7.3.5 scheduler source with synthetic runqueues

Keep the current scheduler mode. Switching from the source default `concur` to guest-wide `max` gave the group with one runnable task four times as much relative weight against an equal-priority group with four runnable tasks. Either group can be the publication service. The result depends on which group has runnable work where the two compete.

| Runnable service tasks | Runnable sibling tasks | Service/sibling weight on vCPU 0, `concur` | Service/sibling weight on vCPU 0, `max` |
| --- | --- | ---: | ---: |
| Four, one per vCPU | One on vCPU 0 | 1 | 1/4 |
| Four on vCPU 0 | One on vCPU 0 | 4 | 1 |
| One on vCPU 0 | Four, one per vCPU | 1 | 4 |
| One on vCPU 0 | Four on vCPU 0 | 1/4 | 1 |

Both sibling groups had the same base shares, nice-0 tasks, synthetic steady-state load averages and access to vCPUs 0–3. The archived service used `cpu.max=400000 100000` and this four-vCPU set. The replay compiled the original mode selector and group weight functions from the saved `kernel/sched/fair.c`. Each placement held both groups' inputs fixed while the selector changed.

Four controls covered equal sparse groups, equally runnable groups with different placements, disjoint placements and symmetric spread. Equal sparse groups retained a ratio of 1 despite both weights quadrupling. Four spread service tasks against four packed sibling tasks retained 1/4 on vCPU 0. Disjoint groups had zero contested vCPUs. Symmetric spread retained 1 on every vCPU. Separate boundary checks verified both modes agree with a one-vCPU cpuset and reproduced the nice −20 ceiling for `max`.

The earlier #231.10 replay tested `tasks` with evenly spread work. Under #237, separate experiments varied quota exposure, competitor nice level or interrupt placement. This comparison changes only the guest-wide weight calculation. The archive establishes the service budget. Measuring a throughput effect still requires the effective guest mode, per-CPU runnable service and sibling work, guest CPU consumption, receiver throughput and fresh-request latency from the same run. A TCP stream count alone cannot establish runnable placement. [Earlier #231.10 result](../batch06-trace/group-weight.receipt.md) · [Quota comparison](../backlog-batch-03.md) · [Competitor nice and IRQ comparisons](../backlog-batch-09.md)

From this directory, run `python3 -B replay.py`. The driver verifies all input digests, compiles the pinned code with Clang and checks the raw weights in both evaluation orders. Two runs with the recorded compiler produced byte-identical JSON, SHA-256 `5872d09583b29a19498fdf1f51cfde501c7df4e627c21b0a78f5f08201d81641`. [Driver](replay.py) · [C fixture](probe.c) · [Weights and checks](result.json)
