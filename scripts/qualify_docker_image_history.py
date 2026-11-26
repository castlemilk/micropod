#!/usr/bin/env python3
"""Qualify Docker API 1.47 image history on explicit local Unix sockets."""

import argparse
from datetime import datetime
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import subprocess
import tarfile
import tempfile
from urllib.parse import quote
import uuid

from qualify_engine_api import UnixHTTP


API = "1.47"


def verify(condition, detail):
    if not condition:
        raise RuntimeError(detail)


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def tar_bytes(entries):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode="w") as archive:
        for name, data in entries:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def fixture(tags):
    contents = [b"o", b"\x27" * 8193]
    layers = [tar_bytes([(f"file-{i}", data)]) for i, data in enumerate(contents)]
    diff_ids = [digest(layer) for layer in layers]
    history = [
        {"created": "2026-11-01T00:00:01Z", "created_by": "COPY file-0 /file-0", "comment": "first file"},
        {"created_by": "LABEL io.micropod.fixture=metadata", "comment": "metadata only", "empty_layer": True},
        {"created": "2026-11-01T00:00:03.123Z", "created_by": "COPY file-1 /file-1", "comment": "second file"},
        {"created": "2026-11-01T00:00:04Z", "created_by": 'CMD ["/fixture"]', "empty_layer": True},
    ]
    config = json.dumps({
        "architecture": "arm64", "os": "linux", "config": {"Cmd": ["/fixture"]},
        "rootfs": {"type": "layers", "diff_ids": diff_ids}, "history": history,
    }, sort_keys=True, separators=(",", ":")).encode()
    config_name = digest(config).split(":", 1)[1] + ".json"
    members = [(f"layer-{i}.tar", layer) for i, layer in enumerate(layers)]
    manifest = [{"Config": config_name, "RepoTags": tags, "Layers": [name for name, _ in members]}]
    archive = tar_bytes([("manifest.json", json.dumps(manifest).encode()), (config_name, config), *members])
    expected = {
        "archive": digest(archive), "config_id": digest(config), "diff_ids": diff_ids,
        "history": history, "regular_file_bytes": [len(data) for data in contents],
        "layer_tar_bytes": [len(data) for data in layers], "tags": tags,
    }
    return archive, expected


class Engine:
    def __init__(self, socket_path, config):
        self.path = socket_path.resolve()
        verify(stat.S_ISSOCK(self.path.stat().st_mode), f"{self.path} is not a Unix socket")
        self.env = {key: value for key, value in os.environ.items() if key not in {
            "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_TLS", "DOCKER_TLS_VERIFY",
            "DOCKER_CERT_PATH", "DOCKER_CUSTOM_HEADERS", "DOCKER_DEFAULT_PLATFORM",
        }}
        self.env.update(DOCKER_CONFIG=str(config), DOCKER_API_VERSION=API)

    def get(self, path):
        connection = UnixHTTP(self.path)
        try:
            connection.request("GET", f"/v{API}{path}")
            response = connection.getresponse()
            return response.status, json.load(response)
        finally:
            connection.close()

    def read(self, path):
        status, body = self.get(path)
        verify(status == 200, f"{self.path} GET {path} returned {status}: {body}")
        return body

    def cli(self, *args, input_data=None):
        result = subprocess.run(["docker", "--host", f"unix://{self.path}", *args],
                                env=self.env, input=input_data, capture_output=True, timeout=30)
        verify(result.returncode == 0, f"{self.path} docker {args}: {result.stderr.decode(errors='replace')}")
        return result.stdout.decode()

    def history(self, ref):
        return self.read(f"/images/{quote(ref, safe='/:@')}/history")

    def inspect(self, ref):
        return self.read(f"/images/{quote(ref, safe='/:@')}/json")


def familiar(ref):
    for prefix in ("docker.io/", "index.docker.io/"):
        if ref.startswith(prefix):
            return ref.removeprefix(prefix).removeprefix("library/")
    return ref


def observe(engine, ref, enforce_repository):
    image = engine.inspect(ref)
    history = engine.history(ref)
    verify(isinstance(history, list) and history, f"{ref} has no history rows")
    verify(history[0]["Id"] == image["Id"], f"{ref} history head does not match inspected ID")
    for row in history:
        verify(set(row) == {"Id", "Created", "CreatedBy", "Tags", "Size", "Comment"}, f"invalid history row {row}")
        verify(type(row["Size"]) is int and row["Size"] >= 0, f"invalid history size {row}")
    verify(history == engine.history(image["Id"]), f"{ref} history differs when looked up by ID")
    short_id = image["Id"].removeprefix("sha256:")[:12]
    verify(history == engine.history(short_id), f"{ref} history differs when looked up by short ID")
    cli = [json.loads(line) for line in engine.cli(
        "history", "--no-trunc", "--human=false", "--format", "{{json .}}", ref).splitlines()]
    wire_rows = [(row["Id"], row["CreatedBy"], row["Size"], row["Comment"]) for row in history]
    cli_rows = [(row["ID"], row["CreatedBy"], int(row["Size"]), row["Comment"]) for row in cli]
    verify(wire_rows == cli_rows, f"{ref} stock CLI disagrees with API output")
    digests = image.get("RepoDigests") or []
    for alias in digests:
        verify(engine.inspect(alias)["Id"] == image["Id"], f"{ref} inspect resolves another image through {alias}")
        verify(history == engine.history(alias), f"{ref} history differs when looked up by {alias}")
    wrong_repo = None
    if digests:
        wrong = f"micropod-history-absent-{uuid.uuid4().hex}@{digests[0].split('@', 1)[1]}"
        wrong_repo = {suffix: engine.get(f"/images/{wrong}/{suffix}")[0] for suffix in ("json", "history")}
        if enforce_repository:
            verify(wrong_repo == {"json": 404, "history": 404}, f"digest resolved through unrelated repository {wrong}")
    tags = {familiar(item) for item in image.get("RepoTags") or []}
    tagged_history = {familiar(item) for item in history[0]["Tags"] or []}
    verify(tags <= tagged_history <= tags | {familiar(item) for item in digests}, f"{ref} history tags disagree with image inspect")
    return {
        "image_id": image["Id"], "short_id": short_id, "repo_tags": image.get("RepoTags"), "repo_digests": digests,
        "wrong_repo_statuses": wrong_repo,
        "diff_ids": image["RootFS"].get("Layers", []), "inspect_size": image["Size"],
        "history_size": sum(row["Size"] for row in history), "history": history, "cli": cli,
    }


def verify_fixture(observed, expected, mode):
    verify(observed["diff_ids"] == expected["diff_ids"], "fixture DiffIDs differ")
    rows = observed["history"]
    verify(len(rows) == len(expected["history"]), "fixture history row count differs")
    verify(set(expected["tags"]) <= {familiar(tag) for tag in rows[0]["Tags"] or []}, "fixture head lacks its pair of tags")
    for row in rows[1:]:
        verify(row["Id"] == "<missing>" and not row["Tags"], "fixture acquired undocumented ancestry")
    sizes = []
    for row, step in zip(reversed(rows), expected["history"], strict=True):
        timestamp = int(datetime.fromisoformat(step["created"]).timestamp()) if "created" in step else 0
        verify((row["Created"], row["CreatedBy"], row["Comment"]) ==
               (timestamp, step["created_by"], step.get("comment", "")), "fixture history metadata differs")
        if step.get("empty_layer"):
            verify(row["Size"] == 0, "metadata-only layer consumed disk")
        else:
            verify(row["Size"] > 0, "filesystem fixture layer has no size")
            sizes.append(row["Size"])
    if mode == "classic":
        verify(sizes == expected["regular_file_bytes"], "classic history did not report the logical file bytes")
    else:
        verify(all(size >= logical for size, logical in zip(sizes, expected["regular_file_bytes"], strict=True)),
               "overlay fixture reports fewer bytes than the files it stores")
    return sizes


def storage_mode(info):
    if info["Driver"] == "overlayfs" or ["driver-type", "io.containerd.snapshotter.v1"] in (info.get("DriverStatus") or []):
        return "snapshotter"
    if info["Driver"] == "overlay2":
        return "classic"
    raise RuntimeError(f"unsupported reference storage mode {info['Driver']}")


def comparable(observed):
    return [(row["Created"], row["CreatedBy"], row["Comment"], row["Id"] == "<missing>") for row in observed["history"]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--alpine", default="alpine:3.23")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    prefix = f"micropod-history-{uuid.uuid4().hex}"
    tags = [f"{prefix}:fixture", f"{prefix}:alias"]
    archive, expected = fixture(tags)
    receipt = {"api": API, "fixture": expected, "engines": {}, "cleanup": {}}
    with tempfile.TemporaryDirectory(prefix="history-", dir=args.output.parent) as work:
        config = Path(work) / "config"
        config.mkdir()
        engines = {"reference": Engine(args.reference, config)}
        if args.candidate:
            engines["candidate"] = Engine(args.candidate, config)
            verify(engines["reference"].path != engines["candidate"].path, "both arguments name the same socket")
        owned = []
        try:
            for side, engine in engines.items():
                info = engine.read("/info")
                verify((info.get("ServerVersion") == "micropod") == (side == "candidate"), f"wrong {side} socket")
                mode = storage_mode(info)
                for tag in tags:
                    verify(engine.get(f"/images/{tag}/json")[0] == 404, "fixture reference already exists")
                    verify(engine.get(f"/images/{tag}/history")[0] == 404, "missing history returned the wrong status")
                owned.append((side, engine))
                engine.cli("image", "load", input_data=archive)
                images = {"alpine": observe(engine, args.alpine, side == "candidate"),
                          "layered": observe(engine, tags[0], side == "candidate")}
                verify(images["layered"]["history"] == engine.history(tags[1]), "fixture history differs through its other tag")
                sizes = verify_fixture(images["layered"], expected, mode)
                if mode == "classic":
                    for image in images.values():
                        verify(image["history_size"] == image["inspect_size"], "classic history size and image size differ")
                receipt["engines"][side] = {
                    "version": engine.read("/version"), "driver": info["Driver"],
                    "driver_status": info.get("DriverStatus"), "size_mode": mode,
                    "fixture_filesystem_layer_bytes": sizes, "images": images,
                }
            if args.candidate:
                reference, candidate = (receipt["engines"][side] for side in ("reference", "candidate"))
                comparison = {}
                receipt["comparison"] = comparison
                for name in ("alpine", "layered"):
                    first, second = (engine["images"][name] for engine in (reference, candidate))
                    verify(first["diff_ids"] == second["diff_ids"], f"{name} source layers differ")
                    verify(comparable(first) == comparable(second), f"{name} history order or metadata differs")
                    reference_bytes = [row["Size"] for row in first["history"]]
                    candidate_bytes = [row["Size"] for row in second["history"]]
                    comparison[name] = {
                        "metadata_matches": True, "sizes_match": reference_bytes == candidate_bytes,
                        "reference_layer_bytes": reference_bytes, "candidate_layer_bytes": candidate_bytes,
                        "reference_sum": first["history_size"], "candidate_sum": second["history_size"],
                    }
            receipt["passed"] = True
        except Exception as error:
            receipt.update(passed=False, error=str(error))
        finally:
            for side, engine in reversed(owned):
                try:
                    for tag in reversed(tags):
                        if engine.get(f"/images/{tag}/json")[0] == 200:
                            engine.cli("image", "rm", tag)
                        verify(engine.get(f"/images/{tag}/json")[0] == 404, "fixture tag remained after cleanup")
                    receipt["cleanup"][side] = True
                except Exception as error:
                    receipt["cleanup"][side] = str(error)
                    receipt["passed"] = False
            args.output.write_text(json.dumps(receipt, indent=2) + "\n")
    if not receipt["passed"]:
        parser.exit(1, f"History qualification failed. See {args.output}\n")


if __name__ == "__main__":
    main()
