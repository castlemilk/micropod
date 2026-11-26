"""Audit ARM64 ELF load segments in the saved Docker image archives used by the benchmarks.

This reads layer contents without extracting files or running guest code. Results describe
file/virtual address alignment for each ELF occurrence, including shared libraries.
"""
import argparse
import gzip
import hashlib
import io
import json
import struct
import tarfile
from pathlib import Path

HEADER = struct.Struct("<16sHHIQQQIHHHHHH")
PROGRAM = struct.Struct("<IIQQQQQQ")
PAGES = (4096, 16384)


def elf_layout(data):
    ident, kind, machine, version, _, offset, _, _, _, stride, count, *_ = HEADER.unpack_from(data)
    if (ident[:7] != b"\x7fELF\x02\x01\x01" or machine != 183 or version != 1
            or kind not in (2, 3) or stride < PROGRAM.size or not count
            or offset < HEADER.size or offset + count * stride > len(data)):
        raise ValueError("expected a complete little-endian ARM64 executable or shared object")
    loads = []
    for i in range(count):
        typ, flags, pos, vaddr, _, size, memsize, align = PROGRAM.unpack_from(data, offset + i * stride)
        if typ == 1:
            if size > memsize or pos + size > len(data):
                raise ValueError("invalid PT_LOAD bounds")
            loads.append(dict(offset=pos, vaddr=vaddr, flags=flags, file_bytes=size, alignment=align))
    if not loads:
        raise ValueError("no PT_LOAD segments")
    # Low declared p_align alone cannot decide this. File-backed mappings need
    # matching intra-page offsets in the file and in virtual memory.
    mismatches = {str(page): [i for i, s in enumerate(loads) if s["file_bytes"]
                              and s["offset"] % page != s["vaddr"] % page] for page in PAGES}
    return dict(sha256=hashlib.sha256(data).hexdigest(), segments=loads, offset_mismatches=mismatches)


def checked_blob(archive, member):
    data = archive.extractfile(member).read()
    digest = hashlib.sha256(data).hexdigest()
    if member != "blobs/sha256/" + digest:
        raise ValueError(f"content digest differs for {member}")
    return data


def inspect(path):
    with tarfile.open(path) as archive:
        entries = json.load(archive.extractfile("manifest.json"))
        if len(entries) != 1:
            raise ValueError("expected a single exported image")
        entry = entries[0]
        config = json.loads(checked_blob(archive, entry["Config"]))
        layers = entry["Layers"]
        diffs = config["rootfs"]["diff_ids"]
        if (config.get("os"), config.get("architecture")) != ("linux", "arm64") or len(layers) != len(diffs):
            raise ValueError("need a Linux ARM64 config with matching layer count")
        files = []
        for member, expected in zip(layers, diffs):
            blob = checked_blob(archive, member)
            data = gzip.decompress(blob) if blob[:2] == b"\x1f\x8b" else blob
            if "sha256:" + hashlib.sha256(data).hexdigest() != expected:
                raise ValueError("layer differs from image configuration")
            with tarfile.open(fileobj=io.BytesIO(data), mode="r:") as layer:
                for info in layer:
                    if info.isreg():
                        with layer.extractfile(info) as f:
                            magic = f.read(4)
                            if magic == b"\x7fELF":
                                files.append(dict(path=info.name, layer=expected, **elf_layout(magic + f.read())))
        if not files:
            raise ValueError("image has no regular ELF files to inspect")
    return dict(archive=path.name, config_sha256=entry["Config"].split("/")[-1], elf_files=files)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("images", type=Path, nargs="+")
    args = parser.parse_args()
    try:
        result = [inspect(path) for path in args.images]
    except (OSError, EOFError, ValueError, KeyError, struct.error, tarfile.TarError) as exc:
        parser.exit(2, f"Unable to inspect image: {exc}\n")
    print(json.dumps({"scope": "PT_LOAD file/virtual offset congruence only; no guest boot or runtime ABI test",
                      "page_sizes": PAGES, "images": result}, indent=2))
