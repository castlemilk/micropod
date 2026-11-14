# Runtime coordination on a Mac with independent CI services

Status: implementation in progress for #89. The separate approval, resource
fence and signed helper enrollment/session boundary are staged in source.
The control-plane feature flag is off. The agent's private transport and
resource-scoped lifecycle integration remain incomplete, and the staged helper
refuses disruptive operations after runtime-only registration. This work has
not been installed or approved on Gamma; its managed public API remains blocked.

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

The helper must verify a control-plane signature, using an explicitly trusted
issuer and pinned public key. Caller-supplied approval metadata, a configurable
server address or a local test control plane cannot supply this proof. The
signed enrollment must bind the approved account/runtime/rig and the actual
coordinator process incarnation. Maintenance proofs must also bind the exact
operation, local generation, selected artifact and resource-fence generation.
Ordinary pipeline identity tokens and host-update receipts must be rejected.
Do not learn verification keys from an agent's request or silently trust a new
issuer during recovery. Key rotation requires a verified update or explicit
administrator trust setup.

Control-plane creation and transition endpoints must start disabled. Deploy
and verify every admission writer before enabling them; an older backend that
does not enforce the resource fence cannot participate in that release or its
rollback. Retained runtime admission records must remain enforced when the new
endpoint flag is turned off. An operator pause is insufficient as a substitute
for this deployment requirement.

The runtime grant must confer no physical-host ownership, desktop app update,
machine reboot, legacy-service control or changes to the desktop Apple store.
Existing host-maintenance authorization and its refusal tests must remain
unchanged. Each operation must state its scope; an unknown, missing or
mismatched scope must refuse the new contract. A runtime receipt must never be
accepted by a host-update or reboot path.

The first version supports one coordinator rig per dedicated runtime. Its
resource fence covers that rig's work across projects. Adding another rig or
changing the protected account/instance requires explicit reconciliation;
re-registration cannot silently change membership. The separate root-owned
`runtime-coordinator.json` must never satisfy the legacy `rig.json` check.

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

Source verification so far includes a real isolated PostgreSQL test database,
race tests for late leases, retained native/pool cleanup claims, manual stop
across agent replacement, and exact lost-release receipts. The local database
is PostgreSQL 18.6; intended CI PostgreSQL coverage remains separate. The helper
tests verify pinned RSA signatures, account/process/operation substitution,
expiry, one-use challenges, restart invalidation and replacement ownership.
These results do not qualify a live agent handoff or reboot.

The local paired implementation now wires the root controller through signed
runtime-only drain, prepare, begin, verify and release handoffs. The private
API fixes its engine to Apple and refuses generic engine, lifecycle and updater
controls; its feature advertisement lets the agent require that restriction
before admitting work. Runtime sessions can renew while existing work drains,
but cannot reopen a closed local fence or change a retained enrollment.
Tests reconstruct the helper after a lost completion, preserve cancelled
outcomes after lost release replies, and refuse a changed native outcome
without replaying a start or stop.

When a release is committed but its reply is lost, a departed agent can be
replaced for receipt reconciliation even if its runtime approval has since
been revoked. Root requires positive prior-process exit, a newer signed
status generation and a fresh proof of the exact original release. It retains
the original enrollment and marks the replacement as reconciliation-only.
That record cannot authorize a data session or new maintenance. The controller
test exercises real process birth and exit with test-only signatures, verifies
that no native action is repeated, and refuses an old approval as a session.
Uncertain actions or uncommitted releases remain held.

Source verification on 14 November passed the full Swift suite (1,397 tests,
86 skipped), full Cuttlefish Go suite, targeted race tests, lint, TypeScript
and three isolated browser journeys covering approval, pause, refusal and
lost-response page reload. The file-exchange suite exposed a delayed FSEvents
notification overwriting a newer write. The fix compares each source/view
pair with its exchanged snapshot and replaces copied files atomically;
deterministic event-order tests and the original live-sync test pass.
These are local source results, not installed-agent or physical reboot
qualification. Both Macs remain in the release owners' coordinated pause.

A real Mac reboot remains a separate operator maintenance action after active
jobs finish. This runtime grant cannot authorize it. Boot UUID, retained
operation, account/domain identity and stored image/volume contents must be
checked after the real boot; simulated PID reuse remains separate evidence.
