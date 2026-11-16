# Desktop updates with retained workload owners

Micropod's version 1 updater replaces the desktop app and its linked CLI/MCP
files. It keeps the dedicated API, Apple engine, Docker bridge and shared
filesystem processes running. It also keeps their executable paths and data
formats unchanged. Existing Cuttlefish leases, waits and log streams continue
against those same owners. Runtime or service upgrades remain separate
maintenance operations.

## Supported installations

The first supported updater is 0.13.6. The 0.13.0–0.13.2 candidates used
`PROC_PIDTBSDINFO` for parent identity, which macOS denies across user accounts.
Gamma's live qualification caught that denial before any installer transaction
started; both native test workloads remained running. Parent identity now uses
the same kernel process query as birth/uid identity. A read-only host regression
checks the actual signed helper, dedicated API and Apple engine before rebuilding
the candidates. A second live test caught Sparkle's default coupling between
scheduled checks and download permission in 0.13.3–0.13.5. With the app owning
informational checks, those candidates offered an interactive download instead
of starting the CLI download. Cancelling that prompt reconciled the unchanged
original and reopened admission without an installer handoff. The signed bundle
now explicitly allows downloads independently of Sparkle's scheduler; durable
admission still controls every installation-capable check. Bundle verification
and a real Sparkle settings regression enforce that contract. Older candidates
are excluded by the feed compatibility floor.

The packaged app must carry workload protocol 1 and a source revision. Its
owner must have approved the dedicated runtime. An approved dedicated desktop
workspace is selected by default; explicit CLI paths and runtime-context choices
remain authoritative. Independent Connect servers, existing Apple installations
and CI services keep their current context and ownership.

The Docker bridge and shared filesystem run as user launch agents from a signed,
versioned payload under `~/.micropod/services/payloads`. The app records each
payload before registering it. Relaunches reuse that record and never replace
its files beneath a live process. An independently installed Connect API stays
independent. Disabled services are not started solely to enable updates.

App-owned legacy services, unknown socket owners, in-process desktop sandbox
records, unsupported protocols and an unavailable native backend block the
update. A running service is never killed to make an update eligible. Completed
sandbox records also block until removed because their in-memory ownership
cannot be transferred by this protocol.

The distribution includes a separately signed setup app in `Contents/Helpers`.
Initial setup copies it to `/Applications/Micropod Runtime Setup.app` before
administrator approval. Existing setup app files are never overwritten by a
desktop update. The CLI opens that setup flow and observes its operation when no
helper or runtime is installed. An unavailable existing helper is retained for
recovery. Installing the separate setup app requires write permission in
Applications; authorizing its daemon still uses macOS administrator approval.

## Transaction and admission

`DesktopActivity` covers whole desktop container operations, mutating CLI calls
and interactive terminals. Closing it is atomic with starting another local
operation. The app checks its local operation registry after closure. Work owned
by other processes remains admitted through its existing services.

Before downloading, `ManagedUpdateAdmission` verifies:

- the dedicated runtime identity and root-owned API configuration;
- the API and Apple engine's unique process incarnations and service-account UID;
- each public endpoint's signed executable and its registered launchd owner;
- process birth, boot identity, live/on-disk code-directory identity and executable
  SHA-256; and
- fresh native readiness through both the setup helper and the authenticated API.

The transaction binds an operation and generation to the source executable,
expected version/source revision, exact official artifact URL, EdDSA signature,
length and retained service witnesses. Files are fsynced under a kernel lock in
`~/.micropod/updates`. A monotonic 30-second begin deadline cannot be extended by
changing wall time. Expiry never clears an existing transaction.

Sparkle's independent installer starts during extraction. The app records that
boundary before returning from `willExtractUpdate`; it also records preparation
and installation callbacks. Permission exists before any installation-capable
Sparkle check, including resumed drivers and install-on-quit. Informational
checks do not grant installation permission. The old shell relaunch watchdog is
removed; Sparkle owns its signed installer and relaunch flow.

The replacement verifies its signed running executable, expected source/version
and protocol, unchanged service witnesses, and fresh native backend before it
records success and opens desktop admission. A verified expected replacement
can settle a lost helper acknowledgement. Stale generations, wrong builds,
changed owners and unsupported schemas remain fenced.

A terminal pre-installer download rejection records its own durable state.
Archive validation/unarchiving rejection can use that path only before installer
preparation. Recovery verifies the original executable and retained native
services before reopening the old desktop. Other interrupted installer outcomes
require the expected signed replacement; an idle observation, elapsed timer or
process exit cannot clear them. Reboot changes invalidate the old owner witnesses.
No command replays an uncertain installation or discards its records.

## CLI and automatic policy

`micropod update apply` checks, downloads, installs and waits for the replacement
receipt. It never replays an apply after a lost reply. `update status --json`
reports the app source/version, channel, automatic policy, blocker and transaction.
`update recover` requests verified reconciliation.

`update auto on|off [--idle-after SECONDS]` controls future automatic installation.
The default idle delay is ten minutes. The interface must be in the background;
workloads may remain running. The app performs informational checks on launch and
hourly while running. It enables Sparkle downloading only after the same durable
hold used for manual installation. Changing a preference does not cancel an
installer that already has permission.

`update channel stable|qualification` selects one of two compiled feed URLs.
Arbitrary feed or package URLs are not accepted. A channel change is refused
while a transaction needs reconciliation. Standalone CLI installation retains
its existing signature-verified self-update command; app-managed tools update
with the app.

## CLI acceptance

`micropod update verify [--automatic] [--image IMAGE]` starts two named-volume
workloads through the authenticated native API. The image must already be cached;
the command does not start an implicit image download. It retains live Connect
log streams across the update, compares container identities and mounts, reads a
volume marker, then checks authoritative exit codes 0 and 7. The automatic branch
places the interface in the background and requests only an informational check;
it never invokes apply. Temporary automatic policy changes are restored.

Evidence is retained under `~/.micropod/updates/verification`. Successful tests
delete only their two stopped containers; volumes and artifacts remain available
for review. Failures retain the identified resources and do not force-clean an
unknown result. Each workload has a bounded 15-minute lifetime if its CLI exits.

A signed bootstrap installation precedes acceptance from older blocked releases.
An idle bootstrap alone does not qualify self-updating. Stable publication needs
both a signed manual hop and an automatic hop with jobs in flight, plus fault
regressions. The reviewed release manifest pins the resulting acceptance JSON.
Until that evidence exists, candidates remain on the explicitly selected
qualification channel. See [publication policy](qualified-release-publication.md).
