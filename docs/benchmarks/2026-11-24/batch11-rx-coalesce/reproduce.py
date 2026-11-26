"""Replay an RX-only timer request through the original global and per-queue virtio setters."""
import argparse
import hashlib
import json
import re
import subprocess
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
DRIVER = "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"
BASE = "2e9b37c1e68334c443d71b729f0bd6334d824ddd"
NAMES = """txq2vq rxq2vq virtnet_send_ctrl_coal_vq_cmd virtnet_send_rx_ctrl_coal_vq_cmd
virtnet_send_tx_ctrl_coal_vq_cmd virtnet_send_tx_notf_coal_cmds virtnet_send_rx_notf_coal_cmds
virtnet_send_notf_coal_cmds virtnet_send_rx_notf_coal_vq_cmds virtnet_send_notf_coal_vq_cmds
virtnet_coal_params_supported virtnet_should_update_vq_weight virtnet_set_coalesce
virtnet_set_per_queue_coalesce""".split()


def sha(data):
    return hashlib.sha256(data).hexdigest()


def replay(driver):
    source = driver.read_bytes()
    assert sha(source) == DRIVER
    functions = []
    for name in NAMES:
        match = re.search(rb"(?m)^static int " + name.encode() + rb"\([^;{]*?\)\n\{", source)
        assert match, name
        functions.append(source[match.start():source.index(b"\n}\n", match.end()) + 3])
    code = b"\n".join(functions)
    # Each context has two arms, differing solely in the setter used for the same numeric request.
    scenarios = [
        ("both, device accepts", (1, 1, 1, 0), ("global", "queue0")),
        ("both, device refuses TX commands", (1, 1, 1, 1), ("queue0", "global")),
        ("global feature alone", (1, 0, 0, 0), ("queue0", "global")),
        ("neither notification feature", (0, 0, 0, 0), ("global", "queue0")),
    ]
    inputs = []
    for _, setup, order in scenarios:
        for arm in order:
            inputs.append(" ".join(map(str, (*setup, int(arm == "queue0")))))
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp)
        (dest / "driver.h").write_bytes(code)
        exe = dest / "coalesce"
        subprocess.run(["cc", "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter",
                        "-I", tmp, str(HERE/"fixture.c"), "-o", str(exe)], check=True)
        lines = subprocess.check_output([str(exe)], input="\n".join(inputs)+"\n", text=True).splitlines()
    assert len(lines) == 8
    expect = [
        ("0 TR 20 20 8 8 20 8", "0 rt 20 80 8 16 10 8"),
        ("-22 rt 20 80 8 16 10 8", "-22 T 10 80 8 16 10 8"),
        ("-95 - 10 10 8 8 10 8", "0 TR 20 20 8 8 20 8"),
        ("-95 - 0 0 0 0 0 0", "-95 - 0 0 0 0 0 0"),
    ]
    rows = []
    for n, (name, setup, order) in enumerate(scenarios):
        for i, arm in enumerate(order):
            output = lines[2*n+i]
            assert output == expect[n][i], (name, arm, output)
            rc, trace, rx0, rx1, tx0, tx1, grx, gtx = output.split()
            rows.append(dict(context=name, arm=arm, global_feature=setup[0], vq_feature=setup[1],
                             initial_rx_us=[10,80] if setup[2] else [10*setup[0]]*2,
                             initial_tx_us=[8,16] if setup[2] else [8*setup[0]]*2,
                             device_refuses_tx=bool(setup[3]), status=int(rc), commands_sent=trace,
                             final_rx_us=[int(rx0),int(rx1)], final_tx_us=[int(tx0),int(tx1)],
                             final_global_rx_us=int(grx), final_global_tx_us=int(gtx)))
    return dict(date="2026-11-24", id="231.03", tier="source/fixture", micropod_base=BASE,
                kernel="7.3.5", kernel_tar_sha256="8f293f83d54f0b7b9be56863ebc5e4ea79d73e530b4ae55c572be97ef39f0990",
                driver_path="drivers/net/virtio_net.c", driver_sha256=DRIVER, functions_sha256=sha(code),
                functions=NAMES, fixture_sha256=sha((HERE/"fixture.c").read_bytes()),
                reproducer_sha256=sha(Path(__file__).read_bytes()),
                compiler=subprocess.check_output(["cc","--version"],text=True).splitlines()[0],
                fixed="Two modeled queue pairs. Driver marked up, TX NAPI weight 64, adaptive RX off; all "
                      "frames-one, RX timer request 20 us; target queue 0. TX timer parameter unchanged.",
                trace_legend="R/T = global RX/TX, r/t = individual RX/TX, -=no command. Includes refused commands.",
                limits="Mock control-VQ acknowledgments, captured driver cache; no NIC interrupt/packet/time measurements.",
                rows=rows)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("virtio_driver", type=Path)
    parser.add_argument("new_output", type=Path)
    args = parser.parse_args()
    result = replay(args.virtio_driver)
    with args.new_output.open("x") as f:
        json.dump(result, f, indent=2)
        f.write("\n")
