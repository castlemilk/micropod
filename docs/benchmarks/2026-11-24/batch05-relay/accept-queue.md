# Accept work before a second ready listener receives service

24 November 2026 · 230.03 · Source/fixture on Darwin arm64, fixed work.

Limiting one accept turn to eight handoffs let a newly ready sparse listener run after eight busy connections. The stock limit allowed 32 ahead of it. A single listener draining 40 connections required five nonempty polls with the smaller quantum and two with stock. These counts establish a multi-listener trade-off. They give no evidence for changing the one-listener worker trial.

The control used the stock accept loop at revision `7d9b565173a901cb18942e00384838da96e0ba98` (source SHA-256 `f35e0245ebc1d394f748ea31ef03df180c70ad4a979925037ea063f7a2a08cee`). The candidate changed only the per-event accept loop limit from 32 to eight (source SHA-256 `d4fe208205317072e2d23bd487ec9b8c4f7d1ad48c0f1adc6b5aa7d1ed4e4d54`). Both arms used the same two registered queues, offered order, handoff function and relay owner.

A named private UNIX listen socket encountered EPERM at bind during initial setup. That first preflight is retained in `accept-quantum.json` (SHA-256 `14ca1608b3201a3b706649654dfe358884458d98171d8371d27841f2ec1fdf34`). It returned zero measured rows. The scored source fixture used anonymous socketpairs. One token represented a queued connected descriptor. Darwin kqueue, relay accept scheduling, the handoff callback, socketpair request/reply delivery and FIN were real. Token removal modeled the successful accept or EAGAIN. This fixture cannot establish kernel listen-backlog overflow, TCP handshake costs or guest service times.

| Busy offers | Sparse offer position | Busy handoffs before sparse, stock → candidate | Nonempty polls, stock → candidate |
| ---: | --- | ---: | ---: |
| 40 | None | n/a | 2 → 5 |
| 40 | Before busy offers | 0 → 0 | 2 → 5 |
| 40 | After 1, 20 or 40 busy offers (three cases) | 32 → 8 | 2 → 5 |
| 1 | After the busy offer | 1 → 1 | 1 → 1 |

Each arm ran six cases twice in ABBA order. All 412 offered marker replies and FINs per arm arrived, all queues drained and results repeated exactly. These positions are deterministic and carry no statistical interval. Elapsed time, fresh p95/p99, CPU/GiB, throughput and runnable time remain unmeasured.

Keep the 32-accept control for the one-port worker screen. Pursue the eight-accept candidate if an admitted multi-listener diagnostic shows handoffs waiting behind busy leases.

Raw-verified local evidence is in `accept-queue.json` (SHA-256 `4c09b75d915834bc52c8bb664b7fec2ae9e2a53d3dadbc87c69f0374fce17f80`). From this directory run `python3 -B run_accept_queue.py --output /tmp/micropod-accept-queue-new.json` on an authorized Darwin workspace. Choose an unused result filename. The raw file pins all source digests and compiler flags.
