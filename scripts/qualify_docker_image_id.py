#!/usr/bin/env python3
"""Exercise image deletion and retained containers on an explicit Docker API 1.47 socket."""

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
from uuid import uuid4

from qualify_docker_image_history import tar_bytes
from qualify_engine_api import UnixHTTP


LABEL = "io.micropod.image-id-qualification"
BASE = "alpine:3.23"


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def fixture(source, tag, token):
    with tarfile.open(fileobj=io.BytesIO(source)) as archive:
        row, = json.load(archive.extractfile("manifest.json"))
        config = json.load(archive.extractfile(row["Config"]))
        cfg = config.setdefault("config", {})
        cfg["Labels"] = (cfg.get("Labels") or {}) | {LABEL: token}
        cfg["Env"] = [*(cfg.get("Env") or []), "MP_IMAGE_RUN=" + token]
        payload = json.dumps(config, separators=(",", ":")).encode()
        name = hashlib.sha256(payload).hexdigest() + ".json"
        layers = [(path, archive.extractfile(path).read()) for path in row["Layers"]]
    manifest = [{"Config": name, "RepoTags": [tag], "Layers": row["Layers"]}]
    return tar_bytes([*layers, (name, payload), ("manifest.json", json.dumps(manifest).encode())])


def exercise(args, directory, report):
    token = report["run"]
    tag = "micropod-qa/delete-" + token + ":owned"
    container = "mp-delete-" + token
    env = {k: v for k, v in os.environ.items() if not k.startswith("DOCKER_")}
    env.update(DOCKER_CONFIG=directory, DOCKER_API_VERSION="1.47", DOCKER_CLI_HINTS="false")
    (Path(directory) / "config.json").write_text('{"auths":{}}')

    def docker(*argv, data=None):
        return subprocess.run(["docker", "--host", "unix://" + str(args.socket), *argv], input=data, env=env,
                              capture_output=True, check=True, timeout=35).stdout

    def request(method, path):
        conn = UnixHTTP(args.socket)
        try:
            conn.request(method, "/v1.47" + path)
            response = conn.getresponse()
            return response.status, json.loads(response.read())
        finally:
            conn.close()

    def image(ref):
        return request("GET", "/images/" + quote(ref, safe="/:") + "/json")

    def delete(ref, force):
        return request("DELETE", "/images/" + quote(ref, safe="/:") + "?force=" + ("1" if force else "0"))

    def binds(ref, expected):
        code, result = image(ref)
        return code == 200 and result.get("Id") == expected

    code, base = image(BASE)
    require(code == 200 and image(tag)[0] == 404, "missing preloaded Alpine or occupied fixture tag")
    base_id = base["Id"]
    unique = None
    try:
        docker("load", "-q", data=fixture(docker("save", BASE), tag, token))
        code, loaded = image(tag)
        require(code == 200 and loaded["Config"]["Labels"].get(LABEL) == token and loaded["Id"] != base_id,
                "loaded image does not contain the private fixture")
        unique = report["fixture_id"] = loaded["Id"]
        short = unique.removeprefix("sha256:")[:12]
        docker("run", "-d", "--pull=never", "--network=none", "--name", container, "--label", LABEL + "=" + token,
               tag, "/bin/sh", "-c", "exec sleep 300")
        require(docker("exec", container, "printenv", "MP_IMAGE_RUN").strip().decode() == token, "wrong running image")
        docker("tag", BASE, tag)
        require(binds(tag, base_id) and binds(short, unique), "moving the final named tag lost the retained image")

        for state in ("running", "stopped"):
            if state == "stopped":
                docker("stop", "--timeout", "2", container)
            rows = {}
            for force in (False, True):
                code, body = delete(unique, force)
                rows["force" if force else "plain"] = {"status": code, "response": body, "id_after": image(unique)[0]}
                if args.native:
                    require(code == 409 and binds(short, unique), f"{state} image retention failed: {rows}")
            report[state] = rows
        docker("start", container)
        require(docker("exec", container, "printenv", "MP_IMAGE_RUN").strip().decode() == token, "restart lost original image")
        report["restart_after_final_tag_moved"] = True
        docker("rm", "-f", container)

        if binds(short, unique):
            code, body = delete(short, False)
            removal = {"plain": {"status": code, "response": body}}
            if code == 409:
                require(binds(short, unique), "unforced conflict unexpectedly removed the image")
                code, body = delete(short, True)
                removal["force"] = {"status": code, "response": body}
            require(code == 200 and any(row.get("Deleted") for row in body), f"unused removal returned {removal}")
            names = [row["Untagged"] for row in body if "Untagged" in row]
            require(len(names) == len(set(names)), "the engine returned duplicate untagged references")
            report["unused_short_id"] = removal
        elif args.native:
            raise RuntimeError("unused native image disappeared before explicit deletion")
        report["immediate_absence"] = [image(ref)[0] for ref in (unique, short, unique)]
        require(report["immediate_absence"] == [404, 404, 404], "deleted image remained visible")
        code, images = request("GET", "/images/json?all=1")
        require(code == 200 and isinstance(images, list), "could not enumerate images after removal")
        report["listed_after_removal"] = any(row.get("Id") == unique for row in images)
        require(not report["listed_after_removal"], "deleted image still appeared in the immediate listing")
    finally:
        code, obj = request("GET", "/containers/" + container + "/json")
        if code == 200:
            require(obj["Config"]["Labels"].get(LABEL) == token, "fixture container ownership changed")
            docker("rm", "-f", container)
        code, obj = image(tag)
        if code == 200:
            require(obj["Id"] in (unique, base_id) or obj["Config"]["Labels"].get(LABEL) == token, "fixture tag ownership changed")
            docker("image", "rm", tag)
        if unique and binds(unique, unique):
            code, obj = image(unique)
            require(code == 200 and obj["Config"]["Labels"].get(LABEL) == token and not obj.get("RepoTags"),
                    "fixture ID acquired an unrelated reference")
            delete(unique, True)
        report["cleanup"] = {"base_preserved": binds(BASE, base_id), "tag_absent": image(tag)[0] == 404,
                             "fixture_id_absent": bool(unique) and image(unique)[0] == 404,
                             "container_absent": request("GET", "/containers/" + container + "/json")[0] == 404}
        require(all(report["cleanup"].values()), "incomplete image retention fixture cleanup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--native", action="store_true", help="Require the Micropod worker retention contract")
    args = parser.parse_args()
    if not args.socket.is_socket() or args.output.exists():
        parser.error("select a live local socket and a new receipt path")
    report = {"passed": False, "run": uuid4().hex, "native": args.native}
    try:
        with tempfile.TemporaryDirectory(prefix="mp-img-id-") as tmp:
            exercise(args, tmp, report)
        report["passed"] = True
    except Exception as exc:
        report["error"] = str(exc)
        raise
    finally:
        with args.output.open("x") as output:
            json.dump(report, output, indent=2)
            output.write("\n")


if __name__ == "__main__":
    main()
