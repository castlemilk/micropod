# Disruptive rig upgrades

`micropod update apply --disruptive` replaces Micropod on a CI rig in one
operation: the desktop app with its CLI and MCP, the retained docker-shim and
shared-fs services, and the Connect API (`dev.micropod.api`). Jobs on the host
may be interrupted. The guarded Sparkle path ([updater-admission.md](updater-admission.md))
stays the default for desktops; nothing about it changes unless a host opts in.

The root runtime helper, the dedicated API and the Apple runtime are out of
scope and never touched. When the dedicated runtime is in use, the upgrade
still replaces the user-level components and says so in its result and in
`UpdateState.reason`.

## Policy per host

`micropod update policy disruptive` makes plain `micropod update apply` take
this path and stops the app from installing Sparkle updates by itself (its
informational checks continue). `micropod update policy guarded` restores the
default. The policy lives in `~/.micropod/rig-upgrade/policy.json`.

## Phases

Staging happens first and off the critical path:

1. **Stage** (`micropod update stage`, or the first step of `apply`). The
   newest release on the configured channel (`--channel`, else the app's
   saved channel; `--feed` or `MICROPOD_UPDATE_FEED` override the URL, never
   the key) is downloaded, checked against the feed's length and the release
   EdDSA key, unpacked from its disk image, and its `Micropod.app` must carry
   Micropod's sealed Developer ID signature and the version and source
   revision the feed declares (`micropodSourceRevision` is required). The
   bundle lands in `~/.micropod/releases/<version>-<revision>/` with a
   `staged.json` marker. `UpdateState` reports `KIND_STAGED`. Every network
   and verification failure happens here.

The upgrade itself is journaled in `~/.micropod/rig-upgrade/journal.json`
(fsynced before every step) under a kernel lock only a running engine holds:

| Phase | What happens | Changed so far |
| --- | --- | --- |
| `prepared` | Refuses if a Sparkle transaction or runtime maintenance is in flight, the volume differs from the app's, or the release is installed. Re-verifies the staged bundle, copies it to a service payload, saves every file it will replace into `ops/<operation>/previous/`, writes the new ones into `ops/<operation>/new/`, records which launchd jobs are loaded, and runs a baseline smoke container on the current release. | nothing |
| `draining` | Verifies the staged bundle and payload again, then asks Cuttlefish to drain (below) for up to `--drain-timeout` (120 s); the wait is measured from the first request, across resumes. | nothing |
| `stopping` | Quits the app (SIGTERM, then SIGKILL after 20 s) and the agents it spawned from its bundle, then `launchctl bootout` for each retained service and `dev.micropod.api`. | services stopped |
| `swapping` | `renamex_np(RENAME_SWAP)` exchanges the staged bundle with `/Applications/Micropod.app`; records, launch agents, `connect/bin/MicropodAPI`, `micropod-guest` and `connect/VERSION` are replaced atomically. | app and files |
| `starting` | `launchctl bootstrap` for each job that was loaded; relaunches the app if it was running. | |
| `verifying` | Health gate within `--health-timeout` (120 s): sockets that accepted before accept again; the Connect API answers `Ping` with `micropod_version` equal to the target when it is one this upgrade replaced; `docker-shim` and `shared-fs` components report the target and `running`; the app reports the target version and revision; the smoke container runs and is removed, if it ran before the upgrade. | |
| `completing` | Keeps the swapped-out app as `releases/<previous>/`, releases the drain, garbage-collects. | |
| `completed` | Terminal. | |

Every step is idempotent by inspection rather than by remembered progress:
which bundle is installed is read from its Info.plist and main-executable
digest, a file is replaced only when its digest differs, and launchd jobs are
booted out or in only when needed. A crash, a killed helper or a reboot at any
point is resumed by running the engine again, which completes the forward
phases. A phase that keeps crashing its engine is abandoned after five
attempts: before any change the upgrade is refused, after one it rolls back.

## Rollback

A failure in `stopping` through `verifying` records `failure` and moves to
`rollingBack`: stop everything again, swap the previous bundle back if the
target is installed, restore every saved file (or remove one that did not
exist), bootstrap the jobs that were loaded, relaunch the app, health-gate the
restored release (its result is noted, not required), release the drain and
end in `rolledBack` with the reason. Rollback is resumable the same way. If it
cannot finish within five attempts the journal ends in `recoveryRequired`;
nothing more is changed and `micropod update recover --rig` retries it.

None of this uses the Sparkle transaction store, so an interrupted rig upgrade
never fences the desktop. The app leaves its retained services alone only
while a live engine holds the lock in a phase that replaces them.

## The launchd helper

`apply` prepares the journal in the foreground, then copies `micropod-cli` out
of the staged bundle (or this CLI, when the staged one does not run journal
schema 1, checked with `update rig-helper --probe`) into the operation
directory and bootstraps `com.skunkworq.micropod.rig-upgrade` from
`~/Library/LaunchAgents`: `RunAtLoad`, `KeepAlive` on failure only. The helper
survives the app swap, a closed terminal or a preempted CI job, restarts after
a crash and resumes at login after a reboot. It exits 0 and removes its
definition once the journal is terminal. `apply` follows the journal and
exits 0 only on `completed`; `--detach` returns after the handoff, and
`--foreground` runs the engine in the calling process instead.

## UpdateState

The Connect API (Ping, GetSystem, GetUpdateState) and `micropod update
status` read the journal, so the state is visible while the app is down:

- in flight: `KIND_UPGRADING`, scope `desktop`, `phase` `rig-<phase>` (or
  `rig-rolling-back`), `operation_id`, `current_version`/`target_version`;
- `rolledBack`: `KIND_ROLLED_BACK` with the reason; `refused`:
  `KIND_BLOCKED`; `recoveryRequired`: `KIND_RECOVERY_REQUIRED`;
- a staged release newer than the installed app: `KIND_STAGED`.

An upgrade in flight outranks every other state; its outcome or a staged
release outranks a desktop that is merely current or unobservable.

## Retention

After a successful upgrade the release directory keeps the previous app and
any newer staged release; service payloads keep the target, the payload the
previous records named, anything a service record names and anything a running
process executes from; operation records keep the current and one previous.
Nothing in use is removed.

## What Cuttlefish must do

The drain uses the existing shared-runtime maintenance socket
(`~/.cuttlefish/runner-state/micropod-maintenance.sock`, `RuntimeRigClient`):

- `drain` with a fresh operation UUID, `targetState` `running`,
  `localGeneration` 1, the host's releases directory as `installRoot` and the
  supported Apple runtime's version and package digest. Cuttlefish holds new
  leases and answers `draining` until quiesced, then `drained`. It preempts
  attempts still in flight after `min(CUTTLE_MAINTENANCE_GRACE, 90 s)` and
  hands them back with `maintenance_preempted`, which keeps their retry
  budget. Micropod polls every 2 s and goes ahead when its drain timeout
  (default 120 s) ends, so the grace must stay inside it.
- While services are down Micropod repeats `drain` every 20 s, so the rig
  does not treat the drain as abandoned (two minutes of silence).
- `abort` then `abortComplete` (release kind `cancelled`) end the operation
  and release the lease hold. No admission fence or host fence is taken, so
  Cuttlefish's `localReleased` check is satisfied. A release that fails is
  retried by the next upgrade or `micropod update recover --rig`; meanwhile
  Cuttlefish's abandonment timer frees the leases, but its record keeps
  refusing other operations until the release lands.
- A host without a coordinator skips the drain, and one that cannot be
  reached for 10 s is recorded as `unavailable`; a coordinator that refuses
  (for example, another operation holds host maintenance) is asked again
  until the timeout. Either way the upgrade goes ahead: the policy is
  disruptive and never waits forever.

A rig controller that triggers upgrades should run
`micropod update apply --disruptive --detach` (the helper outlives the job)
and watch `UpdateState` on Ping for `rig-*` phases and the terminal kind.
