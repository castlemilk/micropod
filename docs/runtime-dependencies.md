# Apple container dependency management

This is the first implementation slice for [#89](https://github.com/castlemilk/micropod/issues/89).
The remaining installation, maintenance and clean-machine acceptance below keep
the issue open.

## Discovery and setup

The app, API, CLI, MCP server and Docker shim use one executable locator.
`--cli` remains the CLI's explicit override. `MICROPOD_CONTAINER_CLI_PATH`
overrides discovery everywhere; a missing override is reported rather than
silently replaced. The shim also accepts its older `MICROPOD_CLI_PATH` override.

Discovery checks `/usr/local/bin`, `/opt/homebrew/bin`, then absolute directories
in `PATH`. Relative/empty PATH entries and non-executable files or directories
are excluded. Discovery runs again on use, so installing while the app remains
open works. A custom explicit path remains fixed. The CLI version cache follows
the executable's resolved path, device/inode, size, modification time and change
time; replacement invalidates it without an app restart.

Missing dependencies have setup actions in the main window, onboarding,
Settings and menu bar. These open Apple's official 1.5.0 release page, matching
the native protocol line already audited in `RuntimeServices`. The user downloads
the signed package and follows macOS Installer. Micropod does not download,
verify or run that installer itself in this slice. It does not change privileges
or security settings.

## Diagnostics

- GUI: Settings → Runtime, plus the main-window status and missing-runtime notice.
- CLI: `micropod --json runtime status`.
- API: `GET /v1/system/dependency`.
- MCP: `runtime_status`.

All use `RuntimeDependencyStatus`: state, CLI path/version and version support, API version, selected
backend, message, next action and official installer URL. Missing CLI, unsupported
host, stopped, starting/stopping, CLI fallback, unqualified native version,
unavailable native API and degraded responses stay distinct. Missing dependencies
are a successful diagnostic response, not a failed attempt to run the CLI.
Raw process errors are excluded from the shared report.

The API and CLI verify native readiness with a fresh, bounded native ping and
the existing runtime version gate. The GUI uses the same probe during status
refresh. CLI presence, a running process and CLI fallback cannot produce
`nativeReady`. MCP's direct CLI observation has no native handshake and reports
native readiness as unconfirmed. The existing `status` command/tool and typed
`GetSystem` schema retain their previous contract. A ping confirms API access;
it is not workload admission fencing or a successful workload execution test.

## Lifecycle policy

Automatic startup is off by default. Settings can enable starting a service
whose status JSON explicitly reports stopped and whose CLI version is supported.
Empty exit-1 output, failed
version reads, malformed responses and unknown states cannot trigger startup.
Automatic startup does not download a kernel. Kernel installation stays an
explicit setup action.

Before a start or restart command, the app persists a pause on automatic
startup. A failed/cancelled command or app exit leaves that pause in place.
Confirmed successful startup clears it. A manual Stop persists the pause until
an explicit Start or successful operator recovery; neither elapsed time nor app
relaunch clears user intent. Re-enabling the startup toggle alone does not clear
the pause. Repeated supervisor ticks cannot blindly retry an uncertain start.

Local start, stop, restart, recovery and kernel-install actions exclude each
other. A forced status refresh after mutation waits for any older observation,
then obtains a newer one. Manual restart/recovery must finish the stop command
successfully before issuing start; cancellation or failure leaves automation
paused. There is no automatic stop/restart recovery: liveness failures remain
diagnostic because restarting the shared service could terminate other consumers.

This local policy is not a cross-process lifecycle lock or durable operation
journal. Explicit operator stop/restart/recovery controls still need rig-level
consumer fencing before they can qualify as unattended maintenance APIs.

## Remaining backlog

1. Finish #89 with a verified signed-artifact installer, durable operation
   identity/progress/reconciliation, consent and recovery, shared lifecycle
   authority across consumers, and fresh-Mac/reboot acceptance. Adopt the new
   diagnostics in the rig coordinator; the endpoint alone does not change its
   admission behavior.
2. [#90](https://github.com/castlemilk/micropod/issues/90) requires app/helper
   replacement while existing jobs continue. It needs stable workload ownership
   and a qualified handoff with Cuttlefish #625/#610. The existing updater guard
   remains; a dependency health snapshot cannot authorize replacement. See
   [updater-admission.md](updater-admission.md) and existing lifecycle PR #87.
3. Cache inventory and bounded history observation already exist on master.
   Their limits and producer integration are recorded in
   [cache-history-consumer.md](cache-history-consumer.md). Reuse/lifecycle work
   needs authoritative cache identity and active leases before automated
   retention. This dependency change does not prune or relocate any cache.

Validation uses private executable fixtures and private HTTP servers. No Apple
runtime installation, live service restart, app update or cache deletion is part
of this change's validation.
