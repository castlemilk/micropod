# Publishing frozen qualified assets

Dispatch `release.yml` with `publication_version=vX.Y.Z` after exact-source CI
passes. The reviewed `docs/qualified-releases/vX.Y.Z.json` pins the qualification
run, source, release ID, complete asset IDs/sizes/SHA-256 hashes and the DMG's
Sparkle signature. Publication verifies those bytes before and after promoting
the existing release. It does not rebuild, replace assets or move the release
tag. It adds `sdk/go/vX.Y.Z` at the frozen source so the Go module version
exists for every published release.

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

`release/updater-policy.json` is the one updater policy: the oldest version
whose updater retains workloads (`minimumUpdateVersion`) and the workload
protocol. Packaging writes it into Info.plist (`MicropodMinimumUpdateVersion`,
`MicropodWorkloadProtocol`); the feed scripts and this publisher read the same
file, and no workflow names a version. A workload manifest needs the policy's
`workloadProtocol` and a `minimumUpdaterVersion` no lower than the policy's
floor and no higher than its own version. Its enclosure carries the exact source
revision, workload protocol (`micropodWorkloadProtocol`), EdDSA signature and
size. Sparkle's `minimumUpdateVersion` excludes older apps. The app admits an
item whose floor is at or above its own packaged floor, whose floor it meets and
whose protocol it speaks, then binds that metadata into its durable transaction
before downloading. Raising the floor therefore never strands newer apps, while
a floor below it, which would also admit updaters known not to retain workloads,
is rejected. A manifest that can no longer publish under the policy is removed;
a test enforces that.

Stable workload publication also requires `continuityAcceptance.path` under
`docs/updater-acceptance/` and its SHA-256. The evidence must name the frozen
source and target version, successful manual and automatic update receipts,
unchanged container identities/mounts, continuous logs, retained volume markers,
authoritative exit codes 0 and 7, and passing fault tests. Changing those evidence
bytes, omitting a path, substituting a build or recording an unknown result
rejects publication. A candidate cannot enter the stable feed.

Qualification reserves the release tag at the dispatched master commit before
building. GitHub needs the `workflows` permission, which the repository bot token
never holds, to create a ref or release at a commit whose workflow files no
existing ref carries. Publishing a tagless draft creates its tag at the frozen
source, so once master moved past a workflow change the draft could not be
published. With the tag reserved while the commit is master's head, publication
only flips `draft`, whatever has since changed on master. A failed qualification
that created no release deletes its reservation. A tag push that names frozen
qualified assets skips the build rather than replacing them.

Drafts qualified before tags were reserved have no tag. Publication still checks
their workflow parity with master and stops, naming the tag to create; it never
uses a fallback credential. Prefer qualifying a fresh version from current
master. To publish such a draft anyway, a maintainer disables the Release
workflow, creates `refs/tags/vX.Y.Z` at the manifest's source with their own
credentials, re-enables the workflow and dispatches publication again. The tag
push runs the workflow as it was at that source, which predates the
frozen-qualification guard and would replace the frozen assets, so it must not
run. Branch publication can promote verified assets but cannot change a feed.

Tag builds and human release publication do not create automatic-install entries.
Both feeds are written only by manifest-verified publication on tested master.
Informational versions cannot later be converted into installable entries. Feed
commit retries use the frozen manifest against fresh master and ordinary pushes.
Bot publication dispatches the Pages workflow explicitly.

Verify the resulting public asset metadata, pinned signatures, Pages deployment
and CLI transaction separately. Qualification-channel acceptance does not change
other rigs or opt them into candidates. [Updater ownership and recovery](updater-admission.md)
defines the supported update scope and retained failure states.
