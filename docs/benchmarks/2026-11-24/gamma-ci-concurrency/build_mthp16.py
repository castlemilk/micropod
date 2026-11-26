"""Build one pinned 16 KiB IPvlan Image for a 64 KiB anonymous THP policy comparison."""

import argparse
import gzip
import hashlib
import json
import mmap
import shutil
import signal
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import build_ipvlan as base
from qualify import require, terminal


PARENT_IMAGE = "488a83549377f9abcabfc44a9021f1451c9ed903f85f66f910e296c7ab2327ab"
PARENT_CONFIG = "790fe9a014f3501117af37df8163a39da1617e37a84996f0e605325c3b07a24c"
PARENT_BUILDER = "3b9d07cc789d4f12ed552c504122c4b93652bf8f9015268aa0deb96f23eded47"
PROOF = "mthp64-build.json"
BUILDER = "mthp64-kernel-builder.sh"
TOOLCHAIN = "mthp64-toolchain.txt"
CONFIG = "mthp64-config-16k.gz"
POLICIES = ("never", "always")

# Linux 7.3.5 mm/Kconfig exposes the THP choices and selects MM_ID.
# arch/arm64/Kconfig exposes contiguous PTEs and enables the PMD helpers.
# fs/Kconfig and drivers/dax/Kconfig resolve FS_DAX_PMD and expose DEV_DAX.
# COMPACTION and XARRAY_MULTI are already enabled. The 16 KiB arm64 config
# cannot select ARCH_WANTS_THP_SWAP, so THP_SWAP stays absent.
CONFIG_DELTA = {
    "CONFIG_ARCH_HAS_PMD_SOFTLEAVES": [None, "y"],
    "CONFIG_ARCH_SUPPORTS_HUGE_PFNMAP": [None, "y"],
    "CONFIG_ARCH_SUPPORTS_PMD_PFNMAP": [None, "y"],
    "CONFIG_ARCH_WANT_PMD_MKWRITE": [None, "y"],
    "CONFIG_ARM64_CONTPTE": [None, "y"],
    "CONFIG_DEV_DAX": [None, "n"],
    "CONFIG_FS_DAX_PMD": [None, "y"],
    "CONFIG_MM_ID": [None, "y"],
    "CONFIG_NO_PAGE_MAPCOUNT": [None, "n"],
    "CONFIG_PERSISTENT_HUGE_ZERO_FOLIO": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE": ["n", "y"],
    "CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_MADVISE": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_NEVER": [None, "y"],
    "CONFIG_TRANSPARENT_HUGEPAGE_SHMEM_HUGE_ADVISE": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_SHMEM_HUGE_ALWAYS": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_SHMEM_HUGE_NEVER": [None, "y"],
    "CONFIG_TRANSPARENT_HUGEPAGE_SHMEM_HUGE_WITHIN_SIZE": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_TMPFS_HUGE_ADVISE": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_TMPFS_HUGE_ALWAYS": [None, "n"],
    "CONFIG_TRANSPARENT_HUGEPAGE_TMPFS_HUGE_NEVER": [None, "y"],
    "CONFIG_TRANSPARENT_HUGEPAGE_TMPFS_HUGE_WITHIN_SIZE": [None, "n"],
}


def kernel_args(policy):
    require(policy in POLICIES, "unknown 64 KiB anonymous THP policy")
    # 32 MiB is the PMD size for 16 KiB pages. Linux applies the final
    # clause to the 64 KiB order after disabling every anonymous THP order.
    return "transparent_hugepage=never", f"thp_anon=64K-32M:never;64K:{policy}"


def expected_options(config):
    require(hashlib.sha256(config).hexdigest() == PARENT_CONFIG, "wrong pinned IPvlan config")
    before = base.kernel_candidate.config_options(config)
    require(all(before.get(key) == old for key, (old, _) in CONFIG_DELTA.items()),
            "unexpected Kconfig inputs for transparent huge pages")
    return {**before, **{key: new for key, (_, new) in CONFIG_DELTA.items()}}


def matched_builder(parent_builder, config):
    source = parent_builder.read_bytes()
    require(hashlib.sha256(source).hexdigest() == PARENT_BUILDER, "wrong pinned IPvlan builder")
    entries = expected_options(config)
    # Match LC_ALL=C sort on complete assignment lines, including the '='.
    normalized = "".join(sorted(f"{key}={val}\n" for key, val in entries.items()))
    digest = hashlib.sha256(normalized.encode()).hexdigest()
    olddefconfig = b"make olddefconfig\n"
    require(source.count(olddefconfig) == 1, "unexpected IPvlan Kconfig resolution")
    selected = b"scripts/config -e TRANSPARENT_HUGEPAGE -e TRANSPARENT_HUGEPAGE_NEVER\n"
    preflight = f'''options=$(LC_ALL=C awk '/^CONFIG_[[:alnum:]_]+=/ {{ print; next }}
    /^# CONFIG_[[:alnum:]_]+ is not set$/ {{ print $2 "=n" }}' .config | LC_ALL=C sort | sha256sum)
printf '%s\\n' "Resolved THP Kconfig: $options"
[ "${{options%% *}}" = "{digest}" ] || {{ echo 'Resolved Kconfig differs from the reviewed THP delta' >&2; exit 1; }}
'''.encode()
    return source.replace(olddefconfig, selected + olddefconfig + preflight, 1)


def check_pair(parent, candidate, before, after):
    require(parent["image_sha256"] == PARENT_IMAGE and parent["config_sha256"] == PARENT_CONFIG
            and candidate["image_sha256"] != PARENT_IMAGE
            and all(row["page_kib"] == 16 and row["embedded_config_verified"] for row in (parent, candidate)),
            "expected the pinned IPvlan parent and a 16 KiB THP Image with embedded configs")
    require(hashlib.sha256(after).hexdigest() == candidate["config_sha256"], "THP config digest differs")
    old = base.kernel_candidate.config_options(before)
    new = base.kernel_candidate.config_options(after)
    changes = {key: [old.get(key), new.get(key)] for key in sorted(old.keys() | new.keys())
               if old.get(key) != new.get(key)}
    require(new == expected_options(before) and changes == CONFIG_DELTA, f"unexpected THP Kconfig changes: {changes}")
    return {"control": parent, "candidate": candidate, "config_changes": changes}


def build_inputs(builder, toolchain, parent_builder, config):
    require(builder.read_bytes() == matched_builder(parent_builder, config), "matched THP build script differs")
    base.pinned_packages(toolchain)
    return {"profile": base.PROFILE, "release": base.RELEASE, "source_sha256": base.SOURCE_SHA,
            "seed_sha256": base.BASE_CONFIG, "ipvlan_builder_sha256": PARENT_BUILDER,
            "builder_sha256": terminal.digest(builder), "compiler_image": base.COMPILER_IMAGE,
            "environment": base.BUILD_ENV, "toolchain_sha256": terminal.digest(toolchain),
            "package_count": 97, "packages_sha256": base.PACKAGES_SHA}


def inspect_build(directory, ipvlan, parent):
    profile = directory / base.PROFILE
    config = (ipvlan / base.PROFILE / "config").read_bytes()
    candidate, _ = base.kernel_candidate.inspect(profile, 16)
    require((profile / "release").read_text().strip() == base.RELEASE and
            terminal.digest(directory / "apple.config") == base.BASE_CONFIG,
            "THP kernel release or frozen Apple seed differs")
    pair = check_pair(parent, candidate, config, (profile / "config").read_bytes())
    return {**pair, "inputs": build_inputs(directory / BUILDER, directory / "toolchain.txt",
                                          ipvlan / "build-worker-kernel.sh", config), "builder_retired": True}


def build(control, ipvlan):
    parent = base.verify_build(ipvlan, control)["candidate"]
    config = (ipvlan / base.PROFILE / "config").read_bytes()
    require(parent["image_sha256"] == PARENT_IMAGE, "wrong pinned IPvlan Image")
    builder_bytes = matched_builder(ipvlan / "build-worker-kernel.sh", config)
    out = Path(tempfile.mkdtemp(prefix=datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ-mthp64-"), dir=control.parent))
    print(out, flush=True)
    builder, seed = out / BUILDER, out / "apple.config"
    builder.write_bytes(builder_bytes)
    shutil.copy2(ipvlan / "apple.config", seed)
    base.compile_image(control, control / "linux-7.3.5.tar.xz", seed, builder, out)
    proof = inspect_build(out, ipvlan, parent)
    terminal.save(out / PROOF, proof)
    print(json.dumps(proof, indent=2), flush=True)


def verify_build(directory, ipvlan, control):
    parent = base.verify_build(ipvlan, control)["candidate"]
    proof = inspect_build(directory, ipvlan, parent)
    require(proof == json.loads((directory / PROOF).read_bytes()), "mTHP build receipt differs")
    return proof


def verify_archived(folder, active_image=None):
    parent = base.verify_archived(folder)["candidate"]
    proof = json.loads((folder / PROOF).read_bytes())
    before = gzip.decompress((folder / "ipvlan-config-16k.gz").read_bytes())
    after = gzip.decompress((folder / CONFIG).read_bytes())
    candidate = proof["candidate"]
    pair = check_pair(parent, candidate, before, after)
    inputs = build_inputs(folder / BUILDER, folder / TOOLCHAIN, folder / "ipvlan-kernel-builder.sh", before)
    require(proof == {**pair, "inputs": inputs, "builder_retired": True}, "archived mTHP inputs differ")
    if active_image is not None:
        with active_image.open("rb") as source, mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
            require(len(image) == candidate["image_bytes"] and image[56:60] == b"ARM\x64"
                    and int.from_bytes(image[24:32], "little") & 7 == 4
                    and int.from_bytes(image[16:24], "little") == candidate["image_memory_bytes"]
                    and hashlib.sha256(image).hexdigest() == candidate["image_sha256"]
                    and base.kernel_candidate.verify_embedded_config(image, after, True),
                    "selected Image differs from the archived THP config")
    return proof


def select(directory, ipvlan, control, policy, files, folder):
    kernel_args(policy)
    directory = directory.resolve()
    verify_build(directory, ipvlan.resolve(), control.resolve())
    pages = base.select(ipvlan, control, files, folder)
    for source, target in ((PROOF, PROOF), (BUILDER, BUILDER), ("toolchain.txt", TOOLCHAIN)):
        shutil.copy2(directory / source, folder / target)
    profile = directory / base.PROFILE
    (folder / CONFIG).write_bytes(gzip.compress((profile / "config").read_bytes(), mtime=0))
    proof = verify_archived(folder, profile / "Image")
    files.update(kernel=profile / "Image", kernel_config=profile / "config")
    return {**pages, "kernel_mthp16": True, "kernel_image_sha256": proof["candidate"]["image_sha256"],
            "kernel_config_sha256": proof["candidate"]["config_sha256"],
            "mthp64_build_sha256": terminal.digest(folder / PROOF)}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("control", type=Path, help="pinned stock page-kernel build")
    parser.add_argument("ipvlan", type=Path, help="pinned IPvlan 16 KiB build")
    parser.add_argument("--verify", type=Path, help="verify an existing mTHP build offline")
    args = parser.parse_args()
    control, ipvlan = args.control.resolve(), args.ipvlan.resolve()
    if args.verify is not None:
        print(json.dumps(verify_build(args.verify.resolve(), ipvlan, control), indent=2))
    else:
        signal.signal(signal.SIGTERM, base.terminate)
        build(control, ipvlan)
