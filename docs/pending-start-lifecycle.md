# Pending native starts and clone cleanup

This change is isolated from `ce1af2058ee99dae4d467002a53710e8026e0e78`.
It has not been installed on a rig. The existing dirty
`codex/native-deletion-reliability` worktree is separate and must be reconciled
before integration; both changes touch native deletion.

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
The app's updater rejects pending/unknown inventory and unavailable API reads;
this is an inventory safety check, not an atomic admission drain.

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
- Update restart safety does not yet observe pending operations which have no
  runtime inventory row, nor prevent work admission after the inventory read.
  Production automatic updates need an operation-aware drain/handshake.
- Claims and epochs are process-local. They do not fence another Micropod
  process or a raw Apple CLI client, and an API restart does not prove an old
  XPC mutation has stopped.
- The installed API has no verified source stamp; the observed binary SHA-256
  was `e675a5149b7e5c33cf7080afed310d92257e8b0963f2e426bf135c1a091eab2c`.

## Validation

Deterministic unit tests cover queued cancellation, dispatched ownership,
known/unknown exits, state normalization, ID generation fencing, stale cleanup
snapshots, and aged in-flight clone protection. Existing native create/start,
exit-wait and clone tests are included in the focused suite. No host runtime
restart, deployment, live container probe, or UI change is part of this branch.
Focused integrated validation: 150 tests, one opt-in throughput benchmark
skipped (`MICROPOD_PERF_BENCH=1`), zero failures. Log:
`/tmp/cuttlefish-micropod-integrated-lifecycle-tests-pass3.log`.
Nine isolated Connect HTTP tests passed with no skips or failures in 8.701s
(`/tmp/cuttlefish-micropod-connect-pending-tests-20261025.log`).
Connect HTTP tests run against a private mock CLI/API process, not a live rig.
The final end-to-end pending log regression passed (one test, 0.085s), proving
an earlier run's exit cannot truncate the new attempt's cf-steps output.
Log: `/tmp/cuttlefish-micropod-pending-log-regression.log`.
There is no separate raw InspectContainer HTTP/Connect method; native raw inspect
normalization is covered directly. The legacy REST list still emits scalar
`exitCode: 0` for unknown values; Connect omits it. This draft does not change
that independent legacy projection.

Live acceptance must follow resolution of the blockers above and coordinated
Cuttlefish support for the explicit `starting` state.

Final formatted-source validation passed: 160 selected tests, one opt-in
throughput benchmark skipped, zero failures in 30.871 seconds. Full repository
`swift format lint --strict --recursive Sources Tests Package.swift` passed.
Final log: `/tmp/cuttlefish-micropod-final-formatted-tests.log`.
