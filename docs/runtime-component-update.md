# Runtime component updates

`micropod runtime update` replaces the dedicated runtime's privileged
components on a rig host: the setup app, the root helper, the dedicated API
and the pinned Apple container build. It is signed, needs no administrator
prompt after a one-time `sudo micropod runtime install-authority`, and runs as a coordinated lifecycle operation
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
| Authority bundle | `RuntimeHost/authority/current/Micropod Runtime Setup.app`, a sealed root-owned copy | the helper swap | no |
| Root helper | `Program` of the root-owned LaunchDaemon `/Library/LaunchDaemons/com.skunkworq.micropod.runtime.authority.plist` | the helper swap and a launchd relaunch | no (lifecycle control is down for about 10 s) |
| Runtime Setup app | `/Applications/Micropod Runtime Setup.app`: unprivileged UI. Nothing in it runs as root once the authority is installed | the desktop app | no |
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

## The authority: where the root helper runs

The root helper is a classic LaunchDaemon. Its plist and its program sit
where only root can write:

```
/Library/LaunchDaemons/com.skunkworq.micropod.runtime.authority.plist   root:wheel 0644
  Program = /Library/Application Support/Micropod/RuntimeHost/authority/current/
            Micropod Runtime Setup.app/Contents/MacOS/MicropodRuntimeHost
  MachServices = com.skunkworq.micropod.runtime.authority
  SpawnConstraint = { team-identifier WFTX6CN23F,
                      signing-identifier com.skunkworq.micropod.runtime-authority,
                      validation-category 6 (Developer ID) }
```

- Every ancestor of both the plist and the program is root-owned, with no
  group or other write, no ACL and no symbolic link. On a stock Mac this holds
  for `/Library` (root:wheel 0755) and for `/Library/LaunchDaemons`,
  `/Library/Application Support` and `RuntimeHost` (root 0755).
- The program's bundle is a sealed copy (below).
- The definition is compiled into the helper (`RuntimeAuthority.definition`),
  so it is never read back from a bundle another account can change.
- The SpawnConstraint is defence in depth. The protection rests on file
  ownership, not on launchd behaviour that can't be proven.
- `/Applications/Micropod Runtime Setup.app` is no longer on the root path. It
  is the unprivileged Runtime Setup UI.

The earlier SMAppService design ran the helper from the bundle in
`/Applications`. That directory is `root:admin 0775`, so any admin-group
process could rename the bundle and put another one in its place, including
an older genuine one, or one whose plist had its constraint stripped. Whether
launchd re-reads that plist, or keeps the definition it took at registration,
was never proven. This design does not depend on either.

### Checked at every start

The helper checks itself before it serves, and again on every update and
rollback (`RuntimeAuthority.protection`). All of these must hold:

1. Its own executable is exactly the authority program.
2. The plist, the program, and every ancestor of each, are root-owned, with
   no group or other write, no ACL and no symbolic link (lstat only).
3. The program's bundle is a sealed copy.
4. The plist on disk is exactly the definition this helper was built with,
   compared canonically. A plist with its constraint removed fails.
5. `launchctl print system/com.skunkworq.micropod.runtime.authority`, run
   as root and read-only, reports that program, loaded from that plist. If
   the output can't be read, the check fails.

Status reports `componentProtection`: either `protected` or
`unprotected: <reason>`. An unprotected helper still serves the runtime, but
refuses every component update and rollback until
`sudo micropod runtime install-authority` repairs it.

### Installing the authority (one administrator step)

The trust anchor is the binary the administrator runs under `sudo`. A
`micropod` the user can write could be swapped before sudo runs it, so the
procedure runs **the release's own CLI from the downloaded tarball**, after
checking it:

```sh
tar -xzf Micropod.<version>.tgz && cd <dir>
codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "WFTX6CN23F" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' ./micropod
sudo ./micropod runtime install-authority --app ./Micropod.app
```

Running as root, `install-authority` checks itself and the release before it
changes anything:

1. **Its own path.** It refuses unless its executable (realpath), and every
   ancestor of it, is owned by root or the invoking user, is not writable by
   group or others, and is not a symbolic link.
2. **Its own signature.** Its executable must be Micropod's Developer ID CLI
   (`com.skunkworq.micropod.cli`, team `WFTX6CN23F`, with the Developer ID
   certificate markers).
3. **The release.** The release's manifest signature is verified. A sealed
   root-only copy of the release's setup app is checked for a strict,
   notarized signature and the manifest's digests. The release's helper must
   report the same authority definition this CLI writes.
4. **Version.** It refuses anything below root's high-water mark or below
   the signed security floor.
5. **Confirmation.** It prints exactly what it will install (version,
   revision, setup CDHash, helper, API and guest digests, the definition
   digest, the program and plist paths, and the steps left to do), then asks
   for the first 12 characters of the CDHash. `--confirm` gives them
   non-interactively.

Then, from that sealed copy, it runs `RuntimeAuthorityInstaller`. Each step
is chosen by inspection, so a kill anywhere is finished by running it again.
The order keeps **exactly one helper able to serve, now and after a reboot,
at every point**:

1. **Stage.** Install the sealed authority bundle into
   `RuntimeHost/authority/current`, keeping any previous one. The legacy
   SMAppService job keeps serving.
2. **Neutralize the legacy job,** once the runtime is idle. Its
   `/Applications` bundle is replaced by a sealed copy of the authority
   bundle, so that job can only ever start the new helper:
   - while no authority is installed, the new helper serves (and reports
     itself unprotected);
   - once an authority plist is installed and protected, it exits 0 at once,
     and launchd does not respawn it.
3. **Write the authority plist.** It is written root:wheel 0644 by an atomic
   rename. After a reboot the authority serves and the legacy job yields.
4. **Bootstrap the authority.** Until the old helper releases `host.lock`,
   the authority's helper exits and launchd retries it.
5. **Stop the legacy job's old process,** once the runtime is idle. It
   restarts as the new helper and yields, and the authority takes the lock.

The legacy item stays registered in Login Items after this. It can only
start a helper that yields. Runtime Setup offers **Retire the Old Background
Item…** only while the authority serves and reports `protected`, and only
behind an in-window confirmation; no launch argument triggers it. Until it
is retired, an admin-group process could still put a pre-authority bundle
back for that item. Retiring it removes that last root path through
`/Applications`.

## Trust: what the root helper checks

The installed bundle (`authority/current`) and every copy root makes live
in root-only directories. **Sealed copies** (`RuntimeSecureCopy`) are made
like this:

1. The source tree is walked first with lstat, never following or opening
   anything. Only directories and regular files are accepted, and the tree
   is capped at 512 entries and 1 GiB.
2. It is copied with `ditto --noacl --noextattr --norsrc --noqtn`.
3. Every entry is stripped of file flags, ACLs, extended attributes and
   setuid, setgid and sticky bits. It is set to root:wheel, with 0755 for
   directories and executables and 0644 otherwise.
4. The copy is walked again to prove all of that held.

Removal is descriptor-relative: `openat` and `unlinkat` with `O_NOFOLLOW`,
a device and inode check on every directory, and flags cleared through
descriptors. A symbolic-link swap therefore cannot redirect it outside the
tree. Root never removes or changes a tree that another account can still
modify. A displaced legacy bundle is only renamed into root's directory, and
never read.

A forward update checks, in order:

1. **Source.** `/Applications/Micropod.app`. The manifest and its signature
   are read with bounded, non-blocking, no-follow reads.
2. **Manifest signature.** EdDSA, verified against the compiled-in release
   key. The manifest is not bound to the app's own `Info.plist`, which
   nobody validates. Replaying an older signed manifest is refused by the
   next two checks.
3. **Version.** The current release is the running helper's compiled-in
   `MicropodBuildInfo`; a release that doesn't parse fails closed. The
   target must be:
   - newer than that;
   - at least root's high-water mark;
   - at least the highest signed security floor.

   `component-state.json` is read fail-closed: if it is present but
   unreadable, updates and rollbacks are refused.
4. **Protection.** The live check above.
5. **n-1.** The target's `appleRuntimes` must include the selection in use.
6. **Sealed copy** of the offered setup app.
7. **Code signature:**
   - Developer ID Application from `WFTX6CN23F`, with the Developer ID
     markers;
   - the setup, helper and API identifiers;
   - strict validation, including nested code;
   - notarized.
8. **Digests.** CDHash, executables, version and revision must equal the
   manifest's.
9. **Probe.** The staged helper must report:
   - the same compiled-in release, component protocol and runtime schema;
   - an Apple table that manages the build in use;
   - the **same authority definition** as the running helper and the
     manifest.

   A release that changes the LaunchDaemon definition needs
   `install-authority` again; self-update refuses it.
10. **Verified copy.** A second sealed copy is checked against the target.
    The worker, API and guest are installed only from it, and only root's
    copy of each file is hashed.

The swap (`renamex_np`) exchanges two root-only paths inside `RuntimeHost`.
Nothing in `/Applications` is touched.

When the running helper already is the offered release, nothing is swapped.
The runtime follows from a sealed copy of the installed authority bundle,
checked with a strict signature check. No manifest is needed for that, and
nothing from `/Applications` is copied.

Before any Security.framework call on a bundle, an lstat walk proves it
sealed, because a FIFO main executable hangs `SecStaticCodeCreateWithPath`.
A watchdog is armed first thing at every start: a helper that does not
serve within 120 s exits 75, which counts as a failed launch.

### The launch floor

A helper below the highest signed `securityFloor` root has installed refuses
to run. It exits 0, so launchd does not respawn it; `install-authority` with
a release at or above the floor repairs it. The comparison is against the
floor, not the high-water mark, so a legitimate `--rollback` to a release at
or above the floor still runs.

### The legacy identifier's sunset

Until 2027-04-01 (`IsolatedRuntimePolicy.legacyHelperSunset`), clients
accept a helper signed with the legacy identifier
`com.skunkworq.micropod.runtime.host`, and the helper runs a worker staged by
a legacy helper. That worker is root-installed and digest-pinned. It is
started as root by `launchctl asuser` and drops to `_micropod` in
`--enter-worker`, so until the next restart stages this helper's own worker,
legacy code still runs briefly as root. After the sunset, both are refused.

## What launchd and BTM verify

What the design relies on:

- launchd loads `/Library/LaunchDaemons/*.plist` as written, and only root
  can write there or to the program. The protection rests on ownership, which
  every start re-checks (including launchd's live job).
- launchd's documented `launchctl print` output names the loaded job's
  program and plist path. That is used only to detect a mismatch.

What it does **not** rely on:

- whether launchd re-reads a plist inside a bundle;
- whether BTM keeps the definition it took at registration;
- whether a swap keeps a BTM approval.

The legacy job's bundle is neutralized, and the authority never runs from
`/Applications`.

The SpawnConstraint (team, identifier, `validation-category` 6) should make
launchd refuse anything else at spawn, even if a root-only file were
somehow replaced. This is on the VM plan.

### VM test plan

Run on a macOS 26 VM with SIP on, the production Developer ID, and an
admin-group user without sudo:

1. **Fresh install.** `install-authority` from the tarball CLI. Check:
   - `launchctl print system/com.skunkworq.micropod.runtime.authority` shows
     the program and the constraint;
   - `micropod runtime operation --json` reports `componentProtection:
     protected`;
   - `ls -le@O` on the plist, the program and every ancestor shows root
     ownership, no ACL and no flags.
2. **Migration from SMAppService.** Install a pre-authority release and
   approve it. Then run `install-authority` and kill it after each step
   (staged, neutralized, plist written, bootstrapped). Each time, check
   `launchctl print` for both labels and the serving helper, now and after a
   reboot. The re-run finishes.
3. **Whole-bundle replacement of the legacy item.** As the admin user, rename
   `/Applications/Micropod Runtime Setup.app` away and put back:
   - **(a)** an older genuine Runtime Setup (pre-constraint plist,
     legacy-identifier helper);
   - **(b)** a bundle whose plist has the constraint removed;
   - **(c)** a bundle with an ad-hoc helper that writes a marker file.

   Reboot, then trigger an on-demand launch of the legacy Mach service. Record
   what runs. The expectation is that (a) runs the legacy helper as root.
   This residual is why the legacy item must be retired. Retire it and repeat:
   nothing runs.
4. **The authority under attack.** As the admin user, try to replace the
   plist, the program, or any ancestor, or to add an ACL. Every attempt is
   refused by permissions. As root in the VM, strip the constraint from the
   plist, reboot and launch on demand. Check that the helper starts
   `unprotected` and refuses updates.
5. **Constraint enforcement.** As root, replace the program with an ad-hoc
   binary, then with a binary from another team, then with a legacy-identifier
   helper. Reboot and launch on demand. Expect a launch-constraint violation
   each time.
6. **Approvals and notifications.** Record any BTM notice for the legacy
   daemon on `install-authority` and on a self-update, and check that the
   helper starts after a reboot each time.
7. **Sealed copies.** Plant an ACL, an extended attribute, `uchg` and a
   setuid bit in the offered bundle, and a FIFO as its main executable.
   The FIFO is refused without hanging. After removing it, the installed
   copies show none of the planted attributes.
8. **Crash loop, hang and floor.**
   - A target that exits at once is swapped back after three launches.
   - A target that hangs before it serves is exited by the 120 s watchdog
     and swapped back.
   - A helper below the security floor exits 0 and stays down.

## Administrator approval: once

`sudo ./micropod runtime install-authority` (above) is the only
administrator step. Self-updates swap root-only files and need no approval:
the helper exits 75 and launchd's `KeepAlive {SuccessfulExit: false}` starts
the new bytes. A release that changes the authority definition needs
`install-authority` again.

The Cuttlefish agent must accept the authority's helper identifier first
(skunkworq/cuttlefish#966).

## The operation

### 1. Helper swap: unfenced and undrained

The dedicated API and the Apple apiserver are separate launchd jobs in
`_micropod`'s domain; replacing the helper does not touch them. For about
10 s nothing can start or stop the runtime, and session renewals fail and
are retried. No job is drained or interrupted.

| Phase | What happens | Changed so far |
| --- | --- | --- |
| `staging` | Sealed copy, verification, probe, verified copy | nothing |
| `swapping` | Intent recorded, then `renamex_np(RENAME_SWAP)` exchanges the staged copy with `authority/current`; both paths are root-only. The displaced bundle (root's own) is moved into `previous/`. | the authority bundle |
| `relaunching` | The helper exits. Each launch of the target is counted before anything that could fail, and a 120 s watchdog exits a helper that has not confirmed itself. | |
| `helperReady` | The target serves and has confirmed itself. Root raises the high-water mark and the security floor. | |

When the running helper already is the release, nothing is swapped. The
record goes straight to `helperReady`, with a sealed copy of the installed
authority as the staging source.

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
| `component-state.json` exists but is unreadable | Updates and rollbacks are refused; the helper still runs | — |
| A kill at any step of `install-authority` | Every step is decided by inspection; exactly one helper serves throughout (see "Installing the authority") | re-run finishes |

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
host without the authority, the app upgrade still reports success and names
`install-authority`.

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
micropod runtime update --bootstrap  # how to install the root-owned authority
sudo ./micropod runtime install-authority --app ./Micropod.app   # once, from the release tarball
micropod runtime operation --json    # componentUpdate and the restart it runs
```

## Security reviews (2026-11-19)

### First review: fixed, each with a regression test

- **The setup app as a root path.** The SpawnConstraint plus identifier
  rotation were superseded by the root-owned authority (second review, N1).
- **H1:** sealed copies.
- **H2:** staging only from the verified copy; digests enforced at staging
  and at completion.
- **H3:** the qualification deadlock (`qualify`, settling on `refused`).
- **H4:** the bootstrap is superseded by `install-authority`.
- **M1–M9:**
  - the compiled-in release and a high-water mark;
  - the signed floor;
  - non-blocking reads, with planning off the actor;
  - rollback from sealed copies;
  - launches counted, with a watchdog;
  - the journal read leniently;
  - rollback restores the runtime first;
  - the stopped release in two phases;
  - a deliberately stopped runtime stays stopped.
- **Low-severity items:** L1, L3 (caps and removal of immutable entries),
  L4 (superseded), L5–L11.

### Second review

- **N1:** the root-owned authority, the live check at every start,
  `validation-category` 6, and the VM plan items for whole-bundle
  replacement. Requirements:
  - **1:** the tarball CLI, its own path and signature, and printed
    confirmation;
  - **2:** ancestors checked at install and at every start;
  - **3:** crash-safe, idempotent migration with exactly one serving helper,
    tested step by step.
- **N2:** the launch-time floor.
- **N3:** descriptor-relative removal; root never deletes another account's
  trees.
- **N4:** no `--reregister`. Retiring the legacy item needs a protected
  authority and an in-window confirmation.
- **N5:** no re-seat from `/Applications`. The runtime-only path stages from
  the installed root-only authority, with no manifest needed.
- **N6:** `component-state.json` is read fail-closed.
- **N7:** lstat-sealed checks before Security.framework, and the watchdog
  armed first.
- **N8:** verification, restore, the worker and the probe follow
  `AppleRuntimeRelease.releases`.
- **N9:**
  - `host.lock` is taken before `launch()`;
  - the binding to the app's `Info.plist` is removed (replay is refused by the
    version and the high-water mark);
  - the legacy-identifier sunset and its corrected description.

### Deferred

- **Pruning old `apple/versions/` incarnations** (L3). It needs the selection
  in use and the rollback target kept.
- **A CDHash-pinned SpawnConstraint.** The authority's files are root-only,
  so this would only add to the constraint, at the cost of an
  `install-authority` per release.
- **The VM test plan above.** None of it has been run.

## Tests

- **`RuntimeAuthorityTests`:**
  - the definition, with `validation-category` 6;
  - protection holds only for the exact root-only authority. It is lost when
    the helper runs from elsewhere, when launchd runs another program, when
    the live job is unreadable, or when the plist has had its constraint
    stripped;
  - every ancestor is checked for group write, ACLs and symbolic links;
  - `launchctl print` parsing;
  - the legacy job yields only to a protected plist;
  - the release table;
  - the legacy-identifier sunset;
  - removal never follows a link.
- **`RuntimeAuthorityMigrationTests`:** a kill after each migration step
  leaves exactly one serving helper, now and after a reboot in either start
  order; a re-run finishes; retiring the legacy item changes nothing that
  serves; a fresh host needs no neutralizing.
- **Earlier tests, updated:**
  - an authority definition change refused;
  - unprotected refusal;
  - fail-closed state;
  - the launch floor;
  - a FIFO in the installed bundle refused by lstat;
  - the runtime-only path from the installed authority;
  - `install-authority` refusing without root or from an unprotected path.

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
  - an authority definition change refused (it needs `install-authority`);
  - the compiled-in version and high-water mark;
  - the security floor;
  - the runtime-only path, with nothing swapped;
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
  - an unprotected helper reports it and refuses updates;
  - the stopped-release path, and the rollback after it.
- **Cuttlefish (#966):** the unqualified drain is `notRecorded` and an abort
  is never refused for the build; phase 1 tolerates a stored stopped
  release and never produces one; the qualified set.

These are source tests. A physical qualification is still required.
