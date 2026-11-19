# Runtime component updates

`micropod runtime update` replaces the dedicated runtime's privileged
components on a rig host: the setup app, the root helper, the dedicated API
and the pinned Apple container build. It is signed, needs no administrator
prompt after the first install, and runs as a coordinated lifecycle operation
with the Cuttlefish drain. `micropod update apply --disruptive` chains it, so
one command updates the app and the runtime.

Before this, nothing could replace these components.
`RuntimeSetupInstallation.stage` keeps an existing setup app, and the rig
upgrade ([rig-upgrade.md](rig-upgrade.md)) replaces only the user-level
Micropod. The root-helper fixes in #132 and #133 and the dedicated-API change
in #135 (payload reclaim off the apiserver lock) therefore could not reach a
rig, and neither could a patched Apple build.

## Components

| Component | Where it runs from | Replaced by | Disruptive |
| --- | --- | --- | --- |
| Setup app | `/Applications/Micropod Runtime Setup.app` | the helper swap | no |
| Root helper | `BundleProgram` of the setup app's LaunchDaemon `com.skunkworq.micropod.runtime.host` | the helper swap and a launchd relaunch | no (lifecycle control is down for about 10 s) |
| Worker | `RuntimeHost/tools/<sha256>/MicropodRuntimeHost`, a copy of the helper | staging, then the restart | yes |
| Dedicated API and guest tool | `RuntimeHost/tools/<config>/MicropodAPI`, LaunchAgent in `_micropod`'s Background session | staging (pending configuration), then the restart | yes |
| Apple container build | `RuntimeHost/apple/versions/<version>-<package sha>-<incarnation>` | staging (verified payload), then the restart | yes |

`RuntimeHost` is `/Library/Application Support/Micropod/RuntimeHost`. Workers,
API tools and Apple payloads are content-addressed and kept, so the exact
previous bytes of each are on disk for a rollback.

## Payload format

A release carries its runtime components inside the signed desktop app:

```
Micropod.app/Contents/Helpers/Micropod Runtime Setup.app
Micropod.app/Contents/Resources/runtime-components.json
Micropod.app/Contents/Resources/runtime-components.json.sig
```

`runtime-components.json` (schema `micropod-runtime-components-v1`,
`RuntimeComponentManifest`) pins:

| Field | Meaning |
| --- | --- |
| `version`, `sourceRevision` | The release. Each must equal the setup app's `Info.plist`. |
| `componentProtocol` | The update protocol the release needs. A helper refuses a newer protocol before copying anything. |
| `minimumHelperVersion` | The oldest installed helper allowed to install this release itself. |
| `setup.cdhash` | The setup app's code directory hash. It covers every executable and sealed resource in the bundle. |
| `setup.daemonPlistSHA256` | The LaunchDaemon definition inside the bundle. |
| `helper.sha256`, `api.sha256`, `guestSHA256` | The root helper, dedicated API and guest tool executables. |
| `appleRuntime` | The Apple build this release installs (`version`, `packageSHA256`). |
| `appleRuntimes` | Every Apple build this release's helper can verify and manage. It includes the build it installs and the builds it can roll back to. |

`.sig` holds the release key's EdDSA signature over the manifest's exact
bytes. This is the Sparkle key: `SUPublicEDKey`, `SelfUpdate.publicKey` and
`MicropodReleaseSigning.publicKey`, which a test keeps equal.
`scripts/write_runtime_components.sh` writes both files. `make_dmg.sh` runs
it after the setup app's final Developer ID signature and before the outer
bundle is signed, so the outer seal covers them. The release workflow passes
the Sparkle key to that step and fails a signed build that lacks `.sig`. The
script reads `appleRuntime(s)` from the staged helper itself
(`MicropodRuntimeHost --component-probe`), so the manifest cannot disagree
with the binary it describes.

A local build signed with the team certificate has a valid Developer ID
signature but no release signature, so no rig will self-update from it.

### Dedicated API changes

#135 and the dedicated-API changes after it (cancelling unary handlers on
client hangup, template-cloned workspace volumes) ship as the setup app's
`Contents/MacOS/MicropodAPI`. They need no Apple build change. The restart
activates them by switching the API configuration to the new tool directory.

### Runtime data across updates and rollbacks

An update writes only these paths:

- the setup app, and `RuntimeHost/components/`;
- new content-addressed directories under `RuntimeHost/tools/` and
  `RuntimeHost/apple/versions/`;
- the API configuration and its LaunchAgent definition;
- `operation.json` and `component-update.json`.

It never deletes, moves or migrates anything in the dedicated account's
home. That home holds the Apple app root, images and volumes, and the
dedicated API's own state under its Micropod directory: `reclaim/` (#135)
and `volume-templates/` (#177). All of that survives an update and a
rollback unchanged. Pruning touches only `RuntimeHost/components/`.

A rollback can therefore start an older dedicated API over state a newer
one wrote. That is safe only while every on-disk addition is one older
builds ignore. `reclaim/` and `volume-templates/` qualify: older APIs ignore
both, and a newer API sweeps leftover reclaim names at startup. A change
that older builds cannot ignore must say so in its release: raise
`componentProtocol`, and leave out of `appleRuntimes` any build that cannot
run over the new state. That turns the rollback into a refusal instead of a
corruption.

Escape hatches such as `MICROPOD_CANCEL_ON_HANGUP=off` (#176) and
`MICROPOD_VOLUME_TEMPLATES=off` (#177) cannot be set on a rig by editing the
dedicated API's environment. Root generates that LaunchAgent with a fixed
environment, and the next update rewrites it. They need a root-owned,
allowlisted override that root merges into each staged API definition and
that every update carries forward, for example
`RuntimeHost/api-overrides.json` naming only known `MICROPOD_*` switches.
That is a follow-up for those PRs; this update path neither adds nor drops
such a file.

### Apple container builds, including a patched one

The helper's compiled-in release table (`AppleRuntimeRelease`) is the only
list of builds the helper will install. No request, feed or manifest can add
one. Each entry names a complete payload: package URL, size and SHA-256, the
installer's signing team, and the SHA-256 of every payload file, including
`container-apiserver`, `container-runtime-linux` and the plugins. One
selection is one whole tree under `apple/versions/`, so the apiserver,
runtime and plugins always move in lockstep.

A patched build (for example apple/container tag 1.5.0 at d265d669, with
containerization 0.47.0) becomes a second table entry:

- It keeps `version` `1.5.0` and has its own `packageSHA256`. Selections are
  keyed by version and package digest, so its install root differs from
  Apple's.
- It has its own payload SHA-256 manifest.
- Its installer is signed by Micropod's team, not Apple's `UPBK2H6LZM`.
- Its package is a castlemilk/micropod release asset whose URL and digest
  are compiled into the table.

Today the table has one entry, `supported`, and the installer checks Apple's
signer. Generalising both to a list belongs to the change that adds the
patched build. `RuntimeComponentProbe.current` is the one place that reports
the table, so adding an entry there is enough for this update path to carry
it.

The **n-1 rule:** a release's `appleRuntimes` must include the build it
replaces. The installed helper refuses a release whose helper cannot manage
the Apple build in use now, because that helper could neither verify the
running runtime nor roll back to it. On-disk formats are unchanged between
Apple's 1.5.0 and the patched build, so a rollback to Apple's build is an
ordinary restart onto its retained payload.

**Cuttlefish** pins the Apple build it schedules onto. It checks version
`1.5.0` and Apple's package digest at the drain, on readiness and in the
executor. A Cuttlefish release whose qualified-build set lists the patched
digest must ship before a Micropod release installs that build. API-only
updates need no Cuttlefish change.

## Trust: what the root helper checks

The helper trusts only what it holds in memory or has copied somewhere only
root can write. It checks in this order:

1. **Source.** It reads the source from the fixed path
   `/Applications/Micropod.app`. No request names a path, URL, bundle or
   digest.
2. **Manifest signature.** It reads the manifest and signature with bounded
   no-follow reads and verifies the signature against the compiled-in
   release key. It decodes and validates the manifest only after that.
3. **Version.** The target must be newer than the installed helper, and the
   installed helper must be at least `minimumHelperVersion`. The only way
   back to older bytes is a rollback to bytes root itself retained.
4. **n-1.** The target's `appleRuntimes` must include the selection in use.
5. **Copy.** It copies the setup app with `ditto` into
   `RuntimeHost/components/<operation>/new/` (mode 0700) and makes the copy
   root-owned. Every later check runs on the copy, so nothing can change it
   between the check and the swap.
6. **Code signature.** The copy must be:
   - Developer ID from team `WFTX6CN23F`;
   - the identifier `com.skunkworq.micropod.runtime-setup`, with the helper
     and API executables signed under their own identifiers;
   - strictly valid with nested code (`kSecCSStrictValidate |
     kSecCSCheckNestedCode`);
   - **notarized** (`notarized` in the code requirement). The DMG's ticket
     covers nested code; an unstapled copy is looked up online, and an
     offline check refuses with nothing changed.
7. **Digests.** The copy's CDHash, executable digests, daemon plist digest,
   version and revision must all equal the manifest's.
8. **Launchd definition.** The new daemon definition must equal the
   installed one, compared by content. A release that changes it would need
   a new administrator approval, so self-update refuses it and Runtime Setup
   installs it instead.
9. **Probe.** The installed helper runs the staged helper with
   `--component-probe`. The probe must report the same version, component
   protocol and runtime schema, and an Apple table that manages the build in
   use. This proves the new binary loads and runs on this Mac before
   anything is swapped.

## Administrator approval: once

The LaunchDaemon was registered through `SMAppService` from
`/Applications/Micropod Runtime Setup.app`, and an administrator approved it
once. That approval is bound to the team, the bundle identifier and the
daemon definition.

A self-update keeps all three: same path, same team and identifier,
byte-identical definition. The helper swaps the bundle and then exits with
`EX_TEMPFAIL` (75). launchd's `KeepAlive {SuccessfulExit: false}` restarts the
job after its 10 s throttle, from the bundle that is installed now. No
`launchctl`, `sudo` or approval is involved: the already-approved root
helper updates itself after verifying a signed payload.

The first update from a helper older than component protocol 1 is the one
exception, because that helper cannot update itself:

1. `micropod runtime update --bootstrap` checks, as the user, what the root
   helper later checks again: the release signature, notarization, CDHash
   and an unchanged launchd definition. It also checks that the old helper
   holds nothing (the "Pause Helper for Update" conditions). It then
   exchanges the setup app in `/Applications` atomically and keeps the
   previous bundle under `~/.micropod/runtime-setup/`. App Management lets a
   process signed by Micropod's team update Micropod's app.
2. The administrator runs one command:
   `sudo launchctl kickstart -k system/com.skunkworq.micropod.runtime.host`.
   launchd restarts the approved job from the new bundle.
3. `micropod runtime update` finishes unattended, as below.

## The operation

A component update has two halves.

### 1. Helper swap: unfenced and undrained

The dedicated API and the Apple apiserver are separate launchd jobs in
`_micropod`'s domain. Replacing the helper does not touch them; earlier
qualification showed a helper and app replacement preserving the API process
and an active container. For about 10 s nothing can start or stop the
runtime and session renewals fail and are retried. No job is drained or
interrupted. The swap therefore takes no admission fence and asks Cuttlefish
for nothing, and its journal has nothing to hand off.

It is journaled in `RuntimeHost/component-update.json`
(`RuntimeComponentUpdateRecord`), never in `operation.json`. Every helper,
including one rolled back to, must always be able to read the runtime
operation journal.

| Phase | What happens | Changed so far |
| --- | --- | --- |
| `staging` | Copy, verify and probe, as above. | nothing |
| `swapping` | Intent recorded, then `renamex_np(RENAME_SWAP)` exchanges the staged copy with the installed bundle. The displaced bundle becomes `components/<operation>/previous/`. | the setup app |
| `relaunching` | The helper exits. Each launch of the target counts. | |
| `helperReady` | The target serves (controller and both listeners started) and confirms itself. | |

### 2. Runtime follow-up: an ordinary coordinated restart

The new helper starts a `restart` operation that first stages its own
components. It is the existing operation with one step added before it, and
it reuses the existing handshake, journal and recovery unchanged:

```
stagingComponents   worker copy, pending API configuration, verified Apple payload
                    (nothing running changes; data sessions keep renewing)
draining            Cuttlefish drain (bounded, preemption after its grace)
fence               RuntimeAdmission.begin, which retires dead receipts (#132)
prepare, begin      signed scheduler fence; action intent recorded
stop                apiserver and dedicated API stop
activate            pending API configuration and Apple selection become current
start, verify       exact native version, roots and install root
complete            signed release; Cuttlefish reopens intake
```

On the wire this is a `restart` (`RuntimeCoordinationOperation.action`,
`targetState` `running`). Its `version`, `packageSHA256` and `installRoot`
are the target selection's. A Cuttlefish agent already accepts it and
identifies the helper by its signing identity, not its path or CDHash. The
generation is issued when the operation starts (#133). A first drain the
coordinator never recorded settles as failed (#133, Cuttlefish #958).

The update follows the restart's outcome. `completed` means the runtime
restarted onto the new components. A restart that ended before its action
(refused, timed out, or not recorded) ends the update `helperUpdated`: the
helper is new, the runtime runs its previous API and Apple build (n-1
guarantees the new helper manages them), and the next `micropod runtime
update` restarts only the runtime. A restart in `recoveryRequired` keeps the
update `restarting` until `micropod runtime recover` settles the restart, as
it would any restart.

## Crash and partial states

Every step is idempotent by inspection: which bundle is installed (CDHash),
which helper is running (its executable digest, proved to be the running
image), and what the journals say. Remembered progress is never trusted.
`RuntimeComponentUpdater.launch()` runs at every helper start, before the
controller reads `operation.json`.

| What happened | What settles it | Ends |
| --- | --- | --- |
| The CLI lost the helper's reply | The CLI keeps the operation ID in `~/.micropod/runtime-component-update.json` and sends the same ID again. The helper answers a known ID with its status and refuses a replayed one once it is in history. | the same update, once |
| Helper killed while staging | Next launch: `staging` | `refused`, nothing changed |
| Killed after recording `swapping` but before `renamex_np` | The source is installed and running | `refused`, nothing changed |
| Killed between `renamex_np` and moving the displaced bundle aside | `renamex_np` changes both names or neither. launchd starts the target; launch finds the source bytes at the staging path and keeps them as `previous`. | continues |
| The new helper crashes before it serves (dyld, controller init, listener) | Each launch increments `targetLaunches` before anything that could crash. The fourth launch swaps the retained previous bytes back, verified by CDHash, and exits. The previous helper settles. | `rolledBack`, exact previous bytes |
| Killed during that rollback swap | Inspection redoes or finishes it | `rolledBack` |
| Killed while staging runtime components | `stagingComponents` precedes the generation, drain and fence, so the next launch settles the restart as cancelled instead of `recoveryRequired` | `helperUpdated` |
| Stale admission receipts (Gamma-128's 167) | The restart's fence retires provably dead receipts (#132) | continues |
| Coordinator refuses the first drain before recording it | The restart settles as failed with no handoff retained (#133) | `helperUpdated` |
| Drain times out, or Cuttlefish refuses (`blocked`) | Two-stage abort, runtime unchanged | `helperUpdated` |
| A pending admission blocks the scheduler close | Cuttlefish #960 skips admissions that never leased | continues |
| The restart's completion reply is lost | The restart is `recoveryRequired` with admission open. `micropod runtime recover` verifies and completes it without replaying the start. | `completed` |
| Action began and its outcome is unknown | Existing recovery: verify, never replay | `completed`, once verified |

Every component update phase holds nothing that another party waits on. The
helper swap holds no fence and no drain. The restart holds only what any
restart holds, and the fixes above settle its recovery. The update record
is terminal whenever its restart is terminal, and no outcome needs a
journal edited by hand.

**One gap remains.** Suppose a target Apple build cannot start after the
restart's `begin`, and verification positively observes the runtime
`stopped`. The restart then stays `recoveryRequired` with rig intake held.
The coordinator contract releases an operation only as its target state or
as cancelled before its action. Holding intake is correct, because the
runtime is not serving. Settling it needs the "stopped release" contract
addition (below), after which the helper releases the restart as `stopped`
and rolls back with a new coordinated start onto the retained build.
API-only updates do not hit this gap.

## Rig upgrades chain it

`micropod update apply --disruptive` runs as before. When it completes on a
host with the dedicated runtime, the CLI asks the root helper to follow the
new app and follows that update to its end. This happens in both the
launchd rig-upgrade helper (`--detach`) and a following `apply`, using the
same pending operation, so it is never repeated. The command exits 0 only
when both complete.

The runtime update runs after the rig upgrade for two reasons:

- Its source is the installed app.
- Cuttlefish refuses a dedicated-runtime `prepare` while a rig-upgrade drain
  holds the rig.

The cost is a second drain: jobs leased in the seconds between the two are
preempted with `maintenance_preempted` and keep their retry budget. Holding
one drain across both would need a Cuttlefish change that lets the
rig-upgrade drain cover a runtime handoff. That is a possible follow-up.

## Rollback

- **Automatic.** A target helper that never serves is swapped back, as
  described in the crash table.
- **Explicit.** `micropod runtime update --rollback` runs the same
  machinery. Its target is the root-retained `previous` bundle, copied and
  checked by CDHash, with no version check. The previous helper starts, and
  its own coordinated restart re-stages its worker, API and Apple build.
  These are content-addressed under `tools/` and `apple/versions/`, so they
  are the exact previous bytes.

## Cuttlefish

- **Wire contract.** Unchanged: the runtime half is a `restart`, and the
  helper's identity is its signature.
- **Qualified Apple builds.** The agent compares against a set instead of
  one digest, so adding the patched build is a one-line change. This is in
  the Cuttlefish PR paired with this one.
- **Stopped release.** Contract addition, proposed and in the paired
  Cuttlefish PR. A `start` or `restart` whose action began and whose runtime
  is verified `stopped` may be released with kind `stopped`. Intake stays
  closed, since a stopped release never reopens it, and the next operation
  starts from a clean resource. Rollout order: control plane, then agent,
  then a Micropod release that sends it. An older agent refuses the call as
  invalid, which leaves today's behaviour.

## Commands

```sh
micropod runtime update              # follow the installed app's release
micropod runtime update --detach     # request it and return
micropod runtime update --rollback   # restore the retained previous components
micropod runtime update --bootstrap  # once, for a helper older than protocol 1
micropod runtime operation --json    # componentUpdate and the restart it runs
```

## Tests

- `RuntimeComponentUpdateTests` (HostKit) use real directories and real
  `renamex_np`. They replay:
  - a kill before the swap and a kill mid-swap;
  - a crash-looping target that rolls back to the exact previous bytes, and
    an interrupted rollback;
  - a manifest not signed by the release key;
  - a bundle that does not match its manifest;
  - a changed launchd definition;
  - a downgrade, a lost reply, a replayed ID and an unmanageable Apple
    build;
  - an explicit rollback.
- `ScopedRuntimeHostControllerTests` (signed coordinator fixture):
  - the full update: swap, relaunch, then drain, prepare, begin, verify and
    complete;
  - a coordinator refusal (`notRecorded`) that settles `helperUpdated`,
    followed by a runtime-only retry;
  - a lost restart completion that `recover` settles;
  - stale old-format receipts retired by the restart;
  - a helper killed while staging.
- `RuntimeComponentManifestTests` cover signatures, tampering, protocol,
  malformed manifests and a two-build table. `RuntimeComponentUpdateClientTests`
  cover a lost reply resent under the same ID, a rerun resuming the pending
  operation, a legacy helper and following through a relaunch.

These are source tests. A physical qualification is still required: a
notarized release candidate updating a rig helper and its runtime under a
live Cuttlefish drain, including the 10 s helper relaunch and a reboot
during `relaunching`.
