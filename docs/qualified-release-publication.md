# Publishing frozen qualified assets

Dispatch `release.yml` with `publication_version=vX.Y.Z` after exact-source CI
passes. The reviewed `docs/qualified-releases/vX.Y.Z.json` pins the qualification
run, source, release ID, complete asset IDs/sizes/SHA-256 hashes and the DMG's
Sparkle signature. Publication verifies those bytes before and after promoting
the existing release. It does not rebuild, replace assets, or create or move
`vX.Y.Z`, which qualification reserved at the frozen source. Just before the
release becomes public it creates `sdk/go/vX.Y.Z` at that source (refusing one
that names another commit), so only published releases become Go module
versions. `sdk/go/*` does not match the `v*` tag trigger, so it starts no build.

**The runtime security floor.** A release that ships a runtime component
manifest (`Micropod.app/Contents/Resources/runtime-components.json`, castlemilk/micropod#178)
must name its floor in the reviewed record: `"runtimeComponentsSecurityFloor":
"X.Y.Z"` or `null`. Publication extracts the manifest from the frozen tarball
and refuses unless its `securityFloor` is exactly that value, at most the
release itself, and the manifest names this release. The member may be
`Micropod.app/...` or `./Micropod.app/...`; any other copy of
`runtime-components.json` in the tarball, or more than one, is refused. From
v0.13.10 on (`runtimeComponentsSince`, the first release after #178) the
manifest is required; an older release without it must not name a floor.
`scripts/write_runtime_components.sh` already refuses to build a floor above
the release. The floor is permanent on every rig that installs
the release (root refuses anything below it), so it is reviewed like the
version itself.

**VM-gate drafts are never published.** A qualification dispatched with
`qualification_security_floor` (docs/vm-release-gate.md) records
`gate-security-floor=X.Y.Z` in `qualification-source.txt`, and publication
refuses that draft whatever its record says. Delete such drafts and their tags
when the gate is done: `gh release delete vX.Y.Z -R castlemilk/micropod --cleanup-tag --yes`.

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
is rejected. Versions are canonical `major.minor.patch` with no leading zeros,
because released 0.13.6–0.13.8 apps compare the floor as an exact string.

The publisher reads only `docs/qualified-releases/vX.Y.Z.json`. An unpublished
manifest there must still be publishable under the policy; one the policy has
outgrown moves to `docs/qualified-releases/archive/`, which keeps the record and
is never read. A manifest whose version a committed feed already carries stays
where it is. A test enforces all three.

Stable workload publication also requires `continuityAcceptance.path` under
`docs/updater-acceptance/` and its SHA-256. The evidence must name the frozen
source and target version, successful manual and automatic update receipts,
unchanged container identities/mounts, continuous logs, retained volume markers,
authoritative exit codes 0 and 7, and passing fault tests. Changing those evidence
bytes, omitting a path, substituting a build or recording an unknown result
rejects publication. A candidate cannot enter the stable feed.

Qualification reserves `vX.Y.Z` at the dispatched master commit before
building, only from master. GitHub refuses the repository bot token
(`GITHUB_TOKEN`) a ref or release at a commit whose workflow files no existing
ref carries; master's head always qualifies. A qualification that fails or is
cancelled before creating a release deletes the tag whenever it still names
its source and no release exists for the version, including a reservation an
interrupted earlier run left behind. A tag push that names frozen qualified
assets skips the build rather than replacing them; an unreadable release
listing stops that tag build instead of letting it run.

The reserved tag does not make publication free. GitHub's
[Update a release](https://docs.github.com/en/rest/releases/releases#update-a-release)
endpoint also requires a token that may modify workflows when the release's
target commit adds or modifies files under `.github/workflows/` relative to the
default branch, and `GITHUB_TOKEN` can never be given that; the endpoint answers
404. So before any mutation, publication compares the frozen source's workflows
with master (`scripts/release_workflow_parity.sh`, any difference counts) for
every draft, tagged or not, and for a stable release that still needs Latest:

- Same workflows: `GITHUB_TOKEN` creates the Go module tag and publishes.
- Different workflows and no `RELEASE_WORKFLOWS_TOKEN`: publication stops with
  a readable error naming the changed files. Qualify a fresh version from
  master.
- Different workflows and `RELEASE_WORKFLOWS_TOKEN` configured: that token
  creates the Go module tag and makes the release `PATCH` calls, and nothing
  else. It is chosen only for publication from master, and only after the job
  confirms the `release-publication` environment requires reviewers, does not
  let administrators bypass them, and deploys from exactly one branch policy,
  `master`. Every other call uses `GITHUB_TOKEN`, and the promote step unsets
  the token on its first line so no repository script sees it.

A draft without a tag (qualified before tags were reserved) is published only
with matching workflows and never with the workflows token: publishing it
creates its tag, and a tag created by that token would start the release
workflow as it was at the frozen source, which predates the frozen-qualification
guard and rebuilds and replaces the assets. Qualify a fresh version instead.

### Setting up `RELEASE_WORKFLOWS_TOKEN`

The `publish-qualified` job runs in the `release-publication` environment, and
publication runs from master only. GitHub creates the environment, unprotected,
on the first publication if it does not exist; the token is refused until the
environment is locked down as below. To enable it:

1. In Settings → Environments → `release-publication`:
   - add required reviewers, and leave "Allow administrators to bypass
     configured protection rules" off;
   - under Deployment branches and tags choose "Selected branches and tags" and
     add exactly one branch rule, `master`.
2. Create a token that can modify workflows, limited to this repository:
   - a fine-grained personal access token with access to `castlemilk/micropod`
     only, repository permissions Contents: read and write and Workflows: read
     and write (Metadata: read is implied), and a short expiry; or
   - an installation token of a GitHub App installed only on this repository
     with the same permissions. It expires after an hour, so store a fresh
     one immediately before dispatching.
3. Add it as an environment secret named `RELEASE_WORKFLOWS_TOKEN` of
   `release-publication`. Never add it as a repository or organization secret:
   the `publication-inputs` job, which has no environment, fails every
   dispatch if it can see a `RELEASE_WORKFLOWS_TOKEN`, and publication waits on
   that job.

Once the environment requires reviewers, every publication waits for a
reviewer's approval, whether or not it needs the token. The token is masked in
logs and never reaches the verification or feed steps. Remove it, or let it
expire, when the publication is done.

The v0.13.6–v0.13.8 drafts were built from 2922fcc1, before the pending-start,
version manifest and drain-timeout fixes, and are superseded: new candidates are
qualified from master rather than published.

Tag builds and human release publication do not create automatic-install entries.
Both feeds are written only by manifest-verified publication on tested master.
Informational versions cannot later be converted into installable entries. Feed
commit retries use the frozen manifest against fresh master and ordinary pushes.
Bot publication dispatches the Pages workflow explicitly.

Verify the resulting public asset metadata, pinned signatures, Pages deployment
and CLI transaction separately. Qualification-channel acceptance does not change
other rigs or opt them into candidates. [Updater ownership and recovery](updater-admission.md)
defines the supported update scope and retained failure states.
