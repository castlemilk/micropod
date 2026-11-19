# Disruptive rig upgrades

`micropod update apply --disruptive` replaces Micropod on a CI rig in one
operation: the desktop app with its CLI and MCP, the retained docker-shim and
shared-fs services, and the Connect API (`dev.micropod.api`). Jobs on the host
may be interrupted. The guarded Sparkle path ([updater-admission.md](updater-admission.md))
stays the default for desktops; nothing about it changes unless a host opts in.

The upgrade itself never touches the root runtime helper, the dedicated API
or the Apple runtime. When the dedicated runtime is in use, the upgrade still
replaces the user-level components and says so in its result and in
`UpdateState.reason`. Once the upgrade completes, the root helper updates the
dedicated runtime to the new app's release in its own coordinated operation
([runtime-component-update.md](runtime-component-update.md)). `apply` follows
it, and exits 0 only when both complete.

## Policy per host

`micropod update policy disruptive` makes plain `micropod update apply` take
this path and stops the app from installing Sparkle updates by itself (its
informational checks continue). `micropod update policy guarded` restores the
default. The policy lives in `~/.micropod/rig-upgrade/policy.json`.

## Staging

`micropod update stage`, or the first step of `apply`, runs before anything is
disrupted. The newest release on the configured channel (`--channel`, else the
app's saved channel; `--feed` or `MICROPOD_UPDATE_FEED` override the URL,
never the key) is downloaded and checked against the feed's length and the
release EdDSA key. It is unpacked from its disk image, and its `Micropod.app`
must carry Micropod's sealed Developer ID signature and the version and source
revision the feed declares (`micropodSourceRevision` is required). The bundle
lands in `~/.micropod/releases/<version>-<revision>/` with a `staged.json`
marker, and `UpdateState` reports `KIND_STAGED`. Every network and
verification failure happens here.

## Phases

The upgrade is journaled in `~/.micropod/rig-upgrade/journal.json` (fsynced
before every step) under a kernel lock that only a running engine holds.

| Phase | What happens | Changed so far |
| --- | --- | --- |
| `prepared` | Refuses on any of the conditions below. Then copies the staged bundle to a service payload. Saves every file it will replace into `ops/<operation>/previous/` and the new versions into `ops/<operation>/new/`, using the staged release's own service definitions (`rig-helper --probe`). Records which launchd jobs are loaded, and runs a baseline smoke container on the current release. | nothing |
| `draining` | Verifies the staged bundle, payload and replacements again, and that this process is signed by Micropod's team. Asks Cuttlefish to drain (see [The drain](#the-drain)). | nothing |
| `stopping` | Freezes the app (SIGSTOP), so it neither respawns agents nor runs its quit path. Ends the agents it spawned from its bundle gracefully (SIGTERM, then SIGKILL after 10 s), so the API's in-process VMs, docker-shim and shared-fs tear down. Then SIGKILLs the app, and runs `launchctl bootout` for each retained service and for `dev.micropod.api`. The app never quits normally: its quit path is where Sparkle installs an update it staged for quit. | services stopped |
| `swapping` | `renamex_np(RENAME_SWAP)` exchanges the staged bundle with `/Applications/Micropod.app`. Records, launch agents, `connect/bin/MicropodAPI`, `micropod-guest` and `connect/VERSION` are each replaced atomically. An app that is neither release (replaced by something else since prepare) is never swapped. | app and files |
| `starting` | Bootstraps each job that was loaded. A job still loaded with another program is booted out and loaded again. Relaunches the app if it was running. | |
| `verifying` | Runs the health gate (see [Health gate](#health-gate)) within `--health-timeout` (120 s). | |
| `completing` | Keeps the swapped-out app as `releases/<previous>/`, releases the drain, garbage-collects. | |
| `completed` | Terminal. | |

`prepared` refuses when any of these hold:

- a Sparkle transaction, Sparkle's installer or runtime maintenance is in flight (an installer is recognised by a Sparkle signing identifier signed by Micropod's team);
- the installed app is not Micropod's signed app;
- this process is not signed by Micropod's team, which App Management requires of a process that replaces the app;
- either bundle is not a directory this account owns and can write, or the bundles are on different volumes;
- a file it would replace is a symbolic link;
- the release is already installed.

### Health gate

The `verifying` phase passes only when all of these hold:

- sockets that accepted connections before the upgrade accept them again;
- the Connect API answers `Ping` with `micropod_version` equal to the target, when it is one this upgrade replaced;
- the `docker-shim` and `shared-fs` components report the target and `running`;
- the app reports the target version and revision;
- the smoke container runs and is removed, if it ran before the upgrade.

## Resuming

Every step is idempotent by inspection, not by remembered progress:

- which bundle is installed is read from its Info.plist and its main executable's digest;
- a file is replaced only when its digest differs;
- a launchd job is booted out or in only when its loaded program differs from its plist.

A crash, a killed helper, a reboot or a re-login is resumed by running the
engine again:

- A resume in `draining` with an undrained outcome already recorded still refuses (unless `--force-undrained`). The refusal is written before the drain is released, so no crash can carry an undrained upgrade past the drain.
- A resume in `stopping` or `swapping` first checks that Sparkle's installer has not started meanwhile.
- A resume in `swapping` or `starting` stops everything again first. That ends whatever launchd reloaded at login and whatever app was opened since.
- A resume in `verifying` or `completing` starts everything again first.

The journal counts engine runs per phase, and the count resets when the phase
changes. A phase whose fifth run also crashes is abandoned the way a failed
step is: before anything changed the upgrade is refused, after a change it
rolls back.

## Rollback

A failure in `stopping` through `verifying` records `failure` and moves to
`rollingBack`. Rollback is best-effort step by step:

1. Stop the app and boot out each job.
2. Swap the previous bundle back if the target is installed.
3. Restore every saved file, or remove one that did not exist.
4. Bootstrap every job that was loaded and relaunch the app if it was running, whatever failed before.

With nothing left over it health-gates the restored release (the result is
noted, not required), releases the drain and ends `rolledBack` with the
reason.

Otherwise it records what it could not restore:

- A failure that a retry might fix is retried by the next run, up to five runs in `rollingBack`.
- An app that is neither release, which no retry can fix, ends `recoveryRequired` at once. Services and the app are still started as they are.

`micropod update recover --rig` runs the rollback again.

## Abandoning and recovering

| Command | Phase | Effect |
| --- | --- | --- |
| `micropod update apply --abandon` | `prepared` or `draining` | Ends the upgrade as `refused` and releases its drain. Refused once services have stopped. |
| `micropod update recover --rig` | `prepared` or `draining` | Abandons the upgrade. |
| | `recoveryRequired` | Runs the rollback again. |
| | `stopping` through `completing`, or `rollingBack` | Resumes the upgrade. |
| | finished | Releases drains still outstanding. |

If the helper cannot be started, the prepared journal is refused, not left
waiting.

## Fencing

The rig upgrade never uses the Sparkle transaction store, and it never closes
desktop admission (`DesktopActivity`).

While a rig upgrade is under way, the app refuses to install a Sparkle update,
and Ping reports `KIND_UPGRADING`. An upgrade counts as under way in either
case:

- it is past `draining`;
- it is in `prepared` or `draining`, and an engine holds the lock or launchd has this operation's helper loaded (`launchctl print` names its binary).

A journal left in `prepared` by a CLI that died before starting its helper
fences nothing, and neither does a helper plist left behind.

The app leaves its retained services alone only while a live engine holds the
lock in a phase that replaces them.

## The launchd helper

`apply` prepares the journal in the foreground. It then copies `micropod-cli`
out of the staged bundle (or this CLI, when the staged one does not run
journal schema 1) into the operation directory and checks that the copy runs
(`update rig-helper --probe`). It then makes sure
`com.skunkworq.micropod.rig-upgrade` runs from `~/Library/LaunchAgents` with
`RunAtLoad` and `KeepAlive` on failure only:

- A launch lock serialises callers.
- A job already loaded from this helper is kickstarted, which starts it only if it is not running.
- A job left loaded by an earlier operation is replaced.

A launch that fails removes the plist again, so nothing loads it at the
next login.

The helper survives the app swap, a closed terminal or a preempted CI job,
restarts after a crash, and resumes at login after a reboot. It waits, bounded
(5 minutes), for a `--foreground` engine to finish.

Each helper is bound to its operation:

- It gets `--operation <uuid>` and refuses any other journal.
- Started for a `prepared` journal more than 10 minutes old, with no recent launch by a CLI, it abandons the journal instead of starting it: launchd loaded a leftover definition at login.

After 20 runs of one operation the helper gives up. The journal becomes:

- `refused`, before anything stopped;
- `completed`, if verified;
- `recoveryRequired` with the reason, otherwise, after the services and the app are started as they are.

When the journal is terminal or its budget is spent, the helper removes its
definition and boots itself out. `apply` follows the journal and exits 0 only
on `completed`. `--detach` returns after the handoff, and `--foreground` runs
the engine in the calling process instead.

## UpdateState

The Connect API (Ping, GetSystem, GetUpdateState) and `micropod update
status` read the journal, so the state is visible while the app is down. All
of these are scope `desktop`:

- In flight: `KIND_UPGRADING`, with `phase` `rig-<phase>` (or `rig-rolling-back`), `operation_id`, `current_version` and `target_version`.
- `rolledBack`: `KIND_ROLLED_BACK`, with the reason.
- `refused`: `KIND_BLOCKED`.
- `recoveryRequired`: `KIND_RECOVERY_REQUIRED`.
- A staged release newer than the installed app: `KIND_STAGED`.

An upgrade in flight outranks every other state. Its outcome, or a staged
release, outranks a desktop that is merely current or unobservable.

## Retention

After a successful upgrade:

- **Release directories** keep the previous app and any newer staged release. When the previous app could not be moved, its only copy stays in the staged directory and is kept there.
- **Service payloads** keep the target, the payload the previous records named, anything a service record names, and anything a running process executes from.
- **Operation records** keep the current one and one previous.

Nothing in use is removed.

## The drain

The drain is a `rig-upgrade` drain on Cuttlefish's maintenance socket
(`~/.cuttlefish/runner-state/micropod-maintenance.sock`), one JSON line each
way. The shapes are pinned in [contracts/rig-upgrade-drain.json](contracts/rig-upgrade-drain.json),
which both sides test against.

- **Request.** `{"action":"drain"|"abort"|"abortComplete","kind":"rig-upgrade","operation":"<uuid>"}`. No install root, runtime version or package digest is sent.
  - The operation and kind are pinned in the journal (`drainSpec`), and every drain, heartbeat and release names them.
  - The CLI or helper sending it is signed `com.skunkworq.micropod.cli`.
- **Reply.** `{"operation","phase","reason"}`:
  - `draining`: Cuttlefish holds new leases. Attempts still running after `min(CUTTLE_MAINTENANCE_GRACE, 60 s)` are preempted and handed back with `maintenance_preempted`, which keeps their retry budget.
  - `drained`.
  - `refused` or `blocked`, with a reason. Cuttlefish frames its refusals as `blocked`.
- **Unexpected answers.** A closed connection without a reply means an older Cuttlefish that rejects the unknown `kind`; so does an answer that is not one of these phases. Both are `incompatible`, never `draining`. A request that could not be written (no socket, unverified peer) is `unavailable`.
- **Polling.** Micropod polls every 2 s for up to `--drain-timeout` (120 s), measured from the first request and across resumes. When the time runs out while Cuttlefish is still `draining`, the rig is held and the upgrade goes ahead (`timedOut`).
- **Undrained rig.** With a coordinator configured, the upgrade is refused before anything stops when the outcome is any of these:
  - `refused`, at the deadline;
  - `incompatible`, at once;
  - `unavailable`, after 10 s.

  `--force-undrained` goes ahead anyway and says so loudly. A host with no coordinator configured skips the drain.
- **Heartbeat.** While services are down, the drain is re-sent every 20 s. This continues after `unavailable`, so a coordinator that comes back holds the rig. Cuttlefish releases the hold itself when no call arrives for two minutes.
- **Release.** `abort`, then `abortComplete`; the reply is `cancelled`. No local `fence.json` or host fence is involved.
  - `blocked` or `refused` with a reason containing "unknown" means Cuttlefish holds nothing.
  - An abort closed without a reply means "not held" only when Cuttlefish never acknowledged this drain. An older Cuttlefish rejects every call that way. Otherwise the close may be transient, and the release is retried.
  - Every drain is kept in `~/.micropod/rig-upgrade/unreleased-drains.json`, from before the first request until its release is confirmed, with whether Cuttlefish acknowledged it.
  - Any later engine run (including a new prepare that replaces the journal) and `recover --rig` release what is listed. Entries older than seven days are dropped.
- **Coordinators of other accounts.** Only this account's coordinator is asked to drain. A Cuttlefish maintenance socket found under another account's home is noted and logged, not used.

### What Cuttlefish must implement

None of this is on Cuttlefish `main` yet. Until it ships, every rig-upgrade drain is `incompatible`, and a configured rig refuses the upgrade unless `--force-undrained` is given.

- Accept a maintenance-socket peer signed `com.skunkworq.micropod.cli` (team `WFTX6CN23F`), as well as `com.skunkworq.micropod`, for `kind: rig-upgrade`. Today only the app's identifier is accepted.
- Decode the `kind` field. `micropodMaintenanceCall` decodes with `DisallowUnknownFields`, which rejects it today.
- For this kind, skip the `validManagedRuntimeRoot` install-root check and the version, package digest, `localGeneration` and `targetState` validation. The request carries none of them.
- For this kind, take no host fence, and do not require the local admission `fence.json` to be absent on `abortComplete`.
- Answer every decoded rig-upgrade call with one reply line, never a silent close:
  - for `drain`: `draining`, `drained`, or `refused`/`blocked` with a reason;
  - for a release: `aborting` then `cancelled`;
  - for an operation it never recorded: `blocked` with a reason containing "unknown".

The bounded grace, preemption with `maintenance_preempted`, and release of a hold with no call for two minutes all come from Cuttlefish changes that are not merged yet: skunkworq/cuttlefish `claude/maintenance-preemption-agent` (d8593eb7, 9e332180). Until they land, a drain only waits for idle, and Micropod's timeout decides.

The list is repeated in the contract fixture as `cuttlefishMustImplement`.

A rig controller that triggers upgrades should run
`micropod update apply --disruptive --detach` (the helper outlives the job)
and watch `UpdateState` on Ping for `rig-*` phases and the terminal kind.
