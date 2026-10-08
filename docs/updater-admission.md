# Workload-safe updater admission

Production update installation is unavailable until Micropod and Cuttlefish
have a jointly qualified maintenance bridge. Checking for a newer version
remains informational. Manual, API and automatic apply refuse installation;
Sparkle's interactive/background drivers are denied before installer resumption.
Automatic downloading is disabled because it can stage an install on quit
outside the guarded apply route. No preference can enable a substitute guard.

The app reports `restartGuard` and `restartBlockedReason` separately from the
last feed-check error. The GUI, CLI and MCP show the blocker. Typed API clients
receive the diagnostic in their existing `error` field. A downloaded update
remains staged after a blocked request; that does not mean apply is authorized.

## Local guard scaffolding

`UpdateRestartGuard` accepts a coordinator interface for deterministic tests.
The only production coordinator is `UnavailableUpdateAdmission`. This interface
is internal scaffolding, not an implemented maintenance API or a qualification
of any installed host.

- Requests serialize before asynchronous acquisition. A ten-second preparation
  deadline returns even when a transport ignores cancellation. An operation ID
  rejects cancelled/late replies and prevents them from invoking an installer.
- A mock hold spans the workload observation and response-flush delay. A one-time
  begin transition must validate generation and unexpired permission immediately
  before watchdog/helper/installer action. Definite denial never invokes action.
- Before action, cancellation requests a conditional, idempotent abort. The
  coordinator may release only if it proves action never began and the old
  runtime is usable. Uncertainty must retain its durable fence.
- Unknown begin, interrupted installation and missing outcome retain ownership.
  Expiry revokes begin permission; it never automatically reopens admission.
  Only a trusted, generation-bound receipt for verified restored runtime can
  reconcile recovery. There is no periodic idle polling or blind release.

The workload preflight fails closed on unavailable/unobserved local state,
pending local operations, nonterminal/unknown container states, API failure,
malformed responses, cancellation and oversized responses. It rechecks local
state after awaiting the API. Reads use fixed loopback with no redirects,
credentials, cookies or response cache and bounded time/bytes. This remains an
observation: native container listing can use recent cached metadata, and no
snapshot can fence future work.

## Required production integration

Cuttlefish owns authenticated rig/session identity, scheduler admission and
durable host-fence ownership. Its existing host-maintenance authority is the
building block; its private native broker job hooks are not a maintenance API.
Micropod must supply closure and lifecycle acknowledgement for runtime consumers.
Credentials stay behind the trusted coordinator.

Before adding a production provider or allowing installation, jointly qualify:

1. OS-derived host/rig/process-birth identity and an operation capability bound
   to the expected signed version/artifact, owner and admission generation.
2. Atomic closure of pending claims, late grants and every Micropod, Docker shim,
   native Apple CLI/API and external consumer entry point. Unsupported coverage
   fails closed. Existing work is never killed to obtain an idle window.
3. Durable prepare/begin/helper-handoff/recovery state across app, API, shim and
   coordinator replacement, including one-time begin permission and bounded action.
4. Idempotent generation-bound abort/release that preserves newer ownership and
   operator drain state. Lost responses and expiry cannot reopen unknown outcomes.
5. Independently verified replacement build/runtime/helper readiness, or verified
   rollback to the prior build, before admission resumes.

Required integration regressions include late lease/Apple grants racing closure,
delayed acquisition after abort, API outage/partial inventory, stale session or
foreign generation, duplicate release, crashes around helper handoff, coordinator
replacement, expiry during apply, wrong-build readiness, failed rollback and an
unmanaged consumer. Mock tests of app ordering do not replace these database,
runtime and lifecycle checks. Release/adoption of a working coordinated updater
remains gated on those results.
