"""Bind REA Mach-O observations to installed bytes and the recorded Micropod boot."""
import argparse
import gzip
import hashlib
import json
import plistlib
import re
import sys
import zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(ROOT / "scripts/relaybench"))
from kernel_candidate import config_options, verify_embedded_config
from gamma_contrasts import VM, read_receipt
from peer_verdict import ARCHIVE_SHA

OPTIONS = ("CONFIG_CPU_MITIGATIONS", "CONFIG_RANDOMIZE_BASE", "CONFIG_UNMAP_KERNEL_AT_EL0",
           "CONFIG_ARM64_E0PD", "CONFIG_VIRTIO_NET", "CONFIG_VIRTIO_FS")
MARKERS = ("src/vmm/src/device_manager/hvf/mmio.rs", "src/vmm/src/macos/vstate.rs",
           "src/devices/src/virtio/net/device.rs", "src/devices/src/virtio/net/worker.rs",
           "src/devices/src/virtio/net/dgram.rs", "src/devices/src/virtio/queue.rs",
           "src/devices/src/virtio/vsock/tcp.rs", "src/devices/src/virtio/fs/hvc.rs")


def sha(data):
    return hashlib.sha256(data).hexdigest()


def image_config(image):
    marker = b"IKCFG_ST\x1f\x8b\x08"
    if image[56:60] != b"ARM\x64" or image.count(marker) != 1:
        raise ValueError("expected an arm64 Image with one embedded config")
    start = image.index(marker) + len(b"IKCFG_ST")
    end = image.index(b"IKCFG_ED", start)
    config = zlib.decompressobj(31).decompress(image[start:end], 1024 * 1024 + 1)
    if len(config) > 1024 * 1024:
        raise ValueError("embedded config exceeds 1 MiB")
    verify_embedded_config(image, config, True)
    return config


def kernel(image, config):
    values = config_options(config)
    return {"image_sha256": sha(image), "config_sha256": sha(config),
            "recorded_config_options": len(values),
            "options": {name: values.get(name) for name in OPTIONS}}


def inspect(args):
    contents = args.app / "Contents"
    metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    packed = args.bundle.read_bytes()
    bundle = gzip.decompress(packed) if packed.startswith(b"\x1f\x8b") else packed
    records = json.loads(bundle)["records"]
    binaries = {}
    for path in ("MacOS/OrbStack", "Frameworks/OrbStack Helper.app/Contents/MacOS/OrbStack Helper"):
        artifact = (contents / path).read_bytes()
        digest = sha(artifact)
        matches = [r for r in records if r["operation"] == "inspect_macho" and
                   r["subject"]["digest"]["sha256"] == digest]
        if len(matches) != 1:
            raise ValueError(f"expected one matching REA Mach-O observation for {path}")
        record = matches[0]
        result = record["normalized_result"]
        imports = result["imports"]
        binaries[path] = {
            "sha256": digest, "rea_evidence_id": record["evidence_id"], "uuid": result["uuid"],
            "architecture": record["subject"]["architecture"],
            "framework_dependencies": [d["path"] for d in result["dependencies"]["items"]
                                       if any(f"/{f}.framework/" in d["path"]
                                              for f in ("Hypervisor", "Virtualization", "vmnet"))],
            "observed_framework_imports": {f: [i["name"] for i in imports["items"] if i["source"] == f]
                                           for f in ("Hypervisor", "Virtualization", "vmnet")},
            "imports_exhaustive": imports["exhaustive"],
            "rust_path_strings": [name for name in MARKERS if name.encode() in artifact],
        }
    image = (contents / "Resources/assets/release/arm64/kernel").read_bytes()
    orb = kernel(image, image_config(image))
    releases = {m.decode() for m in re.findall(rb"Linux version ([0-9][\w.+-]+)", image)}
    if len(releases) != 1:
        raise ValueError("ambiguous packaged Linux release")
    orb["release"] = releases.pop()
    orb["driver_path_strings"] = [s for s in ("drivers/net/virtio_net.c", "drivers/virtio/virtio_mmio.c")
                                  if s.encode() in image]
    fixture_bytes = args.fixture.read_bytes()
    fixture = json.loads(fixture_bytes)["A"]
    path = args.micropod_image or Path(fixture["kernel"])
    image, config = path.read_bytes(), path.with_name("config").read_bytes()
    verify_embedded_config(image, config, True)
    mp = kernel(image, config)
    if (mp["image_sha256"], mp["config_sha256"]) != (fixture["kernel_image_sha256"], fixture["guest_config_sha256"]):
        raise ValueError("local Micropod image/config differs from the benchmark fixture")
    mp.update(boot_id=fixture["boot"], release=fixture["release"], fixture_sha256=sha(fixture_bytes))
    historical = read_receipt(VM, ARCHIVE_SHA)["scopes"]["confirm-orb"]["state"]["release"]
    devices = None
    if args.boot_log:
        lines = args.boot_log.read_bytes().splitlines()
        devices = sorted({m[1].decode() for line in lines
                          if (m := re.search(rb"kernel \| \[\s*[0-9.]+\] (virtio_net virtio\d+ [\w.-]+):", line))})
    return {"rea_bundle_sha256": sha(bundle),
            "orbstack_version": metadata["CFBundleShortVersionString"], "build": metadata["CFBundleVersion"],
            "binaries": binaries, "packaged_orbstack_kernel": orb, "micropod_fixture_kernel": mp,
            "historical_peer": {"archive_sha256": ARCHIVE_SHA, "release": historical,
                                "matches_packaged_release_string": historical == orb["release"]},
            "guest_interfaces_seen_in_local_boot_log": devices}


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--app", type=Path, default=Path("/Applications/OrbStack.app"))
    p.add_argument("--bundle", type=Path, default=HERE / "native-rea.json.gz")
    p.add_argument("--fixture", type=Path, default=HERE.parent / "disposable-local-fixture" /
                   "20261124T090510Z-local-d0y_1j57/baseline/receiver/fixtures.json")
    p.add_argument("--micropod-image", type=Path, help="installed Image beside its config")
    p.add_argument("--boot-log", type=Path, help="optional OrbStack vmgr.log, scanned for NIC bindings")
    try:
        print(json.dumps(inspect(p.parse_args()), indent=2))
    except (OSError, ValueError, KeyError, zlib.error) as err:
        p.exit(1, f"Cannot verify local artifacts: {err}\n")
