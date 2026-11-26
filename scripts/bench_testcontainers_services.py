#!/usr/bin/env python3
"""Measure eight sibling stock Testcontainers clients sharing a real Ryuk session."""

import argparse
import asyncio
from contextlib import ExitStack
import http.client
import json
from pathlib import Path
from tempfile import TemporaryDirectory
import time
from urllib.parse import urlparse
from uuid import uuid4

from qualify_testcontainers_go import CONTAINER_ID, OWNER, RYUK, SESSION, SESSION_ID
from qualify_testcontainers_go import Engine, Probe, checked_image, require, sha_file


async def wait_ready(proc, probe, row):
    while line := await proc.stdout.readline():
        event = json.loads(line)
        kind = event["event"]
        row["events"].append(event)
        if kind == "session":
            require(SESSION_ID.fullmatch(event["id"]), "Invalid SDK session")
            probe.session = event["id"]
        elif kind == "published-http":
            row["endpoint"] = event["endpoint"]
        elif kind == "abandon-ready":
            require(probe.session and CONTAINER_ID.fullmatch(event["id"]) and row.get("endpoint"),
                    "Stock client did not publish and verify its service")
            row.update(id=event["id"], session=probe.session, ready_ns=time.monotonic_ns())
            return
        elif kind == "result":
            raise RuntimeError(str(event))
    raise RuntimeError("Stock client exited before its service became ready")


def check_services(probes, jobs, images):
    require(len({row["id"] for row in jobs}) == len(jobs), "Services shared a container")
    require(len({p.session for p in probes}) == 1, "Sibling clients did not share an SDK session")
    require(len({r["endpoint"] for r in jobs}) == len(jobs), "Published ports were reused")
    reapers = probes[0].reapers()
    require(len(reapers) == 1 and reapers[0]["State"] == "running", "Expected one running shared Ryuk")
    reaper_id = reapers[0]["Id"]
    code, reaper = probes[0].request("GET", f"/containers/{reaper_id}/json")
    require(code == 200 and reaper["Image"] == images[RYUK]["Id"], "Running Ryuk image differs")
    for p, row in zip(probes, jobs):
        code, state = p.request("GET", f"/containers/{row['id']}/json")
        require(code == 200 and state["State"]["Running"] and state["Config"]["Labels"][OWNER] == p.scope
                and state["Config"]["Labels"][SESSION] == p.session, "Running service ownership differs")
        endpoint = urlparse(row["endpoint"])
        require(endpoint.scheme == "http" and endpoint.hostname in ("localhost", "127.0.0.1")
                and endpoint.port, "Expected a published loopback service")
        client = http.client.HTTPConnection("127.0.0.1", endpoint.port, timeout=4)
        try:
            client.request("GET", "/ready")
            response = client.getresponse()
            require(response.status == 200 and response.read(1024) == (p.scope + "\n").encode(),
                    "Concurrent published service returned different content")
        finally:
            client.close()
    return reaper_id


async def wave(args, report, folder):
    engine = Engine(args.socket, args.image, None, None, api_version="1.47")
    scopes = ["mp-tc-" + uuid4().hex[:24] for _ in range(8)]
    jobs = report["jobs"] = [{"name": scope, "events": []} for scope in scopes]
    probes = [Probe(engine, scope, {"manual_cleanup": []}) for scope in scopes]
    images = report["images_before"] = {name: checked_image(engine, name) for name in (args.image, RYUK)}
    require(images[RYUK]["Id"] == args.ryuk_id, "The preloaded Ryuk image differs from the admitted image")
    for p in probes:
        require(not any(p.scope_rows().values()) and p.request("GET", f"/containers/{p.scope}/json")[0] == 404,
                "A generated fixture name or label already exists")
    (folder / "config.json").write_text('{"auths":{"fixture.invalid":{}}}')
    env = {k: v for k, v in engine.env.items()
           if not k.startswith(("TESTCONTAINERS_", "RYUK_")) and k not in ("DOCKER_TLS", "DOCKER_CUSTOM_HEADERS")}
    env.update(DOCKER_HOST="unix://" + str(args.socket), DOCKER_CONFIG=str(folder),
               TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE="/var/run/docker.sock",
               TESTCONTAINERS_RYUK_DISABLED="false", TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED="false")
    processes, readers = [], []
    with ExitStack() as files:
        errors = [files.enter_context((folder / f"client-{i}.log").open("w+b")) for i in range(len(jobs))]
        start = time.monotonic_ns()
        try:
            for row, probe, stderr in zip(jobs, probes, errors):
                row["launch_ns"] = time.monotonic_ns()
                proc = await asyncio.create_subprocess_exec(str(args.client), "-image", args.image, "-name", probe.scope,
                           "-mode", "ryuk-abandon", env=env, stdin=asyncio.subprocess.PIPE,
                           stdout=asyncio.subprocess.PIPE, stderr=stderr)
                processes.append(proc)
                readers.append(asyncio.create_task(wait_ready(proc, probe, row)))
            await asyncio.wait_for(asyncio.gather(*readers), 38)
            report["start_to_last_ready_ms"] = (max(r["ready_ns"] for r in jobs) - start) / 1e6
            report["reaper_id"] = check_services(probes, jobs, images)
            for proc in processes:
                proc.stdin.write(b"exit fixture\n")
                await proc.stdin.drain()
                proc.stdin.close()
            outputs = await asyncio.wait_for(asyncio.gather(*(p.communicate() for p in processes)), 12)
            for proc, row, (stdout, _) in zip(processes, jobs, outputs):
                tail = [json.loads(line) for line in stdout.splitlines()]
                require(proc.returncode == 0 and any(e.get("event") == "result" and e.get("passed") for e in tail),
                        "Testcontainers child did not exit successfully")
                row["events"].extend(tail)
            released = time.monotonic_ns()
            ids = [r["id"] for r in jobs] + [report["reaper_id"]]
            while True:
                states = [probes[0].request("GET", f"/containers/{i}/json")[0] for i in ids]
                require(all(code in (200, 404) for code in states), "Unexpected cleanup response")
                if all(code == 404 for code in states):
                    break
                require(time.monotonic_ns() - released < 28_000_000_000, "Ryuk left a service or itself behind")
                await asyncio.sleep(0.1)
            report["to_verified_cleanup_ms"] = (time.monotonic_ns() - start) / 1e6
            report["automatic_removal_status"] = states
        finally:
            for task in readers:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*readers, return_exceptions=True)
            for proc in processes:
                if proc.returncode is None:
                    proc.kill()
            await asyncio.gather(*(p.wait() for p in processes))
            for row, stream in zip(jobs, errors):
                stream.seek(0)
                row["stderr"] = stream.read(64000).decode(errors="replace")
            for p in probes:
                p.recover_scope()
            report["manual_cleanup"] = [record for p in probes for record in p.report["manual_cleanup"]]
            report["remaining"] = [p.scope_rows() for p in probes]
            report["remaining_reapers"] = [p.reapers() for p in probes if p.session]
            report["images_after"] = {name: checked_image(engine, name) for name in images}
            require(not any(any(v.values()) for v in report["remaining"]) and not any(report["remaining_reapers"])
                    and report["images_after"] == images, "Owned cleanup or image preservation failed")
    require(not report["manual_cleanup"], "Wave required manual removal")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("socket", "client", "out"):
        parser.add_argument("--" + option, type=Path, required=True)
    parser.add_argument("--image", required=True)
    parser.add_argument("--ryuk-id", required=True)
    args = parser.parse_args()
    require(args.socket.is_socket() and args.client.is_file() and not args.out.exists(),
            "Expected an explicit socket, compiled stock client and fresh output")
    report = {"passed": False, "image": args.image, "driver_sha256": sha_file(Path(__file__)),
              "client_sha256": sha_file(args.client), "socket": str(args.socket)}
    try:
        with TemporaryDirectory(dir=args.out.parent) as temporary:
            asyncio.run(wave(args, report, Path(temporary)))
        report["passed"] = True
    except Exception as exc:
        report["error"] = repr(exc)
    finally:
        with args.out.open("x") as out:
            json.dump(report, out, indent=2)
            out.write("\n")
    return int(not report["passed"])


if __name__ == "__main__":
    raise SystemExit(main())
