"""Compile exact per-queue virtio-net setters and getters and test one TX mode change."""
import argparse
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER_SHA = "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"
TAR_SHA = "8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990"
IMAGE_SHA = "7e3713940eec7466d1b47f959244534051b46ea70c50796e292a651112e8a0bd"
FUNCS = ("virtnet_coal_params_supported", "virtnet_should_update_vq_weight",
         "virtnet_set_per_queue_coalesce", "virtnet_get_per_queue_coalesce")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def verified_source(path):
    raw = path.read_bytes()
    if digest(raw) != DRIVER_SHA:
        raise ValueError("driver source SHA differs")
    chunks = []
    for name in FUNCS:
        start = raw.index(b"static int " + name.encode() + b"(")
        end = raw.index(b"\n}\n", start) + 3
        chunks.append(raw[start:end])
    return b"\n".join(chunks)


def run(source):
    fragment = HERE / "virtio-tx-coalesce.inc"
    functions = fragment.read_bytes().split(b"// End provenance header.\n", 1)[1]
    if source and verified_source(source) != functions:
        raise ValueError("extracted functions differ from pinned source")
    fixture = HERE / "napi_tx_fixture.c"
    compiler = os.environ.get("CC", "cc")
    version = subprocess.check_output([compiler, "--version"], text=True).splitlines()[0]
    with tempfile.TemporaryDirectory() as temp:
        exe = str(Path(temp) / "napi-tx")
        subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-O0",
                        str(fixture), "-o", exe], check=True)
        output = subprocess.check_output([exe], text=True)
    rows = []
    for line in output.splitlines():
        up, initial, requested, result, weight, readback = map(int, line.split())
        changed = requested != bool(initial)
        expected = -16 if up and changed else 0
        expected_weight = initial if expected else requested * 64
        if (result, weight, readback) != (expected, expected_weight, int(bool(expected_weight))):
            raise ValueError("unexpected control, rejection or readback")
        rows.append(dict(interface_up=bool(up),initial_weight=initial,requested_tx_frames=requested,
                         changes_weight=changed,driver_return=result,effective_weight=weight,
                         readback_tx_frames=readback))
    if len({(x["interface_up"], x["initial_weight"], x["requested_tx_frames"]) for x in rows}) != 8:
        raise ValueError("incomplete fixture matrix")
    return dict(date="2026-11-24",id="231.03",tier="source/fixture",linux="7.3.5",
                stock_image_sha256=IMAGE_SHA,linux_tar_sha256=TAR_SHA,driver_file_sha256=DRIVER_SHA,
                procedures=list(FUNCS),functions_sha256=digest(functions),fixture_sha256=digest(fixture.read_bytes()),
                compiler=version,stdout=output,observations=rows,assumptions=[
                    "One TX queue; VQ_NOTF_COAL absent. The setting path is driver code; the net device, selected "
                    "feature and ethtool request structs are modeled. No sysfs, socket, interface or VM was accessed.",
                    "Each row runs once. These deterministic syscall-handler return and queue-state checks have no "
                    "sampling interval, throughput, loss, fresh latency or process CPU measurements."])

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="verify included functions byte-for-byte against virtio_net.c")
    print(json.dumps(run(parser.parse_args().source), indent=2))
