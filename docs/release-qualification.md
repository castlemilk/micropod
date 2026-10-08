# Draft-only release qualification

The existing Release workflow publishes the Sparkle feed on tag push. Installed
0.12.2 enables automatic download, install-on-quit and an idle/no-running-container
apply heuristic. Publishing that feed would undermine preservation of active jobs
before the maintenance bridge is qualified.

The manual qualification path uses the same trusted signing/notarization
and SDK verification jobs, requires successful exact-master source CI and existing Apple/Sparkle
signing configuration, and creates a fresh draft release. It stores source identity
and the public signed appcast envelope beside the draft's artifacts. It does not
push the live appcast, dispatch Pages or publish SDK assets/module tags. SDK build
verification still runs, without a retained SDK Actions artifact for qualification. There
is no automatic promotion or installed-app update. Missing prerequisites fail the
qualification. A draft left by a failed qualification is not accepted as a release.

Before running: qualify the workflow source, finish its exact-master hosted checks
and obtain a fresh, unused candidate version. Dispatch Release on master with that
qualification_version. No extra infrastructure or signing/key changes are needed.

After the candidate succeeds, download artifacts into this task's workspace without
mounting a DMG. Verify exact source/version, checksum, Developer ID Team WFTX6CN23F,
strict nested signatures, notarization/stapling, Gatekeeper and Sparkle Ed25519
against the key already embedded in 0.12.2. Keep signed qualification distinct from
producer adoption, maintenance-bridge safety and actual desktop acceptance.

Manual dispatch creates a draft through GITHUB_TOKEN; its tag may not exist yet.
The candidate must remain draft and must not be promoted or trigger a normal tag
release while the 0.12.2 feed is held.
Normal publication and safe user adoption need their own reviewed bridge/release
path. A successful qualification run does not qualify a production update.

Lookup failures fail closed; tag absence must return the specific no-match code.
Checkout HEAD and candidate release/tag target are checked against the qualified
SHA. Signature-envelope uploads reassert draft/source identity before and after
without clobbering assets. Only the qualification owner may control this draft;
do not promote or replace it while the pipeline is running.
