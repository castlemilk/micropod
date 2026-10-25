# Pending native starts and clone cleanup

Rebased onto master `2922fcc1` (2026-11-17). Master's process-wide admission
receipts (`RuntimeAdmission`), the stopped-snapshot exit wait (#95), mount and
image preflight before create admission, and the update workload preflight are
kept unchanged; this change adds the per-container ownership they do not
provide. Cuttlefish consumes the explicit `starting` state since
skunkworq/cuttlefish#535. Nothing here has been installed on a rig.

## State contract

Apple reports a newly created container as `stopped` before its first process
starts. Micropod now reports `created` for known never-started containers and
`starting` while its own start operation is queued, dispatched, or unresolved.
List/Get and inspect-based Wait share the normalization. A real recorded exit
remains authoritative even when a state snapshot still says `starting`.
An absent runtime row during an owned operation does not establish an exit.

Per-ID lifecycle claims serialize creation, start, deletion, and clone cleanup.
Claims remain in memory across backend replacement within the same API process;
CLI-backed paths do not yet enforce them (see release blockers). A caller may
cancel a start before dispatch. After dispatch, an independently owned worker
continues until the runtime method returns; caller cancellation cannot release
its ownership or allow a reaper to overtake it. Stop/kill also respect an active
claim, so an attempt timing out must not claim it killed the task without proof.

On an ambiguous startProcess response, its actual exit waiter is preserved.
The original waiter's known exit can reconcile that start's retained claim;
nil/unknown exit and raw `stopped`/absence cannot. Checks are generation-fenced.
Wait observations fence both registry generations and lifecycle revisions, and
ignore an earlier run's exit during queued admission before the new worker
clears it. Get/List enrichment also refuses to attach that old exit.

The Docker shim retains `starting` in inspect/list and does not end Wait or
emit a die event for pending states. Native log following uses the same pending
state rules, including an absent row while a create/start is owned. Native cache
commit holds a per-ID claim from its stopped check through disk replacement.
The app's update preflight (`UpdateWorkloadPreflight`, on master) already
treats `starting`/`created` and unavailable reads as work in flight.

A native start still takes master's `native.start` admission receipt before
its lifecycle claim. The receipt is settled only by a completed start; the
caller waits for the dispatched worker, so the receipt covers the whole runtime
operation even after caller cancellation.

Clone sweeps capture a creation epoch before querying live containers. Cleanup
is skipped if creation began/completed since that snapshot or the ID has an
active claim. Cleanup claims never wait on another create's ID, avoiding a
cycle between concurrent creates sweeping each other's clone directories.

## Remaining release blockers

- The HTTP unary transport still does not propagate caller disconnect/deadline
  into queued work. Cancellation tests exercise delivered task cancellation.
- Bootstrap transport failure before an exit waiter exists has no proven
  automatic reconciliation. The same is true when the original exit waiter
  fails or ages out with a nil exit. These retained start claims are deliberately
  unresolved; this is a release blocker, not an instruction to reset the API.
- Apple's XPC timeout/cancellation can return locally while an underlying
  mutation continues. The broader create/delete ambiguity handling is not
  solved here. Their existing return behavior is retained; this branch must not
  be represented as complete lifecycle recovery.
- Native-to-CLI backend replacement and native service requests which delegate
  to CLI (`tty`, interactive, or non-detached run) bypass lifecycle claims. The
  shared claim object surviving in memory does not enforce those paths.
- Claims and epochs are process-local. They do not fence another Micropod
  process or a raw Apple CLI client, and an API restart does not prove an old
  XPC mutation has stopped.
- A retained uncertain start claim also refuses stop/kill/delete of that ID
  (`failedPrecondition`) until a known exit reconciles it or the API process
  restarts. Rig cleanup that force-deletes such a container must expect that.

Resolved since the draft: operation-aware maintenance admission
(`RuntimeAdmission` durable receipts and fence) and the update workload
preflight now block disruptive restarts while work is pending.

## Validation

Deterministic unit tests cover queued cancellation, dispatched ownership,
known/unknown exits, state normalization, ID generation fencing, stale cleanup
snapshots, and aged in-flight clone protection. Connect HTTP tests run against
a private mock CLI/API process, not a live rig; one end-to-end regression
proves an earlier run's exit cannot truncate a new attempt's log output. There
is no separate raw InspectContainer HTTP/Connect method; native raw inspect
normalization is covered directly. The legacy REST list still emits scalar
`exitCode: 0` for unknown values; Connect omits it.

On master `2922fcc1`: `swift build`, `swift format lint --strict`, and the
pre-push selection (MicropodAPI, Core, DockerShim, Integration and Runtime
tests) ran 1,117 tests with 86 opt-in live-runtime/benchmark skips and zero
failures. No host runtime restart, deployment or live container probe is part
of this change. Live acceptance must follow resolution of the blockers above.
