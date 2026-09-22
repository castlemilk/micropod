# Upstream report draft: `container run --init` does not forward SIGTERM
# Target: https://github.com/apple/container/issues (new issue)
# Status: DRAFT — verified locally, not yet filed.

Title: `--init` does not forward SIGTERM to the container process

Environment:
- `container` v1.3.1, macOS arm64
- Guest: alpine:3.22 (`/bin/sh` → busybox)

Repro:
  container run -d --init --name t sh -c 'trap "echo GOTTERM; exit 0" TERM; echo READY; sleep 300'
  sleep 2
  time container stop t   # 5.25 s, logs show READY but never GOTTERM
  container logs t        # no GOTTERM
  container rm -f t

Expected (per `--help`: "an init process that forwards signals and reaps
processes"): TERM forwarded, trap fires, container exits promptly (~1 s —
this is exactly what happens WITHOUT --init when PID 1 itself traps TERM:
`trap...; while true; do sleep 1; done` exits in ~1 s with GOTTERM).

Actual: identical behavior with and without --init (5.25 s stop, no
GOTTERM) — the init appears to reap (zombies) but not forward signals.

Impact: CI runners cannot rely on graceful shutdown through --init;
every TERM-ignoring guest burns the full stop grace period. Workaround
used downstream: kill semantics (`stop -t 0` / `kill` / `rm -f`).

Notes for triage:
- Direct-PID-1 trap case works (proves TERM delivery itself is fine).
- Naive PID-1 `sleep 300` (no handler, default action should terminate)
  also takes the full grace — consistent with signals never reaching the
  guest process tree in either configuration.
