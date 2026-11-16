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
- No GitHub bootstrap, Cuttlefish credential, host directory or host Docker
  socket was provided to these fixtures.

Networked qualification is **not passed**. A separate networked fixture reported
192.168.66.2/24 with gateway 192.168.66.1, while the attached host bridge had
192.168.65.1. Guest ARP for its configured gateway failed and public egress timed
out. This resembles https://github.com/apple/container/issues/2051; that issue
is evidence of a possible mechanism, not proof of the exact cause here.
No shared runtime restart, network reset, or further network topology experiment
was attempted after identifying the risk to other running workloads.

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
The combined native build and all 1,428 Swift tests passed (86 opt-in tests
skipped, zero failures); Go SDK tests, TypeScript typecheck and standalone
Swift SDK build also pass. This is source compatibility evidence and does not
change the outstanding networked acceptance or runtime authorization policy.
