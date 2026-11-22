"""Untimed storage and recovery controls for the local PostgreSQL fixture benchmark."""
from concurrent.futures import ThreadPoolExecutor
from contextlib import ExitStack, contextmanager
import json
from pathlib import PurePosixPath
import re
import subprocess
import time
import uuid

STOCK = "/var/lib/postgresql/data"
OVERLAY = "/var/lib/micropod-fixture/data"
CASES = {"fresh": STOCK, "fresh-overlay": OVERLAY, "prepared": OVERLAY}
CHECK_SQL = "CREATE TABLE ci_probe (value integer NOT NULL); INSERT INTO ci_probe VALUES (42); SELECT value FROM ci_probe;"
INITDB_ARGS = "--auth-local=trust --auth-host=scram-sha-256"
LABEL = "io.micropod.postgres-profile"


def require(condition, message):
    if not condition:
        raise ValueError(message)


def image_history(dk, image):
    # Docker's non-human History.Size is an integer byte count; the default is rounded.
    lines = dk("image", "history", "--no-trunc", "--human=false", "--format", "{{json .}}", image)
    rows = [json.loads(line) for line in lines.splitlines()]
    return [(row["CreatedBy"], int(row["Size"])) for row in rows]


def added_image_history(base, derived):
    require(base and len(derived) >= len(base) and derived[-len(base):] == base,
            "Derived image history does not retain the pinned base")
    sizes = [size for _, size in derived[:-len(base)]]
    require(all(size >= 0 for size in sizes), "Image history byte size unavailable")
    return {"added_history_bytes": sizes, "added_layer_bytes": sum(sizes)}


def pinned_base(requested, digests):
    pattern = r"(?:(?:index[.])?docker[.]io/)?(?:library/)?postgres@(sha256:[0-9a-f]{64})"
    pins = {m[1] for ref in digests or [] if (m := re.fullmatch(pattern, ref))}
    if "@" in requested:
        m = re.fullmatch(pattern, requested)
        require(m and m[1] in pins, "Requested PostgreSQL digest differs from the locally provisioned image")
        return "docker.io/library/postgres@" + m[1]
    require(len(pins) == 1, "Pass the exact provisioned official PostgreSQL digest")
    return "docker.io/library/postgres@" + pins.pop()


def effective_mount(mode, data_dir, mounts, mountinfo, driver):
    """Match the deepest path component in both Docker metadata and Linux mountinfo."""
    require(data_dir == CASES[mode] and driver in {"overlayfs", "overlay2"}, "Unexpected data directory or driver")
    path = PurePosixPath(data_dir)
    docker_mounts = [m for m in mounts if path.is_relative_to(m["Destination"])]
    docker_mount = max(docker_mounts, key=lambda m: len(PurePosixPath(m["Destination"]).parts), default=None)
    matches = []
    for line in mountinfo.splitlines():
        left, right = line.split(" - ", 1)
        fields, fs = left.split(), right.split()
        target = re.sub(r"\\([0-7]{3})", lambda m: chr(int(m[1], 8)), fields[4])
        if path.is_relative_to(target):
            matches.append(dict(target=target, fs=fs[0], device=fields[2], writable="rw" in fields[5].split(",")))
    require(matches, "Linux did not report a PGDATA mount")
    mount = max(matches, key=lambda m: len(PurePosixPath(m["target"]).parts))
    require(sum(m["target"] == mount["target"] for m in matches) == 1, "Ambiguous Linux PGDATA mount")
    require(mount["writable"], "PGDATA is read-only")
    if mode == "fresh":
        require(docker_mount and docker_mount["Type"] == "volume" and docker_mount["RW"] and docker_mount.get("Name")
                and docker_mount["Destination"] == mount["target"] == data_dir, "Stock PGDATA is not the job's Docker volume")
        kind, volume = "volume", docker_mount["Name"]
    else:
        require(docker_mount is None and mount["target"] == "/" and mount["fs"] in {"overlay", "overlayfs"},
                "Overlay PGDATA is covered by a mount or is not on the writable root overlay")
        kind, volume = "overlay", None
    return dict(pgdata=data_dir, kind=kind, volume=volume, driver=driver, linux_mount=mount)


def io_counters(raw):
    sections = {}
    section = None
    for line in raw.splitlines():
        if line.startswith("[") and line.endswith("]"):
            section = line[1:-1]
            sections[section] = []
        elif line.strip():
            require(section is not None, "Unlabelled cgroup counter")
            sections[section].append(line)
    by_device = {}
    for line in sections.get("io.stat", []):
        device, *fields = line.split()
        counts = dict(field.split("=", 1) for field in fields)
        by_device[device] = {key: int(counts[key]) for key in ("rbytes", "wbytes") if key in counts}
    writes = {d: c["wbytes"] for d, c in by_device.items() if "wbytes" in c}
    return dict(sample_unix_us=time.time_ns() // 1000, files=sections,
                io_status="reported" if writes else ("empty" if "io.stat" in sections else "unavailable"),
                write_bytes_by_device=writes or None)


def disk_delta(before, after):
    require(before and before.keys() == after.keys(), "Guest block device set changed or was unavailable")
    result = {}
    for device, sectors in before.items():
        require(after[device] >= sectors, "Guest disk write counter reset")
        result[device] = (after[device] - sectors) * 512
    return result


class StorageProbe:
    def __init__(self, dk, raw, worker, base, images, token):
        self.dk, self.raw = dk, raw
        self.worker, self.base, self.images, self.token = worker, base, images, token

    @contextmanager
    def database(self, mode, password):
        cid = self.dk("create", "--pull=never", "--network", "none", "--label", f"{LABEL}={self.token}",
                      "-e", "POSTGRES_USER=ci", "-e", "POSTGRES_DB=ci", "-e", "POSTGRES_PASSWORD=" + password,
                      "-e", "POSTGRES_INITDB_ARGS=" + INITDB_ARGS, self.images[mode]).strip()
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "Unexpected diagnostic container ID")
        meta = json.loads(self.dk("container", "inspect", cid))[0]
        require(meta["Config"]["Labels"].get(LABEL) == self.token, "Unexpected diagnostic container ownership")
        try:
            # Containerd may expose an index for a local image ID and a platform
            # digest on the container. Config.Image is the immutable create input.
            require(meta["Config"]["Image"] == self.images[mode] and re.fullmatch(r"sha256:[0-9a-f]{64}", meta["Image"]),
                    "Diagnostic container does not run the pinned case")
            yield cid, meta
        finally:
            self.dk("rm", "-fv", cid)

    def ready(self, cid):
        self.dk("start", cid)
        deadline = time.monotonic() + 120
        while self.raw("exec", cid, "pg_isready", "-q", "-h", "127.0.0.1", "-U", "ci", "-d", "ci").returncode:
            state = self.dk("inspect", "--format", "{{.State.Status}} {{.State.ExitCode}}", cid).strip()
            require(state.startswith("running "), "PostgreSQL stopped before final TCP readiness: " + state)
            require(time.monotonic() < deadline, "Final TCP readiness timed out")
            time.sleep(.1)

    def sql(self, cid, password, statement):
        return self.raw("exec", "-e", "PGPASSWORD=" + password, cid, "psql", "-XqAt", "-w", "-h", "127.0.0.1",
                        "-U", "ci", "-d", "ci", "-v", "ON_ERROR_STOP=1", "-c", statement)

    def query(self, cid, password, statement):
        result = self.sql(cid, password, statement)
        require(result.returncode == 0, "PostgreSQL diagnostic query failed: " + result.stderr[-300:])
        return result.stdout.strip()

    def stop(self, cid):
        self.dk("stop", cid)
        require(self.dk("wait", cid).strip() == "0", "Database did not exit cleanly")

    def recovery(self, mode, receipt):
        old, new = uuid.uuid4().hex, uuid.uuid4().hex
        with self.database(mode, old) as (cid, meta):
            receipt["killed_container"] = cid
            first = receipt["killed_volumes"] = [m["Name"] for m in meta["Mounts"] if m["Type"] == "volume"]
            self.ready(cid)
            require(self.query(cid, old, CHECK_SQL) == "42", "Dirty fixture lost its committed row")
            self.dk("kill", "--signal=KILL", cid)
            receipt["killed_exit"] = int(self.dk("wait", cid))
            require(receipt["killed_exit"] == 137, "Fault injection failed")
        with self.database(mode, new) as (cid, meta):
            receipt["successor_container"] = cid
            second = receipt["successor_volumes"] = [m["Name"] for m in meta["Mounts"] if m["Type"] == "volume"]
            require(cid != receipt["killed_container"] and first and second and not set(first).intersection(second),
                    "Recovered database reused a container or writable volume")
            self.ready(cid)
            require(self.query(cid, new, "SELECT to_regclass('public.ci_probe') IS NULL;") == "t", "Previous table survived")
            denied = self.sql(cid, old, "SELECT 1;")
            require(denied.returncode != 0 and "password authentication failed" in denied.stderr, "Prior credential check failed")
            require(self.query(cid, new, CHECK_SQL) == "42", "Recovered SQL check failed")
            self.stop(cid)
            receipt["successor_exit"] = 0
        require(not set(first + second).intersection(self.dk("volume", "ls", "-q").split()),
                "A recovery volume survived database removal")
        receipt["passed"] = True

    def inspect_size(self, cid):
        info, = json.loads(self.dk("container", "inspect", "--size", cid))
        size = info.get("SizeRw")
        require(isinstance(size, int) and size >= 0, "Docker did not provide a writable-layer size")
        return info, size

    def volume_bytes(self, name):
        # The server is stopped at both samples. Mount only this job's verified volume.
        output = self.dk("run", "--rm", "--pull=never", "--network", "none", "--read-only", "--label", f"{LABEL}={self.token}",
                         "--mount", f"type=volume,src={name},dst={STOCK},readonly,volume-nocopy",
                         "--entrypoint", "sh", self.base, "-ec",
                         'du -sx -B1 "$1"; du -sx -B1 --apparent-size "$1"', "sh", STOCK)
        allocated, apparent = (int(line.split()[0]) for line in output.splitlines())
        return dict(allocated=allocated, apparent=apparent)

    def cgroup(self, cid):
        command = """printf '[cgroup]\\n'; cat /proc/self/cgroup
rel=$(sed -n 's/^0:://p' /proc/self/cgroup)
[ -n "$rel" ] || exit 0
for f in io.stat cpu.stat cpu.pressure io.pressure memory.events; do
    p="/sys/fs/cgroup${rel%/}/$f"
    if [ -r "$p" ]; then printf '[%s]\\n' "$f"; cat "$p"; fi
done"""
        return io_counters(self.dk("exec", cid, "sh", "-ec", command))

    def disks(self, observer):
        # Whole hardware-backed guest devices only, without partition double counting.
        raw = self.dk("exec", observer, "sh", "-ec",
                      'for p in /sys/block/*; do [ -e "$p/device" ] || continue; read -r a b c d e f sectors rest < "$p/stat"; '
                      'printf "%s %s\\n" "${p##*/}" "$sectors"; done')
        return {name: int(sectors) for name, sectors in (line.split() for line in raw.splitlines())}

    @contextmanager
    def disk_observer(self):
        cid = self.dk("run", "-d", "--pull=never", "--network", "none", "--read-only", "--tmpfs", STOCK,
                      "--label", f"{LABEL}={self.token}", "--entrypoint", "sleep", self.base, "infinity").strip()
        require(re.fullmatch(r"[0-9a-f]{64}", cid), "Unexpected observer ID")
        try:
            yield cid
        finally:
            self.dk("rm", "-fv", cid)

    def cohort(self, mode, clients, rec, observer):
        """Hold every DB ready together; capacity scans never run in a timed batch."""
        jobs = rec["jobs"] = []
        rec.update(mode=mode, clients=clients, timed=False, image=self.images[mode], worker_boot=self.worker["boot"], passed=False)
        with ExitStack() as cleanup:
            passwords = {}
            for _ in range(clients):
                password = uuid.uuid4().hex
                cid, _ = cleanup.enter_context(self.database(mode, password))
                passwords[cid] = password
                info, size = self.inspect_size(cid)
                mounts = info["Mounts"]
                volumes = [m["Name"] for m in mounts if m["Type"] == "volume"]
                data_volume = next((m["Name"] for m in mounts if m["Type"] == "volume" and m["Destination"] == STOCK), None)
                # Both overlay images inherit the upstream VOLUME at a different path.
                volume = data_volume if mode == "fresh" else None
                require(mode != "fresh" or volume, "No stock PGDATA volume at create")
                job = dict(container=cid, image=info["Image"], requested_image=info["Config"]["Image"],
                           platform_manifest=info.get("ImageManifestDescriptor"), volumes=volumes, pgdata_volume=volume,
                           cgroup_namespace=info["HostConfig"].get("CgroupnsMode"),
                           size_rw_bytes={"created": size}, pgdata_volume_bytes=None, passed=False)
                jobs.append(job)
                if volume:
                    job["pgdata_volume_bytes"] = {"created": self.volume_bytes(volume)}

            def parallel(stage, fn):
                def one(job):
                    try:
                        fn(job)
                    except (KeyError, TypeError, ValueError, OSError, subprocess.TimeoutExpired) as exc:
                        job.update(failed_stage=stage, error=str(exc))
                with ThreadPoolExecutor(max_workers=clients) as pool:
                    list(pool.map(one, jobs))
                require(not any("error" in j for j in jobs), f"{mode} storage cohort failed at {stage}")

            def ready(job):
                cid = job["container"]
                self.ready(cid)
                job["cgroup_at_ready"] = self.cgroup(cid)
                require(job["cgroup_namespace"] != "host" or job["cgroup_at_ready"]["files"].get("cgroup") != ["0::/"],
                        "The Docker job exposes the guest root cgroup")

            def ready_storage(job):
                cid = job["container"]
                info, job["size_rw_bytes"]["ready"] = self.inspect_size(cid)
                actual = self.query(cid, passwords[cid], "SHOW data_directory")
                mount = effective_mount(mode, actual, info["Mounts"], self.dk("exec", cid, "cat", "/proc/self/mountinfo"),
                                        self.worker["storage"])
                require(mount["volume"] == job["pgdata_volume"], "PGDATA volume changed")
                job["effective_mount"] = mount

            def exercise(job):
                cid = job["container"]
                require(self.query(cid, passwords[cid], CHECK_SQL) == "42", "Canonical SQL check failed")
                job["cgroup_after_sql"] = self.cgroup(cid)
                self.stop(cid)
                job["exit"] = 0

            before = self.disks(observer)
            parallel("startup", ready)
            at_ready = self.disks(observer)
            parallel("ready_storage", ready_storage)
            after_inventory = self.disks(observer)
            parallel("sql_and_stop", exercise)
            stopped = self.disks(observer)
            rec["guest_device_write_bytes"] = {"start_to_all_ready": disk_delta(before, at_ready),
                                               "ready_storage_observation": disk_delta(at_ready, after_inventory),
                                               "sql_through_all_stopped": disk_delta(after_inventory, stopped)}
            for job in jobs:
                _, job["size_rw_bytes"]["stopped"] = self.inspect_size(job["container"])
                if job["pgdata_volume"]:
                    job["pgdata_volume_bytes"]["stopped"] = self.volume_bytes(job["pgdata_volume"])
            names = [v for j in jobs for v in j["volumes"]]
            require(len(names) == len(set(names)), "Diagnostic jobs shared an anonymous volume")
        require(not set(names).intersection(self.dk("volume", "ls", "-q").split()), "Diagnostic volume survived removal")
        for job in jobs:
            job["passed"] = True
        rec["passed"] = True
