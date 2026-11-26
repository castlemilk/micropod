"""Prepare and sign the private worker disk cache comparison from the sealed product."""

import argparse
import fcntl
from hashlib import sha256
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

from build_delivery import BASE, CLI_INFO, HERE, digest


SOURCE = "Sources/MicropodRuntime/SandboxVM.swift"
PATCH = HERE / "worker-disk-cache.patch"
PRIOR = HERE / "sibling-job-parent-product.json"
MANIFEST = HERE / "sibling-worker-disk-cache-product.json"
CONTAINERIZATION = {"revision": "c0185aea5c04fcd4d1cfe9359e0066a380835403", "version": "0.42.0"}
ENTITLEMENTS = {"com.apple.security.virtualization": True}
PATH_OPTIONS = {"--scratch-path": "build", "--cache-path": "cache", "--config-path": "config",
                "--security-path": "security"}


def read(path):
    return json.loads(path.read_bytes())


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def clone(source, destination):
    subprocess.run(["/bin/cp", "-cR", source, destination], check=True)


def check_sources(source, expected):
    require(all(digest(source / file) == sha for file, sha in expected.items()), "worker source snapshot changed")


def check_dependencies(source, scratch):
    pins = read(source / "Package.resolved")["pins"]
    exact, = [pin["state"] for pin in pins if pin["identity"] == "containerization"]
    require(exact == CONTAINERIZATION, "wrong Apple Containerization pin")
    for pin in pins:
        checkout = scratch / "checkouts" / pin["identity"]
        commit = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"], text=True).strip()
        diff = subprocess.check_output(["git", "-C", checkout, "status", "--porcelain", "--untracked-files=no"])
        require(commit == pin["state"]["revision"] and not diff, f"dependency checkout changed: {pin['identity']}")


def inputs():
    manifest = read(PRIOR)
    previous = Path(manifest["current_product"]).resolve()
    base, prior = previous.parent, read(previous)
    require(base.parent == BASE and previous.name == "product.json"
            and prior["base_revision"] == manifest["base_revision"]
            and prior["entitlements"] == ENTITLEMENTS == manifest["entitlements"]
            and prior["guest_runner_sha256"] == manifest["new_guest_sha256"]
            and prior["guest_start_sha256"] == manifest["bootstrap_sha256"]
            and digest(base / "micropod") == prior["worker_executable_sha256"] == manifest["host_sha256"]
            and digest(base / "worker.patch") == prior["patch_sha256"] == manifest["patch_sha256"],
            "wrong sealed worker product")
    verify_guest(base, prior)
    check_sources(base / "src", prior["compiled_sources"])
    command = prior["command"]
    require(command[:3] == ["xcrun", "swift", "build"], "unknown release build command")
    donor = Path(command[command.index("--scratch-path") + 1]).resolve()
    require(donor.name == "build" and donor.parent.parent == BASE, "unexpected previous Swift release cache")
    require(digest(donor.parent / "micropod") == manifest["host_sha256"], "Swift cache is from a different host release")
    check_dependencies(base / "src", donor)
    patch = PATCH.read_bytes()
    files = [line for line in patch.splitlines() if line.startswith((b"--- ", b"+++ "))]
    require(files == [f"--- a/{SOURCE}".encode(), f"+++ b/{SOURCE}".encode()],
            "disk cache patch must edit only the frozen SandboxVM source")
    key = sha256(previous.read_bytes() + b"\x00" + patch).hexdigest()[:16]
    return previous, prior, donor, patch, BASE / f"ci-published-link-{key}"


def verify_guest(scope, record):
    tools = scope / "micropod-oci-tools"
    for file, key in (("runner/bin/job", "guest_runner_sha256"), ("runner/start.sh", "guest_start_sha256"),
                      ("runner/published-ports.sh", "guest_publication_script_sha256")):
        require(digest(tools / file) == record[key], f"sealed guest artifact changed: {file}")


def apply_patch(source, patch):
    subprocess.run(["patch", "-s", "-p1", "-d", source], input=patch, check=True)


def prepare(previous, prior, donor, patch, scope):
    if not scope.exists():
        with tempfile.TemporaryDirectory(prefix="worker-disk-cache-", dir=BASE) as work:
            stage = Path(work) / "prepare"
            stage.mkdir()
            source = stage / "src"
            clone(previous.parent / "src", source)
            apply_patch(source, patch)
            compiled = {**prior["compiled_sources"], SOURCE: digest(source / SOURCE)}
            require(compiled[SOURCE] != prior["compiled_sources"][SOURCE], "missing disk cache experiment")
            check_sources(source, compiled)
            (stage / "worker.patch").write_bytes((previous.parent / "worker.patch").read_bytes() + patch)
            (stage / PATCH.name).write_bytes(patch)
            record = {key: prior[key] for key in ("base_revision", "publication_key", "guest_mtu_at_boot",
                      "guest_runner_sha256", "guest_start_sha256", "guest_publication_script_sha256")}
            record.update(arena=str(scope), compiled_sources=compiled, patch_sha256=digest(stage / "worker.patch"),
                          worker_disk_cache_patch_sha256=digest(stage / PATCH.name),
                          source_product=str(previous), source_product_sha256=digest(previous),
                          swift_cache_donor=str(donor), containerization=CONTAINERIZATION)
            save(stage / "prepared.json", record)
            stage.rename(scope)
    record = read(scope / "prepared.json")
    require(record["source_product_sha256"] == digest(previous)
            and record["worker_disk_cache_patch_sha256"] == digest(PATCH) == digest(scope / PATCH.name)
            and record["patch_sha256"] == digest(scope / "worker.patch")
            and {key: sha for key, sha in record["compiled_sources"].items() if key != SOURCE}
            == {key: sha for key, sha in prior["compiled_sources"].items() if key != SOURCE},
            "prepared disk cache recipe changed")
    check_sources(scope / "src", record["compiled_sources"])
    return record


def build(previous, prior, donor, scope, record, jobs):
    product = scope / "product.json"
    exe = scope / "micropod"
    source = scope / "src"
    with (scope / "release.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if not product.exists():
            if not (scope / "build").exists():
                # Clang PCM files embed their module-cache path. Reuse the
                # exact offline dependencies and let this arena compile them.
                with tempfile.TemporaryDirectory(prefix="swift-dependencies-", dir=scope) as work:
                    scratch = Path(work) / "build"
                    scratch.mkdir()
                    for item in ("checkouts", "artifacts", "repositories", "workspace-state.json"):
                        clone(donor / item, scratch / item)
                    scratch.rename(scope / "build")
            check_dependencies(source, scope / "build")
            command = list(prior["command"])
            for flag, name in PATH_OPTIONS.items():
                command[command.index(flag) + 1] = str(scope / name)
            command[command.index("--jobs") + 1] = str(jobs)
            env = {**os.environ, "GIT_ALLOW_PROTOCOL": "file", "CLANG_MODULE_CACHE_PATH": str(scope / "clang-modules"),
                   "SWIFTPM_MODULECACHE_OVERRIDE": str(scope / "modules")}
            with (scope / "build.log").open("ab") as log:
                subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
            check_sources(source, record["compiled_sources"])
            check_dependencies(source, scope / "build")
            shutil.copy2(scope / "build/arm64-apple-macosx/release/micropod", exe)
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements",
                            source / "signing/micropod-cli.entitlements", exe], check=True)
            require(digest(exe) != prior["worker_executable_sha256"] and b"micropod-bench-worker-disk " in exe.read_bytes(),
                    "Swift build did not emit the modified disk-cache worker")
            actual = plistlib.loads(subprocess.check_output(
                ["codesign", "-d", "--entitlements", "-", "--xml", exe], stderr=subprocess.DEVNULL))
            embedded = subprocess.check_output(["xcrun", "otool", "-X", "-P", exe])
            info = plistlib.loads(embedded[embedded.index(b"<?xml"):embedded.index(b"</plist>") + len(b"</plist>")])
            require(actual == ENTITLEMENTS and info == plistlib.loads((source / CLI_INFO).read_bytes()),
                    "incorrect signed worker entitlements or embedded local-network description")
            tools = scope / "micropod-oci-tools"
            if not tools.exists():
                clone(previous.parent / "micropod-oci-tools", tools)
            shutil.copy2(previous.parent / "micropod-oci", scope / "micropod-oci")
            verify_guest(scope, record)
            record.update(worker_executable=str(exe), worker_executable_sha256=digest(exe), entitlements=actual,
                          embedded_cli_info=info, command=command, build_log_sha256=digest(scope / "build.log"))
            save(product, record)
        subprocess.run(["codesign", "--verify", "--strict", exe], check=True)
        require(read(product)["worker_executable_sha256"] == digest(exe), "signed experiment executable changed")
        verify_guest(scope, read(product))
    return product


def manifest(previous, prior, scope, record):
    product = scope / "product.json"
    candidate = read(product)
    exe = scope / "micropod"
    require(all(candidate[key] == value for key, value in record.items())
            and candidate["worker_executable"] == str(exe)
            and digest(exe) == candidate["worker_executable_sha256"] != prior["worker_executable_sha256"]
            and b"micropod-bench-worker-disk " in exe.read_bytes(),
            "worker disk cache release does not match its preparation")
    require(digest(scope / "build.log") == candidate["build_log_sha256"], "worker disk cache build log changed")
    subprocess.run(["codesign", "--verify", "--strict", exe], check=True)
    verify_guest(scope, candidate)
    receipt = {
        "current_product": str(product), "previous_product": str(previous),
        "old_host_sha256": prior["worker_executable_sha256"], "host_sha256": candidate["worker_executable_sha256"],
        "new_guest_sha256": candidate["guest_runner_sha256"], "new_bootstrap_sha256": candidate["guest_start_sha256"],
        "base_revision": candidate["base_revision"], "entitlements": candidate["entitlements"],
        "changed_packaged_inputs": [SOURCE], "sha256_by_changed_input": {SOURCE: record["compiled_sources"][SOURCE]},
        "worker_disk_cache_patch_sha256": record["worker_disk_cache_patch_sha256"],
    }
    if MANIFEST.exists():
        require(read(MANIFEST) == receipt, "previous worker disk cache manifest has different inputs")
    else:
        save(MANIFEST, receipt)
    return MANIFEST


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("check", "prepare", "build", "manifest"))
    parser.add_argument("--jobs", type=int, default=4)
    args = parser.parse_args()
    require(args.jobs > 0, "expected positive build concurrency")
    previous, prior, donor, patch, scope = inputs()
    if args.action == "check":
        with tempfile.TemporaryDirectory(prefix="worker-disk-cache-check-") as work:
            source = Path(work)
            (source / SOURCE).parent.mkdir(parents=True)
            shutil.copy2(previous.parent / "src" / SOURCE, source / SOURCE)
            apply_patch(source, patch)
            print("SandboxVM.swift SHA-256", digest(source / SOURCE))
        return
    record = prepare(previous, prior, donor, patch, scope)
    if args.action == "prepare":
        result = scope
    elif args.action == "manifest":
        result = manifest(previous, prior, scope, record)
    else:
        result = build(previous, prior, donor, scope, record, args.jobs)
    print(result, flush=True)


if __name__ == "__main__":
    main()
