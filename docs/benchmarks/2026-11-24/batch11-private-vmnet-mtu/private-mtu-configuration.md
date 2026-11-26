# Private publication network MTU request

24 November 2026 · #229.01 · source/fixture · operator preparation · zero batch credit.

On macOS 26.5.1, Apple's vmnet framework accepted MTU 1500 and MTU 9000 on two independently allocated host-mode configuration objects. The stock control left the MTU unset and skipped the setter. The benchmark helper rejected a request of 9001 and a 9000 request on a shared-mode object before calling vmnet. Each case ran once. These are configuration return codes. The SDK exposes no public MTU getter for an unmaterialized configuration. No network, interface or VM was created.

The SDK 26.5 header declares `vmnet_network_configuration_set_mtu(config, uint32_t)` and the framework ABI exports it. The earlier `apple_sdk_controls.py` check took the function's address. This fixture called the real setter and captured its result. Raw requests and compiler, source and SDK hashes are in `first-check/`. The raw request SHA-256 is `4e0c35edf47697fa1bbab5d86c87f69c5992a5235af9bdf433b8a37ce410a182`.

The unapplied `published-mtu.patch` targets runtime `86ca2713a0791d26c137e9a8c6385e1b6bd04ebb`. It passes `MICROPOD_BENCH_PRIVATE_PUBLICATION_MTU` only when the native CI worker creates its dedicated secondary publication network. All other call sites preserve the unset path. A private build would need this patch and `PublishedMTUBenchmark.swift` in `Sources/MicropodRuntime/`. The reproducer applied the exact patch to temporary copies of the two stock files and parsed them. It compiled and linked the helper and standalone probe. A complete candidate runtime has yet to be built, signed, launched or attested. The existing stock receiver still selects its signed stock image.

Receiver throughput, negotiated TCP MSS, effective Mac and guest MTUs, drops, p95/p99, CPU/GiB and runnable time are unmeasured. The live comparison still needs the actual host route and bridge, worker and service routes, all three 8,972-byte IPv4 DF probes in each direction with the reverse probe observed on the Mac bridge, service-socket MSS and delivered receiver bytes on the same boot.

Reproduce the configuration check from this directory with `python3 -B check.py /tmp/unused-private-vmnet-result-directory`.

## Signed private candidate, 24 November 2026

The opt-in runtime compiled against SDK 26.5 from stock revision `86ca2713a0791d26c137e9a8c6385e1b6bd04ebb` and all 31 pinned local dependencies. The signed binary has SHA-256 `ea735da27a7cbef8db1a9201192af431511454ff6f41bc271fdd3ce0d4661af9`. Its only entitlement is Apple virtualization. The stock baseline and fixed-worker executable hashes still match their original receipts.

The original patch omitted the launch agent’s environment allowlist. The private correction carries the selector through the signed CLI’s launch plist, the worker manifest’s optional `benchmarkPublicationMTU` field and the VM options to the dedicated host-only attachment. Fresh worker scopes accept explicit 1500 or 9000. Existing manifests retain their recorded value. The runtime rejects a changed MTU on the same populated scope. An absent selector on a fresh scope leaves the stock attachment request unchanged.

Six isolated `ci launch-agent` cases exercised the default, 1500, 9000, invalid value, bridge path and Docker engine. Eight isolated `ci cpu-plan` cases exercised the actual worker manifest parser and its conflict checks. The signed executable imports the Apple vmnet MTU setter. The first private compile was interrupted after SwiftPM requested 18 optimization threads internally. The completed build used two SwiftPM commands and one frontend thread each. This preparation produced zero booted VMs and zero timed attempts. Throughput, effective MTUs on the live route, socket MSS and bidirectional DF delivery still need measurement.

From this directory, `python3 -B build_private_candidate.py verify` checks the sealed binary and parser cases offline. The local inputs and results are in [build.json](private-build/build.json), [worker-config-forwarding.patch](private-build/worker-config-forwarding.patch), [config-parser.json](private-build/config-parser.json), [frontend-bounds.json](private-build/frontend-bounds.json) and [existing-controls.json](private-build/existing-controls.json).
