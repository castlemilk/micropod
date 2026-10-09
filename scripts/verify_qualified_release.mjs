#!/usr/bin/env node
// Verification only: never creates, rebuilds, replaces or uploads release assets.
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const publicKey = "nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM=";
export function releasePolicy(release) {
    return release.assets.some((asset) => asset.name.startsWith("qualification-")) ? "qualified" : "installable";
}
export function validateTag(listing, manifest, required = false) {
    const refs = listing.trim().split("\n").filter(Boolean).map((line) => line.split(/\s+/));
    if (!refs.length) { if (required) throw new Error("published tag is missing"); return; }
    const tag = `refs/tags/${manifest.tag}`;
    if (refs.length > 2 || new Set(refs.map(([, ref]) => ref)).size !== refs.length) throw new Error("ambiguous tag reference");
    if (refs.some(([sha, ref]) => !/^[0-9a-f]{40}$/.test(sha) || ![tag, `${tag}^{}`].includes(ref))) throw new Error("unexpected tag reference");
    const resolved = refs.find(([, ref]) => ref === `${tag}^{}`) ?? refs.find(([, ref]) => ref === tag);
    if (!resolved || resolved[0] !== manifest.source) throw new Error("tag does not resolve to qualified source");
}
export function validateMetadata(release, manifest) {
    if (manifest.policy !== "informational" || !/^v\d+\.\d+\.\d+$/.test(manifest.tag) || !/^[0-9a-f]{40}$/.test(manifest.source)) {
        throw new Error("invalid qualified publication policy");
    }
    if (release.id !== manifest.releaseID || release.tag_name !== manifest.tag || release.target_commitish !== manifest.source || release.prerelease !== false || typeof release.draft !== "boolean") {
        throw new Error("release identity or source changed");
    }
    if (release.assets.length !== Object.keys(manifest.assets).length) throw new Error("release asset set changed");
    for (const [name, expected] of Object.entries(manifest.assets)) {
        const matches = release.assets.filter((asset) => asset.name === name);
        if (matches.length !== 1) throw new Error(`asset missing or duplicated: ${name}`);
        const asset = matches[0];
        if (asset.id !== expected.id || asset.size !== expected.size || asset.digest !== `sha256:${expected.sha256}` || asset.state !== "uploaded") {
            throw new Error(`qualified asset changed: ${name}`);
        }
    }
    if (releasePolicy(release) !== "qualified") throw new Error("not a qualified release");
}
export function verifyAssets(manifest, directory) {
    for (const [name, expected] of Object.entries(manifest.assets)) {
        const bytes = readFileSync(join(directory, name));
        if (bytes.length !== expected.size || createHash("sha256").update(bytes).digest("hex") !== expected.sha256) {
            throw new Error(`qualified bytes changed: ${name}`);
        }
    }
    const source = readFileSync(join(directory, "qualification-source.txt"), "utf8").trim();
    if (source !== manifest.source) throw new Error("qualification source mismatch");
    const sidecar = readFileSync(join(directory, "Micropod.dmg.sha256"), "utf8").trim();
    if (sidecar !== `${manifest.assets["Micropod.dmg"].sha256}  Micropod.dmg`) throw new Error("DMG sidecar mismatch");
    const key = createPublicKey({ key: Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(publicKey, "base64")]), format: "der", type: "spki" });
    if (!verify(null, readFileSync(join(directory, "Micropod.dmg")), key, Buffer.from(manifest.sparkleSignature, "base64"))) {
        throw new Error("DMG Sparkle signature does not match the pinned release key");
    }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
    try {
        const [mode, releasePath, manifestPath, directory] = process.argv.slice(2);
        if (mode === "--tag" || mode === "--published-tag") {
            validateTag(readFileSync(releasePath, "utf8"), JSON.parse(readFileSync(manifestPath, "utf8")), mode === "--published-tag");
        } else if (mode === "--policy") console.log(releasePolicy(JSON.parse(readFileSync(releasePath, "utf8"))));
        else if (mode === "--verify" && manifestPath && directory) {
            const release = JSON.parse(readFileSync(releasePath, "utf8"));
            const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
            validateMetadata(release, manifest);
            verifyAssets(manifest, directory);
            console.log("qualified source, immutable asset identities, hashes and pinned Sparkle signature accepted");
        } else throw new Error("expected --policy release.json or --verify release.json manifest.json assets-directory");
    } catch (error) { console.error(error.message); process.exitCode = 1; }
}
