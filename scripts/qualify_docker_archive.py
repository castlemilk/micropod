#!/usr/bin/env python3
"""Exercise the stock Docker archive client on created, running and stopped containers."""
import argparse
import base64
import csv
import hashlib
import http.client
import io
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tarfile
from tempfile import TemporaryDirectory
import time
from urllib.parse import urlencode

from qualify_docker_restart import CONTAINER_ID, Qualification, LABEL, require

ALPINE_RELEASE = "/etc/alpine-release"
LAYERED_RELEASE = "/etc/debian_version"


def mount(directory, target, readonly=False):
    out = io.StringIO()
    fields = ["type=bind", f"source={directory}", f"target={target}"]
    if readonly:
        fields.append("readonly")
    csv.writer(out, lineterminator="").writerow(fields)
    return out.getvalue()


def path_stat(host, cid, path):
    with socket.socket(socket.AF_UNIX) as sock:
        sock.settimeout(10)
        sock.connect(host.removeprefix("unix://"))
        uri = f"/containers/{cid}/archive?" + urlencode({"path": path})
        sock.sendall(f"HEAD {uri} HTTP/1.1\r\nHost: docker\r\nConnection: close\r\n\r\n".encode())
        with http.client.HTTPResponse(sock, method="HEAD") as response:
            response.begin()
            require(response.status == 200, f"archive HEAD returned HTTP {response.status}")
            return json.loads(base64.b64decode(response.getheader("X-Docker-Container-Path-Stat"), validate=True))


def binary_cp(fixture, source, target, data=None, *, options=()):
    response = subprocess.run([*fixture.cli, "cp", *options, source, target], env=fixture.env, input=data,
                              capture_output=True, timeout=30)
    require(response.returncode == 0, response.stderr.decode(errors="replace")[-2000:])
    return response.stdout


def archive_file(stream):
    with tarfile.open(fileobj=io.BytesIO(stream)) as archive:
        entry, = archive.getmembers()
        require(entry.isfile(), "docker cp emitted an unexpected tar member type")
        with archive.extractfile(entry) as member:
            return entry, member.read()


def check_bytes(fixture, source, expected):
    stream = binary_cp(fixture, source, "-")
    _, content = archive_file(stream)
    require(content == expected, f"archive content mismatch for {source}")
    return stream


def archive_owner_roundtrip(fixture, cid, payload):
    entry = tarfile.TarInfo("archive-owner-proof")
    entry.uid, entry.gid, entry.mode, entry.mtime = 12345, 23456, 0o641, 946782245
    entry.size = len(payload)
    request = io.BytesIO()
    with tarfile.open(fileobj=request, mode="w") as archive:
        archive.addfile(entry, io.BytesIO(payload))
    binary_cp(fixture, "-", f"{cid}:/tmp", request.getvalue(), options=("-a",))
    guest = fixture.exec(cid, "stat -c '%u %g %a %Y' /tmp/archive-owner-proof")
    require(guest == f"{entry.uid} {entry.gid} {entry.mode:o} {entry.mtime}", f"guest archive metadata differs: {guest}")
    exported, content = archive_file(binary_cp(fixture, f"{cid}:/tmp/{entry.name}", "-", options=("-a",)))
    expected = (entry.uid, entry.gid, entry.mode, entry.mtime)
    require((exported.uid, exported.gid, exported.mode, exported.mtime) == expected and content == payload,
            "docker cp -a round-trip changed metadata or content")
    return {"uid": exported.uid, "gid": exported.gid, "mode": f"{exported.mode:04o}", "mtime": exported.mtime}


def readonly_container(fixture, suffix, image, *, auto_remove=False):
    operation = ("run", "--detach", "--rm") if auto_remove else ("create",)
    cid = fixture.docker(*operation, "--pull=never", "--name", f"{fixture.key}-{suffix}",
                         "--label", f"{LABEL}={fixture.key}", "--network", "none",
                         "--read-only", image, "/bin/sleep", "300").stdout.strip()
    require(CONTAINER_ID.fullmatch(cid), "read-only container did not return a full ID")
    row = fixture.inspect(cid)
    require(row["Id"] == cid and row["HostConfig"].get("ReadonlyRootfs"), "read-only container identity differs")
    return cid


def readonly_file(fixture, host, cid, path, expected=None):
    entry, content = archive_file(binary_cp(fixture, f"{cid}:{path}", "-"))
    metadata = path_stat(host, cid, path)
    # Docker HEAD encodes Go's os.FileMode. Tar identifies the entry type.
    require(entry.name == Path(path).name and metadata["name"] == entry.name
            and metadata["size"] == len(content) and (metadata["mode"] & 0o777) == (entry.mode & 0o777),
            f"archive HEAD and tar disagree for {path}: HEAD={metadata}, tar name={entry.name}, mode={entry.mode:o}")
    require(bool(content) and (expected is None or content == expected), f"read-only file content differs for {path}")
    return content


def reject_root_upload(fixture, cid, leaf):
    denied = fixture.docker("cp", str(leaf), f"{cid}:/tmp/readonly-proof", check=False)
    require(denied.returncode != 0 and "read-only" in (denied.stdout + denied.stderr).lower(),
            "root upload did not report a read-only filesystem")


def readonly_lifecycle(fixture, host, leaf):
    cid = readonly_container(fixture, "readonly", fixture.image)
    expected = None
    states = []
    for phase in ("created", "running", "exited"):
        if phase == "running":
            fixture.docker("start", cid)
        if phase == "exited":
            fixture.docker("stop", "--timeout", "1", cid)
        require(fixture.inspect(cid)["State"]["Status"] == phase, f"read-only container did not reach {phase}")
        expected = readonly_file(fixture, host, cid, ALPINE_RELEASE, expected)
        reject_root_upload(fixture, cid, leaf)
        states.append(phase)
    return expected, {"id": cid, "path": ALPINE_RELEASE, "states": states, "sha256": hashlib.sha256(expected).hexdigest()}


def readonly_auto_remove(fixture, host, leaf, expected):
    cid = readonly_container(fixture, "readonly-auto", fixture.image, auto_remove=True)
    row = fixture.inspect(cid)
    require(row["State"]["Running"] and row["HostConfig"].get("AutoRemove"), "read-only --rm container is not running")
    content = readonly_file(fixture, host, cid, ALPINE_RELEASE, expected)
    reject_root_upload(fixture, cid, leaf)
    fixture.docker("stop", "--timeout", "1", cid)
    deadline = time.monotonic() + 5
    while cid in fixture.ids():
        require(time.monotonic() < deadline, "read-only --rm container remained after stop")
        time.sleep(0.05)
    return {"id": cid, "path": ALPINE_RELEASE, "sha256": hashlib.sha256(content).hexdigest(), "auto_removed": True}


def readonly_layered_image(fixture, host, image):
    details, = json.loads(fixture.docker("image", "inspect", image).stdout)
    layers = (details.get("RootFS") or {}).get("Layers")
    require(layers is None or len(layers) > 1, f"{image} does not contain multiple image layers")
    cid = readonly_container(fixture, "readonly-overlay", image)
    require(fixture.inspect(cid)["State"]["Status"] == "created", "layered image container started unexpectedly")
    content = readonly_file(fixture, host, cid, LAYERED_RELEASE)
    return {"id": cid, "image": image, "image_id": details["Id"], "path": LAYERED_RELEASE,
            "layer_count": None if layers is None else len(layers), "sha256": hashlib.sha256(content).hexdigest()}


def owned_volumes(fixture):
    return fixture.docker("volume", "ls", "-q", "--filter", f"label={LABEL}={fixture.key}").stdout.splitlines()


def require_owned_volume(fixture, volume):
    labels = json.loads(fixture.docker("volume", "inspect", "--format", "{{json .Labels}}", volume).stdout) or {}
    require(labels.get(LABEL) == fixture.key, "archive volume identity differs")


def stop_during_copy(fixture, shared, payload):
    name = fixture.key + "-inflight"
    cid = fixture.docker("run", "--detach", "--pull=never", "--network", "none", "--name", name,
                         "--label", f"{LABEL}={fixture.key}", "--mount", mount(shared, "/artifacts"),
                         fixture.image, "sleep", "120").stdout.strip()
    require(CONTAINER_ID.fullmatch(cid) and fixture.inspect(cid)["Id"] == cid, "invalid in-flight copy container")
    archive = io.BytesIO()
    with tarfile.open(fileobj=archive, mode="w") as tar:
        for label, data in (("completed-part", payload[:64]), ("pending-part", payload)):
            entry = tarfile.TarInfo(label)
            entry.size = len(data)
            tar.addfile(entry, io.BytesIO(data))
    # Keep stdin open between two parts of a valid archive, as a CI artifact
    # producer can do while a scheduler is stopping its job.
    with subprocess.Popen([*fixture.cli, "cp", "-", f"{cid}:/artifacts"], env=fixture.env,
                          stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE) as client:
        try:
            client.stdin.write(archive.getvalue()[:65536])
            client.stdin.flush()
            deadline = time.monotonic() + 5
            first, pending = shared / "completed-part", shared / "pending-part"
            while time.monotonic() < deadline and not first.is_file() and client.poll() is None:
                time.sleep(0.025)
            require(first.is_file() and first.read_bytes() == payload[:64] and not pending.exists(),
                    "running archive did not publish its first complete member")
            start = time.monotonic()
            fixture.docker("stop", "--timeout", "0", cid, timeout=6)
            elapsed = time.monotonic() - start
        finally:
            try:
                client.stdin.close()
            except BrokenPipeError:
                pass
            try:
                client.wait(timeout=3)
            except subprocess.TimeoutExpired:
                client.kill()
                client.wait(timeout=3)
        require(client.returncode != 0 and not fixture.inspect(cid)["State"]["Running"],
                "expected the container to stop before the upload completed")
        require(not pending.exists() and not list(shared.glob(".micropod-copy-*")), "partial archive member survived stop")
        return {"id": cid, "stop_seconds": elapsed, "client_exit": client.returncode}


def run(args, work, result):
    f = Qualification(work, args, prefix="mp-archive-")
    name = f.key + "-archive"
    volume = f.key + "-data"
    shared = work / "share"
    shared.mkdir()
    local = work / "artifacts"
    nested = local / "bin"
    nested.mkdir(parents=True)
    leaf = nested / "release artifact"
    payload = hashlib.sha256(f.key.encode()).digest() * 8193
    leaf.write_bytes(payload)
    leaf.chmod(0o751)
    (local / "empty").touch()
    (shared / "existing").write_bytes(b"host input\n")
    digest = hashlib.sha256(payload).hexdigest()
    result.update(scope=f.key, sha256=digest, bytes=len(payload), checks=[], failures={})
    def check(name, action):
        try:
            value = action()
        except Exception as exc:
            result["failures"][name] = str(exc)
        else:
            result["checks"].append(name)
            return value

    try:
        require(f.docker("volume", "create", "--label", f"{LABEL}={f.key}", volume).stdout.strip() == volume,
                "volume creation returned a different name")
        require_owned_volume(f, volume)
        cid = f.docker("create", "--pull=never", "--name", name, "--label", f"{LABEL}={f.key}",
                       "--network", "none", "--mount", f"type=volume,source={volume},target=/artifacts",
                       "--mount", mount(shared, "/workspace"), "--mount", mount(shared, "/inputs", readonly=True),
                       f.image, "sleep", "300").stdout.strip()
        require(CONTAINER_ID.fullmatch(cid) and f.inspect(cid)["Id"] == cid, "archive container identity differs")
        result["id"] = cid

        def directory_roundtrip():
            f.docker("cp", str(local), f"{cid}:/tmp/checkout-copy")
            out = work / "result"
            f.docker("cp", f"{cid}:/tmp/checkout-copy/.", str(out))
            copied = out / "bin" / leaf.name
            require(copied.read_bytes() == payload and (out / "empty").stat().st_size == 0,
                    "directory copy changed content")
            require(copied.stat().st_mode & 0o777 == 0o751, "file mode changed")
            stat = path_stat(args.host, cid, "/tmp/checkout-copy/bin/" + leaf.name)
            require(stat["name"] == leaf.name and stat["size"] == len(payload) and stat["mode"] & 0o777 == 0o751,
                    "archive HEAD metadata differs")

        check("created_directory_roundtrip_and_head", directory_roundtrip)
        f.docker("start", cid)

        def streaming():
            f.docker("cp", str(leaf), f"{cid}:/artifacts/sentinel")
            stream = check_bytes(f, f"{cid}:/artifacts/sentinel", payload)
            binary_cp(f, "-", f"{cid}:/tmp", stream)
            require(f.exec(cid, 'sha256sum /tmp/sentinel').split()[0] == digest, "guest read a different upload")

        def host_share():
            f.docker("cp", str(leaf), f"{cid}:/workspace/published")
            require((shared / "published").read_bytes() == payload, "host did not see published file")
            check_bytes(f, f"{cid}:/inputs/existing", b"host input\n")
            denied = f.docker("cp", str(leaf), f"{cid}:/inputs/new", check=False)
            require(denied.returncode != 0 and not (shared / "new").exists(), "read-only mount accepted a copy")

        check("live_named_volume_and_tar_streams", streaming)
        check("live_workspace_and_readonly_mount", host_share)
        check("created_root_visible_after_start", lambda: check_bytes(f, f"{cid}:/tmp/checkout-copy/bin/{leaf.name}", payload))

        def links():
            linked = work / "linked"
            linked.mkdir()
            (linked / "file").write_bytes(payload)
            os.link(linked / "file", linked / "hard")
            (linked / "symbolic").symlink_to("file")
            f.docker("cp", str(linked), f"{cid}:/tmp/linked")
            equal = f.exec(cid, 'cd /tmp/linked && test "$(readlink symbolic)" = file && test "$(stat -c %i file)" = "$(stat -c %i hard)" && sha256sum symbolic')
            require(equal.split()[0] == digest, "link did not resolve to source contents")
            out = work / "links-out"
            f.docker("cp", f"{cid}:/tmp/linked", str(out))
            require((out / "symbolic").readlink() == Path("file") and (out / "file").samefile(out / "hard"),
                    "archive download changed link identities")

        check("relative_symlink_and_hardlink", links)

        def follow_symlink():
            out = work / "followed"
            f.docker("cp", "-L", f"{cid}:/tmp/linked/symbolic", str(out))
            require(out.is_file() and not out.is_symlink() and out.read_bytes() == payload,
                    "docker cp -L did not download the symlink target")

        check("follow_symlink_download", follow_symlink)
        metadata = check("archive_owner_mode_and_mtime_roundtrip", lambda: archive_owner_roundtrip(f, cid, payload))
        if metadata is not None:
            result["file_metadata"] = metadata
        f.docker("stop", "--timeout", "1", cid)
        check("stopped_retained_root", lambda: check_bytes(f, f"{cid}:/tmp/sentinel", payload))
        check("stopped_named_volume", lambda: check_bytes(f, f"{cid}:/artifacts/sentinel", payload))

        expected = None
        retained = check("readonly_created_running_stopped", lambda: readonly_lifecycle(f, args.host, leaf))
        if retained is not None:
            expected, result["readonly"] = retained
        ephemeral = check("live_readonly_auto_remove", lambda: readonly_auto_remove(f, args.host, leaf, expected))
        if ephemeral is not None:
            result["readonly_auto_remove"] = ephemeral
        if args.overlay_image:
            overlay = check("readonly_layered_image", lambda: readonly_layered_image(f, args.host, args.overlay_image))
            if overlay is not None:
                result["readonly_overlay"] = overlay
        if args.native_retirement:
            result["inflight_stop"] = check("native_stop_during_copy", lambda: stop_during_copy(f, shared, payload))
    finally:
        f.cleanup()
        for owned in owned_volumes(f):
            require(owned == volume, f"unexpected owned volume {owned}")
            require_owned_volume(f, owned)
            f.docker("volume", "rm", owned)
        result["cleanup"] = {"containers": f.ids(), "volumes": owned_volumes(f)}
        require(all(not rows for rows in result["cleanup"].values()), "archive fixtures remain")


def main():
    from bench_workspace_edits import interrupted

    signal.signal(signal.SIGTERM, interrupted)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", required=True, help="explicit unix:// Docker socket")
    parser.add_argument("--workspace", type=Path, required=True, help="worker's shared host directory")
    parser.add_argument("--image", default="alpine:3.23")
    parser.add_argument("--overlay-image", help="preloaded multi-layer image with /etc/debian_version")
    parser.add_argument("--native-retirement", action="store_true", help="check native worker retirement during a CI upload")
    args = parser.parse_args()
    args.context = None
    if not args.host.startswith("unix:///") or not Path(args.host[7:]).is_socket():
        parser.error("--host must identify a Unix socket")
    result = {}
    try:
        with TemporaryDirectory(prefix="archive-", dir=args.workspace.resolve(strict=True)) as directory:
            run(args, Path(directory), result)
    except Exception as exc:
        result["error"] = str(exc)
    print(json.dumps(result, indent=2))
    return int(bool(result.get("failures") or result.get("error")))


if __name__ == "__main__":
    raise SystemExit(main())
