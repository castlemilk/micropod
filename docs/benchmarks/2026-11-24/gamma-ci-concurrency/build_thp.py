"""Compare the 16 KiB anonymous THP policy on one kernel with a 4 KiB userspace ABI."""

import gzip
import hashlib
import json
from pathlib import Path
import shutil

from qualify import require, terminal
from build_pages import BASE_CONFIG, SOURCE_SHA, archive_builder, builder_digest, verify_live_kernel, vm_changes
import kernel_candidate


def select(directory, policy, files, folder):
    directory = directory.resolve()
    inputs = json.loads((directory / "build-inputs.json").read_bytes())
    profile = inputs.get("profile") == "full-mthp"
    seed = directory / ("apple.config" if profile else "apple-thp.config")
    ctl = Path(inputs["control_dir"])
    control, base = kernel_candidate.inspect(ctl, 4)
    trial, opts = kernel_candidate.inspect(directory / "full", 4)
    diffs = {k: [base.get(k), opts.get(k)] for k in sorted(base.keys() | opts.keys()) if base.get(k) != opts.get(k)}
    require(inputs["source_sha256"] == SOURCE_SHA and inputs["config_sha256"] == BASE_CONFIG
            and inputs["input_config_sha256"] == terminal.digest(seed)
            and control["config_sha256"] == "a0da9a6ab98e69e253f2e8a27664bdb23f08ab4cef1dd66178c38c26d0035c9c"
            and opts.get("CONFIG_TRANSPARENT_HUGEPAGE") == opts.get("CONFIG_TRANSPARENT_HUGEPAGE_MADVISE") == "y"
            and trial["embedded_config_verified"] and control["embedded_config_verified"]
            and (directory / "full/release").read_text().strip() == "7.3.5-micropod", "unverified mTHP kernel")
    # Both policy arms subsequently boot precisely this Image, including all derived Kconfig changes.
    for key in ("CONFIG_CC_VERSION_TEXT", "CONFIG_PAHOLE_VERSION", "CONFIG_PREEMPT", "CONFIG_ARM64_4K_PAGES",
                "CONFIG_PAGE_SHIFT", "CONFIG_ARM64_VA_BITS", "CONFIG_CPU_MITIGATIONS", "CONFIG_MEMCG",
                "CONFIG_SECCOMP", "CONFIG_CFS_BANDWIDTH", "CONFIG_DEBUG_INFO_BTF"):
        require(opts[key] == base[key], "mTHP build changed " + key)
    require(trial["config_sha256"] == "6691e357388cc628832113a3b341428430d04c63ebf485c5a8c0535498abf7e5" and len(diffs) == 23,
            "compiled THP config differs from the reviewed native Kconfig resolution")
    archive_builder(directory, inputs, folder)
    builder = json.loads((directory / "build-container.json").read_bytes())
    require(builder["image"] == inputs["alpine_image"] and builder["env"] == inputs["original_builder_environment"],
            "THP build environment differs")
    config = directory / "full/config"
    files.update(kernel=directory / "full/Image", kernel_config=config)
    (folder / "mthp-config.gz").write_bytes(gzip.compress(config.read_bytes(), mtime=0))
    if profile:
        proof = json.loads((directory / "profile-result.json").read_bytes())
        require(proof["profile_image"] == trial and proof["builder_sha256"] == inputs["builder_sha256"]
                and proof["base_config_sha256"] == terminal.digest(seed) == BASE_CONFIG and proof["builder_retired"],
                "profile rebuild evidence differs")
        shutil.copyfile(directory / "profile-result.json", folder / "mthp-profile.json")
        evidence = {"profile_receipt_sha256": terminal.digest(folder / "mthp-profile.json")}
    else:
        shutil.copyfile(directory / "base-config.patch", folder / "mthp-base-config.patch")
        evidence = {"config_patch_sha256": terminal.digest(folder / "mthp-base-config.patch")}
    shutil.copyfile(directory / "toolchain.txt", folder / "mthp-toolchain.txt")
    terminal.save(folder / "mthp-build.json", {"inputs": inputs, "builder": builder, "control": control, "image": trial,
                  "config_changes": diffs, "toolchain_sha256": terminal.digest(folder / "mthp-toolchain.txt"),
                  **evidence})
    return {"mthp_16k": policy, "kernel_image_sha256": trial["image_sha256"], "kernel_config_sha256": trial["config_sha256"]}


def stage_observer(oci):
    script = """
thp=/sys/kernel/mm/transparent_hugepage
{
    cat "$thp/enabled"
    cat "$thp/hugepages-16kB/enabled"
    cat "$thp/hugepages-2048kB/enabled"
} > "$MICROPOD_ENGINE_WORKSPACE/mthp-policy.txt"
"""
    with (oci / "runner/fixture-facts.sh").open("a") as output:
        output.write(script)


def validate_boot(lines, facts, policy):
    cmdline, = [s.removeprefix("cmdline=") for s in facts if s.startswith("cmdline=")]
    args = [s for s in cmdline.split() if s.startswith("thp_anon=")]
    require(args == [f"thp_anon=16K:{policy}", "thp_anon=2M:inherit"] and len(lines) == 3
            and "[madvise]" in lines[0] and f"[{policy}]" in lines[1] and "[inherit]" in lines[2],
            "kernel command line or effective anonymous page policies differ")


def check_boot(workspace, folder, policy, facts):
    source = workspace / "mthp-policy.txt"
    validate_boot(source.read_text().splitlines(), facts.read_text().splitlines(), policy)
    shutil.copy2(source, folder / source.name)


def verify_run(folder, plan, fixtures):
    build = json.loads((folder / "mthp-build.json").read_bytes())
    desc = build["image"]
    policy = plan["mthp_16k"]
    blob = gzip.decompress((folder / "mthp-config.gz").read_bytes())
    assignments = kernel_candidate.config_options(blob)
    if build["inputs"].get("profile") == "full-mthp":
        receipt = json.loads((folder / "mthp-profile.json").read_bytes())
        require(build["profile_receipt_sha256"] == terminal.digest(folder / "mthp-profile.json")
                and receipt["profile_image"] == desc and receipt["base_config_sha256"] == BASE_CONFIG
                and receipt["builder_sha256"] == build["inputs"]["builder_sha256"], "public profile proof differs")
    else:
        require(build["config_patch_sha256"] == terminal.digest(folder / "mthp-base-config.patch"), "THP base patch differs")
    require(desc["page_kib"] == 4 and desc["embedded_config_verified"]
            and hashlib.sha256(blob).hexdigest() == desc["config_sha256"]
            and assignments["CONFIG_TRANSPARENT_HUGEPAGE"] == assignments["CONFIG_TRANSPARENT_HUGEPAGE_MADVISE"] == "y"
            and build["inputs"]["source_sha256"] == SOURCE_SHA and build["inputs"]["config_sha256"] == BASE_CONFIG
            and build["inputs"]["builder_sha256"] == builder_digest(folder, plan)
            and build["toolchain_sha256"] == terminal.digest(folder / "mthp-toolchain.txt"),
            "mTHP kernel artifacts changed")
    require(policy in ("never", "always"), "unknown anonymous page policy")
    validate_boot((folder / "mthp-policy.txt").read_text().splitlines(),
                  (folder / "a/guest-facts.txt").read_text().splitlines(), policy)
    actual = vm_changes(folder, "A")
    require("[madvise]" in actual["thp_policy"] and f"[{policy}]" in actual["sizes"]["hugepages-16kB"],
            "16 KiB policy changed while CI ran")
    allocations = actual["vmstat_delta"]["hugepages-16kB:anon_fault_alloc"]
    require((allocations == 0 if policy == "never" else allocations > 0),
            "kernel did not exercise the selected anonymous page allocation policy")
    return verify_live_kernel(folder, plan, fixtures, 4, desc)
