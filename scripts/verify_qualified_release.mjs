#!/usr/bin/env node
// Verification only: never creates, rebuilds, replaces or uploads release assets.
import { execFileSync } from "node:child_process";
import { createHash, createPublicKey, verify } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { updateAppcast } from "./update_appcast.mjs";

const publicKey = "nJEL+JijqhfC7zxPlqxifCqBM06A3DGki/JmBFTW/VM=";
// The one updater compatibility policy, shared with appcast_policy.py,
// package_app.sh (Info.plist) and the app's UpdaterPolicy.
export function updaterPolicy(path = new URL("../release/updater-policy.json", import.meta.url)) {
    const policy = JSON.parse(readFileSync(path, "utf8"));
    if (policy?.schema !== 1 || !Number.isInteger(policy.workloadProtocol) || policy.workloadProtocol < 1) {
        throw new Error("invalid updater policy");
    }
    releaseVersion(policy.minimumUpdateVersion);
    return policy;
}
// Canonical major.minor.patch: no leading zeros, because released apps
// (0.13.6-0.13.8) compare the floor as an exact string ("0.013.6" is not "0.13.6").
function releaseVersion(text) {
    if (typeof text !== "string" || !/^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(text)) throw new Error(`invalid version ${text}`);
    return text.split(".").map(Number);
}
function compareVersions(a, b) {
    const [left, right] = [releaseVersion(a), releaseVersion(b)];
    for (let i = 0; i < 3; i++) if (left[i] !== right[i]) return left[i] < right[i] ? -1 : 1;
    return 0;
}
// A workload manifest's floor may be the policy's or a later, higher one, but
// never lower: that would also admit updaters known not to retain workloads.
export function admitsWorkloadManifest(manifest, policy = updaterPolicy()) {
    if (manifest.workloadProtocol !== policy.workloadProtocol) return false;
    try {
        return compareVersions(manifest.minimumUpdaterVersion, policy.minimumUpdateVersion) >= 0 &&
            compareVersions(manifest.minimumUpdaterVersion, manifest.tag.slice(1)) <= 0;
    } catch { return false; }
}
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
    if (!["informational", "workload-preserving-candidate", "workload-preserving-v1"].includes(manifest.policy) || !/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(manifest.tag) || !/^[0-9a-f]{40}$/.test(manifest.source)) {
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

export function publicationOptions(manifest, channel, repository = process.cwd()) {
    if (!/^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.test(manifest.tag)) throw new Error("invalid publication version");
    if (manifest.policy === "informational") {
        if (channel !== "stable") throw new Error("announcements use the stable feed");
        return { version: manifest.tag, url: `https://github.com/castlemilk/micropod/releases/tag/${manifest.tag}`, informational: true };
    }
    if (!["workload-preserving-candidate", "workload-preserving-v1"].includes(manifest.policy) ||
        !admitsWorkloadManifest(manifest)) {
        throw new Error("unsupported workload publication policy");
    }
    if (manifest.policy === "workload-preserving-candidate" && channel !== "qualification") {
        throw new Error("an unaccepted candidate cannot enter the stable feed");
    }
    if (!["stable", "qualification"].includes(channel)) throw new Error("unknown feed channel");
    if (channel === "stable") {
        const evidence = manifest.continuityAcceptance;
        if (!evidence || !/^docs\/updater-acceptance\/v\d+\.\d+\.\d+\.json$/.test(evidence.path) ||
            !/^[0-9a-f]{64}$/.test(evidence.sha256)) throw new Error("missing continuity acceptance evidence");
        const bytes = readFileSync(join(repository, evidence.path));
        if (createHash("sha256").update(bytes).digest("hex") !== evidence.sha256) throw new Error("continuity acceptance bytes changed");
        const proof = JSON.parse(bytes);
        if (proof.schema !== 1 || proof.source !== manifest.source || proof.targetVersion !== manifest.tag.slice(1) ||
            proof.faultTestsPassed !== true || proof.manual?.passed !== true || proof.automatic?.passed !== true ||
            proof.automatic.update?.targetVersion !== manifest.tag.slice(1)) throw new Error("incomplete continuity acceptance");
        for (const hop of [proof.manual, proof.automatic]) {
            if (hop.update?.phase !== "succeeded" || hop.update.schema !== 1 || hop.workloads?.length !== 2 ||
                hop.error || hop.update.targetSourceRevision !== manifest.source ||
                hop.workloads.map(w => w.expectedExit).sort().join(",") !== "0,7" ||
                hop.workloads.some(w => w.exit !== w.expectedExit || !w.artifact || !w.logBefore || !w.logAfter || !w.streamCompleted || !w.before || !w.after || !w.runtimeIdentityBefore || w.runtimeIdentityBefore !== w.runtimeIdentityAfter)) {
                throw new Error("workload continuity or final results were not verified");
            }
            for (const workload of hop.workloads) {
                const before = JSON.parse(Buffer.from(workload.before, "base64").toString("utf8"));
                const after = JSON.parse(Buffer.from(workload.after, "base64").toString("utf8"));
                if (!before.id || before.id !== workload.id || before.id !== after.id || !before.createdAt ||
                    before.createdAt !== after.createdAt || before.image !== after.image || after.state !== "running" ||
                    JSON.stringify(before.mounts) !== JSON.stringify(after.mounts) || workload.artifact !== hop.id) {
                    throw new Error("workload identity or volume artifact changed");
                }
            }
        }
        if (proof.manual.automatic !== false || proof.automatic.automatic !== true) throw new Error("manual and automatic paths were not both accepted");
    }
    return { version: manifest.tag, url: `https://github.com/castlemilk/micropod/releases/download/${manifest.tag}/Micropod.dmg`,
        signature: manifest.sparkleSignature, length: manifest.assets["Micropod.dmg"].size,
        "minimum-update-version": manifest.minimumUpdaterVersion, "workload-protocol": manifest.workloadProtocol, source: manifest.source };
}
// qualification-source.txt: the qualified commit, then (only for a draft
// built for the VM release gate) "gate-security-floor=X.Y.Z". Nothing else.
export function qualificationSource(text) {
    const [source, ...fields] = text.trim().split("\n").map((line) => line.trim());
    if (!/^[0-9a-f]{40}$/.test(source ?? "")) throw new Error("qualification source mismatch");
    let gateSecurityFloor = null;
    for (const field of fields) {
        const match = /^gate-security-floor=(.*)$/.exec(field);
        if (!match || gateSecurityFloor !== null) throw new Error(`unknown qualification source field: ${field}`);
        gateSecurityFloor = match[1];
    }
    return { source, gateSecurityFloor };
}
// The first release that must ship a runtime component manifest
// (castlemilk/micropod#178; v0.13.9 is the newest release before it).
export const runtimeComponentsSince = "0.13.10";
const runtimeComponentsMember = "Micropod.app/Contents/Resources/runtime-components.json";
// The runtime component manifest inside the frozen tarball (as
// "Micropod.app/..." or "./Micropod.app/..."), or null for a release before
// runtimeComponentsSince. Fails closed: a missing manifest from that release
// on, a manifest anywhere else in the tarball, or more than one copy.
export function frozenRuntimeComponents(tgz, tag) {
    const listing = execFileSync("tar", ["-tzf", tgz], { maxBuffer: 64 << 20 }).toString("utf8").split("\n").filter(Boolean);
    const normalize = (name) => name.replace(/^(\.\/)+/, "").replace(/\/{2,}/g, "/");
    const named = listing.filter((name) => /(^|\/)runtime-components\.json$/.test(name));
    const members = named.filter((name) => normalize(name) === runtimeComponentsMember);
    if (named.length !== members.length) throw new Error(`runtime component manifest at an unexpected path: ${named.join(", ")}`);
    if (members.length > 1) throw new Error("the frozen tarball holds more than one runtime component manifest");
    if (members.length === 0) {
        if (compareVersions(tag.replace(/^v/, ""), runtimeComponentsSince) >= 0) {
            throw new Error(`${tag} must ship ${runtimeComponentsMember}`);
        }
        return null;
    }
    return JSON.parse(execFileSync("tar", ["-xzOf", tgz, members[0]], { maxBuffer: 1 << 20 }).toString("utf8"));
}
// The runtime security floor a release ships must be the one its reviewed
// record names (runtimeComponentsSecurityFloor: "X.Y.Z" or null), at most the
// release itself; a release without the component manifest names none.
export function checkRuntimeComponentsFloor(manifest, components) {
    const reviewed = manifest.runtimeComponentsSecurityFloor;
    if (components === null) {
        if (reviewed !== undefined && reviewed !== null) throw new Error("reviewed security floor but no runtime component manifest");
        return;
    }
    if (reviewed === undefined) throw new Error("runtimeComponentsSecurityFloor was not reviewed for this release");
    if (components.version !== manifest.tag.slice(1)) throw new Error("runtime component manifest names another release");
    const shipped = components.securityFloor ?? null;
    if (shipped !== reviewed) throw new Error(`runtime security floor ${shipped} is not the reviewed ${reviewed}`);
    if (shipped !== null && compareVersions(shipped, components.version) > 0) throw new Error("runtime security floor is above its release");
}
export function verifyAssets(manifest, directory) {
    for (const [name, expected] of Object.entries(manifest.assets)) {
        const bytes = readFileSync(join(directory, name));
        if (bytes.length !== expected.size || createHash("sha256").update(bytes).digest("hex") !== expected.sha256) {
            throw new Error(`qualified bytes changed: ${name}`);
        }
    }
    const { source, gateSecurityFloor } = qualificationSource(readFileSync(join(directory, "qualification-source.txt"), "utf8"));
    if (source !== manifest.source) throw new Error("qualification source mismatch");
    if (gateSecurityFloor !== null) throw new Error("a draft built with a VM-gate security floor is never published");
    const sidecar = readFileSync(join(directory, "Micropod.dmg.sha256"), "utf8").trim();
    if (sidecar !== `${manifest.assets["Micropod.dmg"].sha256}  Micropod.dmg`) throw new Error("DMG sidecar mismatch");
    const tarballs = Object.keys(manifest.assets).filter((name) => name === `Micropod.${manifest.tag.slice(1)}.tgz`);
    if (tarballs.length !== 1) throw new Error("the frozen tarball is missing");
    checkRuntimeComponentsFloor(manifest, frozenRuntimeComponents(join(directory, tarballs[0]), manifest.tag));
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
        } else if (mode === "--appcast") {
            const manifest = JSON.parse(readFileSync(releasePath, "utf8"));
            writeFileSync(manifestPath, updateAppcast(readFileSync(manifestPath, "utf8"), publicationOptions(manifest, directory)));
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
