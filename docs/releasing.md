# Releasing Micropod

Releases are **fully automated**. Push a `v*` tag and the `Release` workflow
builds, signs (Developer ID), notarizes, staples, and attaches a DMG to the
GitHub release. The landing page's download button points at the stable
permalink, so it always serves the newest release with no site changes:

```
https://github.com/castlemilk/micropod/releases/latest/download/Micropod.dmg
```

## Release checklist

1. Merge your work to `master` (pre-push hook runs build+test locally;
   the `CI` workflow re-runs lint + build + test on GitHub).
2. Pick the next semver and tag the merge commit:

   ```sh
   git checkout master && git pull --ff-only
   git tag -a v0.5.0 -m "v0.5.0"
   git push origin v0.5.0
   ```

3. Watch the run: `gh run watch` (or Actions → Release). ~5 min.
4. Verify:

   ```sh
   gh release view v0.5.0 --json assets --jq '.assets[].name'
   # expect: Micropod.dmg, Micropod.dmg.sha256, Micropod.<ver>.tgz

   curl -sLO https://github.com/castlemilk/micropod/releases/latest/download/Micropod.dmg
   spctl --assess --type open --context context:primary-signature Micropod.dmg
   # expect: "accepted — source=Notarized Developer ID"
   ```

5. Done — https://castlemilk.github.io/micropod/ serves it immediately.

## What the workflow does

`.github/workflows/release.yml`, on `v*` tag push, `macos-26` runner:

1. Imports the Developer ID certificate into a throwaway keychain.
2. Stores a `micropod-notary` notarytool profile (App Store Connect API key).
3. `scripts/package_app.sh` — release build + `.app` assembly + `.tgz`.
4. `scripts/make_dmg.sh --sign … --notarize --key-profile micropod-notary`:
   - inside-out signing: every Mach-O in `Contents/MacOS`, then the bundle,
     with `--options runtime` (hardened runtime) + `--timestamp`
   - `codesign --verify --deep --strict` gate
   - UDZO DMG with `/Applications` symlink
   - DMG signing, `notarytool submit --wait`, `stapler staple`
5. The tarball is repacked from the signed bundle, so its standalone
   `micropod` and `micropod-mcp-bin` are the same Developer ID binaries the
   app carries (`Contents/MacOS/micropod-cli`, `MicropodMCP`). The job fails
   if the bundle lacks them, because the CLI's self-update and the app's
   `~/.local/bin` links depend on them.
6. `gh release create` with the DMG + sha256 + tgz (or `--clobber` upload if
   the release already exists).

If the signing secrets are absent, the workflow publishes
`Micropod-unsigned.dmg` instead — deliberately a different name so it can
never overwrite a signed `Micropod.dmg` attached by a local run.

The `sdk` job (proto drift check, Go/TypeScript/Swift SDK builds and the
npm tarball) runs **in parallel** with the app build. `sdk-publish` then
attaches the tarball and tags `sdk/go/vX.Y.Z` once the release exists, so a
failed release never gets SDK artifacts.

### Where the time goes

Measured on v0.10.x, before these changes:

| step | time |
|---|---|
| pre-push hook on the tag push (local build + full test) | ~5 min |
| `swift build -c release` in "Build + package app" | 11 min of the job's 13 |
| sign + notarize + staple + DMG | ~1 min |
| `sdk` job, waiting for the release job | ~3 min |
| Pages deploy of the appcast | ~1 min, in parallel |

What's changed:
- **Tag pushes skip the local rebuild.** A tag names a commit that already
  passed CI and the branch-push hook.
- **A warm release build cache.** Every push to master runs CI's
  `release-build-cache` job, which saves the release `.build` (~1 GB). The
  Release workflow restores it, so only changed modules compile. The cache
  lives on master because a tag-triggered run can only restore caches from
  its own tag or the default branch. The key includes the Swift toolchain
  fingerprint and `Package.resolved`, so a toolchain or dependency change
  starts cold.
- **The SDK job is off the critical path.**

Measured on v0.11.1, the first warm run:
- 5.0 min of Actions time, down from 16–18
- the release build took 131 s instead of 658 s
- the cache restored in 18 s
- the tag push took 3 s instead of ~5 min

The first release after a toolchain or dependency bump builds cold.

Releases are serialized (`concurrency: release`). Two tags pushed
together once raced: v0.10.2 and v0.11.1 named the same commit, and one
lost the appcast push to master while the other lost GitHub's "Latest"
flag. The appcast step now re-applies its entry on master's tip and
retries. `gh release create` marks a release "Latest" only when no higher
version is already released, so the landing page never downgrades.

## Secrets (configured in repo → Settings → Secrets → Actions)

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | base64 `.p12` export of the Developer ID Application identity |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | `Developer ID Application: Ben Ebsworth (WFTX6CN23F)` |
| `NOTARY_API_KEY_BASE64` | base64 `AuthKey_NDW5V25889.p8` |
| `NOTARY_KEY_ID` | `NDW5V25889` |
| `NOTARY_ISSUER` | `f4c22181-b343-4e92-8fb3-e90dab991b8f` |
| `APPLE_TEAM_ID` | `WFTX6CN23F` |
| `SPARKLE_ED25519_KEY` | base64 EdDSA private key for appcast signing (`generate_keys -x keyfile && base64 -i keyfile`) |

Rotating: re-export the p12 / regenerate the ASC key, `gh secret set` the
new values. No code changes needed. **Do not rotate the Sparkle key** —
it is paired with `SUPublicEDKey` baked into shipped apps; rotating it
breaks update signature verification for every installed client. If the
private key is ever lost, generate a new pair, update `SUPublicEDKey` in
`scripts/package_app.sh`, and ship a build whose feed items are signed
with the new key.

## Auto-update (Sparkle)

The app embeds Sparkle (`SUFeedURL` → `https://castlemilk.github.io/micropod/appcast.xml`,
`SUPublicEDKey` in the packaged Info.plist, hourly checks). Users can also
trigger checks from the app menu, menu-bar panel, or Settings → Updates.

The appcast item is added automatically after the DMG ships:

- **Tag-push releases** (`release.yml`): signs the DMG with the Sparkle
  EdDSA key and pushes the updated `landing/appcast.xml` to `master`,
  which triggers the gh-pages deploy. (It lives in release.yml because
  `GITHUB_TOKEN`-created releases do not trigger `release:` workflows.)
- **Locally published releases**: `update-feed.yml` fires on
  `release: published`, downloads `Micropod.dmg` (verifying the `.sha256`
  sidecar), signs it, and does the same appcast push.

`scripts/update_appcast.mjs` inserts items newest-first and replaces an
existing item for the same version, so re-runs are safe.

The private key also lives in the local login keychain
(`generate_keys` already imported it) for local `sign_update` runs:

```sh
/tmp/sparkle/bin/sign_update dist/Micropod.dmg   # prints edSignature+length
```

Update signing is separate from codesigning/notarization: the EdDSA
signature proves the DMG came from whoever holds the appcast key, and
Sparkle additionally verifies the updated app's codesign identity matches
the running app before installing.

## Local release (fallback / testing)

```sh
scripts/package_app.sh 0.5.0          # dist/Micropod.app + .tgz
scripts/make_dmg.sh \
  --sign "Developer ID Application: Ben Ebsworth (WFTX6CN23F)" \
  --notarize --key-profile micropod-notary   # dist/Micropod.dmg + .sha256
gh release upload v0.5.0 dist/Micropod.dmg dist/Micropod.dmg.sha256
```

(`micropod-notary` keychain profile exists on Ben's machine; recreate with
`xcrun notarytool store-credentials micropod-notary --key <p8> --key-id
NDW5V25889 --issuer f4c22181-…`.)

## Rollback

```sh
gh release delete v0.5.0 --yes --cleanup-tag   # removes release + tag
git push origin :refs/tags/v0.5.0              # if tag pushed but no release
```

## Local git hooks

`task hooks` installs `.githooks/` via `core.hooksPath`:

- **pre-commit** — `bash -n` on staged shell scripts, `actionlint` on staged
  workflows, `swift format lint --strict` when Swift files are staged.
- **pre-push** — `swift build` + `swift test` (mirrors the CI build-test job);
  skipped when only tags are pushed (their commits were already gated).

Both honor `--no-verify` for emergencies.
