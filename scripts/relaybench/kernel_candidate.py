"""Check a page-size experiment using two ci/build-worker-kernel.sh output directories.

Example: python3 scripts/relaybench/kernel_candidate.py stock-4k candidate-16k

An exit status of 0 means that the expected granules and local digests agree and
only page selector symbols changed. Status 1 means there are other effective
Kconfig differences to review, including legitimate page-size dependencies.
Status 2 means the supplied artifacts could not be verified. Boot, OCI, source
and compiler provenance must be established separately.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re


PAGE_SIZES = (4, 16, 64)
PAGE_OPTIONS = {f"CONFIG_ARM64_{size}K_PAGES": size for size in PAGE_SIZES}


def checksums(directory):
    sums = {}
    for line in (directory / "SHA256SUMS").read_text().splitlines():
        match = re.fullmatch(r"([0-9a-f]{64}) [ *](Image|config)", line)
        if not match or match[2] in sums:
            raise ValueError("expected unique Image and config entries in SHA256SUMS")
        sums[match[2]] = match[1]
    if sums.keys() != {"Image", "config"}:
        raise ValueError("incomplete builder SHA256SUMS")
    return sums


def config_options(data):
    options = {}
    for line in data.decode().splitlines():
        entry = re.fullmatch(r"(CONFIG_[A-Za-z0-9_]+)=(.+)", line)
        disabled = re.fullmatch(r"# (CONFIG_[A-Za-z0-9_]+) is not set", line)
        if entry:
            key, value = entry.groups()
        elif disabled:
            key, value = disabled[1], "n"
        elif not line.strip() or line.startswith("#"):
            continue
        else:
            raise ValueError(f"invalid Kconfig entry: {line}")
        if key in options:
            raise ValueError(f"duplicate Kconfig entry: {key}")
        options[key] = value
    return options


def inspect(directory, expected_kib):
    sums = checksums(directory)
    config = (directory / "config").read_bytes()
    if hashlib.sha256(config).hexdigest() != sums["config"]:
        raise ValueError("config digest differs from builder SHA256SUMS")
    options = config_options(config)
    if any(options.get(symbol, "n") not in ("y", "n") for symbol in PAGE_OPTIONS):
        raise ValueError("invalid arm64 page selector in Kconfig")
    selected = [kib for symbol, kib in PAGE_OPTIONS.items() if options.get(symbol) == "y"]
    if options.get("CONFIG_ARM64") != "y" or selected != [expected_kib]:
        raise ValueError(f"expected arm64 with exactly the {expected_kib} KiB Kconfig selector")
    if options.get("CONFIG_CPU_BIG_ENDIAN") == "y":
        raise ValueError("expected a little-endian worker config")

    # Raw Linux arm64 boot protocol: docs.kernel.org/arch/arm64/booting.html.
    # image_size is the required memory extent and can include uninitialised BSS.
    with (directory / "Image").open("rb") as image:
        header = image.read(64)
        checksum = hashlib.sha256(header)
        length = len(header)
        for block in iter(lambda: image.read(1024 * 1024), b""):
            length += len(block)
            checksum.update(block)
    if checksum.hexdigest() != sums["Image"]:
        raise ValueError("Image digest differs from builder SHA256SUMS")
    if length <= 64 or header[56:60] != b"ARM\x64":
        raise ValueError("missing raw arm64 Image header or payload")
    memory_size = int.from_bytes(header[16:24], "little")
    flags = int.from_bytes(header[24:32], "little")
    granule = (None, *PAGE_SIZES)[(flags >> 1) & 3]
    if memory_size <= 64 or flags & 1 or granule != expected_kib:
        raise ValueError(f"arm64 Image header does not confirm little-endian {expected_kib} KiB pages")
    return {"image_sha256": sums["Image"], "config_sha256": sums["config"],
            "image_bytes": length, "image_memory_bytes": memory_size, "page_kib": granule}, options


def compare(control, candidate, control_kib, candidate_kib):
    if control_kib == candidate_kib:
        raise ValueError("the page-size experiment needs two distinct granules")
    base, base_options = inspect(control, control_kib)
    trial, trial_options = inspect(candidate, candidate_kib)
    changes = {symbol: [base_options.get(symbol), trial_options.get(symbol)]
               for symbol in sorted(base_options.keys() | trial_options.keys())
               if base_options.get(symbol) != trial_options.get(symbol)}
    extra = sorted(changes.keys() - PAGE_OPTIONS.keys())
    return {"control": base, "candidate": trial, "config_changes": changes, "additional_config_changes": extra,
            "verdict": "review additional Kconfig changes" if extra else "page selectors verified"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("control", type=Path)
    parser.add_argument("candidate", type=Path)
    parser.add_argument("--control-kib", type=int, choices=PAGE_SIZES, default=4)
    parser.add_argument("--candidate-kib", type=int, choices=PAGE_SIZES, default=16)
    args = parser.parse_args()
    try:
        report = compare(args.control, args.candidate, args.control_kib, args.candidate_kib)
    except (ValueError, OSError) as exc:
        parser.exit(2, f"Kernel artifact verification failed: {exc}\n")
    print(json.dumps(report, indent=2))
    return int(bool(report["additional_config_changes"]))


if __name__ == "__main__":
    raise SystemExit(main())
