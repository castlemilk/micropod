# Apple container dependency management

[#89](https://github.com/castlemilk/micropod/issues/89) adds dependency diagnostics,
a verified installer and a dedicated-account lifecycle authority. It remains open
for physical qualification. The released 0.12.6 app still uses the external Apple
runtime; the development setup app is installed separately for acceptance.

## Discovery and diagnostics

The app, API, CLI, MCP server and Docker shim share one executable locator.
An explicit `--cli` or `MICROPOD_CONTAINER_CLI_PATH` remains authoritative, including
when missing. The shim also supports `MICROPOD_CLI_PATH`. Otherwise the owning
account's system-managed selection takes precedence over a legacy managed copy,
`/usr/local/bin`, `/opt/homebrew/bin` and absolute PATH entries. A broken selection
does not silently select another store. Installation/version changes are detected
while the app remains open.

The dependency report distinguishes missing CLI, unsupported host/version,
stopped, starting/stopping, native readiness, CLI fallback, API unavailable and
degraded states. It includes versions, backend, installation root, maintenance
closure and a next action. Raw command output and session credentials are excluded.

- GUI: onboarding, main window and Settings → Runtime.
- CLI: `micropod --json runtime status`.
- API: `GET /v1/system/dependency`.
- MCP: `runtime_status`.

The managed API performs a fresh native probe. If it is stopped, the authenticated
helper can perform a bounded private-account probe without changing the lifecycle
operation ID. A cached backend, process record or idle list cannot authorize a
runtime change. Legacy MCP CLI observations leave native readiness unconfirmed.

## Install and repair

“Install Apple Container…” describes the dedicated account and requests consent.
macOS then asks an administrator to approve Micropod's signed helper through
System Settings → General → Login Items & Extensions. Setup verifies Apple's
1.5.0 official package, its notarization and signer, and all 17 payload hashes:

- Size: 118,045,087 bytes.
- SHA-256: `a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8`.
- Installer team: `UPBK2H6LZM` (Apple Inc. – Containerization).

Downloads use an ephemeral HTTPS session, restricted redirects, size limits and a
five-minute resource deadline. Installer scripts are not executed. Verified packages
are retained for offline repair; repair stages another immutable directory instead
of overwriting an executable in use.

The approved helper provisions a hidden, locked `_micropod` account. Executables
and control state remain root-owned under
`/Library/Application Support/Micropod/RuntimeHost`. The private home and Apple
store live under `/private/var/db/micropod-runtime`. The desktop runtime, `/usr/local`
and its images, volumes and networks stay separate. Setup does not migrate data,
grant access to the whole home directory, or delete/relocate shared build caches.
See [the account, gateway and recovery design](isolated-runtime-design.md).

## Lifecycle and rig coordination

GUI, CLI/API/MCP controls reach one signed root authority. It serializes operations
and synchronizes progress, operation UUIDs, artifact selection, worker incarnation,
local generation and rig ownership. Its worker enters the dedicated launchd
namespace, irreversibly drops uid/gid and verifies the namespace before any action.
The managed API runs independently of the GUI. Its gateway authenticates a live
client process and holds the same durable admission gate as native and CLI work.

For an enrolled rig, maintenance follows this order:

1. Stage and verify artifacts.
2. Ask Cuttlefish to pause intake and drain current jobs.
3. Close Micropod admission; reject pending or uncertain operations.
4. Obtain host admission and a live coverage proof bound to the private runtime
   instance, operation, artifact, host and generations.
5. Record begin intent, check native/API workloads and lingering client processes,
   then stop the drained API and runtime. Activate the staged configuration and start.
6. Verify the exact private native version, app root and install root. Cuttlefish
   independently requests fresh readiness over its authenticated helper connection.
7. Release Micropod's gate, then complete the retained host handoff. A manual stop
   keeps automatic startup and rig intake paused.

Before an action, cancellation uses the same owner's two-stage abort. An interrupted
or unknown action retains its fence. Recovery verifies kernel process incarnations,
private-account process inventory and the expected native state without blindly
repeating start/stop. A missing, untrusted or offline enrolled coordinator cannot be
ignored. Apple's shared user runtime still cannot supply all-consumer coverage.

Automatic startup remains off by default and respects the existing user opt-in and
manual-stop intent. The app-update guard is unchanged; this work does not qualify
Sparkle or unattended app replacement under #90.

## Operation surfaces

- CLI: `micropod runtime install|repair|start|stop|restart|operation|cancel|recover`.
- API: `GET /v1/system/runtime`, `POST /v1/system/runtime/<action>`.
- MCP: `runtime_manage` with the same actions (`operation` reads progress).

GUI, CLI, HTTP and MCP use the same approved helper for lifecycle controls.
The helper and private API have independent lifetimes. Installation approval remains a visible macOS action.
`recover` reconciles a retained operation; it cannot override foreign ownership,
pending work or incomplete coverage.

## Qualification

Full Swift and Cuttlefish source suites and focused race checks pass. Real Unix
socket tests reject stolen process-bound credentials and verify credential stripping.
Fault tests cover unknown start, lost host-release replies, replay and overlapping
health probes. Earlier tests verified the official package, offline repair, corrupt
package/permission errors and an isolated Alpine workload through a staged CLI
without restarting the existing user service.

The operator approved the notarized setup on Gamma. Physical qualification passed
managed installation and offline repair, private-account/bootstrap/native readiness,
an isolated Alpine workload, scoped generated inputs/read-only secrets/nested
artifacts, idle stop/start and restart, saved-volume/image reuse, and verified
pre-action cancellation. The ordinary desktop Apple service stayed intact.

Persisted-recovery fault tests also reconstruct the controller with a worker
identity from another boot, including a reused live PID. They prove that an
interrupted start retains admission, cannot be replaced by a new start, and is
only released after the retained outcome is independently verified. These are
simulated reboot faults, separate from a real boot acceptance test.

Still required: paired signed Cuttlefish deployment through its guarded
installation flow, a complete scheduled job with workspace/cache exchange,
signed host handoff, a live drain race and actual boot/domain recovery.
The intended-runner CI is being repaired in Cuttlefish #686; provider allowance
currently blocks its cloud runner. Keep #89 and both draft PRs open until these
checks pass. Setup makes no broad ACL grant.
