import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync, readdirSync, mkdtempSync, writeFileSync, rmSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createHash } from "node:crypto";
import { updateAppcast } from "./update_appcast.mjs";
import { releasePolicy, validateMetadata, validateTag, verifyAssets, publicationOptions, updaterPolicy, admitsWorkloadManifest } from "./verify_qualified_release.mjs";

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

test("workload candidates remain off the stable feed and carry exact compatibility/source", () => {
    const candidate = { ...manifest, tag: "v0.13.7", policy: "workload-preserving-candidate", workloadProtocol: 1, minimumUpdaterVersion: "0.13.6" };
    assert.throws(() => publicationOptions(candidate, "stable"), /cannot enter/);
    const options = publicationOptions(candidate, "qualification");
    const xml = updateAppcast(base, options);
    assert.match(xml, /<sparkle:minimumUpdateVersion>0.13.6<\/sparkle:minimumUpdateVersion>/);
    assert.match(xml, new RegExp(`micropodSourceRevision="${manifest.source}"`));
    assert.match(xml, /micropodWorkloadProtocol="1"/);
    assert.throws(() => publicationOptions({ ...candidate, workloadProtocol: 2 }, "qualification"), /unsupported/);
    assert.throws(() => publicationOptions({ ...candidate, minimumUpdaterVersion: "0.13.0" }, "qualification"), /unsupported/);
    assert.throws(() => updateAppcast(base, { ...options, "minimum-update-version": "0.12.7" }), /compatibility/);
    assert.throws(() => updateAppcast(base, { ...options, source: "master" }), /source/);
});

test("one updater policy file supplies the floor and protocol", () => {
    const policy = JSON.parse(readFileSync(new URL("../release/updater-policy.json", import.meta.url), "utf8"));
    assert.deepEqual(updaterPolicy(), policy);
    assert.equal(policy.schema, 1);
    assert.match(policy.minimumUpdateVersion, /^\d+\.\d+\.\d+$/);
    assert.ok(Number.isInteger(policy.workloadProtocol) && policy.workloadProtocol >= 1);
    const directory = mkdtempSync(join(tmpdir(), "micropod-policy-test-"));
    try {
        for (const invalid of [{}, { ...policy, schema: 2 }, { ...policy, minimumUpdateVersion: "0.13" }, { ...policy, workloadProtocol: "1" }, { ...policy, workloadProtocol: 0 }]) {
            writeFileSync(join(directory, "policy.json"), JSON.stringify(invalid));
            assert.throws(() => updaterPolicy(join(directory, "policy.json")), /policy|version/);
        }
    } finally { rmSync(directory, { recursive: true }); }
});

test("workload floors at or above the policy publish; lower floors and other protocols do not", () => {
    const policy = { schema: 1, minimumUpdateVersion: "0.13.6", workloadProtocol: 1 };
    const workload = (tag, minimumUpdaterVersion, workloadProtocol = 1) => ({ tag, minimumUpdaterVersion, workloadProtocol });
    assert.equal(admitsWorkloadManifest(workload("v0.13.9", "0.13.6"), policy), true);
    // A later, higher floor stays publishable rather than stranding the manifest.
    assert.equal(admitsWorkloadManifest(workload("v0.14.1", "0.14.0"), policy), true);
    assert.equal(admitsWorkloadManifest(workload("v0.13.10", "0.13.10"), policy), true);
    for (const rejected of [
        workload("v0.13.9", "0.13.5"), workload("v0.13.9", "0.13.3"), workload("v0.13.9", "0.9.99"),
        workload("v0.13.9", "0.14.0"), workload("v0.13.9", "0.13"), workload("v0.13.9", undefined),
        workload("v0.13.9", "0.13.6", 2), workload("v0.13.9", "0.13.6", "1")
    ]) assert.equal(admitsWorkloadManifest(rejected, policy), false, JSON.stringify(rejected));
});

test("appcast workload items carry the policy floor and protocol together", () => {
    const item = { version: "0.13.9", url: "https://github.com/castlemilk/micropod/releases/download/v0.13.9/Micropod.dmg", signature: "AAAA", length: 2, source: manifest.source };
    const xml = updateAppcast(base, { ...item, "minimum-update-version": "0.13.6", "workload-protocol": "1" });
    const entry = xml.match(/<item>[\s\S]*?<\/item>/)[0];
    assert.match(entry, /<sparkle:minimumUpdateVersion>0.13.6<\/sparkle:minimumUpdateVersion>/);
    assert.match(entry, /micropodWorkloadProtocol="1"/);
    // The CLI passes strings and the publisher passes manifest numbers.
    assert.equal(updateAppcast(base, { ...item, "minimum-update-version": "0.13.6", "workload-protocol": 1 }).includes('micropodWorkloadProtocol="1"'), true);
    assert.match(updateAppcast(base, { ...item, "minimum-update-version": "0.13.7", "workload-protocol": 1 }), /<sparkle:minimumUpdateVersion>0.13.7</);
    for (const [options, message] of [
        [{ "minimum-update-version": "0.13.6" }, /both/],
        [{ "workload-protocol": 1 }, /both/],
        [{ "minimum-update-version": "0.13.5", "workload-protocol": 1 }, /compatibility/],
        [{ "minimum-update-version": "0.13.10", "workload-protocol": 1 }, /compatibility/],
        [{ "minimum-update-version": "0.13", "workload-protocol": 1 }, /compatibility/],
        [{ "minimum-update-version": "0.13.6", "workload-protocol": 2 }, /protocol/],
        [{ "minimum-update-version": "0.13.6", "workload-protocol": "01" }, /protocol/],
        [{ "minimum-update-version": "0.13.6", "workload-protocol": true }, /protocol/]
    ]) assert.throws(() => updateAppcast(base, { ...item, ...options }), message, JSON.stringify(options));
});

test("every committed workload manifest can still publish under the current policy", () => {
    const directory = new URL("../docs/qualified-releases/", import.meta.url);
    for (const name of readdirSync(directory).filter((entry) => entry.endsWith(".json"))) {
        const frozen = JSON.parse(readFileSync(new URL(name, directory), "utf8"));
        assert.equal(`${frozen.tag}.json`, name);
        if (frozen.policy === "informational") continue;
        assert.ok(admitsWorkloadManifest(frozen), `${name} can never publish: remove it or requalify under the current policy`);
    }
});

// Comments may cite history; executable workflow text names no version, so
// the updater policy and tool pins each have one home outside the workflow.
test("workflows contain no version literals", () => {
    const directory = new URL("../.github/workflows/", import.meta.url);
    for (const name of readdirSync(directory).filter((entry) => /\.ya?ml$/.test(entry))) {
        const lines = readFileSync(new URL(name, directory), "utf8").split("\n");
        lines.forEach((line, index) => {
            const code = line.replace(/^\s*#.*$/, "").replace(/\s#.*$/, "");
            assert.doesNotMatch(code, /(?<![\w.])\d+\.\d+\.\d+(?![\w.])/, `${name}:${index + 1}: ${line.trim()}`);
        });
    }
});

test("qualification reserves the release tag so publication only flips draft", () => {
    const workflow = readFileSync(new URL("../.github/workflows/release.yml", import.meta.url), "utf8");
    assert.match(workflow, /git\/refs" \\\n\s+-f ref="refs\/tags\/\$VERSION" -f sha="\$GITHUB_SHA"/);
    assert.match(workflow, /-f ref="refs\/tags\/sdk\/go\/\$VERSION" -f sha="\$source"/);
    // The workflow-parity gate only remains for drafts frozen before tags were reserved.
    const gates = [...workflow.matchAll(/-- \.github\/workflows/g)];
    assert.equal(gates.length, 2);
    for (const gate of gates) {
        const preceding = workflow.slice(0, gate.index).split("\n").slice(-10).join("\n");
        assert.match(preceding, /! -s "\$RUNNER_TEMP\/tag-before\.txt"/);
    }
    // A tag for a frozen qualification never rebuilds or replaces its assets.
    for (const job of ["release", "sdk"]) {
        assert.match(workflow, new RegExp(`\\n  ${job}:\\n    needs: frozen-qualification\\n    if: needs\\.frozen-qualification\\.outputs\\.frozen != 'true' && `));
    }
});

test("stable workload publication requires untampered manual and automatic physical results", () => {
    const directory = mkdtempSync(join(tmpdir(), "micropod-continuity-test-"));
    try {
        const id = "test-operation";
        const snapshot = (name) => Buffer.from(JSON.stringify({ id: name, createdAt: "2026-11-16T00:00:00Z", image: "alpine", state: "running", mounts: [{ source: name + "-data" }] })).toString("base64");
        const hop = (automatic) => ({ id, automatic, passed: true, update: { schema: 1, phase: "succeeded", targetVersion: "0.13.8", targetSourceRevision: manifest.source }, workloads: [0, 7].map(code => ({ id: `job-${code}`, expectedExit: code, exit: code, artifact: id, logBefore: true, logAfter: true, streamCompleted: true, runtimeIdentityBefore: "boot-process-identity", runtimeIdentityAfter: "boot-process-identity", before: snapshot(`job-${code}`), after: snapshot(`job-${code}`) })) });
        const proof = { schema: 1, source: manifest.source, targetVersion: "0.13.8", faultTestsPassed: true, manual: hop(false), automatic: hop(true) };
        const path = "docs/updater-acceptance/v0.13.8.json";
        mkdirSync(join(directory, "docs/updater-acceptance"), { recursive: true });
        const stable = { ...manifest, tag: "v0.13.8", policy: "workload-preserving-v1", workloadProtocol: 1, minimumUpdaterVersion: "0.13.6", continuityAcceptance: { path, sha256: "" } };
        const save = (value) => {
            const bytes = Buffer.from(JSON.stringify(value));
            writeFileSync(join(directory, path), bytes);
            stable.continuityAcceptance.sha256 = createHash("sha256").update(bytes).digest("hex");
        };
        save(proof);
        assert.equal(publicationOptions(stable, "stable", directory).source, manifest.source);
        for (const mutate of [
            p => { p.manual.passed = false; },
            p => { p.automatic.automatic = false; },
            p => { p.automatic.update.targetSourceRevision = "wrong"; },
            p => { p.automatic.workloads[1].exit = 0; },
            p => { p.automatic.workloads[0].streamCompleted = false; },
            p => { p.manual.workloads[0].runtimeIdentityAfter = "rebooted"; },
            p => { p.manual.workloads[0].after = snapshot("replacement"); },
            p => { p.faultTestsPassed = false; },
            p => { p.automatic.error = "unknown exit"; }
        ]) {
            const changed = structuredClone(proof); mutate(changed); save(changed);
            assert.throws(() => publicationOptions(stable, "stable", directory));
        }
        save(proof);
        writeFileSync(join(directory, path), JSON.stringify({ ...proof, source: "tampered" }));
        assert.throws(() => publicationOptions(stable, "stable", directory), /bytes changed/);
        assert.throws(() => publicationOptions({ ...stable, continuityAcceptance: { path: "../evidence.json", sha256: "a".repeat(64) } }, "stable", directory), /evidence/);
    } finally { rmSync(directory, { recursive: true }); }
});
