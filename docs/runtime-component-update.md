# Runtime component updates

`micropod runtime update` replaces the dedicated runtime's privileged
components on a rig host: the setup app, the root helper, the dedicated API
and the pinned Apple container build. It is signed, needs no administrator
prompt after a one-time re-registration, and runs as a coordinated lifecycle operation
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
| `version`, `sourceRevision` | The release. Each must equal the setup app's `Info.plist` and the carrying desktop app's, so a manifest replayed into another release is refused. |
| `componentProtocol` | The update protocol the release needs. A helper refuses a newer protocol before copying anything. |
| `minimumHelperVersion` | The oldest installed helper allowed to install this release itself. |
| `securityFloor` | Optional. Once a host installs this release, root refuses to install or roll back to anything older. |
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
the Sparkle key to that step and fails a signed build that lacks `.sig`.
`sign_update` comes from a Sparkle archive whose SHA-256 is pinned
(`scripts/verify_sparkle_tools.sh`), because it is handed the release key.
The script reads `appleRuntime(s)` and the release from the staged helper
itself (`MicropodRuntimeHost --component-probe` reports the compiled-in
`MicropodBuildInfo`), so the manifest cannot disagree with the binary it
describes.

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
- `operation.json`, `component-update.json` and `component-state.json`.

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

`/Applications` is `root:admin 0775`, so any admin-group process can rename
an entry in it and put another in its place, whoever owns that entry. The
installed setup app is therefore never trusted for what it contains. The
helper trusts:

- what it holds in memory and has verified;
- **sealed copies** in `RuntimeHost/components/<operation>/`, a root-only
  directory.

A sealed copy (`RuntimeSecureCopy`) is made like this:

1. The source tree is first walked without following or opening anything.
   Only directories and regular files are accepted (no FIFO, link or
   device), and the tree is capped at 512 entries and 1 GiB.
2. It is copied with `ditto --noacl --noextattr --norsrc --noqtn`.
3. Every entry is stripped of file flags, ACLs, extended attributes and
   setuid, setgid and sticky bits. It is set to `root:wheel`, with 0755 for
   directories and executables and 0644 for everything else.
4. The copy is walked again to prove it:
   - every entry is root-owned with no group or world write;
   - there are no flags, ACL entries or extended attributes, except the
     system's `com.apple.provenance`;
   - every regular file has a single link.

Only a proven copy is verified, swapped into place, or used as a source for
anything root installs. Removal clears flags first, so an immutable entry
cannot leave a copy behind.

The update checks in this order:

1. **Source.** The fixed path `/Applications/Micropod.app`. No request names
   a path, URL, bundle or digest. Files there are read with bounded,
   non-blocking, no-follow reads that refuse anything but a regular file, so
   a planted FIFO cannot wedge the helper.
2. **Manifest signature.** The helper verifies the EdDSA signature over the
   bytes it holds, against the compiled-in release key, then validates the
   manifest. It must name the desktop app's own release.
3. **Version.** The current release is the running helper's **compiled-in**
   `MicropodBuildInfo`, never a plist in a writable bundle. A helper whose
   release does not parse (a local `dev` build) refuses every update.
   - The target must be newer than the running release, and at least
     root's high-water mark (`component-state.json`, the highest release
     this host ran).
   - It must also be at least the highest signed `securityFloor` root has
     installed.
4. **n-1.** The target's `appleRuntimes` must include the selection in use.
5. **Sealed copy** of the offered setup app into `new/`.
6. **Code signature** of the copy:
   - Developer ID Application from team `WFTX6CN23F`: the Developer ID CA
     and leaf certificate markers are required, so an Apple Development
     certificate with the same team does not pass;
   - the setup, helper (`com.skunkworq.micropod.runtime-authority`) and API
     identifiers;
   - strict validation with nested code;
   - notarization (the `notarized` requirement; an offline check refuses
     with nothing changed).
7. **Digests.** The copy's CDHash, executable digests, daemon plist digest,
   version and revision must equal the manifest's.
8. **Launchd definition.** The target's definition must equal the one root
   last approved (`approvedDefinitionSHA256` in `component-state.json`), not
   the plist in the installed bundle, which another process may have edited.
   A release that changes the definition needs Runtime Setup and a new
   approval.
9. **Probe.** The installed helper runs the staged copy with
   `--component-probe`. The copy must report the same compiled-in release,
   component protocol and runtime schema, and an Apple table that manages
   the build in use.
10. **Verified copy.** A second sealed copy, `verified/`, is checked against
    the target and kept in root's directory. The worker, dedicated API and
    guest tool are installed **only from it**, each copied into a root-owned
    temporary file. Only that copy is hashed and compared with the target's
    digests. The bundle that is swapped into `/Applications` is never read
    again.

The same applies to `install` and `repair`: they stage from a sealed copy of
the running helper's own bundle, never from `/Applications`.

## What launchd and BTM verify when they spawn the helper

The daemon is registered with `SMAppService.daemon` from
`/Applications/Micropod Runtime Setup.app`. launchd execs
`Contents/MacOS/MicropodRuntimeHost` from that path (`BundleProgram`).

- **Without a SpawnConstraint**, which is how every release before this one
  was built, launchd checks only that the executable passes the system's
  code-signing policy at exec. It does **not** require it to come from the
  registering team. Any process that can replace that file, or rename the
  bundle and substitute its own, gets its code run as root at the next
  relaunch or reboot. The setup app used to be copied in as the user, which
  made that easy.
- **With this release's definition**, launchd checks a launch constraint
  at every spawn: `SpawnConstraint` = {`team-identifier`: `WFTX6CN23F`,
  `signing-identifier`: `com.skunkworq.micropod.runtime-authority`}. It
  refuses to spawn anything else, including an earlier helper build, because
  the signing identifier was rotated from `com.skunkworq.micropod.runtime.host`
  in this same release. A Micropod helper from this release or later still
  satisfies the constraint. Against those, the update applies the
  high-water mark and the signed security floor, and the helper re-seats a
  sealed copy as soon as it runs (see below).
- **BTM** (Background Task Management) records the item by the app's team
  and bundle identifier, and an administrator approved it once in Login
  Items.
  - A swap of the bundle at the same path, same team and identifier, with an
    unchanged definition, should keep that approval.
  - A changed definition is applied only by a new registration (unregister,
    then register), which asks for approval again.
  - Both behaviours are on the VM test plan below. Neither is assumed.

The helper also re-seats itself. At every start, if the installed setup app
is not a sealed root-owned copy, the helper does the following without
restarting the runtime:

1. It plans an update against the installed desktop app's signed manifest,
   which must name exactly the running helper.
2. It makes a sealed copy of those verified bytes.
3. It swaps the copy into place.

This covers:

- the first helper launched after a user-level install or after
  `--bootstrap`;
- a bundle another process replaced with the same helper bytes.

The install is therefore root-owned from the helper's first launch. It
cannot be root-owned earlier: before approval there is no root process to
install it.

### VM test plan

Run on a macOS 26 VM with SIP on, the production team's Developer ID, and an
admin-group user without sudo:

1. **Baseline.** Install a release with the SpawnConstraint and approve it.
   - `launchctl print system/com.skunkworq.micropod.runtime.host` shows the
     constraint.
   - `micropod runtime operation --json` reports `componentProtocol` 1.
   - `ls -le@O` on the installed bundle shows root ownership, no ACL and no
     flags after the first start.
2. **Ad-hoc binary.**
   - As the admin user, rename the bundle away and put back a copy whose
     `MicropodRuntimeHost` is an ad-hoc-signed binary that writes a marker
     file.
   - Reboot, then also trigger an on-demand launch through the Mach
     service.
   - Expect a launch-constraint violation in the unified log and no marker.
3. **Another team's binary.** As in step 2, with a binary signed by a
   different Developer ID team. Expect the spawn to be refused.
4. **Older helper.** As in step 2, with a genuine earlier helper (team
   `WFTX6CN23F`, identifier `com.skunkworq.micropod.runtime.host`). Expect
   the spawn to be refused because of the identifier.
5. **Older protocol-1 helper.** A genuine earlier build of this generation
   (same identifier) is spawned. Record that it runs, and that the next
   `micropod runtime update` refuses to go below the high-water mark and
   restores the newest release. That is the residual surface; a CDHash
   allowlist constraint would close it.
6. **Approval persistence.**
   - A self-update swap with an unchanged definition shows no new approval
     prompt, and the helper starts after a reboot.
   - `--bootstrap` re-registration with a changed definition shows exactly
     one prompt.
   - Editing the plist inside the installed bundle (as root, in the VM) and
     rebooting shows whether launchd re-reads it or BTM keeps the registered
     definition. The result decides how far the root-held approved
     definition must go.
7. **Sealed copies.** Plant an ACL, an extended attribute, `uchg` and a
   setuid bit in the offered bundle, and a FIFO next to the manifest. The
   update refuses the FIFO without hanging. After removing the FIFO, the
   installed bundle and `RuntimeHost/components/*` show none of the planted
   attributes.
8. **Crash loop and hang.**
   - A test target that exits at once is swapped back after three launches.
   - One that hangs before serving is exited by the 120 s watchdog three
     times and then swapped back.

## Administrator approval: once

The self-update itself never asks for approval. The approved helper swaps
its own bundle and exits with `EX_TEMPFAIL` (75); launchd's
`KeepAlive {SuccessfulExit: false}` starts the bundle installed now. No
`launchctl` or `sudo` is involved.

This release is the one exception: it adds the SpawnConstraint and rotates
the helper's identifier, which changes the daemon's definition. A helper
older than component protocol 1 cannot update itself either. So, once:

1. `micropod runtime update --bootstrap` checks, as the user:
   - the release signature, notarization and CDHash;
   - that the old helper holds nothing, both before and again immediately
     before the bundle changes.

   It then exchanges the setup app in `/Applications` and keeps the previous
   bundle under `~/.micropod/runtime-setup/`.
2. It opens Runtime Setup with `--reregister`. Runtime Setup checks the old
   helper is idle again, unregisters the daemon and registers it with the
   new definition. **macOS asks an administrator to approve it once, in
   Login Items.** There is no `sudo`.
3. The new helper starts, re-seats itself as a sealed root-owned copy
   verified against the signed manifest, and serves.
   `micropod runtime update` then restarts the runtime onto it.

The Cuttlefish agent must accept the new identifier before step 2:
skunkworq/cuttlefish#966. An older agent refuses the new helper's
maintenance calls and its proofs.

## The operation

### 1. Helper swap: unfenced and undrained

The dedicated API and the Apple apiserver are separate launchd jobs in
`_micropod`'s domain; replacing the helper does not touch them. For about
10 s nothing can start or stop the runtime, and session renewals fail and
are retried. No job is drained or interrupted.

| Phase | What happens | Changed so far |
| --- | --- | --- |
| `staging` | Sealed copy, verification, probe, verified copy | nothing |
| `swapping` | Intent recorded, then `renamex_np(RENAME_SWAP)` exchanges the staged copy with the installed bundle. The displaced bundle is moved into `previous/`, **unread**. | the setup app |
| `relaunching` | The helper exits. Each launch of the target is counted before anything that could fail, and a 120 s watchdog exits a helper that has not confirmed itself. | |
| `helperReady` | The target serves and has confirmed itself. Root raises the high-water mark, the security floor and the approved definition. | |

A **re-seat** (the running helper already is the release) swaps in a sealed
copy of the same bytes and goes straight to `helperReady` with no relaunch.

### 2. Runtime follow-up: an ordinary coordinated restart

The new helper starts a `restart`. Before draining, it:

1. **stages** its worker, pending API configuration and Apple payload from
   the verified copy, and refuses any bytes other than the target's;
2. **asks the coordinator whether it qualifies the build** (`qualify`). An
   unqualified build ends the restart before anything is drained, and the
   update becomes `helperUpdated`.

It then runs the existing handshake: drain, fence (retiring dead receipts,
#132), prepare, begin, stop, activate, start, verify, complete. On the wire
it is a `restart` of the target selection. `completed` stands only if the
runtime then runs exactly the target's worker and API (by digest).
Otherwise the update ends `recoveryRequired`.

Two cases change what happens:

- **The operator stopped the runtime.** It stays stopped: the update ends
  `helperUpdated` with that reason.
- **The runtime was released as stopped (below).** Only an explicit `start`
  resumes it.

## Crash and partial states

The update judges every state by inspection: which helper executable is
installed and which is running (both by digest), and the journals. It never
relies on remembered progress.

| What happened | What settles it | Ends |
| --- | --- | --- |
| The CLI lost the helper's reply | The same operation ID is resent; a replayed ID is refused once in history | the same update, once |
| Killed while staging, or before `renamex_np` | The source is installed and running | `refused`, nothing changed |
| Killed between `renamex_np` and moving the displaced bundle aside | launchd starts the target; launch moves the displaced bundle aside unread | continues |
| The target crashes or hangs before it serves | Launch counter and watchdog. The fourth launch swaps back a sealed, verified copy of the previous bytes. | `rolledBack` |
| Killed during that rollback swap | Inspection redoes or finishes it | `rolledBack` |
| Killed while staging runtime components | The restart is settled as cancelled at launch | `helperUpdated` |
| Stale admission receipts | Retired by the restart's fence (#132) | continues |
| The agent does not qualify the build | `qualify` → notRecorded; nothing drained | `helperUpdated` |
| An older agent refuses the first drain (`refused`) | Treated as never recorded: the restart fails with nothing held | `helperUpdated` |
| The coordinator refuses the first drain (`notRecorded`) | #133 | `helperUpdated` |
| Drain timeout or `blocked` | Two-stage abort | `helperUpdated` |
| The restart's completion reply is lost | `micropod runtime recover` completes it without replaying the start | `completed` |
| The restart completed onto other bytes | Digest check | `recoveryRequired` |
| An undecodable `component-update.json` | Read leniently: only `update` is refused; lifecycle and `recover` run | — |

**Remaining manual cases.** The table above settles every coordination
fault. Two outcomes are deliberately left to an operator, because the rig
must not take work while they hold:

- **A target that cannot come up after `begin`.** The runtime is verified
  `stopped`. Releasing it as `stopped` keeps intake paused and lets
  `--rollback` restart the previous runtime with an explicit start. That
  needs the stopped release, which ships in two phases (below). Until
  phase 2, the restart stays in `recoveryRequired` with intake held, as any
  restart does today.
- **A restart that completed onto other bytes, or a helper that is neither
  release.** The update ends `recoveryRequired` and nothing more is run.

## Rig upgrades chain it

`micropod update apply --disruptive` requests the runtime update after a
completed app upgrade on a dedicated-runtime host, and follows it. It runs
afterwards because its source is the installed app, and because Cuttlefish
refuses a dedicated `prepare` while a rig-upgrade drain holds the rig. On a
helper that cannot update itself, the app upgrade still reports success and
names `--bootstrap`.

## Rollback

- **Automatic.** A target that never serves is swapped back, from a sealed,
  verified copy of the retained bytes. The retained path is never verified
  or run in place.
- **Explicit:** `micropod runtime update --rollback`.
  - It is refused below the signed security floor. Root never lowers the
    high-water mark, so the newest release can always be reinstalled.
  - If the update's restart moved the runtime, the **current** helper first
    restarts the runtime onto the retained previous selection, worker and
    API (`restoringRuntime`). Each is content-addressed and checked by
    digest. Then the helper is swapped back.
  - The previous helper then finds its own runtime and restarts nothing.
  - This also covers a release that changed the Apple build, which the
    previous helper could not manage. Doing it the other way round, previous
    helper first, would leave a runtime that helper cannot verify.

## Cuttlefish (skunkworq/cuttlefish#966)

- **Qualified builds.** The agent checks a qualified set of Apple builds,
  not one digest.
  - A patched build is one entry, in an agent release that ships first.
  - The coordinator judges the build itself:
    - `qualify` answers whether it qualifies a build;
    - a drain of an unqualified build is `notRecorded`, with nothing
      recorded;
    - a prepare of a no-longer-qualified build is blocked;
    - abort, release and status are never refused for the build.
  - This removes the deadlock in which every call, abort included, was
    refused for the build.
- **Helper identifiers.** It accepts both `com.skunkworq.micropod.runtime-authority`
  and the legacy `com.skunkworq.micropod.runtime.host`.
- **Stopped release, in two phases.** A control plane that does not know the
  kind refuses every later transition of a resource that carries it.
  - **Phase 1 (#966).** Every reader tolerates a stored stopped release of a
    start; nothing produces one.
  - **Phase 2.** Producing it is turned on once every control plane that
    can serve the fleet is at phase 1.
  - **No-rollback floor.** Once phase 2 is live, the control plane must not
    roll back below phase 1.
  - Micropod sends the release, and an agent before phase 2 refuses it as
    invalid. That leaves today's behaviour.
- **Rollout order.**
  1. The control plane with #966.
  2. Agents with #966, before any Micropod release with the rotated
     identifier runs on a rig.
  3. Micropod.

## Commands

```sh
micropod runtime update              # follow the installed app's release
micropod runtime update --detach     # request it and return
micropod runtime update --rollback   # restore the retained previous components
micropod runtime update --bootstrap  # once: re-register a helper older than protocol 1
micropod runtime operation --json    # componentUpdate and the restart it runs
```

## Security review (2026-11-19): fixed and deferred

Fixed, each with a regression test:

- **Pre-existing: a user-owned setup app could be replaced to get root.**
  Fixed by the SpawnConstraint, the identifier rotation and the re-seat
  from the first launch.
- **H1: copies kept ACLs, flags and extended attributes.** Fixed by sealed
  copies.
- **H2: the runtime was staged from `/Applications`, and digests were not
  enforced.** It is now staged only from the verified copy; digests are
  enforced at staging and at completion; `helperReady` re-verifies.
- **H3: the qualification deadlock.** Fixed in the agent and the helper.
- **H4: the bootstrap ran an unchecked bundle as root.** The re-seat
  verifies it, and the bootstrap re-checks status before it changes
  anything.
- **M1 through M9:**
  - the version comes from the compiled-in release and a root-held
    high-water mark;
  - the signed security floor is enforced;
  - reads are non-blocking and planning runs off the actor;
  - rollback uses sealed copies;
  - launches are counted first, with a watchdog;
  - the journal is read leniently;
  - rollback restores the runtime first;
  - the stopped release ships in two phases;
  - a deliberately stopped runtime stays stopped.
- **Low-severity fixes:**
  - L1: Developer ID markers in code requirements;
  - L2: the manifest is bound to the carrying release, with the high-water
    mark;
  - L3: size caps, and flag clearing before removal;
  - L4: the approved definition is root-held;
  - L5: launch decides by the helper executable;
  - L6: identity and enrollment files are not rewritten when unchanged;
  - L7: `sign_update` is pinned;
  - L8: legacy-helper rigs no longer fail `update apply`;
  - L9: an unconfirmed helper is exited by the watchdog and counted;
  - L10: no force unwrap;
  - L11: the agent's qualified set is unexported.

Deferred:

- **L3:** pruning old `apple/versions/` incarnations. Each update stages a
  new incarnation, about 500 MB. Pruning needs the runtime's own selection
  and the rollback target retained, and belongs with the patched-build
  table.
- **A launch-time floor** for genuine protocol-1 helpers older than the
  security floor (VM plan, step 5). A CDHash-pinned SpawnConstraint would
  close it, at the cost of a re-registration per release.
- **The VM test plan above.** It needs the production signing identity and
  a VM; none of it was run here.

## Tests

- **`RuntimeSecureCopyTests`:** a pre-planted ACL, extended attribute, flag
  and setuid bit are stripped and proved gone; an ACL added after the copy
  is caught; FIFOs, links and oversized trees are refused before copying;
  immutable leftovers are removed.
- **`RuntimeComponentUpdateTests`** (real directories, real `renamex_np`,
  the real secure copy):
  - kill before, mid and after the swap;
  - a crash-looping target rolled back from a sealed copy, never in place;
  - an interrupted rollback;
  - a forged manifest, a replayed manifest, and a mismatched bundle;
  - planted ACLs, attributes and flags;
  - a definition edited in the installed plist, refused against root's
    approved definition;
  - the compiled-in version and high-water mark;
  - the security floor;
  - a re-seat without relaunch;
  - verified-copy tampering;
  - completion on other bytes;
  - a FIFO;
  - an unreadable journal;
  - rollback, and the restore-first plan.
- **`ScopedRuntimeHostControllerTests`** (signed coordinator fixture):
  - the full update, with `qualify` before the drain;
  - a `notRecorded` drain;
  - a lost completion;
  - stale receipts;
  - a kill during staging;
  - an unqualified build refused as `refused` at the drain (the deadlock,
    replayed) and settled;
  - an unqualified build never drained;
  - tampered staging refused before the drain;
  - rollback restoring the runtime, then the helper;
  - a deliberately stopped runtime left stopped;
  - an unreadable journal blocking only `update`;
  - an unsealed bundle re-seated at launch;
  - the stopped-release path, and the rollback after it.
- **Cuttlefish (#966):** the unqualified drain is `notRecorded` and an abort
  is never refused for the build; phase 1 tolerates a stored stopped
  release and never produces one; the qualified set.

These are source tests. A physical qualification is still required.
