"""Audit an effective arm64 kernel .config or replay the archived Gamma stock build.

Examples:
    python3 scripts/relaybench/kernel_compiler.py --gamma-stock
    python3 scripts/relaybench/kernel_compiler.py --config path/to/config

Values are effective Kconfig entries. Null means the symbol was absent, and n
means it was explicitly disabled. A profile-enabled config does not identify
the sampled profile used by the compiler. Runtime mitigations require a boot.
"""
import argparse
import hashlib
import json
from pathlib import Path

from gamma_contrasts import ROOT, read_receipt
from kernel_candidate import config_options


COMPILERS = {"CONFIG_CC_IS_GCC": "GCC", "CONFIG_CC_IS_CLANG": "Clang"}
LTO_MODES = {"CONFIG_LTO_NONE": "none", "CONFIG_LTO_CLANG_THIN": "Clang ThinLTO",
             "CONFIG_LTO_CLANG_FULL": "Clang full LTO"}
PROFILE_OPTIONS = ("CONFIG_AUTOFDO_CLANG", "CONFIG_PROPELLER_CLANG")
MITIGATIONS = ("CONFIG_CPU_MITIGATIONS", "CONFIG_UNMAP_KERNEL_AT_EL0", "CONFIG_MITIGATE_SPECTRE_BRANCH_HISTORY",
               "CONFIG_ARM64_PTR_AUTH", "CONFIG_ARM64_BTI", "CONFIG_ARM64_BTI_KERNEL", "CONFIG_CFI",
               "CONFIG_SHADOW_CALL_STACK", "CONFIG_STACKPROTECTOR", "CONFIG_STACKPROTECTOR_STRONG",
               "CONFIG_STACKPROTECTOR_PER_TASK", "CONFIG_VMAP_STACK", "CONFIG_RANDOMIZE_BASE")


def selected(options, choices):
    active = [name for symbol, name in choices.items() if options.get(symbol) == "y"]
    if len(active) > 1:
        raise ValueError(f"multiple selections: {active}")
    return active[0] if active else None


def audit(data):
    options = config_options(data)
    if options.get("CONFIG_ARM64") != "y":
        raise ValueError("expected an effective arm64 kernel config")
    for symbol in (*COMPILERS, *LTO_MODES, *PROFILE_OPTIONS, *MITIGATIONS):
        if symbol in options and options[symbol] not in ("y", "n"):
            raise ValueError(f"expected a boolean for {symbol}")
    compiler = selected(options, COMPILERS)
    lto = selected(options, LTO_MODES)
    if compiler == "GCC" and (lto in ("Clang ThinLTO", "Clang full LTO")
                              or any(options.get(key) == "y" for key in PROFILE_OPTIONS)):
        raise ValueError("Clang optimization selected in a GCC config")
    def fields(keys):
        return {key: options.get(key) for key in keys}

    return {"config_sha256": hashlib.sha256(data).hexdigest(), "compiler": compiler,
            "compiler_options": fields((*COMPILERS, "CONFIG_CC_VERSION_TEXT", "CONFIG_GCC_VERSION", "CONFIG_CLANG_VERSION")),
            "lto_mode": lto, "lto_options": fields(LTO_MODES), "profile_options": fields(PROFILE_OPTIONS),
            "mitigation_build_options": fields(MITIGATIONS), "profile_use_verified": False,
            "runtime_mitigations_verified": False}


def gamma_stock():
    archive = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
    record = read_receipt(archive, "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976")
    stock = record["kernels"]["full"]
    report = audit(stock["config"].encode())
    if report["config_sha256"] != stock["config_sha256"]:
        raise ValueError("embedded stock config differs from its recorded digest")
    report.update(recorded_image_sha256=stock["image_sha256"], recorded_release=stock["release"])
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = parser.add_mutually_exclusive_group(required=True)
    src.add_argument("--config", type=Path)
    src.add_argument("--gamma-stock", action="store_true")
    args = parser.parse_args()
    try:
        print(json.dumps(gamma_stock() if args.gamma_stock else audit(args.config.read_bytes()), indent=2))
    except (ValueError, OSError) as error:
        parser.exit(2, f"Cannot audit kernel config: {error}\n")
