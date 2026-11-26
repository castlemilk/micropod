"""Build and verify an IPvlan-enabled kernel matched to Gamma's stock 16 KiB kernel."""

import argparse
import gzip
import hashlib
import json
import mmap
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from qualify import require, terminal
from build_pages import BASE_CONFIG, SOURCE_SHA, select as select_stock
import kernel_candidate


PROFILE = "full-16k"
RELEASE = "7.3.5-micropod"
STOCK_IMAGE = "3c447c100cc30f23d81e0618bd3afef67ee0ab2d93c625ac1ee138d09dc9eb61"
STOCK_CONFIG = "727b1c5539c09cbd1a4ac4a04e3beeb4343b3019e489a537c2b7e6c8bdbafa98"
STOCK_BUILDER = "8428aa21d3c3f496482a47453542450025d625b763a4aef759f0b4f37d1697ad"
STOCK_TOOLCHAIN = "c876eff72b454f12036c88e9bf1b326f2883f0416036bd260e8e3b452c6f68a5"
COMPILER_IMAGE = "sha256:469c9ea410b9215eaee7976ba6c0639039b444be8e5d638f7abbada189971eb2"
PACKAGES_SHA = "3a979f34df86c37a9c1aa49101e9b1e76176d79cad2b985580bf4b6ce28aa7ce"
BUILD_ENV = {
    "KBUILD_BUILD_HOST": "gamma", "KBUILD_BUILD_TIMESTAMP": "Tue Nov 17 10:35:00 UTC 2026",
    "KBUILD_BUILD_VERSION": "1", "JOBS": "4", "KBUILD_BUILD_USER": "micropod",
}
# Linux 7.3.5 enables hidden IPVLAN_L3S with NETFILTER. Its L3 master
# support makes NET_VRF visible, and IPVLAN itself makes IPVTAP visible.
DELTA = {
    "CONFIG_IPVLAN": ["n", "y"],
    "CONFIG_IPVLAN_L3S": [None, "y"],
    "CONFIG_IPVTAP": [None, "n"],
    "CONFIG_NET_L3_MASTER_DEV": ["n", "y"],
    "CONFIG_NET_VRF": [None, "n"],
}
DOCKER = ["docker", "--context", "orbstack"]
BUILD_LABEL = "io.micropod.bench.kernel-build"


def check_pair(control, trial, before, after):
    changes = {k: [before.get(k), after.get(k)] for k in sorted(before.keys() | after.keys())
               if before.get(k) != after.get(k)}
    require(control["image_sha256"] == STOCK_IMAGE and control["config_sha256"] == STOCK_CONFIG,
            "wrong stock 16 KiB kernel")
    require(all(row["page_kib"] == 16 and row["embedded_config_verified"] for row in (control, trial)),
            "expected matched arm64 16 KiB Images with embedded configs")
    require(changes == DELTA, f"unexpected IPvlan Kconfig changes: {changes}")
    return {"control": control, "candidate": trial, "config_changes": changes}


def compare(control, candidate):
    standard, before = kernel_candidate.inspect(control, 16)
    trial, after = kernel_candidate.inspect(candidate, 16)
    require(all((p / "release").read_text().strip() == RELEASE for p in (control, candidate)),
            "kernel release differs")
    return check_pair(standard, trial, before, after)


def pinned_packages(toolchain):
    # `apk info -vv` names each installed APK and its complete revision.
    package_line = re.compile(r"([A-Za-z0-9+_.-]+)-([0-9][^ ]*-r[0-9]+) - .+")
    packages = sorted("=".join(m.groups()) for line in toolchain.read_text().splitlines()
                      if (m := package_line.fullmatch(line)))
    checksum = hashlib.sha256(("\n".join(packages) + "\n").encode()).hexdigest()
    require(len(packages) == 97 and checksum == PACKAGES_SHA, "toolchain APK versions differ from stock")
    return packages


def matched_builder(stock_builder):
    content = stock_builder.read_bytes()
    require(hashlib.sha256(content).hexdigest() == STOCK_BUILDER, "wrong stock kernel build script")
    for before, after in (
        (b"-e MACVLAN -e NETKIT ", b"-e MACVLAN -e IPVLAN -e NETKIT "),
        (b"VIRTIO_NET MACVLAN NETFILTER_INGRESS ", b"VIRTIO_NET MACVLAN IPVLAN NETFILTER_INGRESS "),
    ):
        require(content.count(before) == 1, "unrecognized stock IPvlan build settings")
        content = content.replace(before, after, 1)
    return content


def build_inputs(builder, toolchain, stock_builder):
    require(builder.read_bytes() == matched_builder(stock_builder), "matched IPvlan build script differs")
    pinned_packages(toolchain)
    return {
        "profile": PROFILE, "source_sha256": SOURCE_SHA, "seed_sha256": BASE_CONFIG,
        "stock_builder_sha256": STOCK_BUILDER, "stock_toolchain_sha256": STOCK_TOOLCHAIN,
        "compiler_image": COMPILER_IMAGE, "environment": BUILD_ENV,
        "builder_sha256": terminal.digest(builder), "toolchain_sha256": terminal.digest(toolchain),
        "package_count": 97, "packages_sha256": PACKAGES_SHA,
    }


def check_stock_inputs(control):
    inputs = json.loads((control / "build-inputs.json").read_bytes())
    container = json.loads((control / "build-container.json").read_bytes())
    archive = control / "linux-7.3.5.tar.xz"
    require(inputs["profile_order"] == ["full", PROFILE]
            and terminal.digest(archive) == inputs["source_sha256"] == SOURCE_SHA
            and inputs["config_sha256"] == BASE_CONFIG
            and terminal.digest(control / "build-worker-kernel.sh") == inputs["builder_sha256"] == STOCK_BUILDER
            and terminal.digest(control / "toolchain.txt") == STOCK_TOOLCHAIN,
            "stock source, seed, builder, or toolchain differs")
    require(container["image"] == inputs["alpine_image"] == COMPILER_IMAGE and container["platform"] == "linux"
            and container["env"] == BUILD_ENV and container["nano_cpus"] == 4_000_000_000
            and container["pids_limit"] == 1024 and inputs["jobs"] == 4,
            "stock builder configuration differs")
    return archive


def owned_containers(owner):
    return subprocess.check_output(
        [*DOCKER, "ps", "-aq", "--no-trunc", "--filter", f"label={BUILD_LABEL}={owner}",
         "--filter", f"name=^/{owner}$"], text=True, timeout=30,
    ).split()


def run_builder(command, owner, log_path):
    with log_path.open("xb") as log:
        try:
            subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT, timeout=1800)
        finally:
            remaining = owned_containers(owner)
            if remaining:
                # An automatic removal may have won the race after the inventory read.
                subprocess.run([*DOCKER, "rm", "-f", *remaining], check=False, stdout=log,
                               stderr=subprocess.STDOUT, timeout=30)
            require(not owned_containers(owner), "private IPvlan kernel builder still exists")


def compile_image(control, archive, frozen_seed, builder, out, extra_mounts=()):
    packages = pinned_packages(control / "toolchain.txt")
    image, = json.loads(subprocess.check_output([*DOCKER, "image", "inspect", COMPILER_IMAGE], timeout=30))
    require(image["Id"] == COMPILER_IMAGE and image["Os"] == "linux" and image["Architecture"] == "arm64",
            "local builder image differs")

    builder_sha = terminal.digest(builder)
    owner = "mp-" + out.name.lower().replace("_", "-")
    command = [*DOCKER, "run", "--rm", "--pull=never", "--platform", "linux/arm64", "--cpus", "4",
               "--pids-limit", "1024", "--name", owner, "--label", f"{BUILD_LABEL}={owner}"]
    for key, value in BUILD_ENV.items():
        command += ["-e", f"{key}={value}"]
    for path, target in ((archive, "/inputs/linux.tar.xz"), (builder, "/inputs/build-worker-kernel.sh"),
                         (frozen_seed, "/inputs/apple.config"), *extra_mounts, (out, "/out")):
        command += ["--mount", f"type=bind,src={path},dst={target}" + (",readonly" if target != "/out" else "")]
    install = shlex.join(["apk", "add", "--no-cache", *packages])
    recipe = f"""set -eu
printf '%s  /inputs/apple.config\\n%s  /inputs/build-worker-kernel.sh\\n' '{BASE_CONFIG}' '{builder_sha}' | sha256sum -c -
{install}
{{ gcc --version; ld --version; pahole --version; uname -a; df -h /tmp; apk info -vv; }} > /out/toolchain.txt
sh /inputs/build-worker-kernel.sh /inputs/linux.tar.xz /inputs/apple.config /out/{PROFILE} {PROFILE} > /out/{PROFILE}.log 2>&1 || {{ tail -42 /out/{PROFILE}.log; exit 1; }}
cat /out/{PROFILE}/SHA256SUMS
"""
    command += [COMPILER_IMAGE, "/bin/sh", "-ec", recipe]
    terminal.save(out / "build-command.json", {"command": command, "control_directory": str(control)})
    run_builder(command, owner, out / "driver.log")


def build(control, seed):
    control, seed = control.resolve(), seed.resolve()
    archive = check_stock_inputs(control)
    standard, _ = kernel_candidate.inspect(control / PROFILE, 16)
    require(standard["embedded_config_verified"] and standard["image_sha256"] == STOCK_IMAGE
            and standard["config_sha256"] == STOCK_CONFIG and terminal.digest(seed) == BASE_CONFIG,
            "stock 16 KiB Image or Apple seed differs")
    out = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-ipvlan-"), dir=control.parent))
    print(out, flush=True)
    builder = out / "build-worker-kernel.sh"
    frozen_seed = out / "apple.config"
    stock_builder = control / "build-worker-kernel.sh"
    builder.write_bytes(matched_builder(stock_builder))
    shutil.copy2(seed, frozen_seed)
    compile_image(control, archive, frozen_seed, builder, out)
    pair = compare(control / PROFILE, out / PROFILE)
    inputs = build_inputs(builder, out / "toolchain.txt", stock_builder)
    require(inputs["builder_sha256"] == terminal.digest(builder) and terminal.digest(frozen_seed) == BASE_CONFIG,
            "frozen build input changed")
    terminal.save(out / "ipvlan-build.json", {**pair, "inputs": inputs, "builder_retired": True})
    print(json.dumps(pair, indent=2), flush=True)


def verify_build(directory, control):
    check_stock_inputs(control)
    proof = json.loads((directory / "ipvlan-build.json").read_bytes())
    pair = compare(control / PROFILE, directory / PROFILE)
    require(all(proof[k] == value for k, value in pair.items()) and proof["builder_retired"] is True
            and proof["inputs"] == build_inputs(directory / "build-worker-kernel.sh", directory / "toolchain.txt",
                                                control / "build-worker-kernel.sh")
            and terminal.digest(directory / "apple.config") == BASE_CONFIG,
            "IPvlan build receipt differs")
    return proof


def select(directory, control, files, folder):
    directory, control = directory.resolve(), control.resolve()
    proof = verify_build(directory, control)
    select_stock(control, 16, files, folder)
    config = directory / PROFILE / "config"
    for name, dest in (("ipvlan-build.json", "ipvlan-build.json"), ("toolchain.txt", "ipvlan-toolchain.txt"),
                       ("build-worker-kernel.sh", "ipvlan-kernel-builder.sh")):
        shutil.copy2(directory / name, folder / dest)
    (folder / "ipvlan-config-16k.gz").write_bytes(gzip.compress(config.read_bytes(), mtime=0))
    files.update(kernel=directory / PROFILE / "Image", kernel_config=config)
    candidate = proof["candidate"]
    return {"kernel_ipvlan": True, "kernel_page_kib": 16, "kernel_image_sha256": candidate["image_sha256"],
            "kernel_config_sha256": candidate["config_sha256"]}


def verify_archived(folder, active_image=None):
    proof = json.loads((folder / "ipvlan-build.json").read_bytes())
    stock = json.loads((folder / "kernel-page-pair.json").read_bytes())
    require(stock["candidate"] == proof["control"] and stock["inputs"]["source_sha256"] == SOURCE_SHA
            and stock["inputs"]["config_sha256"] == BASE_CONFIG and stock["inputs"]["alpine_image"] == COMPILER_IMAGE
            and stock["build_container"]["image"] == COMPILER_IMAGE and stock["build_container"]["env"] == BUILD_ENV
            and stock["inputs"]["builder_sha256"] == terminal.digest(folder / "kernel-builder.sh") == STOCK_BUILDER
            and stock["toolchain_sha256"] == terminal.digest(folder / "kernel-toolchain.txt") == STOCK_TOOLCHAIN,
            "archived stock build inputs differ")
    configs = [gzip.decompress((folder / name).read_bytes()) for name in ("kernel-config-16k.gz", "ipvlan-config-16k.gz")]
    for key, config in zip(("control", "candidate"), configs, strict=True):
        require(hashlib.sha256(config).hexdigest() == proof[key]["config_sha256"], "archived kernel config differs")
    pair = check_pair(proof["control"], proof["candidate"], *map(kernel_candidate.config_options, configs))
    require(proof["config_changes"] == pair["config_changes"] and proof["builder_retired"] is True
            and proof["inputs"] == build_inputs(folder / "ipvlan-kernel-builder.sh", folder / "ipvlan-toolchain.txt",
                                                folder / "kernel-builder.sh"),
            "archived IPvlan build inputs differ")
    if active_image is not None:
        candidate = proof["candidate"]
        with active_image.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
            flags = int.from_bytes(image[24:32], "little")
            require(len(image) == candidate["image_bytes"] and image[56:60] == b"ARM\x64" and flags & 7 == 4
                    and int.from_bytes(image[16:24], "little") == candidate["image_memory_bytes"]
                    and hashlib.sha256(image).hexdigest() == candidate["image_sha256"]
                    and kernel_candidate.verify_embedded_config(image, configs[1], True),
                    "selected IPvlan Image differs from archived config")
    return proof


def terminate(signum, _frame):
    raise SystemExit(128 + signum)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path, help="matched stock page-kernel build directory")
    parser.add_argument("seed", nargs="?", type=Path, help="original Apple kernel config")
    parser.add_argument("--verify", type=Path, help="verify an existing IPvlan build without Docker")
    args = parser.parse_args()
    if (args.seed is None) == (args.verify is None):
        parser.error("supply the original seed for a build or use --verify with an existing build directory")
    if args.verify is not None:
        print(json.dumps(verify_build(args.verify.resolve(), args.control.resolve()), indent=2))
    else:
        signal.signal(signal.SIGTERM, terminate)
        build(args.control, args.seed)
