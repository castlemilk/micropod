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
import mmap
from pathlib import Path
import re
import zlib


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


def verify_embedded_config(image, config, configured):
    # kernel/configs.c places a gzip member between IKCFG_ST and IKCFG_ED.
    # The gzip prefix distinguishes the payload from marker literals in code.
    marker = b"IKCFG_ST\x1f\x8b\x08"
    pos = image.find(marker)
    if pos < 0:
        if configured:
            raise ValueError("Image lacks the kernel config enabled in its sidecar")
        return False
    if image.find(marker, pos + len(marker)) >= 0:
        raise ValueError("multiple embedded kernel configs in Image")
    begin = pos + len(b"IKCFG_ST")
    end = image.find(b"IKCFG_ED", begin)
    if end < 0:
        raise ValueError("unterminated embedded kernel config in Image")
    decoder = zlib.decompressobj(16 + zlib.MAX_WBITS)
    try:
        embedded = decoder.decompress(image[begin:end], len(config) + 1)
    except zlib.error as exc:
        raise ValueError("invalid gzip data in embedded kernel config") from exc
    if not decoder.eof or decoder.unused_data or embedded != config:
        raise ValueError("embedded kernel config differs from sidecar")
    return True


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
    with (directory / "Image").open("rb") as source:
        if source.seek(0, 2) <= 64:
            raise ValueError("missing raw arm64 Image header or payload")
        with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as image:
            length = len(image)
            header = image[:64]
            if hashlib.sha256(image).hexdigest() != sums["Image"]:
                raise ValueError("Image digest differs from builder SHA256SUMS")
            if header[56:60] != b"ARM\x64":
                raise ValueError("missing raw arm64 Image header or payload")
            embedded = verify_embedded_config(image, config, options.get("CONFIG_IKCONFIG") == "y")
    memory_size = int.from_bytes(header[16:24], "little")
    flags = int.from_bytes(header[24:32], "little")
    granule = (None, *PAGE_SIZES)[(flags >> 1) & 3]
    if memory_size <= 64 or flags & 1 or granule != expected_kib:
        raise ValueError(f"arm64 Image header does not confirm little-endian {expected_kib} KiB pages")
    return {"image_sha256": sums["Image"], "config_sha256": sums["config"],
            "image_bytes": length, "image_memory_bytes": memory_size, "page_kib": granule,
            "embedded_config_verified": embedded}, options


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
