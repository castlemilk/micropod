# Runtime coordination on a Mac with independent CI services

Status: design requirement for #89. The runtime-scoped contract described here
is not implemented or approved by the current host enrollment. The managed
public API remains blocked on Gamma.

On 14 November 2026 the owner asked to keep Gamma's independent CI services.
The observed configuration contains six native GitHub runners, the SFH VM
pool, a machine runner and a watchdog. Their definitions and ownership must
remain intact. The dedicated `_micropod` runtime must not become a reason to
claim exclusive ownership of this Mac.

## Authority

The existing Cuttlefish host-maintenance contract covers physical-host CI
admission. Its empty-host enrollment requires a truthful administrator approval
and complete coverage. A paused service, an idle inventory or a configuration
switch cannot supply that coverage. The normal CLI's
`organization_admin_required` refusal remains final for that access path.

Supporting this configuration requires a separate, explicitly approved runtime
resource. Its identity must include the protected runtime instance, service
account UID/GID/UUID, owning desktop account and participating Cuttlefish rigs.
The approval must use the normal human administrator flow and bind the exact
resource and revision. Existing host grants, project credentials, machine
tokens and OAuth clients cannot create this grant. A signed local process
alone does not establish control-plane approval.

The runtime grant must confer no physical-host ownership, desktop app update,
machine reboot, legacy-service control or changes to the desktop Apple store.
Existing host-maintenance authorization and its refusal tests must remain
unchanged. Each operation must state its scope; an unknown, missing or
mismatched scope must refuse the new contract. A runtime receipt must never be
accepted by a host-update or reboot path.

## Selection and admission

Keep existing CLI paths, SDK addresses and runtime selections serving their
current stores. Adopting the private runtime must use a deliberate, separate
endpoint or engine selection and a guarded Cuttlefish configuration change.
Installing the helper must not retarget independent services to the managed
runtime. Switching the existing public endpoint requires its own complete
consumer coverage and remains blocked otherwise.

For Cuttlefish, prefer its SDK over the private Unix gateway with a capability
bound to the approved agent's kernel process identity. A separate unauthenticated
loopback listener would let an unregistered CI job attach to the private store
without joining the drain protocol. The protected control socket must issue no
data-plane session until normal approval and resource registration are verified.
Store credentials only in memory; an unavailable or expired session cannot
authorize mutation replay or a fallback to the desktop runtime. Refresh the
vendored Go SDK through its supported sync target.

Keep desktop app update authority separate too. A runtime-only registration must
not make the public-provider enrollment check pass. A paired app release needs
an explicit legacy public-provider selection while its UI and the opted-in rig
use the private store. Verify this selection across the app, CLI links and SDK
addresses before replacement; merely leaving the old Apple process running
does not prove that existing clients retained their store.

The helper must verify the dedicated account and all private Apple XPC, API,
CLI, shim and sandbox entry points. Every private request must participate in
the durable gate. An unknown process, pending mutation, unresolved receipt or
unaccounted consumer blocks a disruptive action. A service-account boundary
and an empty container list are insufficient on their own.

For an approved runtime operation:

1. Persist the resource, operation, selected artifact and generations before
   pausing participating rig admission. Include pending grants and retained
   workspace/cleanup claims when draining those rigs.
2. Close Micropod's private data-plane gate and verify the helper's live,
   process-authenticated proof. Verify all private workloads and consumers
   before recording action intent.
3. Change only the dedicated runtime. Verify the exact selected account,
   native version and roots through a fresh observation.
4. Release the local gate before completing the participating rigs' handoff.
   Retain the original owner and generations after any unknown response.

Cancellation and restart recovery must use the same retained operation. They
must not replay a start/stop, discard an unknown receipt, reopen admission from
elapsed time or turn a runtime grant into a host grant. Manual stop must keep
automatic runtime startup and participating rig intake paused as specified by
the owner's policy.

## Qualification

Source tests must reject host/runtime receipt substitution, stale grants,
changed account/instance/rig membership, late leases, untracked consumers and
lost release replies. Database tests must prove human-only approval, revision
checks and closure of every participating rig across projects. Existing
independent services must retain their configuration and scheduling authority.

Physical acceptance must include an explicit private-runtime scheduled job,
workspace/cache/artifact exchange, a signed live drain race and native recovery.
Record the selected endpoint and engine so an ordinary desktop-runtime job
cannot be mistaken for managed-runtime qualification. A refused public API
adoption or a passing CLI-only workload does not qualify the scheduled Connect
executor.

A real Mac reboot remains a separate operator maintenance action after active
jobs finish. This runtime grant cannot authorize it. Boot UUID, retained
operation, account/domain identity and stored image/volume contents must be
checked after the real boot; simulated PID reuse remains separate evidence.
