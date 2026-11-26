#!/usr/bin/env python3
"""Exercise Docker and Compose restarts against an explicitly selected engine."""

import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
from tempfile import TemporaryDirectory
import time
from uuid import uuid4


LABEL = "io.micropod.qualification"
CONTAINER_ID = re.compile(r"[0-9a-f]{64}")
STATE_DIR = "/tmp/micropod-restart-proof"
WRITABLE_CHECKS = (
    "stable_container_id", "new_process_timestamp", "entrypoint_is_pid_1", "writable_file_contents", "file_mode_owner_group_mtime",
    "hard_link_and_symlink", "deleted_and_renamed_lower_files",
)

BOOT = r"""
p=/tmp/micropod-restart-proof
mkdir -p "$p"
count=0
[ ! -f "$p/count" ] || count=$(cat "$p/count")
count=$((count + 1))
sleep 120 &
child=$!
trap 'printf "%s\n" "$count" >"$p/graceful"; kill "$child"; exit 0' TERM
printf '%s\n' "$$" >"$p/entrypoint-pid"
printf '%s\n' "$count" >"$p/count"
wait "$child"
"""

WRITE = r"""
p=/tmp/micropod-restart-proof
printf '%s\n' "$1" >"$p/data"
chmod 0641 "$p/data"
chown 123:456 "$p/data"
touch -t 200001020304.05 "$p/data"
ln "$p/data" "$p/hard-link"
ln -s data "$p/symlink"
test -f /etc/issue
rm /etc/issue
mv /etc/alpine-release "$p/renamed-release"
"""

READ = r"""
p=/tmp/micropod-restart-proof
test "$(cat "$p/data")" = "$1"
test "$(readlink "$p/symlink")" = data
test "$(cat "$p/symlink")" = "$1"
test "$(stat -c %i "$p/hard-link")" = "$(stat -c %i "$p/data")"
test ! -e /etc/issue
test ! -e /etc/alpine-release
stat -c '%a %u %g %Y %h' "$p/data"
cat "$p/renamed-release"
"""

READONLY = r"""
test -f /etc/alpine-release
if result=$(touch /etc/micropod-restart-proof 2>&1); then exit 1; fi
case "$result" in *'Read-only file system'*) ;; *) echo "$result" >&2; exit 1;; esac
"""


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


class Qualification:
    def __init__(self, work, args, *, prefix="mp-restart-"):
        self.key = prefix + uuid4().hex
        self.image = args.image
        self.compose_file = work / "compose.json"
        self.compose_touched = False
        self.env = {k: v for k, v in os.environ.items() if k not in ("DOCKER_CONTEXT", "DOCKER_HOST", "DOCKER_API_VERSION")}
        if args.context:
            self.cli = ["docker", "--context", args.context]
        else:
            self.cli = ["docker", "--host", args.host]
            self.env["DOCKER_HOST"] = args.host

    def docker(self, *args, check=True, timeout=30):
        result = subprocess.run([*self.cli, *args], env=self.env, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, timeout=timeout)
        if check and result.returncode:
            detail = (result.stdout + result.stderr).strip()[-1600:]
            raise RuntimeError(f"docker {' '.join(args[:2])} exited {result.returncode}\n{detail}")
        return result

    def compose(self, *args, **options):
        return self.docker("compose", "-p", self.key, "-f", str(self.compose_file), *args, **options)

    def inspect(self, id_):
        row, = json.loads(self.docker("container", "inspect", id_).stdout)
        require((row["Config"].get("Labels") or {}).get(LABEL) == self.key, f"Unexpected ownership for {id_}")
        require(CONTAINER_ID.fullmatch(row["Id"]), f"Unexpected ID for {id_}")
        return row

    def exec(self, id_, script, *args):
        return self.docker("exec", id_, "/bin/sh", "-ec", script, "sh", *args).stdout.strip()

    def started(self, name, id_, generation, operation, history):
        row = self.inspect(name)
        require(row["Id"] == id_, f"{name} changed its container ID")
        require(row["State"]["Running"], f"{name} is stopped")
        stamp = row["State"]["StartedAt"]
        require(not history or stamp != history[-1]["started_at"], f"{name} did not start a fresh process")
        until = time.monotonic() + 10
        while True:
            count = self.docker("exec", id_, "cat", STATE_DIR + "/count", check=False, timeout=4)
            if count.returncode == 0 and count.stdout.strip() == str(generation):
                pid = self.exec(id_, "cat " + STATE_DIR + "/entrypoint-pid")
                require(pid == "1", f"{name} entrypoint has PID {pid} in generation {generation}")
                history.append({"number": int(count.stdout), "operation": operation, "started_at": stamp, "entrypoint_pid": 1})
                return
            require(time.monotonic() < until, f"{name} did not reach generation {generation} (got {count.stdout.strip()!r})")
            time.sleep(0.1)

    def seed(self, id_):
        self.exec(id_, WRITE, self.key)
        proof = self.exec(id_, READ, self.key)
        require(proof.splitlines()[0].startswith("641 123 456 ") and proof.splitlines()[0].endswith(" 2"),
                "Unexpected initial mode, ownership or hard-link count")
        return proof

    def writable_receipt(self, name, id_, history, proof, *checks):
        metadata, _, release = proof.partition("\n")
        mode, uid, gid, mtime, links = metadata.split()
        return {
            "name": name, "id": id_, "generations": history, "checks": [*WRITABLE_CHECKS, *checks],
            "file_metadata": {"mode": mode, "uid": int(uid), "gid": int(gid),
                              "mtime": int(mtime), "hard_link_count": int(links)},
            "renamed_alpine_release": release,
        }

    def retained(self):
        name = self.key + "-docker"
        self.docker("run", "--detach", "--pull=never", "--network", "none", "--name", name,
                    "--label", f"{LABEL}={self.key}", self.image, "/bin/sh", "-ec", BOOT)
        id_ = self.inspect(name)["Id"]
        history = []
        self.started(name, id_, 1, "run", history)
        proof = self.seed(id_)
        self.docker("restart", "--timeout", "2", id_)
        self.started(name, id_, 2, "running_restart", history)
        require(self.exec(id_, "cat " + STATE_DIR + "/graceful") == "1", "Restart skipped its graceful stop")
        require(self.exec(id_, READ, self.key) == proof, "Docker restart changed the writable layer")

        self.docker("stop", "--timeout", "2", id_)
        require(self.docker("wait", id_).stdout.strip() == "0", "Stopped process did not exit cleanly")
        self.docker("start", id_)
        self.started(name, id_, 3, "stop_start", history)
        require(self.exec(id_, READ, self.key) == proof, "Stop/start changed the writable layer")

        self.docker("stop", "--timeout", "0", id_)
        self.docker("restart", "--timeout", "0", id_)
        self.started(name, id_, 4, "stopped_restart", history)
        require(self.exec(id_, READ, self.key) == proof, "Restart of a stopped container changed the writable layer")
        return self.writable_receipt(name, id_, history, proof, "graceful_restart", "clean_stop_exit")

    def compose_restart(self):
        name = self.key + "-compose"
        # Pass the variables through Compose for expansion by the guest shell.
        command = BOOT.replace("$", "$$")
        services = {"job": {"image": self.image, "container_name": name,
                            "network_mode": "none", "labels": {LABEL: self.key},
                            "entrypoint": ["/bin/sh", "-ec"], "command": [command]}}
        self.compose_file.write_text(json.dumps({"services": services}), encoding="utf-8")
        self.compose_touched = True
        self.compose("up", "--detach", "--no-build", "--pull", "never")
        id_ = self.inspect(name)["Id"]
        history = []
        self.started(name, id_, 1, "compose_up", history)
        proof = self.seed(id_)
        self.compose("restart", "--timeout", "0", "job")
        self.started(name, id_, 2, "compose_restart", history)
        require(self.exec(id_, READ, self.key) == proof, "Compose restart changed the writable layer")
        return self.writable_receipt(name, id_, history, proof)

    def readonly(self):
        name = self.key + "-readonly"
        self.docker("run", "--detach", "--pull=never", "--network", "none", "--read-only", "--name", name,
                    "--label", f"{LABEL}={self.key}", self.image, "sleep", "120")
        row = self.inspect(name)
        id_ = row["Id"]
        require(row["HostConfig"]["ReadonlyRootfs"], "Read-only root was not enabled")
        self.exec(id_, READONLY)
        self.docker("restart", "--timeout", "0", id_)
        after = self.inspect(name)
        require(after["Id"] == id_ and after["HostConfig"]["ReadonlyRootfs"], "Restart changed a read-only container")
        require(after["State"]["StartedAt"] != row["State"]["StartedAt"], "Read-only container did not restart")
        self.exec(id_, READONLY)
        return {
            "name": name, "id": id_, "checks": ["stable_container_id", "new_process_timestamp", "readonly_root"],
            "generations": [
                {"number": 1, "operation": "run", "started_at": row["State"]["StartedAt"]},
                {"number": 2, "operation": "running_restart", "started_at": after["State"]["StartedAt"]},
            ],
        }

    def ids(self):
        return self.docker("ps", "-aq", "--no-trunc", "--filter", f"label={LABEL}={self.key}").stdout.splitlines()

    def cleanup(self, diagnose=False):
        for id_ in self.ids():
            require(self.inspect(id_)["Id"] == id_, f"Unexpected cleanup ID {id_}")
            if diagnose:
                log = self.docker("logs", id_, check=False)
                print("\n".join((log.stdout + log.stderr).splitlines()[-12:]), file=sys.stderr)
            self.docker("rm", "--force", id_)
        if self.compose_touched:
            self.compose("down", "--timeout", "1")
        remaining = self.ids()
        require(not remaining, "Test containers remain after cleanup")
        return {"remaining_container_ids": remaining}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    target = parser.add_mutually_exclusive_group(required=True)
    target.add_argument("--host", help="Docker Engine endpoint, for example unix:///path/to/docker.sock")
    target.add_argument("--context", help="Docker context, for example orbstack")
    parser.add_argument("--image", default=os.environ.get("MICROPOD_TEST_IMAGE", "alpine:3.23"), help="preloaded Alpine image")
    parser.add_argument("--json", action="store_true", help="print the successful conformance receipt as JSON")
    args = parser.parse_args()
    with TemporaryDirectory(prefix="micropod-restart-") as work:
        probe = Qualification(Path(work), args)
        image, = json.loads(probe.docker("image", "inspect", probe.image).stdout)
        probe.docker("compose", "version")
        try:
            containers = {"docker": probe.retained(), "compose": probe.compose_restart(), "readonly": probe.readonly()}
        except BaseException:
            try:
                probe.cleanup(diagnose=True)
            except Exception as err:
                print(f"Cleanup failed. {err}", file=sys.stderr)
            raise
        else:
            cleanup = probe.cleanup()
    if args.json:
        print(json.dumps({
            "schema": 1, "passed": True, "run_id": probe.key,
            "target": {"context": args.context} if args.context else {"host": args.host},
            "image": {"reference": probe.image, "id": image["Id"]},
            "containers": containers, "cleanup": cleanup,
        }, indent=2))
    else:
        print("Docker and Compose preserved the writable and read-only roots across restart. Test containers removed.")


def interrupted(signum, _frame):
    raise InterruptedError(f"Received signal {signum}")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as exc:
        sys.exit(str(exc) or "Restart qualification interrupted")
