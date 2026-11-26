"""Prepare, build and verify the opt-in two/four-worker binary using local dependencies."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
REV = "5b8ea1a6a79d1741e521c080f968fcf04c591e68"
DEFINE = "MICROPOD_BENCH_FIXED_RELAY_BUDGET=1"
ARTIFACT = ROOT / ".build/local-published-tcp/fixed-workers-5b8ea1a6"
RECORD = HERE / "20261124T062433Z/fixed-workers-runtime-build.json"
WARM = ROOT.parent.parent.parent / "micropod-warm-ci/.build"
SDK = Path.home() / ".micropod/qualified/interactive-a41976076b67-2293dd639a7a"
CONTROL_NAMES = ["Package.swift", "Package.resolved", "Sources/CPublishedTCP/PublishedTCP.c",
                 "Sources/CPublishedTCP/include/PublishedTCP.h", "Sources/MicropodRuntime/NativeLoopbackRelay.swift",
                 "Sources/MicropodRuntime/CIWorker.swift", "Sources/MicropodRuntime/CIWorkerPorts.swift",
                 "signing/micropod-cli.entitlements"]


def sha(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def output(args):
    return subprocess.check_output(args, text=True).strip()


def save(path, value):
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(value, indent=2) + "\n")
    tmp.replace(path)


def prepare():
    if (ARTIFACT / "prepared.json").is_file():
        return
    ARTIFACT.mkdir(parents=True, exist_ok=True)
    src = ARTIFACT / "src"
    src.mkdir(exist_ok=True)
    with subprocess.Popen(["git", "-C", ROOT, "archive", REV, "Package.swift", "Package.resolved",
                           "Sources", "Tests", "sdk/swift", "signing"], stdout=subprocess.PIPE) as git:
        subprocess.run(["tar", "-xf", "-", "-C", src], stdin=git.stdout, check=True)
        if git.wait() != 0:
            raise ValueError("source archive failed")
    build = ARTIFACT / "build"
    build.mkdir(exist_ok=True)
    for name in ("cache", "config", "security", "modules", "clang-modules"):
        (ARTIFACT / name).mkdir(exist_ok=True)
    for name in ("checkouts", "artifacts", "repositories", "workspace-state.json"):
        if not (build / name).exists():
            subprocess.run(["/bin/cp", "-cR", WARM / name, build / name], check=True)
    pins = json.loads((src / "Package.resolved").read_text())["pins"]
    for pin in pins:
        co = build / "checkouts" / pin["identity"]
        if output(["git", "-C", co, "rev-parse", "HEAD"]) != pin["state"]["revision"]:
            raise ValueError(f"unexpected dependency revision for {co.name}")
    seed = {"source_revision": REV, "dependency_revisions": {p["identity"]: p["state"]["revision"] for p in pins},
            "source_sha256": {k: sha(src / k) for k in CONTROL_NAMES}}
    if seed["source_sha256"]["Sources/CPublishedTCP/PublishedTCP.c"] != "c877f1efe9b46a9e80385bf6f8b1a00add0b1671cf8d0d8d8ec02d2d0842990f":
        raise ValueError("unexpected C helper")
    save(ARTIFACT / "prepared.json", seed)


def build_command(jobs):
    return ["xcrun", "swift", "build", "--disable-sandbox", "--skip-update", "--only-use-versions-from-resolved-file",
             "--cache-path", str(ARTIFACT / "cache"), "--config-path", str(ARTIFACT / "config"), "--security-path",
             str(ARTIFACT / "security"), "--scratch-path", str(ARTIFACT / "build"), "-c", "release", "--jobs",
             str(jobs), "--product", "micropod", "-Xcc", "-D" + DEFINE]


def build_binary(jobs):
    prepare()
    if RECORD.exists():
        raise ValueError("existing sealed result; use verify")
    flags = build_command(jobs)
    env = dict(os.environ, GIT_ALLOW_PROTOCOL="file", CLANG_MODULE_CACHE_PATH=str(ARTIFACT / "clang-modules"),
               SWIFTPM_MODULECACHE_OVERRIDE=str(ARTIFACT / "modules"))
    log = ARTIFACT / "compile.log"
    with log.open("ab") as f:
        subprocess.run(flags, cwd=ARTIFACT / "src", env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    return seal(flags, log)


def selector(path):
    asm = output(["xcrun", "llvm-objdump", "--disassemble-symbols=_mp_tcp_data_callback_events",
                  "--no-show-raw-insn", path])
    body = asm.split("<_mp_tcp_data_callback_events>:\n", 1)[1]
    ops = [line.split(":", 1)[1].split(";", 1)[0].split()
           for line in body.splitlines() if re.match(r"^\s*[0-9a-f]+:", line)]
    # Decode the signed ARM64 function itself. It returns constant 128 for both worker counts.
    if len(ops) < 2 or ops[0] not in (["mov", "w0,", "#0x80"], ["mov", "w0,", "#128"]) or ops[1] != ["ret"]:
        raise ValueError(f"unexpected signed binary selector: {ops[:4]}")
    return ops[:2]


def seal(flags, log):
    prepared = json.loads((ARTIFACT / "prepared.json").read_text())
    src, build = ARTIFACT / "src", ARTIFACT / "build"
    for k in CONTROL_NAMES:
        if subprocess.check_output(["git", "-C", ROOT, "show", REV + ":" + k]) != (src / k).read_bytes():
            raise ValueError(f"changed source {k}")
    for name, revision in prepared["dependency_revisions"].items():
        co = build / "checkouts" / name
        if output(["git", "-C", co, "rev-parse", "HEAD"]) != revision or output(["git", "-C", co, "diff", "HEAD", "--name-only"]):
            raise ValueError(f"dependency modified: {name}")
    release, binary = build / "arm64-apple-macosx/release/micropod", ARTIFACT / "micropod"
    subprocess.run(["/bin/cp", "-c", release, binary], check=True)
    ents = src / "signing/micropod-cli.entitlements"
    subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", ents, binary], check=True)
    subprocess.run(["codesign", "--verify", "--strict", binary], check=True)
    ent = plistlib.loads(subprocess.check_output(["codesign", "-d", "--entitlements", "-", "--xml", binary], stderr=subprocess.DEVNULL))
    if ent != plistlib.loads(ents.read_bytes()):
        raise ValueError("signed entitlements mismatch")
    instructions = selector(binary)
    subprocess.run(["/bin/cp", "-c", SDK / "micropod-oci", ARTIFACT / "micropod-oci"], check=True)
    link = ARTIFACT / "micropod-oci-tools"
    if not link.exists():
        link.symlink_to(SDK / "micropod-oci-tools", target_is_directory=True)
    record = dict(prepared, worker_executable=str(binary), worker_executable_sha256=sha(binary),
                  recorded_utc=datetime.now(timezone.utc).isoformat(), swift=output(["xcrun","swift","--version"]),
                  sdk=output(["xcrun","--show-sdk-version"]), command=flags, compile_log=str(log),
                  compile_log_sha256=sha(log), signed_selector_instructions=instructions,
                  entitlements=ent, source_tree=output(["git", "-C", ROOT, "rev-parse", REV + "^{tree}"]),
                  controlled_relay={"read_bytes":262144, "callback_events_by_workers":{"2":128,"4":128},
                                    "compile_define":DEFINE,"binary_selector_verified":True})
    save(RECORD, record)
    return record


def verify():
    r = json.loads(RECORD.read_text())
    binary = Path(r["worker_executable"])
    if r["source_revision"] != REV or sha(binary) != r["worker_executable_sha256"]:
        raise ValueError("sealed build identity mismatch")
    if r["signed_selector_instructions"] != selector(binary):
        raise ValueError("signed selector changed")
    subprocess.run(["codesign", "--verify", "--strict", binary], check=True)
    print(str(RECORD), r["worker_executable_sha256"])


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("action", choices=["prepare", "build", "verify"])
    p.add_argument("--jobs", type=int, choices=[1, 2, 3, 4], default=4)
    a = p.parse_args()
    if a.action == "prepare":
        prepare()
    elif a.action == "build":
        build_binary(a.jobs)
        verify()
    else:
        verify()
