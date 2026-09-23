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
5. `gh release create` with the DMG + sha256 + tgz (or `--clobber` upload if
   the release already exists).

If the signing secrets are absent, the workflow publishes
`Micropod-unsigned.dmg` instead — deliberately a different name so it can
never overwrite a signed `Micropod.dmg` attached by a local run.

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

Rotating: re-export the p12 / regenerate the ASC key, `gh secret set` the
new values. No code changes needed.

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
- **pre-push** — `swift build` + `swift test` (mirrors the CI build-test job).

Both honor `--no-verify` for emergencies.
