# Dedicated managed Apple runtime

The user selected the dedicated-account model on 13 November 2026. Apple's
per-user XPC server checks the requester's effective uid. A separate account
lets Micropod enforce admission without modifying Apple's signed binaries or
stopping the desktop account's existing runtime.

## Installation and ownership

The notarized application registers its signed LaunchDaemon through
`SMAppService`. macOS requires administrator approval. Building or opening the
setup app does not create an account or grant administrator rights.

The helper plans and journals unused uid/gid values and Directory Services
UUIDs before creating `_micropod`. The hidden account has disabled login
authentication, an unusable password and `/usr/bin/false` as its shell. Recovery
matches every identity field and refuses foreign accounts or directories.
Only the dedicated home belongs to this account:

- Verified Apple package and immutable tools: `/Library/Application Support/Micropod/RuntimeHost`
- Private home: `/private/var/db/micropod-runtime`
- Apple store: `/private/var/db/micropod-runtime/Library/Application Support/com.apple.container`

The helper verifies Apple's 1.5.0 package size, SHA-256, installer signer,
notarization, layout, executable signatures and all 17 payload hashes. The
verified package is retained for offline repair. It does not execute installer
scripts or modify `/usr/local`, the desktop Apple store, images, volumes or
networks. It does not clean shared build caches.

Tools are copied through no-follow file descriptors into protected temporary
files, verified, synchronized and published under their hashes. The sandbox
guest helper is copied from the sealed app bundle. API tool directories bind
both API and guest hashes. Install/repair stages the next API configuration;
activation occurs only after the current API and runtime have drained.

The helper uses `launchctl asuser` to enter the private bootstrap namespace,
then irreversibly drops its supplementary groups, gid and uid. The worker
checks its actual uid/gid and the Background namespace's owner before doing
anything. It announces its kernel incarnation and waits until the root helper
has synchronized that witness before receiving its typed action. No IPC
request chooses a uid, executable, package URL, shell command or store.

## Data plane and health

A root-owned LaunchAgent runs MicropodAPI independently of the GUI and helper.
It checks its account, namespace, configuration and Apple payload before
listening. Its HTTP upstream is a socket inside the private home. There is no
unauthenticated private-runtime TCP listener.

A BSD Unix gateway checks a root-issued capability against the connection's
kernel uid, pid, process start time and boot session. Records contain only a
SHA-256 of the secret. Tokens expire and are stripped before forwarding.
Capabilities are issued over live code-authenticated XPC to Micropod's signed
app, CLI, MCP server, API proxy or qualification app. The normal loopback API
can proxy to this gateway without changing SDK addresses or duplex framing.
An existing Cuttlefish installation must enroll before that public proxy can
adopt the managed runtime.

Desktop CLI operations and terminals use the same gateway. Data requests
cannot start/stop the runtime, restart plugins, retarget the runtime root or
supply a host environment. Lifecycle changes use the root authority. Private
API requests hold the durable admission gate; terminal claims remain until
the shell has been reaped. Unknown mutation outcomes retain their receipts.

Fresh health probes use the private worker when the API is stopped. They do
not replace the lifecycle operation ID or authorize a runtime action. A probe
and lifecycle action cannot overlap. Native readiness requires an exact
version, app root and install root from Apple's native ping plus live inventory.
GUI, CLI/API/MCP dependency reporting can distinguish an installed but stopped
runtime from an unavailable managed API. Manual stop remains recorded across
app launches; automatic startup still requires the user's existing opt-in.

## Rig coordination and recovery

Cuttlefish enrolls its host through a peer-authenticated root control socket.
Only the signed Cuttlefish runtime for the owning macOS account may enroll or
read proofs. Enrollment survives process replacement; a missing coordinator
cannot silently unenroll the rig.

Maintenance first asks Cuttlefish to pause intake and drain existing work.
Micropod then acquires its exclusive data-plane gate. Cuttlefish closes host
admission and verifies a live proof bound to the runtime instance, operation,
local generation and host. The runtime action begins only after both holds
are durable. Shared user runtimes still cannot claim this coverage.

Before stopping, the worker checks fresh Apple container/machine inventory
and all engines hosted by the managed API, including sandbox VMs. A kernel
process inventory also refuses lingering CLI, launchctl, worker or unknown
private-account processes. A dead parent is not proof that a late action is
finished. Known immutable Apple daemons, the selected API and signed Apple
platform services are the allowed long-lived processes.

After the action, Micropod verifies the private native identity. Cuttlefish
independently asks the authenticated authority for fresh readiness and checks
its retained host owner. Micropod releases the local gate, then Cuttlefish
completes the host handoff. Unknown responses retain ownership and require
verification. Recovery checks exact generations and worker incarnations;
it does not blindly repeat start/stop. Cancellation before an action uses a
two-stage abort; uncertain actions retain the fence. A manual stop keeps rig
intake paused after release.

## Qualification status

Source tests cover account collisions/interrupted creation, peer-bound
capabilities on real Unix sockets, stripped credentials, lifecycle replay,
unknown start outcomes, overlapping health probes and lost rig-release
responses. Cuttlefish tests reject mismatched host/instance/operation/generation
proofs and ensure that draining alone cannot authorize mutation.

The separate `Micropod Runtime Setup.app` lets this Mac qualify the helper
without replacing the installed Micropod application or Cuttlefish runtime:

```sh
MICROPOD_RUNTIME_SIGN_IDENTITY='Developer ID Application: …' \
MICROPOD_RUNTIME_NOTARY_PROFILE=micropod-notary \
bash scripts/package_runtime_setup.sh
```

On Gamma, administrator approval succeeded and the helper created the locked
`_micropod` account (uid 400, gid 401). Installation and offline repair verified
Apple's package and staged immutable private tools without modifying the
existing `/usr/local` installation. The first startup checks exposed two
physical-Mac defects: launchd's umask reduced public control/tool directories
to 0700, and the process inventory omitted Apple's per-user `distnoted`.
The helper now explicitly publishes protected directories through no-follow
descriptors and permits that exact Apple-platform-signed service. Regression
tests reject symlinks, unexpected owners and writable directories.

Service Management's unregister/register APIs refreshed the separately
installed Setup helper after maintenance was reconciled. The existing
administrator approval persisted; no system security setting was bypassed.
Previous signed bundles were retained. The current qualification candidate
was notarized under submission `bba0ba46-48fb-462d-8bd8-879f2afcaf6d`.

The dedicated native runtime passed an isolated Alpine workload and verified
auto-removal (`micropod-isolated-runtime-ok`). Its managed API now launches in
the Background session; a signed CLI returned the exact private native roots
and an empty private inventory while the old runtime continued serving its
own containers. An unauthenticated gateway request was rejected. This also
qualified payload repair and selection replacement with persistent image
storage. Explicit external CLI selections now retain their own lifecycle;
locator fixtures supply their managed-selection boundary rather than reading
the host installation.

An idle preflight now runs after closing admission but before marking a
runtime action as started. A busy refusal can therefore be reconciled without
trapping the active workload behind a retained disruptive-action fence. Tests
verify that no stop runs and that workload admission reopens after recovery.
Live stop/restart, cancellation/domain recovery and signed Cuttlefish handoff
are still being qualified. #89 remains open until those
checks succeed. Passing source tests is not clean-machine acceptance or
permission to replace the rig's currently running software.

Existing data is not migrated. Host bind mounts still require that the service
account can access the explicitly shared directory; no broad home-directory
ACL grant is made by setup. Qualification must include the rig's real workspace
and volume paths before adopting this runtime for CI.
