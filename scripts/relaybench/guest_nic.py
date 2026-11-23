"""Decode guest_nic_capture.sh stdout from the direct-publication worker NIC."""
import argparse
import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from uuid import UUID


SECTIONS = ("before", "bitmap", "queues", "offloads", "channels", "coalescing", "after")
NAPI_CONTROLS = ("napi_tx_module", "napi_defer_hard_irqs", "gro_flush_timeout_ns")
# Linux drivers/virtio/virtio.c features_show emits bit zero first. Feature
# numbers are from the virtio_net, virtio_ring and virtio_config UAPI headers. Keep the full raw bitmap,
# since a kernel can expose further device and transport features.
FEATURE_BITS = {0: "CSUM", 1: "GUEST_CSUM", 2: "CTRL_GUEST_OFFLOADS",
                7: "GUEST_TSO4", 8: "GUEST_TSO6", 11: "HOST_TSO4", 12: "HOST_TSO6",
                15: "MRG_RXBUF", 17: "CTRL_VQ", 22: "MQ", 28: "INDIRECT_DESC", 29: "EVENT_IDX",
                32: "VERSION_1", 34: "RING_PACKED", 35: "IN_ORDER", 52: "VQ_NOTF_COAL",
                53: "NOTF_COAL", 60: "RSS"}


def split_sections(text):
    version = 2 if text.startswith("@@ guest-nic 2\n") else 1
    lines = iter(text.splitlines())
    if version == 2:
        next(lines)
    sections = {}
    keys = SECTIONS[:-1] + (NAPI_CONTROLS if version == 2 else ()) + ("after",)
    for key in keys:
        if next(lines, None) != "@@ " + key:
            raise ValueError(f"missing section {key}")
        result = []
        for line in lines:
            if line.startswith("@@ "):
                end = re.fullmatch(r"@@ end " + key + r" (\d+)", line)
                if not end:
                    raise ValueError(f"incomplete section {key}")
                sections[key] = (int(end[1]), result)
                break
            result.append(line)
        else:
            raise ValueError(f"truncated section {key}")
    if next(lines, None) is not None:
        raise ValueError("unexpected data after final identity")
    return version, sections


def feature_bitmap(bits):
    if not re.fullmatch(r"[01]{64,}", bits):
        raise ValueError("incomplete virtio feature bitmap")
    return {"raw": bits, "negotiated": {name: bits[bit] == "1" for bit, name in FEATURE_BITS.items()}}


def decode(raw, expected_boot):
    version, sections = split_sections(raw.decode("utf-8"))
    status, identity = sections["before"]
    if status or sections["after"] != (0, identity) or len(identity) != 7:
        raise ValueError("guest or interface identity changed or is incomplete")
    boot, kernel, index, mac, netns, device, driver = identity
    if UUID(boot) != UUID(expected_boot) or not kernel or not re.fullmatch(r"[1-9]\d*", index):
        raise ValueError("unexpected guest boot, kernel release or ifindex")
    if not (re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac) and re.fullmatch(r"net:\[\d+\]", netns)
            and device.startswith("/sys/devices/") and re.fullmatch(r"virtio\d+", PurePosixPath(device).name)
            and driver == "/sys/bus/virtio/drivers/virtio_net"):
        raise ValueError("incomplete virtio-net device identity")
    report = {"schema": version, "boot_id": str(UUID(boot)), "kernel_release": kernel,
              "interface": "eth1", "ifindex": int(index), "mac": mac, "netns": netns, "device": device,
              "driver": driver, "capture_sha256": hashlib.sha256(raw).hexdigest(), "unavailable": {}}
    for key, (status, lines) in sections.items():
        if key in ("before", "after"):
            continue
        if status:
            report[key] = None
            report["unavailable"][key] = {"exit_code": status, "diagnostic": "\n".join(lines)}
            continue
        if key == "bitmap":
            report[key] = feature_bitmap("\n".join(lines))
        elif key == "napi_tx_module":
            if lines not in (["Y"], ["N"]):
                raise ValueError("invalid virtio-net napi_tx module parameter")
            report[key] = lines == ["Y"]
        elif key in ("gro_flush_timeout_ns", "napi_defer_hard_irqs"):
            if len(lines) != 1 or not re.fullmatch(r"0|[1-9][0-9]*", lines[0]):
                raise ValueError(f"invalid {key} readback")
            report[key] = int(lines[0])
        elif key == "queues":
            if not lines or any(not re.fullmatch(r"(rx|tx)-\d+", name) for name in lines) or len(set(lines)) != len(lines):
                raise ValueError("invalid sysfs queue inventory")
            queues = {direction: sorted(int(name[3:]) for name in lines if name.startswith(direction + "-"))
                      for direction in ("rx", "tx")}
            if not all(queues.values()):
                raise ValueError("missing RX or TX queue inventory")
            report[key] = queues
        else:
            title = {"offloads": "Features", "channels": "Channel parameters", "coalescing": "Coalesce parameters"}[key]
            if not lines or lines[0] != title + " for eth1:" or not any(line.strip() for line in lines[1:]):
                raise ValueError(f"missing or wrong-device ethtool {key} output")
            # Preserve tool-specific values such as n/a, [fixed] and requested settings.
            report[key] = "\n".join(lines)
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    parser.add_argument("--expected-boot", required=True, help="Linux guest boot UUID from the benchmark fixture")
    args = parser.parse_args()
    try:
        print(json.dumps(decode(args.capture.read_bytes(), args.expected_boot), indent=2))
    except (OSError, ValueError) as error:
        parser.exit(1, f"Invalid guest NIC capture: {error}\n")
