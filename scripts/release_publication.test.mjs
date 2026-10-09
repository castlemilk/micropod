import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { updateAppcast } from "./update_appcast.mjs";
import { releasePolicy, validateMetadata, validateTag, verifyAssets } from "./verify_qualified_release.mjs";

const base = readFileSync(new URL("../landing/appcast.xml", import.meta.url), "utf8");
const announcement = { version: "0.12.6", url: "https://github.com/castlemilk/micropod/releases/tag/v0.12.6", informational: true, pubDate: "Fri, 09 Oct 2026 08:00:00 GMT" };
const manifest = JSON.parse(readFileSync(new URL("../docs/qualified-releases/v0.12.6.json", import.meta.url), "utf8"));
const release = () => ({
    id: manifest.releaseID, tag_name: manifest.tag, target_commitish: manifest.source,
    draft: true, prerelease: false,
    assets: Object.entries(manifest.assets).map(([name, a]) => ({ name, id: a.id, size: a.size, digest: `sha256:${a.sha256}`, state: "uploaded" }))
});
test("announcement has no payload and retains historical releases", () => {
    const result = updateAppcast(base, announcement);
    const item = result.match(/<item>[\s\S]*?<\/item>/)[0];
    assert.match(item, /<sparkle:version>0\.12\.6<\/sparkle:version>/);
    assert.match(item, /<sparkle:informationalUpdate\s*\/>/);
    assert.match(item, /<link>https:\/\/github.com\/castlemilk\/micropod\/releases\/tag\/v0.12.6<\/link>/);
    assert.doesNotMatch(item, /enclosure|edSignature|length=|sparkle:deltas/);
    assert.equal(result.match(/<enclosure\b/g).length, base.match(/<enclosure\b/g).length);
    assert.equal(updateAppcast(result, announcement), result);
});
test("refuses conversion based on authoritative version even if title changes", () => {
    const result = updateAppcast(base, announcement).replace("<title>Version 0.12.6</title>", "<title>Cache fix</title>");
    assert.throws(() => updateAppcast(result, { version: "0.12.6", url: announcement.url, signature: "AAAA", length: 1 }), /cannot turn/);
});
test("rejects duplicate, malformed and ambiguous policy before writing", () => {
    const item = updateAppcast(base, announcement).match(/<item>[\s\S]*?<\/item>/)[0];
    assert.throws(() => updateAppcast(base.replace("</channel>", item + item + "</channel>"), announcement), /duplicate/);
    assert.throws(() => updateAppcast(base.replace("</rss>", ""), announcement), /no element found/);
    assert.throws(() => updateAppcast(base.replace("<sparkle:version>0.12.2", "<sparkle:version>0.12.1"), announcement), /duplicate/);
    assert.throws(() => updateAppcast(base.replace("<item>", "<item><sparkle:version>0.12.6</sparkle:version>"), announcement), /ambiguous/);
});
test("alternate namespace prefixes and comments cannot bypass policy", () => {
    const result = updateAppcast(base, announcement);
    const alternate = result.replaceAll("sparkle:", "s:").replace("xmlns:sparkle=", "xmlns:s=");
    const installable = { version: "0.12.6", url: announcement.url, signature: "AAAA", length: 1 };
    assert.throws(() => updateAppcast(alternate, installable), /cannot turn/);
    const updated = updateAppcast(alternate, announcement);
    assert.equal(updated.match(/<sparkle:version>0.12.6<\/sparkle:version>/g).length, 1);
    const comment = "<!-- <sparkle:version>0.12.6</sparkle:version><enclosure/> -->";
    assert.throws(() => updateAppcast(result.replace("</item>", comment + "</item>"), installable), /cannot turn/);
    const encoded = result.replace("<sparkle:version>0.12.6", "<sparkle:version>0.12&#46;6");
    assert.throws(() => updateAppcast(encoded, installable), /cannot turn/);
});
test("announcement rejects payload arguments, unsafe links and invalid versions", () => {
    for (const options of [
        { signature: "AAAA" }, { length: 1 }, { url: "https://github.com/castlemilk/micropod/releases/download/v0.12.6/Micropod.dmg" },
        { url: "http://github.com/castlemilk/micropod/releases/tag/v0.12.6" }, { version: "../v0.12.6" }
    ]) assert.throws(() => updateAppcast(base, { ...announcement, ...options }));
});
test("ordinary signed release compatibility and XML escaping", () => {
    const result = updateAppcast(base, { version: "1.0.0", url: "https://example.org/app?x=1&y=2", signature: "AAAA", length: 2 });
    assert.match(result, /url="https:\/\/example.org\/app\?x=1&amp;y=2"/);
    assert.match(result, /sparkle:edSignature="AAAA"/);
});
test("qualified detection fails safe for incomplete qualification markers", () => {
    assert.equal(releasePolicy(release()), "qualified");
    assert.equal(releasePolicy({ assets: [{ name: "qualification-source.txt" }] }), "qualified");
    assert.equal(releasePolicy({ assets: [{ name: "Micropod.dmg" }] }), "installable");
    assert.throws(() => releasePolicy({}));
});
test("metadata pins source and every immutable asset field", () => {
    validateMetadata(release(), manifest);
    const published = release(); published.draft = false; validateMetadata(published, manifest);
    for (const [key, value] of [["id", 1], ["tag_name", "v0.12.5"], ["target_commitish", "master"], ["prerelease", true], ["draft", undefined]]) {
        const altered = release(); altered[key] = value; assert.throws(() => validateMetadata(altered, manifest));
    }
    for (let index = 0; index < release().assets.length; index++) {
        for (const [key, value] of [["id", 1], ["size", 1], ["digest", null], ["state", "new"], ["name", "other"]]) {
            const altered = release(); altered.assets[index][key] = value;
            assert.throws(() => validateMetadata(altered, manifest));
        }
    }
    for (const mutate of [(r) => r.assets.pop(), (r) => r.assets.push(r.assets[0]), (r) => r.assets[1] = r.assets[0]]) {
        const altered = release(); mutate(altered); assert.throws(() => validateMetadata(altered, manifest));
    }
});
test("absent draft tag allowed; published and existing tags pin exact source", () => {
    validateTag("", manifest);
    assert.throws(() => validateTag("", manifest, true), /missing/);
    validateTag(`${manifest.source}\trefs/tags/${manifest.tag}\n`, manifest, true);
    validateTag(`${"0".repeat(40)}\trefs/tags/${manifest.tag}\n${manifest.source}\trefs/tags/${manifest.tag}^{}\n`, manifest, true);
    assert.throws(() => validateTag(`${"0".repeat(40)}\trefs/tags/${manifest.tag}\n`, manifest), /qualified source/);
    assert.throws(() => validateTag(`${manifest.source}\trefs/tags/v9.9.9\n`, manifest), /unexpected/);
});
test("byte verification rejects tampering and an otherwise matching unsigned DMG", () => {
    const directory = mkdtempSync(join(tmpdir(), "micropod-publication-test-"));
    try {
        const small = structuredClone(manifest);
        for (const [name, spec] of Object.entries(small.assets)) {
            let bytes = Buffer.from(name);
            if (name === "qualification-source.txt") bytes = Buffer.from(small.source + "\n");
            if (name === "Micropod.dmg.sha256") bytes = Buffer.from(small.assets["Micropod.dmg"].sha256 + "  Micropod.dmg\n");
            spec.size = bytes.length; spec.sha256 = createHash("sha256").update(bytes).digest("hex");
            writeFileSync(join(directory, name), bytes);
        }
        assert.throws(() => verifyAssets(small, directory), /Sparkle signature/);
        writeFileSync(join(directory, "Micropod.dmg"), "tampered");
        assert.throws(() => verifyAssets(small, directory), /bytes changed/);
    } finally { rmSync(directory, { recursive: true }); }
});
