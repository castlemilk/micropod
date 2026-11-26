"""Verify the historical service path and both stock setup revisions, offline."""
from pathlib import Path
import gzip
import hashlib
import json
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
ARCHIVE = ROOT / "docs/benchmarks/2026-11-21/gamma-direct-macvlan.json.gz"
ARCHIVE_SHA = "cc3b9e5c365383a3353423ce1f7fc443c8d858a1af24bb082117bcec24ffa976"
REVISIONS = ("7a4eb51a04b51f6332ed49561b3dd0bb42ffacd9", "ad9d174eda5eb499e0e15675829e21a00d836f84")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def run():
    archive = ARCHIVE.read_bytes()
    assert digest(archive) == ARCHIVE_SHA
    d = json.loads(gzip.decompress(archive))
    worker = d["records"]["holdout_workers"]["full-reno"]
    before, after = worker["state"], worker["end-scoring"]
    assert worker["boot.json"]["cpus"] == 4 and worker["controller"] == "reno"
    assert before["release"] == after["release"] == "7.3.5-micropod"
    routes = worker["routes.json"]["mppub0"]
    assert len(routes) == 1
    route = routes[0]
    assert (route["Congctl"], route["RtoMin"], route["RtoMinLock"], route["Dst"]["Mask"]) == ("reno", 20, True, "/////w==")
    deltas = {}
    for name in ("eth0", "mppub0"):
        a, b = [x["interfaces"][name] for x in (before, after)]
        assert a["mac"] == b["mac"] and a["mac"]
        assert not (a.keys() | b.keys()) & {"qdisc", "qdiscs"}
        deltas[name] = b["tx_bytes"] - a["tx_bytes"]
    pins = {}
    for rev in REVISIONS:
        source = {name: subprocess.check_output(["git", "show", f"{rev}:guest/runner/{name}"], cwd=ROOT)
                  for name in ("docker_port_direct_linux.go", "docker_port_nat_linux.go", "docker_engine_linux.go")}
        direct = source["docker_port_direct_linux.go"]
        assert b'Name: "mppub0", ParentIndex: parent.Index' in direct and b'Mode: netlink.MACVLAN_MODE_PRIVATE' in direct
        assert direct.index(b'end.pod.RouteAdd(&route)') < direct.index(b'paceDefaultQueue(end.pod, end.link, "noqueue")')
        helper = source["docker_port_nat_linux.go"]
        assert all(marker in helper for marker in (b'link, "pfifo_fast"', b'q.Attrs().Parent != netlink.HANDLE_ROOT',
                                                   b'q.Attrs().Handle == 0 && q.Type() == initial',
                                                   b'handle.QdiscReplace(netlink.NewFq('))
        assert b'if err := pacePublishedLink();' in source["docker_engine_linux.go"]
        pins[rev] = {name: digest(data) for name, data in source.items()}
    return {"archive": ARCHIVE.name, "archive_sha256": ARCHIVE_SHA, "record": "records.holdout_workers.full-reno",
            "worker_boot": worker["boot.json"]["boot"], "kernel": before["release"], "gateway": route["Dst"]["IP"],
            "return_interface": "mppub0", "route_congestion": route["Congctl"], "scope_interval_tx_bytes": deltas,
            "runtime_root_qdisc_readback": None, "stock_setup_source_hashes": pins}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2))
