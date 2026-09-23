#!/usr/bin/env node
// Insert or replace a Sparkle appcast item for a release.
//
//   node scripts/update_appcast.mjs \
//     --version 0.5.0 \
//     --url https://github.com/castlemilk/micropod/releases/download/v0.5.0/Micropod.dmg \
//     --signature "…edSignature…" --length 12916426 \
//     [--appcast landing/appcast.xml]
//
// Items are kept newest-first; an item for the same version is replaced
// (idempotent re-runs of the release feed workflow).

import { readFileSync, writeFileSync } from "node:fs";

function arg(name, required = true) {
    const i = process.argv.indexOf(`--${name}`);
    const v = i >= 0 ? process.argv[i + 1] : null;
    if (required && !v) {
        console.error(`missing --${name}`);
        process.exit(2);
    }
    return v;
}

const version = arg("version").replace(/^v/, "");
const url = arg("url");
const signature = arg("signature");
const length = arg("length");
const appcastPath = arg("appcast", false) ?? "landing/appcast.xml";

const pubDate = new Date().toUTCString();
const item = `    <item>
      <title>Version ${version}</title>
      <pubDate>${pubDate}</pubDate>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:shortVersionString>${version}</sparkle:shortVersionString>
      <enclosure
        url="${url}"
        sparkle:edSignature="${signature}"
        length="${length}"
        type="application/octet-stream"/>
    </item>`;

let xml = readFileSync(appcastPath, "utf8");

// Remove any existing item for this version so re-runs replace rather
// than duplicate.
const itemRe = new RegExp(
    `    <item>\\s*\\n\\s*<title>Version ${version.replace(".", "\\.")}</title>[\\s\\S]*?</item>\\s*\\n`,
    "g",
);
xml = xml.replace(itemRe, "");

const marker = "<language>en</language>";
const i = xml.indexOf(marker);
if (i < 0) {
    console.error(`no ${marker} marker in ${appcastPath}`);
    process.exit(1);
}
xml = `${xml.slice(0, i + marker.length)}\n${item}\n${xml.slice(i + marker.length)}`;

writeFileSync(appcastPath, xml);
console.log(`appcast: added ${version} (${length} bytes)`);
