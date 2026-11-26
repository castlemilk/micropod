"""Build a disposable 16 KiB IPvlan kernel with an opt-in EEVDF buddy deadline bound."""
import argparse
import json
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import build_ipvlan as base
from qualify import require, terminal


PATCH = "bounded-buddy.patch"
PATCH_SHA = "8c66ba3dbb32b40dd5e545c8badb0295223f1254db43743d138ca5e6bccd44dc"
BUILDER = "bounded-kernel-builder.sh"
TOOLCHAIN = "bounded-toolchain.txt"
PROOF = "bounded-kernel.json"


def matched_script(parent):
    command = b'cd "$work/linux-7.3.5"\n'
    content = parent.read_bytes()
    require(content.count(command) == 1, "unknown kernel source extraction")
    hook = f"echo '{PATCH_SHA}  /inputs/{PATCH}' | sha256sum -c -\npatch -p1 < /inputs/{PATCH}\n".encode()
    return content.replace(command, command + hook)


def check_files(folder, parent_builder, parent, candidate):
    require((folder / BUILDER).read_bytes() == matched_script(parent_builder)
            and terminal.digest(folder / PATCH) == PATCH_SHA, "bounded buddy kernel sources differ")
    base.pinned_packages(folder / TOOLCHAIN)
    require(parent["image_sha256"] != candidate["image_sha256"] and
            parent["config_sha256"] == candidate["config_sha256"] and
            all(k["page_kib"] == 16 and k["embedded_config_verified"] for k in (parent, candidate)),
            "bounded buddy Image or embedded kernel config differs")
    return {"parent": parent, "candidate": candidate, "patch_sha256": PATCH_SHA,
            "builder_sha256": terminal.digest(folder / BUILDER), "parent_builder_sha256": terminal.digest(parent_builder),
            "toolchain_sha256": terminal.digest(folder / TOOLCHAIN), "packages_sha256": base.PACKAGES_SHA,
            "compiler_image": base.COMPILER_IMAGE, "build_environment": base.BUILD_ENV}


def build(control, ipvlan):
    parent = base.verify_build(ipvlan, control)["candidate"]
    seed = ipvlan / "apple.config"
    out = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-buddy-"), dir=control.parent))
    print(out, flush=True)
    shutil.copyfile(Path(__file__).with_name(PATCH), out / PATCH)
    require(terminal.digest(out / PATCH) == PATCH_SHA, "scheduler patch changed")
    parent_script = ipvlan / "build-worker-kernel.sh"
    builder = out / BUILDER
    builder.write_bytes(matched_script(parent_script))
    base.compile_image(control, control / "linux-7.3.5.tar.xz", seed, builder, out,
                       [(out / PATCH, "/inputs/" + PATCH)])
    shutil.copyfile(out / "toolchain.txt", out / TOOLCHAIN)
    candidate, _ = base.kernel_candidate.inspect(out / base.PROFILE, 16)
    require((out / base.PROFILE / "release").read_text().strip() == base.RELEASE, "unexpected kernel release")
    proof = check_files(out, parent_script, parent, candidate)
    terminal.save(out / PROOF, proof)
    print(json.dumps(proof), flush=True)


def select(directory, ipvlan, control, files, folder):
    pages = base.select(ipvlan, control, files, folder)
    for name in (PROOF, PATCH, BUILDER, TOOLCHAIN):
        shutil.copyfile(directory / name, folder / name)
    kernel = directory.resolve() / base.PROFILE
    files.update(kernel=kernel / "Image", kernel_config=kernel / "config")
    candidate = verify_archived(folder, files["kernel"])["candidate"]
    return {**pages, "kernel_bounded_buddy": True, "kernel_image_sha256": candidate["image_sha256"]}


def verify_archived(folder, active_image):
    parent = base.verify_archived(folder)["candidate"]
    candidate, _ = base.kernel_candidate.inspect(active_image.parent, 16)
    require(active_image.name == "Image" and (active_image.parent / "release").read_text().strip() == base.RELEASE,
            "wrong bounded buddy kernel file or release")
    proof = check_files(folder, folder / "ipvlan-kernel-builder.sh", parent, candidate)
    require(proof == json.loads((folder / PROOF).read_bytes()), "bounded buddy build receipt differs")
    return proof


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path)
    parser.add_argument("ipvlan", type=Path)
    args = parser.parse_args()
    signal.signal(signal.SIGTERM, base.terminate)
    build(args.control.resolve(), args.ipvlan.resolve())
