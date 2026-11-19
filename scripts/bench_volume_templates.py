#!/usr/bin/env python3
"""CreateVolume latency, and how long it holds the apiserver's volumes actor.

Each round creates one workspace-sized volume through a scratch MicropodAPI
and, --probe-delay seconds in, lists volumes straight from container-apiserver
with the `container` CLI. The apiserver formats a new volume's ext4 image
synchronously on its volumes actor, and the list waits on that actor, so the
probe's latency (less its idle latency, measured first) is how long the
create kept every other volume call waiting. Then the volume is deleted.

Run it against two scratch APIs from the same build, one with
MICROPOD_VOLUME_TEMPLATES=off, never the shared :45454 one:

  MICROPOD_API_PORT=45495 MICROPOD_VOLUME_TEMPLATES=off MICROPOD_VOLUME_TEMPLATE_ROOT=$T/off .build/debug/MicropodAPI &
  MICROPOD_API_PORT=45496 MICROPOD_VOLUME_TEMPLATE_ROOT=$T/on .build/debug/MicropodAPI &
  python3 scripts/bench_volume_templates.py --base http://127.0.0.1:45495 --label off
  python3 scripts/bench_volume_templates.py --base http://127.0.0.1:45496 --label on

The first templated create of a size builds its template (one ordinary
format); it is reported separately as `first`. Everything it creates is
named <prefix>-* and removed. Stdlib only.
"""

import argparse
import json
import statistics
import subprocess
import threading
import time
import urllib.error
import urllib.request


def call(base, method, body, timeout=600):
    request = urllib.request.Request(
        f"{base}/api/micropod.v1.VolumeService/{method}", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
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


def probe(cli):
    started = time.monotonic()
    subprocess.run([cli, "volume", "ls", "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    return time.monotonic() - started


def p50(values):
    return statistics.median(values) if values else float("nan")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--size", default="136g", help="what the agent asks for its workspaces")
    parser.add_argument("--rounds", type=int, default=4)
    parser.add_argument("--probe-delay", type=float, default=0.3)
    parser.add_argument("--pause", type=float, default=3)
    parser.add_argument("--cli", default="container")
    parser.add_argument("--prefix", default="tplbench")
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    base = args.base.rstrip("/")
    if base.endswith(":45454"):
        raise SystemExit("refusing the shared :45454 API; start a scratch MicropodAPI")

    idle = [probe(args.cli) for _ in range(3)]
    idle_p50 = p50(idle)
    rows = []
    for round_ in range(args.rounds):
        name = f"{args.prefix}-{args.label}-{int(time.time() * 1000)}-{round_}"
        held = {}

        def probing():
            time.sleep(args.probe_delay)
            held["probe_s"] = probe(args.cli)

        thread = threading.Thread(target=probing)
        thread.start()
        code, _, took = call(base, "CreateVolume", {"name": name, "size": args.size})
        thread.join()
        row = {"label": args.label, "round": round_, "create_code": code, "create_s": round(took, 3),
               "probe_s": round(held.get("probe_s", float("nan")), 3),
               "actor_wait_s": round(max(0.0, held.get("probe_s", 0) - idle_p50), 3)}
        dcode, _, dtook = call(base, "DeleteVolume", {"name": name})
        row["delete_s"] = round(dtook, 3)
        rows.append(row)
        print(json.dumps(row), flush=True)
        time.sleep(args.pause)

    steady = rows[1:] if args.label == "on" and len(rows) > 1 else rows
    print(f"[{args.label}] idle probe p50 {idle_p50:.3f}s")
    if args.label == "on" and rows:
        print(f"[{args.label}] first create (builds the template) {rows[0]['create_s']:.2f}s")
    print(f"[{args.label}] CreateVolume p50 {p50([r['create_s'] for r in steady]):.3f}s"
          f"  max {max(r['create_s'] for r in steady):.3f}s  (n={len(steady)})")
    print(f"[{args.label}] volumes-actor wait seen by a list p50 {p50([r['actor_wait_s'] for r in steady]):.3f}s"
          f"  max {max(r['actor_wait_s'] for r in steady):.3f}s")


if __name__ == "__main__":
    main()
