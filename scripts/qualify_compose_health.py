#!/usr/bin/env python3
"""Exercise a stock Compose service_healthy dependency using a preloaded image."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
import gzip
import hashlib
import json
from pathlib import Path
import signal
import sys
import tarfile
from tempfile import TemporaryDirectory
import time

from qualify_docker_restart import LABEL, Qualification, interrupted, require
from qualify_docker_image_history import familiar, tar_bytes


IMAGE_SHELL = ["/bin/sh", "-ec", 'export MP_HEALTH_SHELL=from-image; exec /bin/sh -c "$1"', "health"]


def await_health(fixture, cid, description, predicate):
    deadline = time.monotonic() + 12
    while True:
        state = fixture.inspect(cid)["State"]
        health = state.get("Health") or {}
        require(state["Running"], f"Dependency exited while waiting for {description}. State {state!r}")
        if predicate(health):
            return health
        require(time.monotonic() < deadline, f"Timeout waiting for {description}. Last state {health!r}")
        time.sleep(0.1)


def timestamp(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def qualify(fixture, result):
    since = str(int(time.time()) - 1)
    common = {
        "image": fixture.image, "pull_policy": "never", "network_mode": "none",
        "labels": {LABEL: fixture.key}, "entrypoint": ["/bin/sh", "-c"], "command": ["exec sleep 120"],
    }
    services = {
        "dependency": {**common, "healthcheck": {
            "test": ["CMD", "test", "-f", "/tmp/ready"], "interval": "300ms", "timeout": "2s",
            "retries": 2, "start_period": "15s", "start_interval": "300ms",
        }},
        "job": {**common, "depends_on": {"dependency": {"condition": "service_healthy"}}},
    }
    fixture.compose_file.write_text(json.dumps({"services": services}))
    result["image_id"] = json.loads(fixture.docker("image", "inspect", fixture.image).stdout)[0]["Id"]
    result["compose_version"] = fixture.docker("compose", "version", "--short").stdout.strip()
    fixture.compose_touched = True
    fixture.compose("create", "--pull", "never")
    ids = {name: fixture.inspect(fixture.compose("ps", "-aq", name).stdout.strip())["Id"] for name in services}
    result["containers"] = ids
    with ThreadPoolExecutor(max_workers=1) as executor:
        up = executor.submit(fixture.compose, "up", "--detach", "--wait", "--wait-timeout", "18",
                             "--pull", "never", check=False, timeout=23)
        deadline = time.monotonic() + 8
        while not fixture.inspect(ids["dependency"])["State"]["Running"]:
            require(not up.done(), "Compose returned before the dependency started")
            require(time.monotonic() < deadline, "Dependency never started")
            time.sleep(0.1)
        first = await_health(fixture, ids["dependency"], "a failed readiness probe",
                             lambda h: any(p["ExitCode"] == 1 for p in h.get("Log", [])))
        result["before_ready"] = {"dependency": first, "job": fixture.inspect(ids["job"])["State"]["Status"]}
        require(result["before_ready"]["job"] == "created", "Dependent job started before the readiness probe passed")
        fixture.docker("exec", ids["dependency"], "touch", "/tmp/ready")
        ready = await_health(fixture, ids["dependency"], "healthy", lambda h: h.get("Status") == "healthy")
        completed = up.result()
        require(completed.returncode == 0, completed.stderr[-1600:] or "Compose wait failed")

    job = fixture.inspect(ids["job"])["State"]
    first_success = next(probe for probe in ready["Log"] if probe["ExitCode"] == 0)
    require(ready["Status"] == "healthy" and job["Running"], "Compose returned before both services were ready")
    require(timestamp(job["StartedAt"]) >= timestamp(first_success["End"]),
            "Job start preceded the dependency's successful probe")
    result["after_ready"] = {"dependency": ready, "job_started": job["StartedAt"]}
    fixture.docker("exec", ids["dependency"], "rm", "/tmp/ready")
    result["unhealthy"] = await_health(fixture, ids["dependency"], "unhealthy", lambda h: h.get("Status") == "unhealthy")
    require(result["unhealthy"]["FailingStreak"] >= 2, "Health changed before two consecutive failures")
    fixture.docker("exec", ids["dependency"], "touch", "/tmp/ready")
    result["recovered"] = await_health(fixture, ids["dependency"], "recovery", lambda h: h.get("Status") == "healthy")
    require(result["recovered"]["FailingStreak"] == 0, "Successful probe did not reset failure streak")
    events = fixture.docker("events", "--since", since, "--until", str(int(time.time()) + 1),
                            "--filter", "container=" + ids["dependency"], "--filter", "event=health_status",
                            "--format", "{{json .}}")
    actions = [json.loads(line) for line in events.stdout.splitlines()]
    require(all(event["Actor"]["ID"] == ids["dependency"] for event in actions), "Unexpected health event owner")
    result["health_events"] = [event["Action"] for event in actions]
    require(result["health_events"] == ["health_status: healthy", "health_status: unhealthy", "health_status: healthy"],
            f"Unexpected transition events {result['health_events']}")


def create_health_archive(base, destination, tag, owner):
    with tarfile.open(base) as source:
        row, = (row for row in json.load(source.extractfile("manifest.json"))
                if "alpine:3.23" in {familiar(t) for t in row.get("RepoTags") or []})
        image = json.load(source.extractfile(row["Config"]))
        layers = [source.extractfile(name).read() for name in row["Layers"]]
    require(image["architecture"] == "arm64" and image["os"] == "linux", "Unexpected base platform")
    diffids = ["sha256:" + hashlib.sha256(gzip.decompress(layer) if layer.startswith(b"\x1f\x8b") else layer).hexdigest()
               for layer in layers]
    require(image["rootfs"]["diff_ids"] == diffids, "Base layer bytes differ from image config")
    config = image["config"]
    config["Labels"] = {**(config.get("Labels") or {}), LABEL: owner}
    config["Env"] = [*(config.get("Env") or []), "MP_HEALTH_ENV=qualified"]
    config["Shell"] = IMAGE_SHELL
    config["Healthcheck"] = {
        "Test": ["CMD-SHELL", 'echo "${MP_HEALTH_SHELL:-default}:$MP_HEALTH_ENV"; test "$MP_HEALTH_ENV" = qualified && test -e /tmp/ready'],
        "Interval": 300_000_000, "Timeout": 2_000_000_000, "StartPeriod": 15_000_000_000,
        "StartInterval": 300_000_000, "Retries": 2,
    }
    encoded = json.dumps(image, sort_keys=True, separators=(",", ":")).encode()
    config_name = hashlib.sha256(encoded).hexdigest() + ".json"
    layer_names = [f"layer-{i}.tar" for i in range(len(layers))]
    manifest = [{"Config": config_name, "RepoTags": [tag], "Layers": layer_names}]
    destination.write_bytes(tar_bytes([(config_name, encoded), ("manifest.json", json.dumps(manifest).encode()),
                                       *zip(layer_names, layers)]))


def run_health_container(fixture, image, *options):
    cid = fixture.docker("run", "--detach", "--pull", "never", "--network", "none",
                         "--label", LABEL + "=" + fixture.key, "--entrypoint", "/bin/sh",
                         *options, image, "-c", "exec sleep 120")
    return fixture.inspect(cid.stdout.strip())["Id"]


def qualify_stopped(fixture, result):
    cid = run_health_container(fixture, fixture.image, "--health-cmd", "true", "--health-interval", "300ms")
    initial = await_health(fixture, cid, "healthy before stop", lambda h: h.get("Status") == "healthy")
    fixture.docker("stop", "--time", "1", cid)
    row = fixture.inspect(cid)["State"]
    stopped = row["Health"]
    require(row["Status"] == "exited" and stopped["Status"] == "unhealthy" and stopped["FailingStreak"] == 0,
            "Stopping a healthy container changed the probe failure count")
    require(any(p["Start"] == initial["Log"][-1]["Start"] for p in stopped["Log"]), "Stop discarded the probe history")
    fixture.docker("start", cid)
    started = timestamp(fixture.inspect(cid)["State"]["StartedAt"])
    resumed = await_health(fixture, cid, "first new healthy result",
                           lambda h: h.get("Status") == "healthy" and any(timestamp(p["Start"]) >= started for p in h["Log"]))
    fast = fixture.docker("run", "--detach", "--pull", "never", "--network", "none", "--label", LABEL + "=" + fixture.key,
                          "--entrypoint", "/bin/sh", "--health-cmd", "true", "--health-interval", "30s",
                          fixture.image, "-c", "exit 0").stdout.strip()
    require(fixture.docker("wait", fast).stdout.strip() == "0", "Quick-exit container failed")
    quick = fixture.inspect(fast)["State"]["Health"]
    require(quick["Status"] == "unhealthy" and quick["FailingStreak"] == 0 and not quick["Log"],
            "Container exit before its first probe fabricated a failure")
    result["stop"] = {"healthy_container_stopped": stopped, "restarted": resumed, "quick_exit": quick}


def qualify_parallel(fixture, result):
    def sibling(_):
        return run_health_container(fixture, fixture.image, "--health-cmd", "test -e /tmp/ready",
                                    "--health-retries", "1", "--health-interval", "500ms")

    def ready(cid):
        fixture.docker("exec", cid, "touch", "/tmp/ready")
        return await_health(fixture, cid, "parallel healthy state", lambda h: h.get("Status") == "healthy")["Status"]

    def failed(cid):
        return await_health(fixture, cid, "parallel unhealthy state", lambda h: h.get("Status") == "unhealthy")["Status"]

    with ThreadPoolExecutor(max_workers=8) as executor:
        ids = list(executor.map(sibling, range(8)))
        require(len(set(ids)) == 8, "Concurrent health containers collided")
        require(list(executor.map(failed, ids)) == ["unhealthy"] * 8, "Missing initial failures")
        list(executor.map(ready, ids[:4]))
        healthy = [cid for cid in ids if fixture.inspect(cid)["State"]["Health"]["Status"] == "healthy"]
        require(healthy == ids[:4], "A sibling changed health when another container became ready")
        list(executor.map(ready, ids[4:]))
    require(all(fixture.inspect(cid)["State"]["Health"]["Status"] == "healthy" for cid in ids),
            "Parallel health statuses did not converge")
    result["eight_containers"] = {"ids": ids, "initial_unhealthy": 8, "first_healthy": healthy, "final_healthy": 8}


def qualify_inherited(fixture, result, base, directory, tag):
    archive = directory / "health.tar"
    create_health_archive(base, archive, tag, fixture.key)
    fixture.docker("image", "load", "--input", str(archive))
    image, = json.loads(fixture.docker("image", "inspect", tag).stdout)
    require(image["Config"]["Labels"][LABEL] == fixture.key, "Loaded health image ownership mismatch")
    result["owned_image_id"] = image["Id"]
    cid = run_health_container(fixture, tag)
    row = fixture.inspect(cid)
    result["inherited_test"] = row["Config"]["Healthcheck"]["Test"]
    first = await_health(fixture, cid, "image-defined probe",
                         lambda h: any(p["ExitCode"] == 1 for p in h.get("Log", [])))
    result["shell"] = {"image": image["Config"].get("Shell"), "container": row["Config"].get("Shell"),
                       "image_healthcheck": image["Config"].get("Healthcheck"), "probe_output": first["Log"][-1]["Output"]}
    require(result["shell"]["image"] == IMAGE_SHELL and result["shell"]["image_healthcheck"] == row["Config"]["Healthcheck"],
            "Image inspection lost the declared probe configuration")
    # Moby merges the image healthcheck and environment at container create.
    # Its CMD-SHELL runtime probe uses the container's own shell setting.
    require(not result["shell"]["container"] and result["shell"]["probe_output"].strip() == "default:qualified",
            f"Unexpected inherited probe execution {result['shell']}")
    fixture.docker("exec", cid, "touch", "/tmp/ready")
    result["inherited_healthy"] = await_health(fixture, cid, "inherited recovery", lambda h: h.get("Status") == "healthy")
    fixture.docker("restart", cid)
    new_start = timestamp(fixture.inspect(cid)["State"]["StartedAt"])
    result["restarted"] = await_health(fixture, cid, "healthy after restart",
                                       lambda h: h.get("Status") == "healthy" and any(
                                           p["ExitCode"] == 0 and timestamp(p["Start"]) >= new_start for p in h["Log"]))

    disabled = fixture.inspect(run_health_container(fixture, tag, "--no-healthcheck"))
    require(disabled["Config"]["Healthcheck"]["Test"] == ["NONE"] and not disabled["State"].get("Health"),
            "Explicit disable still scheduled a health check")
    result["disabled"] = True
    timed = run_health_container(fixture, fixture.image, "--health-cmd", "echo $$ >/tmp/health-pid; exec sleep 20",
                                 "--health-timeout", "350ms", "--health-interval", "2s", "--health-retries", "1")
    health = await_health(fixture, timed, "a timed-out probe", lambda h: h.get("Status") == "unhealthy")
    require(health["Log"][-1]["ExitCode"] == -1, "Timed-out probe must have exit code -1")
    fixture.exec(timed, 'pid=$(cat /tmp/health-pid); test "$pid" -gt 1 && test ! -d "/proc/$pid"')
    result["timeout"] = health

    noisy = run_health_container(fixture, fixture.image, "--health-cmd", r"head -c 8192 /dev/zero | tr '\000' x",
                                 "--health-interval", "300ms")
    full = await_health(fixture, noisy, "five recorded probes", lambda h: len(h.get("Log", [])) == 5)
    oldest = full["Log"][0]["Start"]
    rolled = await_health(fixture, noisy, "oldest probe eviction",
                          lambda h: len(h.get("Log", [])) == 5 and h["Log"][0]["Start"] != oldest)
    expected = "x" * 4096 + "..."
    require(all(p["ExitCode"] == 0 and p["Output"] == expected for p in rolled["Log"]),
            "Probe output did not preserve the stock truncation boundary")
    result["bounded_log"] = {"entries": len(rolled["Log"]), "output_bytes": len(expected), "oldest_evicted": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--host")
    target.add_argument("--context")
    parser.add_argument("--image", required=True, help="Already loaded image with sh, sleep, test, touch and rm")
    parser.add_argument("--base-archive", type=Path, help="Docker archive containing alpine:3.23 for inheritance and timeout checks")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="micropod-health-") as directory:
        fixture = Qualification(Path(directory), args, prefix="mp-health-")
        tag = "micropod-qa/" + fixture.key + ":inherited"
        result = {"schema": 1, "project": fixture.key, "image": fixture.image, "passed": False}
        try:
            qualify(fixture, result)
            if args.base_archive:
                qualify_inherited(fixture, result, args.base_archive, Path(directory), tag)
                qualify_stopped(fixture, result)
                qualify_parallel(fixture, result)
            result["passed"] = True
        except Exception as exc:
            result["error"] = str(exc)
        finally:
            try:
                result["cleanup"] = fixture.cleanup()
                candidates = fixture.docker("network", "ls", "-q", "--filter",
                                            "label=com.docker.compose.project=" + fixture.key).stdout.splitlines()
                networks = json.loads(fixture.docker("network", "inspect", *candidates).stdout) if candidates else []
                remaining = [row["Id"] for row in networks
                             if (row.get("Labels") or {}).get("com.docker.compose.project") == fixture.key]
                result["cleanup"]["remaining_network_ids"] = remaining
                require(not remaining, "Compose project networks remain")
            except Exception as exc:
                result["cleanup_error"] = str(exc)
                result["passed"] = False
            if args.base_archive:
                try:
                    owned = fixture.docker("image", "inspect", tag, check=False)
                    if owned.returncode == 0:
                        row, = json.loads(owned.stdout)
                        require(row["Config"]["Labels"][LABEL] == fixture.key, "Refusing unrelated image removal")
                        fixture.docker("image", "rm", tag)
                        by_id = fixture.docker("image", "inspect", row["Id"], check=False)
                        if by_id.returncode == 0:
                            retained, = json.loads(by_id.stdout)
                            require(retained["Config"]["Labels"][LABEL] == fixture.key and not retained.get("RepoTags"),
                                    "Unexpected image reference after untagging")
                            fixture.docker("image", "rm", row["Id"])
                        require(fixture.docker("image", "inspect", row["Id"], check=False).returncode != 0,
                                "Owned health image ID remains")
                    require(fixture.docker("image", "inspect", tag, check=False).returncode != 0, "Health tag remains")
                    result.setdefault("cleanup", {})["image_absent"] = True
                except Exception as exc:
                    result["image_cleanup_error"] = str(exc)
                    result["passed"] = False
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    sys.exit(main())
