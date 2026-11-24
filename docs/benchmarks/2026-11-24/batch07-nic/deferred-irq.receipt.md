**24 November 2026 · 231.03 · Deferred RX interrupts at a fixed 20 µs timer**

Source/fixture, Micropod `a60d203b16b24abd857e1b5c9e817636b241f850`, pinned Linux 7.3.5. Compared zero with two deferred hard-IRQ polls while holding the GRO flush timeout at 20,000 ns. The fixture compiled the unchanged NAPI completion and watchdog functions with virtio-net's receive completion wrapper. A logical device supplied 32 receive descriptors at each of seven fixed spacings (0, 1, 19, 20, 21, 50 and 25,000 µs). The driver completed each under-budget poll without a held GRO entry. Software ran immediately on an IRQ or scheduled timer. The timer fired at its exact logical deadline.

| Arrival spacing | Device IRQs, 0 → 2 | Timer polls, 0 → 2 | Empty polls with deferral | Maximum modeled descriptor wait, 0 → 2 |
| ---: | ---: | ---: | ---: | ---: |
| 1 µs | 32 → 1 | 0 → 4 | 2 | 0 → 19 µs |
| 19 µs | 32 → 1 | 0 → 32 | 2 | 0 → 19 µs |
| 25 ms | 32 → 32 | 0 → 64 | 64 | 0 → 0 µs |

All 224 descriptors per arm reached the simulated receive poll. Seven deterministic workload pairs, with every delay retained. No statistical interval applies. Under dense arrivals, two deferrals can batch work. With sparse arrivals they added empty polls without saving an interrupt. IRQ counts alone also concealed the nearly one-for-one substitution of timer polls at 19 µs spacing. Actual guest polling duration, hardware interrupt moderation, vCPU scheduling, GRO aggregation and timer jitter are outside the fixture. No wire traffic, throughput, losses, fresh p95/p99, CPU/GiB or runnable time was measured.

Keep the stock VM settings. If the publication queue supports a separate trial, measure completed RX descriptors per poll, timer versus device wakeups, and receiver progress under the same open-loop fresh traffic. Raw-verified local result `deferred_irq.json` SHA-256 `4725dd3b18e56eb5eb147fce4b9800e2b671da2d57c7316be1e95d5e057b2077`. Reproduce with `python3 -B kernel_queue.py LINUX_7_3_5_TREE deferred_irq`. The raw file pins both source members, three original functions as compiled, harness and compiler.
