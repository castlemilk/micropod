# Publishing frozen qualified assets

Dispatch `release.yml` with `publication_version=vX.Y.Z` after exact-source CI
passes. The reviewed `docs/qualified-releases/vX.Y.Z.json` pins the qualification
run, source, release ID, complete asset IDs/sizes/SHA-256 hashes and the DMG's
Sparkle signature. Publication verifies those bytes before and after promoting
the existing release. It does not rebuild, replace assets or push a tag.

The manifest chooses one policy:

| Policy | Feed | Installation |
| --- | --- | --- |
| `informational` | stable | A release-page link with no enclosure. |
| `workload-preserving-candidate` | qualification | Signed protocol 1 payload, explicitly selected for acceptance. |
| `workload-preserving-v1` | stable | Accepted manual and automatic workload continuity. |

Candidates and informational releases use `make_latest=false`. A stable workload
release becomes Latest only after its acceptance evidence passes. Existing public
candidate assets are verified again before stable promotion. Their source, tag
and asset identities remain unchanged.

A workload manifest requires `workloadProtocol: 1` and
`minimumUpdaterVersion: "0.13.6"`. Its enclosure carries the exact source revision,
EdDSA signature and size. Sparkle's `minimumUpdateVersion` excludes older apps.
The app binds that metadata into its durable transaction before downloading.

Stable workload publication also requires `continuityAcceptance.path` under
`docs/updater-acceptance/` and its SHA-256. The evidence must name the frozen
source and target version, successful manual and automatic update receipts,
unchanged container identities/mounts, continuous logs, retained volume markers,
authoritative exit codes 0 and 7, and passing fault tests. Changing those evidence
bytes, omitting a path, substituting a build or recording an unknown result
rejects publication. A candidate cannot enter the stable feed.

GitHub's repository bot token cannot promote a draft when its frozen workflow
files differ from current master. Publication checks that condition and stops;
it never uses a fallback credential. Keep workflow changes in the source that
is qualified. Subsequent manifest/evidence commits can then publish those frozen
assets. Branch publication can promote verified assets but cannot change a feed.

Tag builds and human release publication do not create automatic-install entries.
Both feeds are written only by manifest-verified publication on tested master.
Informational versions cannot later be converted into installable entries. Feed
commit retries use the frozen manifest against fresh master and ordinary pushes.
Bot publication dispatches the Pages workflow explicitly.

Verify the resulting public asset metadata, pinned signatures, Pages deployment
and CLI transaction separately. Qualification-channel acceptance does not change
other rigs or opt them into candidates. [Updater ownership and recovery](updater-admission.md)
defines the supported update scope and retained failure states.
