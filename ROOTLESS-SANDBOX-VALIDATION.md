# Rootless Docker inside an ephemeral VM

`SandboxOptions.rootless_docker` explicitly treats the isolated VM as the Linux
host for a rootless Docker engine. It removes the outer OCI proc submount locks:
otherwise Docker's child user namespaces cannot mount proc, even when the engine
itself starts. It grants no additional process capabilities. Host directory
mounts, published ports, exposed host services, egress secret injection and
checkpoints are rejected for this profile. The VM kernel, disk and memory remain
private and bounded by the existing sandbox request.

The sandbox runtime advertises `rootless-docker`; older servers cannot silently
accept the new profile. Platform image manifest digests are exposed separately
from Apple's synthesized local image index so clients can qualify an actual
pinned platform manifest.

Validation on 2026-11-16:

- Focused Swift sandbox, mapping and protocol tests passed (31 tests).
- A network-free VM booted the allocation worker, prepared rootless Docker
  29.9.3 using OverlayFS, imported an offline Alpine fixture, and ran a container
  which read a file from its private VM workspace (exit 0).
- The helper's retirement fence succeeded after the container exited. The
  offline VM was deleted through the normal container API.
- No GitHub bootstrap, Cuttlefish credential, user host-directory mount or host
  Docker socket was provided. The built-in read-only guest-helper binary share
  remains part of Micropod's exec transport.

After the operator authorized further network tests, three consecutive bounded
VMs on Gamma-64GB passed the credential-free private Docker fixture: rootless
Docker 29.9.3 + OverlayFS, internet image pull, private file-mount read, DNS and
GitHub HTTPS from inside the container, helper retirement fence, deletion ACK and
subsequent not-found. Warm end-to-end times: 6.26s, 5.81s and 5.71s. Tested image
platform digest: `sha256:c2c666b4325d74b82da9ebb1b60f52bc0bf6e4c3db7887bacdefba1f81f21217`.

The tests also exposed a concurrent cleanup race. VM stops now share one task;
network-stop waiters share one confirmation, including late callback settlement,
without replaying either mutation. Boot ownership is retained before create, so
an interrupted caller cannot delete a still-preparing VM or report cleanup
without a confirmed stop. A bridge anchor is used only by the opt-in rootless
profile; ordinary sandbox networking retains its previous setup. Focused Swift
sandbox tests: 52 executed, one skipped, zero failures.

The session also owns its network before waiting for bridge startup, so a
preparation failure before a configured VM exists cannot discard the cleanup
handle. An unconfirmed stop retains the session and workspace without inventing
an exit; a late callback permits deletion without issuing another stop. Ten
deterministic startup/ownership/stop cases pass. Replacing the fixed failure
condition with its previous behavior reproduces the false deletion
acknowledgement in the regression test. These checks use private fixtures and
do not qualify an installed runtime or a live GitHub runner.

Full GitHub runner qualification is **not passed**. Positive GitHub egress works
on Gamma-64GB, but the attached bridge's IPv6 link-local host probe times out
instead of returning the required rejection. Cuttlefish continues to reject that
result. Matching vminit 0.42.0 did not resolve it.

An earlier Gamma-128GB networked fixture reported
192.168.66.2/24 with gateway 192.168.66.1, while the attached host bridge had
192.168.65.1. Guest ARP for its configured gateway failed and public egress timed
out. This resembles https://github.com/apple/container/issues/2051; that issue
is evidence of a possible mechanism, not proof of the exact cause here.
No shared production runtime restart or network reset was performed. Temporary
test API processes were replaced only after their owned VMs were removed.

Do not promote this as a qualified networked GitHub runner runtime until the
real host-isolation and positive egress checks pass on a safe validation host.
The dedicated Apple runtime's API policy is unchanged; this change does not
permit routing around a private endpoint's authorization restrictions.

No database or UI flow changes. Real Connect/VM checks replace Playwright for
this runtime-only change; networked acceptance is deliberately still open.

Reconciliation with per-VM init images (#97): regenerated the Go, Swift and
TypeScript client contracts through `scripts/gen-sdk.sh`, retaining both
`RunContainerRequest.init_image` and `SandboxOptions.rootless_docker`. The SDK
regression covers JSON and protobuf round trips for both independent features.
The combined native build and all 1,438 Swift tests passed (86 opt-in tests
skipped, zero failures); Go SDK tests, TypeScript typecheck and standalone
Swift SDK build also pass. This is source compatibility evidence and does not
change the outstanding networked acceptance or runtime authorization policy.
