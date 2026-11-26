// scripts/verify_release_payload.sh refuses a release whose HVF runtime is
// absent, incomplete or unsigned. Run: node --test scripts/verify_release_payload.test.mjs
import assert from "node:assert/strict";
import { test, before, after } from "node:test";
import { spawnSync } from "node:child_process";
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "..");
const script = join(repo, "scripts/verify_release_payload.sh");
const entitlements = join(repo, "signing/micropod-vmm.entitlements");
const source = "0123456789abcdef0123456789abcdef01234567";
let scratch;
let vmmTemplate;

function run(command, args, options = {}) {
    const result = spawnSync(command, args, { encoding: "utf8", ...options });
    assert.equal(result.status, 0, `${command} ${args.join(" ")}: ${result.stderr}`);
    return result;
}

before(() => {
    scratch = mkdtempSync(join(tmpdir(), "verify-release-payload-test-"));
    // A real arm64 Mach-O, so codesign and lipo see what a release VMM is.
    vmmTemplate = join(scratch, "vmm-template");
    run("cc", ["-arch", "arm64", "-x", "c", "-", "-o", vmmTemplate], { input: "int main(void) { return 0; }\n" });
});
after(() => rmSync(scratch, { recursive: true, force: true }));

let serial = 0;
function fresh(name) {
    const dir = join(scratch, `${name}-${++serial}`);
    mkdirSync(dir, { recursive: true });
    return dir;
}

// A Linux ELF64 little-endian header for `machine` (0xb7 is AArch64).
function elf(machine = 0xb7) {
    const bytes = Buffer.alloc(64);
    Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]).copy(bytes);
    bytes.writeUInt16LE(2, 16);
    bytes.writeUInt16LE(machine, 18);
    return bytes;
}
function kernel() {
    const bytes = Buffer.alloc(256, 0x11);
    bytes.write("ARMd", 56, "latin1");
    return bytes;
}
const initrd = () => Buffer.from("070701" + "0".repeat(104) + "TRAILER!!!\0");

function file(path, bytes, mode = 0o644) {
    mkdirSync(dirname(path), { recursive: true });
    writeFileSync(path, bytes);
    chmodSync(path, mode);
}

// signVMM(path, how): "entitled" (as release packaging signs it), "plain"
// (validly signed without the hypervisor entitlement) or "unsigned".
function signVMM(path, how = "entitled") {
    if (how === "unsigned") return run("codesign", ["--remove-signature", path]);
    const extra = how === "entitled" ? ["--entitlements", entitlements] : [];
    run("codesign", ["--force", "--sign", "-", ...extra, path]);
}

// The HVF runtime in one layout: the VMM in `bin`, the rest in `resources`.
function payload(bin, resources, { engineCommit = source, engineDirty = false } = {}) {
    const vmm = join(bin, "micropod-vmm");
    mkdirSync(bin, { recursive: true });
    copyFileSync(vmmTemplate, vmm);
    chmodSync(vmm, 0o755);
    signVMM(vmm);
    file(join(resources, "vmlinux-hvf"), kernel());
    file(join(resources, "mp-hvf-init.cpio"), initrd());
    const tools = join(resources, "micropod-oci-tools");
    for (const name of ["crun-1.31-arm64", "runner/bin/containerd", "runner/bin/containerd-shim-runc-v2", "runner/bin/job", "runner/bin/buildkitd"]) {
        file(join(tools, name), elf(), 0o755);
    }
    file(join(tools, "runner/start.sh"), "#!/bin/sh\nexit 0\n", 0o755);
    file(join(tools, "runner/buildkitd.toml"), "[grpc]\n");
    file(join(tools, "runner/containerd.toml"), "version = 3\n");
    file(join(tools, "runner/manifest.json"), JSON.stringify({ engineCommit, engineDirty, cacheApi: 1, buildkit: "v0.26.2", capabilities: ["caches", "buildkit", "grpc-build"] }));
}

function app(dir, options) {
    const bundle = join(dir, "Micropod.app");
    payload(join(bundle, "Contents/MacOS"), join(bundle, "Contents/Resources"), options);
    file(join(bundle, "Contents/Info.plist"), "<plist/>\n");
    return bundle;
}

function verify(...args) {
    const result = spawnSync("bash", [script, ...args], { encoding: "utf8", env: { ...process.env, GITHUB_ACTIONS: "" } });
    return { status: result.status, stderr: result.stderr, stdout: result.stdout };
}

function assertRefused(result, ...fragments) {
    assert.equal(result.status, 1, `expected a refusal, got ${result.status}: ${result.stdout}${result.stderr}`);
    for (const fragment of fragments) assert.ok(result.stderr.includes(fragment), `stderr lacks "${fragment}":\n${result.stderr}`);
}

const assets = [
    ["Contents/MacOS/micropod-vmm", "HVF asset micropod-vmm is missing"],
    ["Contents/Resources/vmlinux-hvf", "HVF asset vmlinux-hvf is missing"],
    ["Contents/Resources/mp-hvf-init.cpio", "HVF asset mp-hvf-init.cpio is missing"],
    ["Contents/Resources/micropod-oci-tools", "HVF asset micropod-oci-tools/ (guest tool bundle) is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/bin/job", "HVF asset micropod-oci-tools/runner/bin/job is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/bin/buildkitd", "HVF asset micropod-oci-tools/runner/bin/buildkitd is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/bin/containerd", "HVF asset micropod-oci-tools/runner/bin/containerd is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/bin/containerd-shim-runc-v2", "micropod-oci-tools/runner/bin/containerd-shim-runc-v2 is missing"],
    ["Contents/Resources/micropod-oci-tools/crun-1.31-arm64", "HVF asset micropod-oci-tools/crun-1.31-arm64 is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/start.sh", "HVF asset micropod-oci-tools/runner/start.sh is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/buildkitd.toml", "HVF asset micropod-oci-tools/runner/buildkitd.toml is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/containerd.toml", "HVF asset micropod-oci-tools/runner/containerd.toml is missing"],
    ["Contents/Resources/micropod-oci-tools/runner/manifest.json", "HVF asset micropod-oci-tools/runner/manifest.json is missing"],
];

test("a complete app bundle passes and its assets are summarised with their sizes", () => {
    const bundle = app(fresh("complete"));
    const summary = join(scratch, "summary-complete.md");
    const result = verify("--source", source, "--summary", summary, bundle);
    assert.equal(result.status, 0, result.stderr);
    const table = readFileSync(summary, "utf8");
    for (const [name, bytes] of [["micropod-vmm", null], ["vmlinux-hvf", 256], ["mp-hvf-init.cpio", initrd().length]]) {
        const row = table.split("\n").find((line) => line.startsWith(`| Micropod.app | ${name} |`));
        assert.ok(row, `no summary row for ${name}:\n${table}`);
        const size = Number(row.split("|")[3]);
        assert.ok(size > 0, row);
        if (bytes !== null) assert.equal(size, bytes, row);
    }
    assert.match(table, /\| Micropod\.app \| micropod-oci-tools\/ \| [1-9][0-9]* \| 9 files \|/);
});

test("a bundle missing any one HVF asset fails and names it", () => {
    for (const [relative, message] of assets) {
        const bundle = app(fresh("missing"));
        rmSync(join(bundle, relative), { recursive: true, force: true });
        assertRefused(verify(bundle), message);
    }
});

test("every missing asset is reported, not just the first", () => {
    const bundle = join(fresh("empty"), "Micropod.app");
    mkdirSync(join(bundle, "Contents/MacOS"), { recursive: true });
    const result = verify(bundle);
    assertRefused(result, "micropod-vmm is missing", "vmlinux-hvf is missing", "mp-hvf-init.cpio is missing", "micropod-oci-tools/ (guest tool bundle) is missing");
    assert.match(result.stderr, /failed with 4 problem\(s\)/);
});

test("empty, symlinked, non-executable or foreign-architecture assets fail", () => {
    const cases = [
        ["Contents/Resources/vmlinux-hvf", (path) => writeFileSync(path, ""), "vmlinux-hvf is empty"],
        ["Contents/Resources/vmlinux-hvf", (path) => writeFileSync(path, Buffer.alloc(256)), "vmlinux-hvf is not an ARM64 Linux Image"],
        ["Contents/Resources/mp-hvf-init.cpio", (path) => writeFileSync(path, "not an initramfs"), "mp-hvf-init.cpio is not a cpio initramfs"],
        ["Contents/Resources/micropod-oci-tools/runner/bin/job", (path) => writeFileSync(path, elf(0x3e)), "runner/bin/job is not a Linux arm64 executable"],
        ["Contents/Resources/micropod-oci-tools/runner/bin/buildkitd", (path) => copyFileSync(vmmTemplate, path), "runner/bin/buildkitd is not a Linux arm64 executable"],
        ["Contents/Resources/micropod-oci-tools/runner/bin/job", (path) => chmodSync(path, 0o644), "runner/bin/job is not executable"],
        ["Contents/Resources/vmlinux-hvf", (path) => { const outside = join(dirname(path), "../../../kernel-elsewhere"); writeFileSync(outside, kernel()); rmSync(path); symlinkSync(outside, path); }, "vmlinux-hvf is a symlink"],
        ["Contents/Resources/micropod-oci-tools", (path) => { const outside = join(dirname(path), "../../../tools-elsewhere"); run("mv", [path, outside]); symlinkSync(outside, path); }, "micropod-oci-tools/ (guest tool bundle) is missing"],
        ["Contents/MacOS/micropod-vmm", (path) => writeFileSync(path, "#!/bin/sh\n"), "micropod-vmm is not an arm64 Mach-O"],
    ];
    for (const [relative, mutate, message] of cases) {
        const bundle = app(fresh("malformed"));
        mutate(join(bundle, relative));
        assertRefused(verify(bundle), message);
    }
});

test("an unsigned VMM, or one signed without the hypervisor entitlement, fails", () => {
    const unsigned = app(fresh("unsigned"));
    signVMM(join(unsigned, "Contents/MacOS/micropod-vmm"), "unsigned");
    assertRefused(verify(unsigned), "micropod-vmm is unsigned or its signature is invalid");

    const plain = app(fresh("plain"));
    signVMM(join(plain, "Contents/MacOS/micropod-vmm"), "plain");
    assertRefused(verify(plain), "micropod-vmm is not signed with com.apple.security.hypervisor");

    const tampered = app(fresh("tampered"));
    const vmm = join(tampered, "Contents/MacOS/micropod-vmm");
    const bytes = readFileSync(vmm);
    bytes[0x2000] ^= 0xff; // inside __TEXT: the code no longer matches its signature
    writeFileSync(vmm, bytes);
    assertRefused(verify(tampered), "micropod-vmm is unsigned or its signature is invalid");
});

test("--developer-id refuses an ad-hoc signed VMM and an unsealed app", () => {
    const bundle = app(fresh("adhoc"));
    assert.equal(verify(bundle).status, 0);
    assertRefused(verify("--developer-id", bundle), "micropod-vmm is not signed with a Developer ID Application identity",
        "micropod-vmm is not signed with the hardened runtime", "the app's signature does not seal its contents");
});

test("--source pins the guest engine to the release commit, built from a clean tree", () => {
    assertRefused(verify("--source", source, app(fresh("other-commit"), { engineCommit: "f".repeat(40) })),
        `was built from ${"f".repeat(40)}, not the release source ${source}`);
    assertRefused(verify("--source", source, app(fresh("dirty"), { engineDirty: true })), "was built from a modified tree");
    const bundle = app(fresh("no-buildkit"));
    writeFileSync(join(bundle, "Contents/Resources/micropod-oci-tools/runner/manifest.json"), JSON.stringify({ engineCommit: source, capabilities: [] }));
    assertRefused(verify(bundle), "does not declare the buildkit capability");
});

// The release tarball: the app plus the same runtime flat beside the CLI.
function tarball(dir, mutate = () => {}) {
    const tree = join(dir, "tree");
    app(tree);
    payload(tree, tree);
    mutate(tree);
    const archive = join(dir, "Micropod.9.9.9.tgz");
    const members = ["Micropod.app", "micropod-vmm", "vmlinux-hvf", "mp-hvf-init.cpio", "micropod-oci-tools"].filter((member) => existsSync(join(tree, member)));
    run("tar", ["-czf", archive, "-C", tree, ...members]);
    return archive;
}

test("the standalone tarball carries the runtime too, identical to the app's copy", () => {
    assert.equal(verify("--source", source, tarball(fresh("tgz"))).status, 0);
    assertRefused(verify(tarball(fresh("tgz-missing"), (tree) => rmSync(join(tree, "vmlinux-hvf")))), "Micropod.9.9.9.tgz: HVF asset vmlinux-hvf is missing");
    assertRefused(verify(tarball(fresh("tgz-app-missing"), (tree) => rmSync(join(tree, "Micropod.app/Contents/Resources/micropod-oci-tools/runner/bin/job")))),
        "Micropod.9.9.9.tgz: Micropod.app: HVF asset micropod-oci-tools/runner/bin/job is missing");
    assertRefused(verify(tarball(fresh("tgz-differs"), (tree) => writeFileSync(join(tree, "mp-hvf-init.cpio"), Buffer.concat([initrd(), Buffer.from("x")])))),
        "the standalone mp-hvf-init.cpio differs from the app's copy");
});

test("a DMG is checked through a read-only attach", (t) => {
    if (spawnSync("hdiutil", ["help"]).status === null) return t.skip("hdiutil is unavailable");
    const make = (name, mutate = () => {}) => {
        const dir = fresh(name);
        const staging = join(dir, "staging");
        mutate(app(staging));
        const dmg = join(dir, "Micropod.dmg");
        run("hdiutil", ["create", "-quiet", "-volname", "Micropod", "-srcfolder", staging, "-ov", "-format", "UDZO", dmg]);
        return dmg;
    };
    assert.equal(verify(make("dmg")).status, 0);
    assertRefused(verify(make("dmg-missing", (bundle) => rmSync(join(bundle, "Contents/MacOS/micropod-vmm")))), "Micropod.dmg: HVF asset micropod-vmm is missing");
});

test("usage errors and unknown targets never pass", () => {
    assert.equal(verify().status, 2);
    assert.equal(verify("--source", "master", app(fresh("usage"))).status, 2);
    assert.equal(verify("--source").status, 2);
    assertRefused(verify(join(scratch, "Micropod.zip")), "not an .app, .dmg or .tgz release target");
    assertRefused(verify(join(scratch, "absent.dmg")), "no disk image at");
});

// The release path runs the verifier with no skip: packaging, the DMG and
// the published tarball all go through it.
test("release packaging, the DMG build and the release workflow require the HVF payload", () => {
    const read = (path) => readFileSync(join(repo, path), "utf8");
    const has = (text, fragment, where) => assert.ok(text.includes(fragment), `${where} lacks ${fragment}`);
    const lacks = (text, pattern, where) => assert.ok(!pattern.test(text), `${where} still matches ${pattern}`);
    has(read("scripts/package_app.sh"), "bash scripts/verify_release_payload.sh", "package_app.sh");
    const makeDMG = read("scripts/make_dmg.sh");
    has(makeDMG, 'verify_release_payload.sh" "$APP"', "make_dmg.sh");
    has(makeDMG, 'verify_release_payload.sh" --developer-id "$APP"', "make_dmg.sh");
    const workflow = read(".github/workflows/release.yml");
    const step = (name, next) => {
        const start = workflow.indexOf(`- name: ${name}`);
        const end = workflow.indexOf(`- name: ${next}`, start);
        assert.ok(start >= 0 && end > start, `release.yml has no "${name}" step before "${next}"`);
        return workflow.slice(start, end);
    };
    lacks(step("Fetch qualified native runtime", "Build + package app"), /exit 0/, "the HVF fetch step");
    has(workflow, 'verify_release_payload.sh --developer-id --source "$GITHUB_SHA"', "release.yml");
    has(workflow, "node --test scripts/verify_release_payload.test.mjs", "release.yml");
    const repack = step("Repack tarball with signed binaries", "Upload release assets");
    lacks(repack, /if \[ -[fe] "\$bundle\/(MacOS\/\$helper|Resources\/\$resource|MacOS\/micropod-vmm)"/, "the tarball repack");
    has(repack, 'verify_release_payload.sh --developer-id --source "$GITHUB_SHA"', "the tarball repack");
});
