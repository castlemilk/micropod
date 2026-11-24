"""Compare two service_qdisc_capture.sh snapshots bracketing a direct-path diagnostic."""
import argparse
import hashlib
from ipaddress import IPv4Address
import json
from pathlib import Path
import re
from uuid import UUID

from bql_bounds import uptime
from guest_link_path import snapshot, unique_keys


def read_snapshot(raw, boot, netns, peer):
    lines = raw.decode("ascii").splitlines()
    if len(lines) < 13 or lines[0] != "service-qdisc-v1" or lines[-4] != "@@ end":
        raise ValueError("incomplete service qdisc snapshot")
    if (str(UUID(lines[1])) != str(UUID(boot)) or lines[-1] != lines[1] or lines[2] != netns
            or lines[-2] != netns or not re.fullmatch(r"net:\[[1-9]\d*\]", netns)):
        raise ValueError("unexpected service namespace or boot")
    begin, end = uptime(lines[3]), uptime(lines[-3])
    if end < begin:
        raise ValueError("reversed capture interval")

    names = ("link-before", "route", "qdisc", "link-after")
    marks = [(i, line) for i, line in enumerate(lines[4:-4], 4) if line.startswith("@@")]
    if [v for i, v in marks] != ["@@ " + name for name in names] or marks[0][0] != 4:
        raise ValueError("incomplete or reordered capture sections")
    offset = [i for i, v in marks] + [len(lines) - 4]
    values = [json.loads("\n".join(lines[i + 1:j]), object_pairs_hook=unique_keys)
              for i, j in zip(offset, offset[1:])]
    left, route, qdiscs, right = values
    links = [snapshot({"links": data}) for data in (left, right)]
    if any(set(link) != {"mppub0"} for link in links):
        raise ValueError("expected direct service interface")
    identities = [link["mppub0"][0] for link in links]
    ident = identities[0]
    if ident != identities[1] or ident[2:4] != ("macvlan", "private") or type(ident[4]) is not int or ident[4] <= 0:
        raise ValueError("private macvlan link changed or parent ifindex missing")
    if (len(route) != 1 or route[0].get("dev") != "mppub0" or route[0].get("gateway")
            or route[0].get("dst") != str(IPv4Address(peer))):
        raise ValueError("destination no longer uses the dedicated direct service interface")
    roots = [q for q in qdiscs if q.get("root") is True]
    if len(roots) != 1:
        raise ValueError("need one root service qdisc")
    root = roots[0]
    if not isinstance(root.get("kind"), str) or not re.fullmatch(r"[0-9a-f]+:", root.get("handle", "")):
        raise ValueError("incomplete root qdisc identity")
    counts = {key: root.get(key) for key in ("bytes", "packets", "drops", "requeues")}
    tx = [link["mppub0"][1]["tx_bytes"] for link in links]
    if any(type(n) is not int or n < 0 for n in (*counts.values(), *tx)) or tx[1] < tx[0]:
        raise ValueError("missing or invalid qdisc/link counter")
    return dict(link=ident, route_source=route[0].get("prefsrc"), kind=root["kind"], handle=root["handle"],
                options=root.get("options"), counts=counts, link_tx=tx, uptime_cs=[begin, end],
                sha256=hashlib.sha256(raw).hexdigest())


def compare(first, last, boot, netns, peer):
    a, b = [read_snapshot(data, boot, netns, peer) for data in (first, last)]
    fields = ("link", "route_source", "kind", "handle", "options")
    if any(a[k] != b[k] for k in fields) or a["uptime_cs"][1] >= b["uptime_cs"][0]:
        raise ValueError("changed qdisc/link configuration or overlapping observations")
    delta = {key: b["counts"][key] - value for key, value in a["counts"].items()}
    link_bytes = b["link_tx"][0] - a["link_tx"][1]
    if min(*delta.values(), link_bytes) < 0:
        raise ValueError("service qdisc or link counter fell across snapshots")
    return dict(boot=boot, netns=netns, peer=peer, interface="mppub0", before=a, after=b,
                qdisc_delta=delta, link_tx_bytes_between_inner_bounds=link_bytes,
                fq_counted_bytes=a["kind"] == "fq" and delta["bytes"] > 0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    parser.add_argument("--boot", required=True)
    parser.add_argument("--netns", required=True)
    parser.add_argument("--peer", required=True)
    args = parser.parse_args()
    print(json.dumps(compare(args.before.read_bytes(), args.after.read_bytes(),
                             args.boot, args.netns, args.peer), indent=2))
