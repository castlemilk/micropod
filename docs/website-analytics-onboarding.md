# Optional landing-page analytics (disabled)

This draft changes only the static Micropod landing page, not the native app, CLI, container runtime, API docs or inventories.
`landing/analytics-config.js` has no measurement ID or origin and stays `enabled:false` and `gaPrivacyReviewed:false`.

Before enabling, verify the actual deployment and canonical URL (source currently declares `https://castlemilk.github.io/micropod/`), use Micropod's own GA4 property, and review the public disclosure. Never use a sibling project's measurement ID.
In GA4 Admin disable Enhanced Measurement, Google Signals, advertising links, user-provided data and cross-domain measurement before setting `gaPrivacyReviewed:true`. Administrative settings are not verified automatically.

The code allows only `/micropod/` and `/micropod/index.html` on the configured exact origin. It excludes sibling GitHub Pages paths, docs, queries and fragments. GA cookies use `micropod` prefix, `/micropod/` path and no parent-domain expansion. Consent storage uses a project-specific key. This is not a host-wide tracker. Cookie path and prefix reduce collisions, but do not security-isolate JavaScript on sibling same-origin sites.

When configured, the opt-in disclosure explains Google/browser/network/cookie usage, and refusal is equally available. Denial sends nothing to Google. Acceptance permits one fixed page_view plus `download_intent` for the annotated DMG link (not a verified install/download). No link URLs, container inventories, form text or identities are supplied as custom fields. DNT and GPC prevent initialization. Withdrawal disables GA first and reloads only if denial/removal was saved; a storage failure keeps this document stopped and tells the person to close the tab. Existing cookies can remain; submitted requests cannot be recalled.

No Flaggr SDK or invented CDN pin is included. Verified project/site ownership and a released bundle containing the tested transmission-stop contract in skunkworq/flaggr PR #200 are prerequisites for a separate, opt-in integration. The stop is not full observer teardown.

Validation: `node --test scripts/website-analytics.test.cjs` is hermetic. Provider delivery, Google admin settings, live release and OpenSEO linkage must be verified separately. Do not call analytics active merely because the draft's mocked tests pass.
