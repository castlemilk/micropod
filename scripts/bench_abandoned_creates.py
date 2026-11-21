#!/usr/bin/env python3
"""Does a create its client abandoned still reach the runtime?

The agent gives up on a CreateContainer at its deadline (it closes the
connection; connect-go also sends Connect-Timeout-Ms). This sends
CreateContainer (create only, never started) to a scratch MicropodAPI the
same way: with Connect-Timeout-Ms and a client timeout of --deadline-ms, and
it hangs up when that passes. A few seconds later it asks whether the
container exists. Before cancellation-on-hangup, the abandoned create
finished anyway (a "ghost"); with it, a create abandoned before dispatch
never reaches the runtime.

Run against two scratch APIs from the same build, one with
MICROPOD_CANCEL_ON_HANGUP=off, never the shared :45454 one:

  MICROPOD_API_PORT=45493 MICROPOD_CANCEL_ON_HANGUP=off .build/debug/MicropodAPI &
  MICROPOD_API_PORT=45494 .build/debug/MicropodAPI &
  python3 scripts/bench_abandoned_creates.py --base http://127.0.0.1:45493 --image <local image> --label off
  python3 scripts/bench_abandoned_creates.py --base http://127.0.0.1:45494 --image <local image> --label on

Everything it creates is named <prefix>-* and removed. Stdlib only.
"""

import argparse
import json
import socket
import time
import urllib.error
import urllib.request
from urllib.parse import urlparse


def post(base, method, body, timeout=60):
    request = urllib.request.Request(
        f"{base}/api/micropod.v1.ContainerService/{method}", data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return "ok", json.loads(response.read() or b"{}")
    except urllib.error.HTTPError as error:
        try:
            return json.loads(error.read() or b"{}").get("code", f"http_{error.code}"), {}
        except ValueError:
            return f"http_{error.code}", {}


def abandoned_create(base, image, name, deadline_ms):
    """CreateContainer with Connect-Timeout-Ms, hanging up at the deadline.
    Returns (what the client saw, seconds until it saw it)."""
    url = urlparse(base)
    body = json.dumps({"image": image, "name": name, "detach": True, "arguments": ["true"],
                       "labels": {"dev.micropod.bench": "abandoned"}}).encode()
    head = (f"POST /api/micropod.v1.ContainerService/CreateContainer HTTP/1.1\r\n"
            f"Host: {url.hostname}:{url.port}\r\nContent-Type: application/json\r\n"
            f"Connect-Timeout-Ms: {deadline_ms}\r\nContent-Length: {len(body)}\r\n\r\n").encode()
    started = time.monotonic()
    sock = socket.create_connection((url.hostname, url.port))
    sock.settimeout(deadline_ms / 1000)
    try:
        sock.sendall(head + body)
        data = sock.recv(65536)
        status = data.split(b" ", 2)[1].decode() if data else "eof"
        return status, time.monotonic() - started
    except socket.timeout:
        return "client_gave_up", time.monotonic() - started
    finally:
        sock.close()  # the hangup


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base", required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--deadline-ms", type=int, default=50)
    parser.add_argument("--settle", type=float, default=5, help="seconds to wait before looking for the container")
    parser.add_argument("--prefix", default="abandoned")
    parser.add_argument("--label", default="")
    args = parser.parse_args()
    base = args.base.rstrip("/")
    if base.endswith(":45454"):
        raise SystemExit("refusing the shared :45454 API; start a scratch MicropodAPI")
    ghosts = 0
    for round_ in range(args.rounds):
        name = f"{args.prefix}-{args.label}-{int(time.time() * 1000)}-{round_}"
        seen, took = abandoned_create(base, args.image, name, args.deadline_ms)
        time.sleep(args.settle)
        code, _ = post(base, "GetContainer", {"id": name})
        landed = code == "ok"
        ghosts += landed
        if landed:
            post(base, "DeleteContainer", {"id": name, "force": True})
        print(json.dumps({"label": args.label, "round": round_, "deadline_ms": args.deadline_ms,
                          "client_saw": seen, "client_s": round(took, 3), "landed_after_abandon": landed}),
              flush=True)
    print(f"[{args.label}] abandoned creates that reached the runtime: {ghosts}/{args.rounds}")


if __name__ == "__main__":
    main()
