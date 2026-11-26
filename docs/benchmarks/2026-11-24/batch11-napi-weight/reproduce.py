"""Replay receive-poll TX cleanup and RX consumption in the pinned virtio driver."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

HERE = Path(__file__).resolve().parent
DRIVER = "d5f3d5c926e9460d0e79b636352021754fca00d8f16b328d40de5bcecc5deace"
CORE = "8b3c43e8becfd552ead597c2e009edf16b126924a7cbe4c5c961e74563b76274"


def source(filename, digest):
    data = Path(filename).read_bytes()
    assert hashlib.sha256(data).hexdigest() == digest
    return data.decode()


def function(text, signature):
    start = text.index(signature)
    return text[start:text.index("\n}", start) + 2]


def main():
    driver, core = source(sys.argv[1], DRIVER), source(sys.argv[2], CORE)
    assert "weight = n->weight;" in core and "work = n->poll(n, weight);" in core
    assert "module_param(napi_weight, int, 0444);" in driver
    assert "vi->rq[i].napi.weight = napi_weight;" in driver and "napi_tx ? napi_weight : 0" in driver
    poll = function(driver, "static int virtnet_poll(")
    cleanup = "virtnet_poll_cleantx(rq, budget);"
    get_rx = "received = virtnet_receive(rq, budget, &xdp_xmit);"
    assert poll.index(cleanup) < poll.index(get_rx) < poll.index("return received;")
    assert "packets = virtnet_receive_packets(vi, rq, budget, xdp_xmit, &stats);" in driver
    signatures = ["static void __free_old_xmit(", "static void virtnet_free_old_xmit(",
                  "static void free_old_xmit(", "static void virtnet_poll_cleantx(",
                  "static int virtnet_receive_packets("]
    original = "\n\n".join(function(driver, sig) for sig in signatures)
    code = (HERE / "fixture.c.in").read_text().replace("@FUNCTIONS@", original)
    code = code.replace("@POLL@", poll[poll.index(cleanup):poll.index(get_rx) + len(get_rx)])
    with tempfile.TemporaryDirectory() as folder:
        c = Path(folder) / "fixture.c"
        exe = Path(folder) / "fixture"
        c.write_text(code)
        subprocess.run(["cc", "-std=c11", "-O1", "-Wall", "-Werror", c, "-o", exe], check=True)
        arms = []
        for weight in (64, 128):
            run = subprocess.check_output([exe, str(weight)], text=True)
            rows = [json.loads(row) for row in run.splitlines()]
            assert rows[0]["tx_completed"] == 96 and rows[0]["rx_processed"] == min(weight, 96)
            assert sum(r["rx_processed"] for r in rows) == 96
            arms.append({"weight": weight, "polls": rows})
    print(json.dumps({"kernel": "Linux 7.3.5", "virtio_net_sha256": DRIVER,
                      "net_core_sha256": CORE, "tx_skb_bytes": 16384,
                      "rx_buffer_bytes": 128, "arms": arms}, indent=2))


if __name__ == "__main__":
    main()
