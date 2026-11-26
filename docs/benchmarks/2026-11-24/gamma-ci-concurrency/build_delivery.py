"""Build the production private-link changes from a recorded source snapshot on Gamma."""

import argparse
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
BASE = ROOT / ".build/local-published-tcp"
DONOR = BASE / "private-pub-mtu-86ca2713"
CLI_INFO = "signing/micropod-cli-info.plist"
CPUB = "Sources/CPublishedTCP/PublishedTCP.c"
RUNNER_INPUTS = [str(path.relative_to(ROOT)) for path in sorted((ROOT / "guest/runner").glob("*.go"))]
FILES = [
    "Package.swift",
    CLI_INFO,
    CPUB,
    "Sources/CPublishedTCP/include/PublishedTCP.h",
    "Sources/MicropodRuntime/NativeLoopbackRelay.swift",
    "Sources/MicropodRuntime/CIWorker.swift",
    "Sources/MicropodRuntime/CIWorkerNetwork.swift",
    "Sources/MicropodRuntime/SandboxVM.swift",
    "Sources/MicropodRuntime/SandboxNetwork.swift",
    "Tests/MicropodRuntimeTests/CIWorkerTests.swift",
    "Tests/MicropodRuntimeTests/NativePublishedPortsTests.swift",
    "ci/runner/published-ports.sh",
    "ci/runner/start.sh",
    "guest/runner/go.mod",
    "guest/runner/go.sum",
    *RUNNER_INPUTS,
]


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def git(*args):
    return subprocess.check_output(["git", "-C", ROOT, *args])


def prepare(host_product=None):
    rev = git("rev-parse", "HEAD").decode().strip()
    patch = git("diff", "--binary", "HEAD", "--", *FILES)
    if not git("ls-files", "--", CLI_INFO):
        new = subprocess.run(["git", "diff", "--no-index", "--", "/dev/null", CLI_INFO],
                             cwd=ROOT, capture_output=True, check=False)
        if new.returncode != 1:
            raise ValueError("could not snapshot the new CLI information property list")
        patch += new.stdout
    identity = hashlib.sha256(rev.encode() + patch)
    if host_product:
        identity.update(b"\0host-product\0" + bytes.fromhex(digest(host_product)))
    scope = BASE / ("ci-published-link-" + identity.hexdigest()[:16])
    src = scope / "src"
    if not (scope / "prepared.json").exists():
        scope.mkdir()
        src.mkdir()
        with subprocess.Popen(
            [
                "git",
                "-C",
                ROOT,
                "archive",
                rev,
                "Package.swift",
                "Package.resolved",
                "Sources",
                "Tests",
                "sdk/swift",
                "signing",
                "ci/runner/published-ports.sh",
                "ci/runner/start.sh",
                "guest/runner",
            ],
            stdout=subprocess.PIPE,
        ) as archive:
            subprocess.run(["tar", "-xf", "-", "-C", src], stdin=archive.stdout, check=True)
            if archive.wait():
                raise ValueError("could not extract the pinned source")
        # The other concurrent experimental changes in the worktree are outside this build.
        subprocess.run(["patch", "-s", "-p1", "-d", src], input=patch, check=True)
        (scope / "worker.patch").write_bytes(patch)
        scratch = scope / "build"
        scratch.mkdir()
        for name in ("checkouts", "artifacts", "repositories", "workspace-state.json"):
            subprocess.run(["/bin/cp", "-cR", DONOR / "build" / name, scratch / name], check=True)
        pins = json.loads((src / "Package.resolved").read_bytes())["pins"]
        for pin in pins:
            checkout = scratch / "checkouts" / pin["identity"]
            actual = subprocess.check_output(["git", "-C", checkout, "rev-parse", "HEAD"]).decode().strip()
            if actual != pin["state"]["revision"]:
                raise ValueError("wrong dependency checkout: " + pin["identity"])
        record = {
            "base_revision": rev,
            "patch_sha256": digest(scope / "worker.patch"),
            "compiled_sources": {
                f: digest(src / f) for f in [*FILES, "Package.resolved"]
            },
            "publication_key": "MICROPOD_CI_PUBLISHED_MTU",
            "guest_mtu_at_boot": True,
            "arena": str(scope),
        }
        (scope / "prepared.json").write_text(json.dumps(record, indent=2) + "\n")
    return scope


def build(scope, jobs, host_product=None):
    record = json.loads((scope / "prepared.json").read_bytes())
    src = scope / "src"
    if not all(digest(src / f) == h for f, h in record["compiled_sources"].items()):
        raise ValueError("prepared source changed")
    flags = [
        "xcrun",
        "swift",
        "build",
        "--disable-sandbox",
        "--skip-update",
        "--only-use-versions-from-resolved-file",
        "--scratch-path",
        str(scope / "build"),
        "--cache-path",
        str(scope / "cache"),
        "--config-path",
        str(scope / "config"),
        "--security-path",
        str(scope / "security"),
        "-c",
        "release",
        "--jobs",
        str(jobs),
        "--product",
        "micropod",
        "-Xswiftc",
        "-num-threads",
        "-Xswiftc",
        "1",
        "-Xswiftc",
        "-j1",
    ]
    exe = scope / "micropod"
    path = scope / "product.json"
    if not path.exists():
        env = {
            **os.environ,
            "GIT_ALLOW_PROTOCOL": "file",
            "CLANG_MODULE_CACHE_PATH": str(scope / "clang-modules"),
            "SWIFTPM_MODULECACHE_OVERRIDE": str(scope / "modules"),
        }
        if host_product is None:
            with (scope / "build.log").open("ab") as log:
                subprocess.run(flags, env=env, cwd=src, stdout=log, stderr=subprocess.STDOUT, check=True)
            shutil.copy2(scope / "build/arm64-apple-macosx/release/micropod", exe)
            ent = src / "signing/micropod-cli.entitlements"
            subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", ent, exe], check=True)
        else:
            # A guest-only change can ship with the already tested Mac executable.
            original = json.loads(host_product.read_bytes())
            prior = host_product.resolve().parent
            def host_inputs(receipt):
                return {key: sha for key, sha in receipt["compiled_sources"].items()
                        if not key.startswith(("guest/", "ci/runner/"))}
            if (prior.parent != BASE or original.get("experimental_read_bytes")
                    or original["base_revision"] != record["base_revision"]
                    or host_inputs(original) != host_inputs(record)
                    or digest(prior / "micropod") != original["worker_executable_sha256"]
                    or digest(prior / "build.log") != original["build_log_sha256"]):
                raise ValueError("signed host or its build inputs differ")
            shutil.copy2(prior / "micropod", exe)
            shutil.copy2(prior / "build.log", scope / "build.log")
            flags = original["command"]
            record["host_product"] = str(host_product.resolve())
        actual = subprocess.check_output(
            ["codesign", "-d", "--entitlements", "-", "--xml", exe], stderr=subprocess.DEVNULL
        )
        if plistlib.loads(actual) != {"com.apple.security.virtualization": True}:
            raise ValueError("incorrect signed worker entitlements")
        embedded = subprocess.check_output(["xcrun", "otool", "-X", "-P", exe])
        info = plistlib.loads(embedded[embedded.index(b"<?xml"):embedded.index(b"</plist>") + len(b"</plist>")])
        if info != plistlib.loads((src / CLI_INFO).read_bytes()):
            raise ValueError("signed worker has the wrong local network usage description")
        shutil.copy2(DONOR / "micropod-oci", scope / "micropod-oci")
        guest_tools = scope / "micropod-oci-tools"
        subprocess.run(["/bin/cp", "-cR", (DONOR / "micropod-oci-tools").resolve(), guest_tools], check=True)
        publication_script = guest_tools / "runner/published-ports.sh"
        shutil.copy2(src / "ci/runner/published-ports.sh", publication_script)
        shutil.copy2(src / "ci/runner/start.sh", guest_tools / "runner/start.sh")
        job = guest_tools / "runner/bin/job"
        def runner_inputs(receipt):
            return {key: sha for key, sha in receipt["compiled_sources"].items() if key.startswith("guest/runner/")}
        if host_product and original.get("guest_runner_sha256") and runner_inputs(original) == runner_inputs(record):
            previous_job = prior / "micropod-oci-tools/runner/bin/job"
            if digest(previous_job) != original["guest_runner_sha256"]:
                raise ValueError("previous Linux runner differs from its build receipt")
            shutil.copy2(previous_job, job)
            record["guest_runner_product"] = str(host_product.resolve())
        else:
            go_env = {**os.environ, "GOARCH": "arm64", "GOOS": "linux", "CGO_ENABLED": "0", "GOPROXY": "off"}
            go_env.pop("GOROOT", None)
            subprocess.run(["go", "build", "-trimpath", "-o", job, "."], cwd=src / "guest/runner",
                           env=go_env, check=True)
        record.update(
            worker_executable=str(exe),
            worker_executable_sha256=digest(exe),
            entitlements=plistlib.loads(actual),
            embedded_cli_info=info,
            command=flags,
            build_log_sha256=digest(scope / "build.log"),
            guest_publication_script_sha256=digest(publication_script),
            guest_start_sha256=digest(guest_tools / "runner/start.sh"),
            guest_runner_sha256=digest(job),
        )
        path.write_text(json.dumps(record, indent=2) + "\n")
    subprocess.run(["codesign", "--verify", "--strict", exe], check=True)
    if json.loads(path.read_bytes())["worker_executable_sha256"] != digest(exe):
        raise ValueError("signed worker changed")
    return path


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--host-product", type=Path, help="reuse the signed Mac release for a guest-only change")
    opts = parser.parse_args()
    arena = prepare(opts.host_product)
    print(arena if opts.prepare else build(arena, opts.jobs, opts.host_product), flush=True)
