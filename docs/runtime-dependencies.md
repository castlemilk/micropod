# Apple container dependency management

[#89](https://github.com/castlemilk/micropod/issues/89) now has dependency diagnostics,
a managed signed-package installer and durable lifecycle orchestration. **It remains
open:** activation requires complete runtime consumer coverage, which the current
Cuttlefish broker does not implement. CI admission ownership alone is insufficient.
There is no setting that overrides this requirement.

## Discovery and diagnostics

The app, API, CLI, MCP server and Docker shim share one executable locator.
An explicit `--cli` or `MICROPOD_CONTAINER_CLI_PATH` remains authoritative, even
when missing. The shim also supports `MICROPOD_CLI_PATH`. Otherwise a valid managed
selection takes precedence over `/usr/local/bin`, `/opt/homebrew/bin` and absolute
PATH entries. An invalid managed selection fails closed instead of switching stores.
Discovery and executable-version identity are refreshed while the app remains open.

The shared dependency report distinguishes missing CLI, unsupported host/version,
stopped, starting/stopping, native readiness, CLI fallback, API unavailable and
degraded states. It includes CLI/API versions, backend, runtime installation root,
maintenance closure and the next action. Raw command output is excluded.

- GUI: onboarding, main window and Settings → Runtime.
- CLI: `micropod --json runtime status`.
- API: `GET /v1/system/dependency`.
- MCP: `runtime_status`.

App/API/CLI native readiness uses a fresh bounded XPC ping. MCP's direct CLI
observation reports native readiness as unconfirmed. A cached backend, process
existence or an idle list does not authorize lifecycle maintenance.

## Managed installer

“Prepare Apple Container…” obtains explicit consent to download and stage Apple's
1.5.0 runtime. The installer uses the official signed package, pinned to:

- URL: Apple's `container` GitHub release, `container-1.5.0-installer-signed.pkg`.
- Size: 118,045,087 bytes.
- SHA-256: `a24808cb202318fa1c3bbee0c6c6887fe1225fe899d7b687a0ddd939bd6573f8`.
- Developer ID Installer: Apple Inc. – Containerization, team `UPBK2H6LZM`.

Downloads use an ephemeral HTTPS session, restricted redirects, bounded size and a
five-minute resource deadline. Package integrity, installer signature, Gatekeeper
assessment, package metadata and all 17 payload hashes are checked. Mach-O signatures
are verified against Apple's team. Installer scripts are never executed.

Files stay in the account's private `~/Library/Application Support/Micropod/Runtime`:
`versions/<version>-<digest>-<UUID>` contains each immutable installation; `packages`
retains the verified package for reuse and offline repair. Each use rechecks its
integrity. A repair stages a new directory without replacing running executables.
`current.json` changes only after maintenance admission and an acknowledged stop.
No root installer, security-setting change, global CLI replacement or store migration
is performed. Images, volumes and networks remain in Apple's existing application root.

Preparing files works independently of runtime activation. On the current production
bridge, activation is refused and the current service remains running. The signed
package and staged files remain available; a refusal is not installation completion.

## Lifecycle protocol

One app-owned actor and cross-process owner lock serialize GUI/API/CLI/MCP operations.
Progress, operation UUID, target artifact, local generation and host ownership are
atomically written and synchronized to disk. Journal reads reject oversized files
and symbolic links. Cancellation before action conditionally aborts the same owner;
a lost grant, interrupted action or unconfirmed release retains recovery state.

The intended sequence is:

1. Verify and stage the pinned runtime, without changing the running service.
2. Ask the authenticated rig coordinator to hold new work and drain existing jobs.
3. Obtain durable host admission ownership and proof of complete consumer coverage.
4. Close Micropod mutation admission, reject pending/uncertain operations and recheck
   fresh container/machine inventory. Recheck artifact bytes and owner/generation.
5. Persist one-time begin intent, stop the drained service, select the version and
   start it with the explicitly consented kernel-install option.
6. Verify CLI version and a fresh native API response naming the exact installation
   root. Cuttlefish independently verifies the pinned files and native backend.
7. Complete the local handoff, then release the exact host owner/generation. A manual
   stop keeps automatic startup and rig intake paused.

The bridge uses a private Unix socket and OS-derived peer PID/UID with live
Security.framework code-signature verification in both directions. Cuttlefish retains
its control-plane credentials. Requests contain fixed transitions and artifact identity,
never shell commands. The transport has one total twenty-second budget. Drain waits
are limited to two minutes; stop/start commands have separate bounded deadlines.

Native create/start sequences, XPC mutations and CLI mutations participate in the local
admission gate. Late ordinary XPC replies can settle their own pending receipts;
transport loss cannot erase uncertainty. Recovery verifies a started operation rather
than blindly replaying stop/start. A stop with unknown outcome remains blocked.

Automatic startup remains off by default and persists user stop/maintenance intent.
The app's legacy restart/recovery/stop controls cannot bypass managed admission.
The existing app-update guard remains unavailable; this protocol does not qualify
Sparkle, helper replacement or unattended application updates under #90.

## Operation surfaces

All actions use the same manager and durable journal:

- CLI: `micropod runtime install|repair|start|stop|restart|operation|cancel|recover`.
- API: `GET /v1/system/runtime`, `POST /v1/system/runtime/<action>`.
- MCP: `runtime_manage` with the same actions (`operation` reads progress).

The app must be running to own the operation. `recover` performs reconciliation;
it is not an override for missing ownership, foreign generations or incomplete coverage.

## Qualification and remaining work

Cuttlefish's `RuntimeConsumerCoverage` contract explicitly requires every supported
Apple CLI/API, Micropod and shim entry point to participate in durable closure across
pending/late work and process replacement. **No production broker supplies this proof.**
An enrolled CI rig or a zero-container snapshot cannot substitute for it. A missing,
untrusted, offline or CI-only coordinator refuses activation. Pending native-start work
in PR #87 and external consumer enrollment must be resolved before this can be qualified.

Validated on this Mac on 13 November 2026:

- Official package verification and private staging, including all file pins.
- An isolated Alpine container through the staged Apple CLI; it returned the expected
  output and removed itself. The shared service was not stopped or restarted.
- Corrupt-package rejection, durable gate/journal boundaries, cancellation, competing
  app ownership, late preparation, changed host owner, failed-start verification and
  lost-completion reconciliation across app replacement.
- Cuttlefish host authority/recovery tests and live process-signature checks.

This is not fresh-Mac or managed-backend activation acceptance. Still required: a
production all-consumer provider; signed paired deployment through the existing guarded
agent updater; real drain/activation/native adoption; partial-install
fault qualification; reboot recovery and an unmanaged/late consumer racing closure.
Keep #89 and the paired pull requests open until those checks pass. No shared build
cache is deleted or relocated by the installer or its tests.
