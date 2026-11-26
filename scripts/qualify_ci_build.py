#!/usr/bin/env python3
"""Qualify Buildx, publication, 32 concurrent compiles and tag removal on a native worker."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4


IMAGE = "alpine:3.23"
LABEL = "io.micropod.ci-proof"
JOBS = 32
ID = re.compile(r"[a-f0-9]{64}")
IMAGE_ID = re.compile(r"sha256:[a-f0-9]{64}")

C_SOURCE = r"""#include <stdio.h>
#ifndef SLOT
#define SLOT 0
#endif
int main(void) { printf("%d\n", 3*SLOT+7); return 0; }
"""

COMPILE_JOB = r"""
touch "/out/ready-$1"
i=0
while [ ! -f /out/release ]; do
    i=$((i+1))
    test "$i" -lt 1000
    sleep 0.1
done
cc -O2 -DSLOT="$1" /src/main.c -o /tmp/check
value=$(/tmp/check)
test "$value" = "$((3*$1+7))"
printf "%s %s\n" "$1" "$value" >"/out/result-$1"
"""

RELEASE_BARRIER = r"""
for i in $(seq 1 80); do
    set -- /out/ready-*
    [ "$#" = 32 ] && break
    sleep .1
done
test "$#" = 32
touch /out/release
echo "$#"
"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def docker_environment(work):
    # Keep plugin discovery while isolating builder metadata, credentials and contexts.
    source = Path(os.environ.get("DOCKER_CONFIG") or Path.home() / ".docker").expanduser().resolve()
    config_file = source / "config.json"
    config = json.loads(config_file.read_text(encoding="utf-8")) if config_file.is_file() else {}
    plugin_dirs = config.get("cliPluginsExtraDirs") or []
    docker_config = work / "docker"
    docker_config.mkdir()
    (docker_config / "config.json").write_text(
        json.dumps({"cliPluginsExtraDirs": [*plugin_dirs, str(source / "cli-plugins")]}),
        encoding="utf-8",
    )
    env = {key: value for key, value in os.environ.items() if not key.startswith(("DOCKER_", "BUILDX_"))}
    env.update(DOCKER_CONFIG=str(docker_config), BUILDX_CONFIG=str(work / "buildx"), MICROPOD_CI_ENGINE="containerd")
    return env


class Qualification:
    def __init__(self, work):
        self.key = "mpci" + uuid4().hex
        self.label = f"{LABEL}={self.key}"
        self.tag = f"micropod-qa/buildkit:{self.key}"
        self.alias = self.tag + "-alias"
        self.volume = self.key + "-out"
        self.cli = os.environ.get("MICROPOD_CLI") or "micropod"
        self.env = docker_environment(work)

        status = json.loads(self.ci("runner-status").stdout)
        require(status.get("engine") == "containerd", "A native Micropod worker must be running")
        self.endpoint = self.ci("runner-docker-endpoint").stdout.strip()
        require(self.endpoint.startswith("unix:///") and Path(self.endpoint[7:]).is_socket(),
                "The managed Docker endpoint must be a local Unix socket")

        self.context = work / "context"
        self.context.mkdir()
        (self.context / "main.c").write_text(C_SOURCE, encoding="utf-8")
        (self.context / "Dockerfile").write_text(f"""FROM {IMAGE} AS compiler
RUN apk add --no-cache gcc musl-dev
FROM compiler AS worker
EXPOSE 9090/tcp
COPY main.c /src/main.c
RUN cc -O2 -o /usr/local/bin/smoke /src/main.c && test "$(smoke)" = 7
LABEL {self.label}
""", encoding="utf-8")

    def run(self, *args, check=True, timeout=15):
        args = [str(arg) for arg in args]
        result = subprocess.run(args, env=self.env, capture_output=True, text=True,
                                errors="replace", stdin=subprocess.DEVNULL, timeout=timeout)
        if check and result.returncode:
            output = (result.stdout + "\n" + result.stderr).strip()
            raise RuntimeError(f"{shlex.join(args)} exited {result.returncode}\n{output[-1600:]}")
        return result

    def ci(self, *args, **options):
        return self.run(self.cli, "ci", *args, **options)

    def docker(self, *args, **options):
        return self.run("docker", "--host", self.endpoint, *args, **options)

    def owned_image(self, ref):
        result = self.docker("image", "inspect", ref, check=False)
        if result.returncode:
            require("no such image" in result.stderr.lower(), f"Could not inspect {ref}\n{result.stderr.strip()}")
            return None
        image, = json.loads(result.stdout)
        labels = (image.get("Config") or {}).get("Labels") or {}
        require(labels.get(LABEL) == self.key and IMAGE_ID.fullmatch(image.get("Id", "")),
                f"Image {ref} does not belong to this run")
        return image["Id"]

    def container_ids(self):
        return self.docker("ps", "-aq", "--no-trunc", "--filter", f"label={self.label}").stdout.splitlines()

    def remove_containers(self, ids):
        if not ids:
            return
        require(all(ID.fullmatch(id_) for id_ in ids), "Invalid container ID from Docker")
        rows = json.loads(self.docker("container", "inspect", *ids, timeout=30).stdout)
        owned = {row.get("Id") for row in rows if (row["Config"].get("Labels") or {}).get(LABEL) == self.key}
        require(owned == set(ids), "Refusing to remove a container whose ID or label differs")
        self.docker("rm", "-f", *ids, timeout=60)

    def owns_volume(self):
        listed = self.docker("volume", "ls", "-q", "--filter", f"label={self.label}").stdout.splitlines()
        if not listed:
            return False
        require(listed == [self.volume], "Unexpected volume carrying this run's label")
        volume, = json.loads(self.docker("volume", "inspect", self.volume).stdout)
        require(volume.get("Name") == self.volume and (volume.get("Labels") or {}).get(LABEL) == self.key,
                "Refusing to use a volume whose name or label differs")
        return True

    def builds(self):
        self.docker("image", "inspect", IMAGE)
        attempts = []
        for name in ("initial", "repeat"):
            require(self.ci("runner-docker-endpoint").stdout.strip() == self.endpoint,
                    "The managed Docker endpoint changed during the check")
            started = time.monotonic()
            result = self.ci("docker", "buildx", "build", "--load", "--progress", "plain", "--provenance=false",
                             "--tag", self.tag, "--tag", self.alias, self.context, timeout=120)
            elapsed = round(time.monotonic() - started, 2)
            log = result.stderr + "\n" + result.stdout
            image = self.owned_image(self.tag)
            require(image is not None and self.owned_image(self.alias) == image, "Buildx did not load both image tags")
            attempts.append({"attempt": name, "seconds": elapsed, "cached_steps": sum(
                "CACHED" in line for line in log.splitlines()), "image_id": image})
        require(attempts[0]["image_id"] == attempts[1]["image_id"] and attempts[1]["cached_steps"] > 0,
                f"Repeat build did not reuse work with the same immutable image ID. {attempts}")
        return attempts

    def exposed_port(self):
        container = self.docker("run", "-d", "--pull", "never", "-P", "--name", self.key + "-port",
                                "--label", self.label, self.tag, "sleep", "120").stdout.strip()
        require(ID.fullmatch(container), "Invalid ID for the EXPOSE probe")
        try:
            address = self.docker("port", container, "9090/tcp").stdout.strip()
            listed = self.docker("ps", "--no-trunc", "--filter", "id=" + container, "--format", "{{.Ports}}").stdout.strip()
            match = re.fullmatch(r"127\.0\.0\.1:([1-9][0-9]{0,4})", address)
            require(match and int(match[1]) <= 65535 and listed == address + "->9090/tcp",
                    f"Dockerfile EXPOSE and -P disagreed. docker port={address!r}, docker ps={listed!r}")
            return address
        finally:
            self.remove_containers([container])

    def start_job(self, slot):
        result = self.docker("run", "-d", "--pull", "never", "--name", f"{self.key}-{slot}", "--label", self.label,
                             "--network", "none", "--mount", f"type=volume,src={self.volume},dst=/out",
                             "--cpus", "1", "--memory", "128m", self.tag, "sh", "-ec", COMPILE_JOB, "ci", slot,
                             timeout=40)
        id_ = result.stdout.strip()
        require(ID.fullmatch(id_), f"Invalid container ID for compile slot {slot}")
        return id_

    def compiles(self):
        self.docker("volume", "create", "--label", self.label, self.volume)
        require(self.owns_volume(), "The compile volume was not created with this run's label")
        with ThreadPoolExecutor(max_workers=8) as pool:
            ids = list(pool.map(self.start_job, range(JOBS)))
            running = self.docker("ps", "-q", "--no-trunc", "--filter", f"label={self.label}",
                                  "--filter", "status=running").stdout.splitlines()
            require(len(running) == JOBS and set(running) == set(ids), "All 32 compile containers must run concurrently")
            ready = self.docker("exec", ids[0], "sh", "-ec", RELEASE_BARRIER).stdout.strip()
            waits = list(pool.map(lambda id_: self.docker("wait", id_, timeout=60).stdout.strip(), ids))

        results = self.docker("run", "--rm", "--pull", "never", "--network", "none", "--label", self.label,
                              "--name", self.key + "-read", "--mount", f"type=volume,src={self.volume},dst=/out,readonly",
                              IMAGE, "sh", "-ec", "cat /out/result-*").stdout.splitlines()
        outputs = sorted(tuple(map(int, row.split())) for row in results)
        require(ready == str(JOBS) and waits == ["0"] * JOBS and outputs == [(slot, 3 * slot + 7) for slot in range(JOBS)],
                f"Compile barrier, status, or result mismatch. ready={ready!r}, waits={waits}, outputs={outputs}")
        return {"running": len(running), "ready": int(ready), "exit_zero": waits.count("0"), "verified_outputs": len(outputs)}

    def tag_removal(self, image):
        self.remove_containers(self.container_ids())
        require(self.owned_image(self.tag) == image, "The primary tag changed before removal")
        self.docker("image", "rm", self.tag)
        require(self.owned_image(self.tag) is None and self.owned_image(self.alias) == image,
                "Primary tag removal did not preserve the alias at the same image ID")

        retained = self.docker("create", "--pull", "never", "--label", self.label, "--name", self.key + "-retain",
                               self.alias, "sleep", "20").stdout.strip()
        require(ID.fullmatch(retained), "Invalid ID for the retained container")
        try:
            conflict = self.docker("image", "rm", self.alias, check=False)
            require(conflict.returncode and "retained container" in conflict.stderr and self.owned_image(self.alias) == image,
                    f"Expected the retained container to protect its last tag. {conflict.stderr.strip()}")
        finally:
            self.remove_containers([retained])

        require(self.owned_image(self.alias) == image, "The alias changed before removal")
        self.docker("image", "rm", self.alias)
        require(self.owned_image(self.alias) is None, "Last tag still resolves after removing its container")
        return {"primary_removed": True, "alias_preserved": True, "in_use_conflict": True, "final_alias_removed": True}

    def cleanup(self):
        self.remove_containers(self.container_ids())
        if self.owns_volume():
            self.docker("volume", "rm", self.volume)
        for ref in (self.tag, self.alias):
            if self.owned_image(ref) is not None:
                self.docker("image", "rm", ref)
        require(not self.container_ids() and not self.owns_volume(), "Owned containers or volume remain after cleanup")
        require(all(self.owned_image(ref) is None for ref in (self.tag, self.alias)), "Owned tags remain after cleanup")
        return {"containers": 0, "volumes": 0, "tags": 0}

    def qualify(self):
        try:
            builds = self.builds()
            address = self.exposed_port()
            compiles = self.compiles()
            removal = self.tag_removal(builds[-1]["image_id"])
        except BaseException:
            try:
                self.cleanup()
            except Exception as error:
                print(f"Cleanup for {self.key} failed. {error}", file=sys.stderr)
            raise
        return {"check": "buildx-ci", "passed": True, "run": self.key, "builds": builds, "expose_9090": address,
                "parallel_compiles": compiles, "tag_removal": removal, "cleanup": self.cleanup()}


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Uses the current native Micropod worker and emits one JSON receipt on success. "
        "Preload Alpine 3.23 and install Docker Buildx. The first build may need to fetch packages."
    ))
    parser.parse_args()

    def terminate(_signum, _frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, terminate)
    try:
        with TemporaryDirectory(prefix="mp-ci-build-") as work:
            receipt = Qualification(Path(work)).qualify()
        print(json.dumps(receipt, separators=(",", ":")))
    except KeyboardInterrupt:
        return 130
    except Exception as error:
        print(f"Buildx CI check failed. {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
