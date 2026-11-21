#!/usr/bin/env python3
"""How long a delete holds container-apiserver's containers lock.

One CI-shaped round at a time against a scratch MicropodAPI:
  CreateVolume (workspace), RunContainer that writes --files small files into
  its rootfs and as many into the workspace (scattered 2-16 KiB writes, the
  shape that makes an APFS clone expensive to free), WaitContainer, then
  DeleteContainer and DeleteVolume. While each delete is in flight a probe
  CreateContainer (create only, never started) is sent: create takes the same
  lock, so its latency is how long the delete kept everyone else waiting.

Run it twice, against the same build with MICROPOD_RECLAIM=off and on, and
compare. Everything it creates is named <prefix>-* and removed at the end.
Never point it at the shared :45454 API:

  MICROPOD_API_PORT=45491 MICROPOD_RECLAIM=off \\
    MICROPOD_VOLUME_CLONE_ROOT=$TMP/clones MICROPOD_RECLAIM_ROOT=$TMP/reclaim \\
    .build/debug/MicropodAPI &
  python3 scripts/bench_reclaim.py --base http://127.0.0.1:45491 --image <local image with python3>

Stdlib only.
"""

import argparse
import json
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request

SERVICES = {
    "CreateContainer": "ContainerService",
    "RunContainer": "ContainerService",
    "WaitContainer": "ContainerService",
    "DeleteContainer": "ContainerService",
    "ListContainers": "ContainerService",
    "CreateVolume": "VolumeService",
    "DeleteVolume": "VolumeService",
    "ListVolumes": "VolumeService",
}

WRITER = """import os, random
r = random.Random(7); b = os.urandom(16384)
for root in ('/opt/w', '/ws/w'):
    for d in range(500): os.makedirs('%s/%d' % (root, d), exist_ok=True)
    for i in range({files}):
        with open('%s/%d/%d' % (root, r.randrange(500), i), 'wb') as f:
            f.write(b[:r.choice([2048, 4096, 8192, 16384])])
os.sync()
"""


def call(base, rpc, body, timeout=600):
    url = f"{base}/api/micropod.v1.{SERVICES[rpc]}/{rpc}"
    request = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers={"Content-Type": "application/json"})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read() or b"{}")
            return "ok", payload, time.monotonic() - started
    except urllib.error.HTTPError as error:
        try:
            detail = json.loads(error.read() or b"{}")
        except ValueError:
            detail = {}
        return detail.get("code", f"http_{error.code}"), detail, time.monotonic() - started
    except Exception as error:  # timeouts, resets
        return "client_" + type(error).__name__, {"message": str(error)}, time.monotonic() - started


def probe_during(base, image, name, delay, out):
    """A create (never started) sent `delay` s into a delete: how long it waits."""
    time.sleep(delay)
    code, _, took = call(base, "CreateContainer", {
        "image": image, "name": name, "detach": True, "arguments": ["true"],
        "labels": {"dev.micropod.bench": "reclaim-probe"}})
    out["probe_code"], out["probe_s"] = code, round(took, 3)
    call(base, "DeleteContainer", {"id": name, "force": True})


def timed_delete(base, rpc, body, image, probe_name, delay):
    probe = {}
    thread = threading.Thread(target=probe_during, args=(base, image, probe_name, delay, probe))
    thread.start()
    code, _, took = call(base, rpc, body)
    thread.join()
    return {"code": code, "s": round(took, 3), **probe}


def metrics(base):
    try:
        with urllib.request.urlopen(f"{base}/metrics", timeout=30) as response:
            text = response.read().decode()
    except Exception:
        return {}
    out = {}
    for line in text.splitlines():
        if line.startswith("micropod_reclaim_pending") or line.startswith("micropod_reclaim_freed_bytes_total"):
            key, value = line.split()
            out[key] = float(value)
        elif line.startswith("micropod_reclaim_request_duration_microseconds_total"):
            out["reclaim_unlink_seconds"] = round(float(line.split()[-1]) / 1e6, 3)
        elif line.startswith("micropod_reclaim_requests_total"):
            out["reclaim_unlinks"] = float(line.split()[-1])
    return out


def cleanup(base, prefix):
    _, listed, _ = call(base, "ListContainers", {}, timeout=120)
    for container in (listed or {}).get("containers", []):
        if container.get("id", "").startswith(prefix + "-"):
            call(base, "DeleteContainer", {"id": container["id"], "force": True})
    _, volumes, _ = call(base, "ListVolumes", {}, timeout=120)
    for volume in (volumes or {}).get("volumes", []):
        name = volume.get("id") or volume.get("name", "")
        if name.startswith(prefix + "-"):
            call(base, "DeleteVolume", {"name": name})


def summarize(rows, key):
    values = sorted(r[key] for r in rows if isinstance(r.get(key), (int, float)))
    if not values:
        return "-"
    return f"p50 {statistics.median(values):6.2f}s  max {values[-1]:6.2f}s  (n={len(values)})"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--image", required=True, help="a local image with python3 (no pull)")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--files", type=int, default=20000, help="small files written to the rootfs and to /ws each")
    parser.add_argument("--ws-size", default="64G")
    parser.add_argument("--probe-delay", type=float, default=0.3)
    parser.add_argument("--pause", type=float, default=5, help="seconds between rounds")
    parser.add_argument("--prefix", default="reclaimbench")
    parser.add_argument("--label", default="")
    parser.add_argument("--out")
    args = parser.parse_args()
    base = args.base.rstrip("/")
    if base.endswith(":45454"):
        sys.exit("refusing to load the shared :45454 API; start a scratch MicropodAPI on another port")

    cleanup(base, args.prefix)
    rows = []
    for round_ in range(args.rounds):
        tag = f"{args.prefix}-{int(time.time())}-{round_}"
        ws, name = f"{tag}-ws", f"{tag}-c"
        code, _, took = call(base, "CreateVolume", {"name": ws, "size": args.ws_size})
        if code != "ok":
            print(f"CreateVolume {code}", file=sys.stderr)
            continue
        row = {"round": round_, "create_volume_s": round(took, 3)}
        code, payload, took = call(base, "RunContainer", {
            "image": args.image, "name": name, "detach": True, "volumes": [f"{ws}:/ws"],
            "entrypoint": "/usr/bin/python3", "arguments": ["-c", WRITER.format(files=args.files)],
            "cpus": 2, "memory": "2g", "labels": {"dev.micropod.bench": "reclaim"}})
        row["run_s"] = round(took, 3)
        if code != "ok":
            row["run_code"] = code
            row["run_error"] = str(payload)[:200]
        deadline = time.monotonic() + 900
        while code == "ok" and time.monotonic() < deadline:
            wcode, wpayload, _ = call(base, "WaitContainer", {"id": name, "timeoutSeconds": 60}, timeout=120)
            if wcode == "ok" and wpayload.get("exited"):
                row["exit_code"] = wpayload.get("exitCode")
                break
        time.sleep(1)
        row["delete_container"] = timed_delete(
            base, "DeleteContainer", {"id": name, "force": True}, args.image, f"{tag}-p1", args.probe_delay)
        row["delete_volume"] = timed_delete(
            base, "DeleteVolume", {"name": ws}, args.image, f"{tag}-p2", args.probe_delay)
        row["metrics"] = metrics(base)
        rows.append(row)
        print(json.dumps({"label": args.label, **row}), flush=True)
        time.sleep(args.pause)
    cleanup(base, args.prefix)

    flat = [{
        "dc": r["delete_container"]["s"], "dc_probe": r["delete_container"].get("probe_s"),
        "dv": r["delete_volume"]["s"], "dv_probe": r["delete_volume"].get("probe_s"),
    } for r in rows]
    print(f"[{args.label}] DeleteContainer        {summarize(flat, 'dc')}")
    print(f"[{args.label}] probe create during it {summarize(flat, 'dc_probe')}")
    print(f"[{args.label}] DeleteVolume           {summarize(flat, 'dv')}")
    print(f"[{args.label}] probe create during it {summarize(flat, 'dv_probe')}")
    if rows:
        print(f"[{args.label}] reclaimer: {rows[-1]['metrics']}")
    if args.out:
        with open(args.out, "w") as handle:
            json.dump(rows, handle, indent=2)


if __name__ == "__main__":
    main()
