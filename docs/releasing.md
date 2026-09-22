# Releasing Micropod

Releases are tag-driven: push a `v*` tag and `.github/workflows/release.yml`
builds the app, packages `Micropod.dmg`, and attaches it to a GitHub release.
The landing page's download button points at the stable permalink:

```
https://github.com/castlemilk/micropod/releases/latest/download/Micropod.dmg
```

so it always serves the newest release with no site changes.

## Signed + notarized builds

Unsigned DMGs still publish, but Gatekeeper will warn. To ship trusted builds,
configure these repo secrets (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `MACOS_CERTIFICATE` | `base64` of a Developer ID Application `.p12` export |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_SIGNING_IDENTITY` | e.g. `Developer ID Application: You (ABCDE12345)` |
| `NOTARY_API_KEY_BASE64` | `base64` of `AuthKey_<id>.p8` from App Store Connect |
| `NOTARY_KEY_ID` | the API key's ID |
| `NOTARY_ISSUER` | the issuer UUID (App Store Connect → Users and Access → Keys) |
| `APPLE_TEAM_ID` | 10-char team ID (reserved for future checks) |

Obtaining them:

1. Apple Developer Program membership ($99/yr) → create a **Developer ID
   Application** certificate in Certificates, Identifiers & Profiles.
2. Export the cert + private key from Keychain Access as `.p12`, then
   `base64 -i cert.p12 | pbcopy` into `MACOS_CERTIFICATE`.
3. App Store Connect → Users and Access → Integrations → App Store Connect
   API → generate a key; download `AuthKey_*.p8`, base64 it into
   `NOTARY_API_KEY_BASE64`; the Key ID and Issuer are shown on the same page.

## Cutting a release

```sh
git tag -a v0.4.0 -m "v0.4.0" && git push origin v0.4.0
# watch: gh run watch
# the release lands at github.com/castlemilk/micropod/releases
```

Local dry run (unsigned):

```sh
scripts/package_app.sh 0.4.0   # dist/Micropod.app + .tgz
scripts/make_dmg.sh            # dist/Micropod.dmg + .sha256
```

With credentials on your keychain:

```sh
scripts/make_dmg.sh --sign "Developer ID Application: …" \
    --notarize --key-profile micropod-notary
```

(`notarytool store-credentials micropod-notary …` once to create the profile.)
