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
  is the unprivileged Runtime Setup UI. `install-authority` boots out and
  persistently disables the legacy SMAppService job that ran it, and marks
  the bundle (a sealed root-owned copy by then) system-immutable.

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
6. The legacy SMAppService job (`com.skunkworq.micropod.runtime.host`) is
   not loaded (`launchctl print system/<label>` fails) and is persistently
   disabled (`launchctl print-disabled system`). While it can load, a root
   path through `/Applications` remains, so the authority is not protected.

Status reports `componentProtection`: either `protected` or
`unprotected: <reason>`, and `helperService`, the Mach service the answering
helper listens on. An unprotected helper still serves the runtime, but
refuses every component update and rollback until
`sudo micropod runtime install-authority` repairs it.

**Clients.** Once `/Library/LaunchDaemons/com.skunkworq.micropod.runtime.authority.plist`
exists, a client calls only the authority's Mach service and never falls
back to the legacy one (`IsolatedRuntimePolicy.clientServiceNames`). Before
that, it tries the authority first and the legacy service only when the
authority's cannot be reached.

### Installing the authority (one administrator step)

The trust anchor is the binary the administrator runs under `sudo`. A
`micropod` another account can write could be swapped before or while sudo
runs it, so the procedure copies **the release's own CLI** into a directory
only root can change, checks that copy, and runs it from there. Do it from a
clean admin session: a fresh login as a local administrator (not the rig's
CI account), with no other user session, CI job or agent running, typing the
commands rather than pasting them from a page another process could edit.

```sh
# 1. Unpack the release tarball into an empty directory and cd there.
tar -xzf Micropod.<version>.tgz
# 2. Copy the CLI into a root-only directory.
sudo install -d -o root -g wheel -m 0700 /var/root/micropod-install
sudo rm -rf /var/root/micropod-install/<version>
sudo install -d -o root -g wheel -m 0700 /var/root/micropod-install/<version>
sudo ditto --noextattr --noacl ./micropod /var/root/micropod-install/<version>/micropod
sudo chown root:wheel /var/root/micropod-install/<version>/micropod
sudo chmod 0755 /var/root/micropod-install/<version>/micropod
# 3. Check that copy, not the download.
sudo codesign --verify --strict -R='anchor apple generic and certificate leaf[subject.OU] = "WFTX6CN23F" and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists' /var/root/micropod-install/<version>/micropod
# 4. Run it from there.
sudo /var/root/micropod-install/<version>/micropod runtime install-authority --app ./Micropod.app
```

`ditto` keeps the source's owner when root runs it, hence the `chown`. A
notarized Developer ID installer package would make steps 1–3 one
Gatekeeper-checked double-click; it needs a Developer ID *Installer*
certificate in the release workflow, which it does not have yet, so it is
deferred (below). The CLI does not trust the procedure: it enforces it.

Running as root, `install-authority` checks itself and the release before it
changes anything:

1. **Its own path.** It refuses unless its executable (realpath), and every
   ancestor of it up to `/`, is owned by root, is not writable by group or
   others, carries no ACL, and is not a symbolic link. An unpacked download
   (owned by the administrator) is refused, with these instructions.
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
is chosen by inspection, so a kill anywhere is finished by running it again,
and **at most one helper serves at any point**, now and after a reboot:

1. **Stage.** Install the sealed authority bundle into
   `RuntimeHost/authority/current`, keeping any previous one. The legacy
   SMAppService job keeps serving. (Over a live authority this waits for an
   idle runtime, and step 6 restarts it.)
2. **Neutralize the legacy job,** once the runtime is idle. Its
   `/Applications` bundle is replaced by a sealed root-owned copy of the
   authority bundle, so a respawn of that job can only start the new
   helper: while no authority plist is installed it serves (and reports
   itself unprotected); once a protected authority plist exists it exits 0
   at once, and launchd does not respawn it.
3. **Write the authority plist,** root:wheel 0644, by an atomic rename. From
   here clients call only the authority's service. After a reboot launchd
   loads the authority from `/Library/LaunchDaemons` and it serves.
4. **Bootstrap the authority.** While the old helper holds `host.lock`, the
   authority's helper exits and launchd retries it after its throttle.
5. **Retire the legacy job,** once the runtime is idle:
   `launchctl bootout system/com.skunkworq.micropod.runtime.host` (its old
   process ends and releases the lock), `launchctl disable` of the same
   label (persistent: it is not loaded at the next boot), and
   `chflags -R schg` on its sealed bundle, so no admin-group process can
   rename, replace or write it. `install-authority` does not finish until
   the job is unloaded, disabled and the bundle immutable.
6. **Start the authority** (`launchctl kickstart`, with `-k` when a live
   authority runs another build) until its live process is the target:
   install-authority reads `RuntimeHost/serving.json`, which the helper
   writes once its XPC and rig servers listen, and accepts it only when its
   pid is the one `launchctl print` reports for the authority job, its
   process birth matches, and it names the authority's service.

It prints `Installed` only after steps 5 and 6 are verified. Undoing the
immutable flag, for example to delete the old bundle by hand, needs root at
the default `kern.securelevel` 0:
`sudo chflags -R noschg "/Applications/Micropod Runtime Setup.app"`. A later
`install-authority` clears and re-sets it itself.

The legacy item may still be listed in Login Items. Runtime Setup offers
**Retire the Old Background Item…** (SMAppService unregister) only when the
status reply comes from the authority's own service (`helperService`), not
merely when it reports `protected`, and only behind an in-window
confirmation; no launch argument triggers it. It removes the listing; the job
itself was already booted out and disabled.

### When no helper serves

"At most one" is not "exactly one". These cases leave no helper reachable,
and each is recovered by running `install-authority` again:

| Case | Why nothing serves | What the re-run does |
| --- | --- | --- |
| Killed after the plist was written, before the authority serves | Clients no longer call the legacy service; the old helper still holds the lock | Bootstraps the authority, retires the legacy job, starts the authority |
| Killed after bootstrap, before retirement | The same | Retires the legacy job, starts the authority |
| launchd refuses the authority's spawn (a constraint mismatch) | The program never runs | With a good release: stages it and restarts the authority |
| The installed release is below the signed security floor | The helper exits 0 at start | With a release at or above the floor: stages and restarts it |

A reboot inside either of the first two windows also recovers on its own:
launchd loads the authority's plist and the neutralized legacy helper
yields. `RuntimeAuthorityMigrationTests.testTheNoHelperWindowsAreTheDocumentedOnes`
replays every kill point and checks that these two are the only windows.

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
somehow replaced. Gate test G2 checks it.

Also unproven until the gate runs: that `launchctl bootout` and
`launchctl disable` keep an SMAppService-registered job unloaded across a
reboot and an on-demand lookup of its Mach service (G4).

### VM release gate

No release ships the authority until these nine tests pass on a throwaway
macOS 26 VM with SIP on and the production Developer ID build (a draft
qualification candidate). `scripts/vm/runtime-authority-gate.sh` runs them
inside the VM and prints PASS/FAIL per check; `scripts/vm/gate-host.sh`
creates the VM with tart and runs the kill matrix on clones;
docs/vm-release-gate.md has the exact commands.

0. **Harden** (`harden`, `harden matrix`). Every step refuses outside a
   hypervisor guest carrying the gate's root-owned marker, or next to any
   Cuttlefish process, state or install, or a Micropod runtime the gate did
   not create. `harden` sets a random password, key-only ssh, and no
   passwordless sudo except the matrix's scoped rule. The host script
   refuses to boot while any other VM runs on the host.
1. **Fresh install** (`g1`). The root-only-copy procedure; a user-owned CLI
   refused as root; plist root:wheel 0644 naming the program; the authority
   serving (live pid matches `serving.json`); legacy job unloaded and
   disabled; replies from the authority's service; `protected`; the
   dedicated runtime installs.
2. **Constraint enforcement** (`g2`). The program replaced by an ad-hoc
   build, a legacy-identifier build (0.13.3's helper), another identifier of
   this team (the CLI), another team's Developer ID binary and an Apple
   Development build: launchd runs none of them, and the original serves
   again afterwards.
3. **Migration kill matrix** (`g3-kill`, `g3-check`; `gate-host.sh matrix`).
   From 0.13.3 with its approved SMAppService helper, `install-authority` is
   SIGKILLed at each checkpoint (`staged`, `neutralized`, `plistWritten`,
   `bootstrapped`, `retired`, `started`), with and without a reboot after
   the kill, each on a fresh clone. At most one helper runs, no 0.13.3 code
   runs as root after a reboot once neutralized, and the re-run finishes.
4. **The legacy residual, before and after retirement** (`g4-before`,
   `g4-after`). An admin-group process started the way the Cuttlefish agent
   starts jobs (a user LaunchAgent child) moves the legacy bundle aside and
   plants an ad-hoc helper, then a reboot or a legacy-service lookup (0.13.3's
   CLI) tries to run it. Before: recorded as a baseline. After retirement:
   every attempt fails and nothing runs, before and after a reboot.
5. **Authority files under admin-group attack** (`g5`). From the same
   agent-child context: writing, moving or removing the plist or program,
   creating files or ACLs under `RuntimeHost`, moving the support folder,
   bootout/disable/kickstart of the authority, and moving, writing or
   un-flagging the legacy bundle. All fail; the bytes are unchanged.
6. **Self-update with no BTM prompt** (`g6`). Candidate A to candidate B
   with `micropod runtime update`: B serves, the plist is unchanged, no new
   background item appears in `sfltool dumpbtm`, and the operator confirms
   no prompt or notice appeared.
7. **Crash loop, hang and floor** (`g7-crash`, `g7-hang`, `g7-floor`). With
   the root-only gate fault file, B crashes (or hangs until the 120 s
   watchdog) after its launch is counted: the update rolls back to A. With
   B built with `qualification_security_floor` = B: a rollback and an
   `install-authority` of A are refused, and B keeps serving. Status reports
   the armed fault.
8. **Sealed copies** (`g8`). An ACL, an extended attribute and a setuid bit
   planted in the offered app: the installed authority carries none, nor any
   flag, group/other write or other owner, and verifies strictly.
9. **The install-authority procedure** (`g9`). The documented procedure on
   the 0.13.3 VM: the R2 refusal, the install, the legacy bundle sealed and
   immutable, no 0.13.3 code running, the runtime restarted onto A, the
   Login Items entry retired from Runtime Setup, and everything still true
   after a reboot.

Human steps: approving Login Items for 0.13.3 (`prepare-legacy`), clicking
Install Dedicated Runtime in its Setup, the Retire button (`g9`), answering
the no-prompt question (`g6`), and the reboots the runner asks for (the host
script does the kill matrix's reboots itself). Inputs the gate cannot make:
candidate B (a second draft qualification build newer than A), B built with
a floor for `g7-floor`, another team's Developer ID binary and an Apple
Development build for `g2`. A missing input makes its test `INCOMPLETE`,
never `PASS`. So does an agent-spawned attacker that never ran (`g4`,
`g5`): the child proves it ran by recording, as its first line, that
launchd started it. A step that asks for a reboot records the checks it made
first as its own line; its test passes only if that line and the one after
the reboot both pass.

The gate's two hooks (`RuntimeGateHooks`) are armed only by root-owned
files in `RuntimeHost`, name the exact code they affect, and expire (at most
six hours):

- `gate-fault.json` (version, helper SHA-256, `crash` or `hang`, expiry): only
  that exact helper crashes or hangs, after its launch is counted. While the
  file exists, status reports `gateFaultArmed: true` and
  `componentProtection` ends in "; release-gate fault armed".
- `gate-kill.json` (checkpoint, the install-authority CLI's CDHash, expiry):
  that CLI removes the file and dies at that checkpoint, once.

**Gate drafts never ship.** `qualification_security_floor` is recorded as
`gate-security-floor=` in the draft's `qualification-source.txt`, and
publication refuses such a draft (docs/qualified-release-publication.md).
Every release's runtime floor must also be at most its own version
(`RuntimeComponentManifest.validate`), equal the reviewed
`runtimeComponentsSecurityFloor` at publication, and is capped at the
carrying release when root records it.

## Administrator approval: once

`install-authority`, run as root from a root-only copy of the release's CLI
(above), is the only administrator step. Self-updates swap root-only files and need no approval:
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
| A kill at any step of `install-authority` | Every step is decided by inspection; at most one helper serves throughout, and none is reachable only in the windows "When no helper serves" lists | re-run finishes |

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

## Install attestation for the coordinator

The Cuttlefish agent reaches the root helper only through the coordination
socket (`RuntimeCoordinationCall`), not the CLI's `status`. A
`runtime-inspect` call with `"purpose": "attestation"` gets the reply's
`attestation` object; without that purpose the reply is byte-for-byte what it
was, because the agent decodes coordination replies strictly
(`DisallowUnknownFields`) and an unasked-for field would make every deployed
agent refuse `runtime-inspect`. A helper that predates this refuses the
purpose (it requires none), so a new coordinator fails closed against it.

The attestation is checked for each reply (`installFacts()`: the same
protection check `status` reports, the installed plist compared with the
compiled definition, the sealed walk of the running bundle, and the legacy
job's `launchctl` state), stamped with `checkedAt`, and recorded as
`status`'s `componentProtection`, so the two never disagree for longer than
one check.

| Field | JSON type | Bound | Meaning |
| --- | --- | --- | --- |
| `helperIdentifier` | string | 128 bytes | the helper's signing identifier |
| `helperVersion` | string | 64 | its compiled-in release |
| `componentProtocol` | integer | | the component protocol it implements; 0 if none |
| `helperService` | string | 128 | the Mach service it serves: `com.skunkworq.micropod.runtime.authority` or the legacy `com.skunkworq.micropod.runtime.host` |
| `componentProtection` | string | 512 | `protected` or `unprotected: <reason>`, either followed by `; release-gate fault armed` on a VM gate |
| `authorityDefinitionSHA256` | string | 64 | lowercase hex of the LaunchDaemon definition it expects |
| `spawnConstraint` | boolean | | it runs as the authority, from a plist that is exactly that definition (SpawnConstraint included) |
| `installSealed` | boolean | | the bundle it runs from is a sealed root-owned copy |
| `nativeState` | string, optional | 64 | the managed Apple runtime's last observed state; omitted when never observed |
| `legacyJob` | string | | `retired`, `loaded`, `enabled` or `unknown` |
| `checkedAt` | string | 40 | RFC 3339 UTC with fractional seconds, when these checks ran |

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
sudo /var/root/micropod-install/<version>/micropod runtime install-authority --app ./Micropod.app
                                     # once, from a root-only copy (above)
micropod runtime operation --json    # componentUpdate, componentProtection, helperService
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
  - **1:** the release's own CLI, its own path and signature, and printed
    confirmation (tightened to a root-only copy by R2);
  - **2:** ancestors checked at install and at every start;
  - **3:** crash-safe, idempotent migration with at most one serving helper
    (R3), tested step by step.
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

### Third review

- **R1 (high):** the legacy job is retired by `install-authority` itself:
  bootout, persistent disable, and `schg` on its sealed bundle; protection
  requires the job unloaded and disabled; `Installed` is printed only after
  retirement and a verified serving authority; clients never fall back to
  the legacy service once the authority plist exists; Runtime Setup's
  Retire button follows `helperService`, not `protected`; migration does
  not finish while the job can load.
- **R2 (medium):** `install-authority` refuses any path not root-owned to
  `/` (no ACL either); the procedure copies the CLI into
  `/var/root/micropod-install/<version>`, checks it there and runs it from
  there, from a clean admin session. The installer package is deferred.
- **R3 (low-medium):** "exactly one" was "at most one". The cases with no
  helper are listed ("When no helper serves") and a re-run recovers each:
  a new `start` step restarts an authority that is not serving the target.
- **R4 (low):** removal descends at most 64 levels. The version manifest
  gains `runtime-authority` (`missing` while a dedicated runtime still
  depends on the legacy helper), which Cuttlefish forwards, shows in
  `cuttle runners show` and warns about in `cuttle agent doctor`, so the
  rigs to migrate before 2027-04-01 are visible fleet-wide.
- The reviewer's nine VM tests are the release gate, with a harness.

### Fourth review

- **F1 (high):** a manifest's `securityFloor` must be at most its own
  version; root caps a recorded floor at the carrying release; publication
  extracts the frozen tarball's manifest and requires its floor to equal the
  reviewed `runtimeComponentsSecurityFloor`; a draft built with the gate's
  floor records it in `qualification-source.txt` and is never published.
- **F2–F4 (harness):** `harden` (random password, key-only ssh, no
  passwordless sudo but the matrix's scoped rule), a VM guard in front of
  every step, a host preflight refusing to boot beside any other VM, and
  guest output treated as untrusted.
- **F5–F6:** both gate hooks are root-owned files naming the exact code and
  expiring; an armed fault is reported.
- **Follow-up:** `harden` writes the marker last (with a `hardened` line the
  guard requires); the matrix's sudo rule names `/bin/bash` and the runner
  pins `PATH`; publication fails closed on a missing (from v0.13.10),
  misplaced or duplicated tarball manifest; the build refuses a floor above
  the release.
- **F7:** `runtime-authority` reports `unprotected` and `legacy_active` from
  the authority's published protection check (`RuntimeHost/protection.json`,
  refreshed at start, on updates and every five minutes);
  `cuttle runners list --needs-install-authority` lists every rig to fix.

### Deferred

- **Pruning old `apple/versions/` incarnations** (L3). It needs the selection
  in use and the rollback target kept.
- **A CDHash-pinned SpawnConstraint.** The authority's files are root-only,
  so this would only add to the constraint, at the cost of an
  `install-authority` per release.
- **A notarized Developer ID installer package** for `install-authority`
  (R2's first choice). It needs a Developer ID Installer certificate and a
  `productsign`/notarize step in the release workflow. Until then the CLI
  enforces the root-only-copy procedure.
- **The VM release gate above.** None of it has been run; the harness is
  written but has not run in a VM either.

## Tests

- **`RuntimeAuthorityTests`:**
  - the definition, with `validation-category` 6;
  - protection holds only for the exact root-only authority. It is lost when
    the helper runs from elsewhere, when launchd runs another program, when
    the live job is unreadable, or when the plist has had its constraint
    stripped;
  - every ancestor is checked for group write, ACLs and symbolic links;
  - `launchctl print` parsing, including state and pid;
  - the legacy job yields only to a protected plist;
  - protection lost while the legacy job is loaded, enabled or unreadable
    (R1), and the legacy job's state read from `launchctl print-disabled`
    in both output formats;
  - clients never call the legacy service once the authority plist exists;
  - the serving record must describe the authority job's live process
    (pid, birth, service);
  - removal depth bounded (R4); gate faults name one release;
  - the release table;
  - the legacy-identifier sunset;
  - removal never follows a link.
- **`RuntimeAuthorityMigrationTests`:** a kill after each of the six
  checkpoints leaves at most one serving helper, now and after a reboot in
  either start order, and no client reaches the legacy service once the
  plist exists; a re-run finishes with the legacy job unloaded, disabled
  and its bundle immutable; the windows with no reachable helper are exactly
  the two documented ones; install-authority does not finish while the
  disable has not taken; an authority that cannot run is reported and a
  re-run recovers it; a newer release restarts a serving authority; a fresh
  host needs no neutralizing.
- **`VersionManifestTests`:** `runtime-authority` is `missing` while the
  dedicated runtime uses the legacy helper, `running` or `stopped` once its
  plist is installed.
- **Earlier tests, updated:**
  - an authority definition change refused;
  - unprotected refusal;
  - fail-closed state;
  - the launch floor;
  - a FIFO in the installed bundle refused by lstat;
  - the runtime-only path from the installed authority;
  - `install-authority` refusing without root, from a path the invoking
    administrator owns (R2), or through an ACL.

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
