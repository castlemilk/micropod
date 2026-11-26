#!/usr/bin/env python3
"""Exercise Buildx's built-in docker driver through a private native Docker socket."""

import argparse
import concurrent.futures
import hashlib
import io
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tarfile
import tempfile
import time
from urllib.parse import quote

from qualify_engine_api import UnixHTTP


def run(options, directory, result):
    label = "io.micropod.qa.buildx"
    nonce = secrets.token_hex(5)
    tag = f"micropod-qa/native-buildx:{nonce}"
    alias = tag + "-stable"
    iid_alias = tag + "-iid"
    provenance_tag = tag + "-provenance"
    fixture_tags = (tag, alias, iid_alias, provenance_tag)
    ids = set()
    name = f"mp-buildx-{nonce}"
    config = directory / "docker"
    config.mkdir()
    (config / "config.json").write_text(json.dumps({"cliPluginsExtraDirs": [str(options.plugin_dir)]}))
    env = {k: v for k, v in os.environ.items() if not k.startswith(("DOCKER_", "BUILDX_", "BUILDKIT_"))}
    env.update(HOME=str(directory), DOCKER_CONFIG=str(config), BUILDX_CONFIG=str(directory / "buildx"),
               DOCKER_HOST="unix://" + str(options.socket))
    result.update(tag=tag, container=name, calls=[], exports={})

    def docker(*args, check=True):
        start = time.monotonic_ns()
        proc = subprocess.run(["docker", *map(str, args)], env=env, capture_output=True, text=True, timeout=120)
        end = time.monotonic_ns()
        result["calls"].append(dict(argv=[str(arg) for arg in args], exit=proc.returncode,
                                    started_ns=start, ended_ns=end, elapsed_ms=(end - start) / 1e6,
                                    stdout=proc.stdout, stderr=proc.stderr))
        if check and proc.returncode:
            raise RuntimeError(f"docker {' '.join(map(str, args[:3]))}: {proc.stderr[-1200:]}")
        return proc

    def get(path, limit=4 << 20):
        conn = UnixHTTP(options.socket)
        try:
            conn.request("GET", "/v1.47" + path)
            response = conn.getresponse()
            data = response.read(limit + 1)
            if len(data) > limit:
                raise RuntimeError("Docker response exceeds fixture limit")
            return response.status, data
        finally:
            conn.close()

    def image(ref):
        status, data = get("/images/" + quote(ref, safe="") + "/json")
        if status == 404:
            return None
        if status != 200:
            raise RuntimeError(f"inspect {ref} returned HTTP {status}: {data[:200]!r}")
        return json.loads(data)

    def context(path, key, executable=False):
        path.mkdir()
        data = hashlib.shake_256(key.encode()).digest(512 * 1024 + 17)
        (path / "payload").write_bytes(data)
        instructions = ["FROM scratch AS material", "COPY payload /data/payload", "FROM scratch",
                        "COPY --from=material /data/payload /out/payload"]
        if executable:
            # A released, statically linked ARM64 CLI exercises the image's entrypoint.
            (path / "cli").write_bytes(options.probe_binary.read_bytes())
            (path / "cli").chmod(0o755)
            instructions += ["COPY cli /cli", 'ENTRYPOINT ["/cli"]']
        (path / "Dockerfile").write_text("\n".join(instructions) + "\n")
        return hashlib.sha256(data).hexdigest()

    build = ("buildx", "build", "--builder", "default", "--progress", "plain", "--network", "none")

    def export(key, path, digest):
        output = directory / ("output-" + key)
        proc = docker(*build, "--provenance=false", "--output", f"type=local,dest={output}", path)
        actual = hashlib.sha256((output / "out/payload").read_bytes()).hexdigest()
        if actual != digest:
            raise RuntimeError(f"unexpected export for {key}")
        return {"sha256": actual, "cache_reported": "CACHED" in proc.stderr}

    def load(key, tags, path, default_provenance=False):
        metadata = directory / (key + ".json")
        iid = directory / (key + ".iid")
        names = [item for ref in tags for item in ("--tag", ref)]
        command = ("build", "--progress", "plain", "--network", "none") if default_provenance else (*build, "--provenance=false", "--load")
        proc = docker(*command, "--iidfile", iid, "--metadata-file", metadata,
                      "--label", f"{label}={nonce}", *names, path)
        info = json.loads(metadata.read_text())
        digests = {}
        for kind in ("config", "manifest"):
            matches = set(re.findall(r"exporting " + kind + r" (sha256:[0-9a-f]{64})\b", proc.stderr))
            if len(matches) != 1:
                raise RuntimeError(f"expected exactly one exported {kind} digest, found {matches}")
            digests[kind] = matches.pop()
        image_id = digests["config"]
        ids.add(image_id)
        iid_value = iid.read_text().strip()
        result.setdefault("loads", {})[key] = {**digests, "tags": tags, "metadata": info, "iidfile": iid_value}
        if default_provenance:
            roots = set(re.findall(r"exporting manifest list (sha256:[0-9a-f]{64})\b", proc.stderr))
            if len(roots) != 1 or info["containerimage.descriptor"]["mediaType"] != "application/vnd.oci.image.index.v1+json":
                raise RuntimeError("stock default provenance did not publish its OCI index")
            root_id = roots.pop()
        else:
            root_id = digests["manifest"]
        if info.get("containerimage.digest") != root_id or info.get("containerimage.config.digest", image_id) != image_id:
            raise RuntimeError("Buildx metadata differs from the exported image")
        resolved = image(iid_value)
        if iid_value != info.get("containerimage.config.digest", root_id) or not resolved or resolved["Id"] != image_id:
            raise RuntimeError("Buildx --iidfile did not resolve immediately to the runnable image")
        for ref in tags:
            record, = json.loads(docker("image", "inspect", ref).stdout)
            if record["Id"] != image_id or record["Config"]["Labels"].get(label) != nonce:
                raise RuntimeError("published tag and built config differ")
        return image_id

    docker("buildx", "version")
    info = docker("buildx", "inspect", "default")
    if not any(line.split() == ["Driver:", "docker"] for line in info.stdout.splitlines()):
        raise RuntimeError("the stock plugin selected a different driver: " + info.stdout)
    root = directory / "source"
    digest = context(root, nonce, executable=True)
    try:
        for key in ("cold", "warm"):
            result["exports"][key] = export(key, root, digest)
        original = load("original", [tag, alias], root)
        docker("run", "--rm", "--pull=never", "--network", "none", "--label", f"{label}={nonce}", tag, "--version")
        iid_value = result["loads"]["original"]["iidfile"]
        docker("image", "tag", iid_value, iid_alias)
        if image(iid_alias)["Id"] != original:
            raise RuntimeError("tagging a stock --iidfile selected a different image")
        result["cli_version"] = docker("run", "--name", name, "--pull=never", "--network", "none",
                                       "--label", f"{label}={nonce}", iid_value, "--version").stdout.strip()
        if "ctr" not in result["cli_version"] or "containerd" not in result["cli_version"]:
            raise RuntimeError("loaded entrypoint did not report the containerd CLI version")
        status, archive = get(f"/containers/{name}/archive?path=/out/payload")
        if status != 200:
            raise RuntimeError(f"archive of built image payload returned HTTP {status}")
        with tarfile.open(fileobj=io.BytesIO(archive)) as contents:
            member, = [item for item in contents if item.isfile()]
            result["loaded_payload_sha256"] = hashlib.sha256(contents.extractfile(member).read()).hexdigest()
        if result["loaded_payload_sha256"] != digest:
            raise RuntimeError("loaded image bytes differ from local export")
        (root / "payload").write_bytes(b"updated " + nonce.encode())
        revised = load("revised", [tag], root)
        if revised == original or image(alias)["Id"] != original or image(tag)["Id"] != revised:
            raise RuntimeError("the rebuilt tag did not move independently of its alias")
        # An untagged build still leaves an image addressable by its immutable config.
        (root / "payload").write_bytes(b"dangling " + nonce.encode())
        dangling = load("untagged", [], root)
        untagged = image(dangling)
        if not untagged or untagged["Config"]["Labels"].get(label) != nonce:
            raise RuntimeError("untagged build did not publish its config")
        (root / "payload").write_bytes(b"attested " + nonce.encode())
        load("default_provenance", [provenance_tag], root, default_provenance=True)
        default_iid = result["loads"]["default_provenance"]["iidfile"]
        version = docker("run", "--rm", "--pull=never", "--network", "none", "--label", f"{label}={nonce}",
                         default_iid, "--version").stdout.strip()
        if version != result["cli_version"]:
            raise RuntimeError("the attested image did not run by its stock --iidfile")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            pending = {}
            for index in range(4):
                key = f"parallel-{index}"
                path = directory / key
                check = context(path, nonce + key)
                pending[key] = pool.submit(export, key, path, check)
            for key, task in pending.items():
                result["exports"][key] = task.result()
        calls = [c for c in result["calls"] if c["argv"][-1].startswith(str(directory / "parallel-"))]
        result["parallel_overlap_ms"] = (min(c["ended_ns"] for c in calls) - max(c["started_ns"] for c in calls)) / 1e6
        if len(calls) != 4 or result["parallel_overlap_ms"] <= 0:
            raise RuntimeError("four stock builds did not overlap")
        result["passed"] = True
    finally:
        cid = docker("ps", "-aq", "--filter", f"label={label}={nonce}", check=False)
        if cid.returncode:
            raise RuntimeError("cannot enumerate owned build containers")
        for owned in cid.stdout.split():
            docker("rm", "-f", owned)
        for ref in fixture_tags:
            row = image(ref)
            if not row:
                continue
            if row["Config"]["Labels"].get(label) != nonce:
                raise RuntimeError("unexpected image under private test tag")
            ids.add(row["Id"])
            docker("image", "rm", ref)
        # Native containerd can retain separate verified config-ID aliases.
        for identity in sorted(ids):
            retained = image(identity)
            if retained:
                if retained["Config"]["Labels"].get(label) != nonce or retained.get("RepoTags"):
                    raise RuntimeError("unexpected retained image ownership or tags")
                docker("image", "rm", "-f", identity)
            if image(identity):
                raise RuntimeError("private image ID survived cleanup")
        if docker("ps", "-aq", "--filter", f"label={label}={nonce}").stdout.strip():
            raise RuntimeError("private build containers survived cleanup")
        if any(image(ref) for ref in fixture_tags):
            raise RuntimeError("a private tag survived cleanup")
        if any(image(load["iidfile"]) for load in result.get("loads", {}).values()):
            raise RuntimeError("a private Buildx image ID survived cleanup")
        result["cleanup_verified"] = True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ("socket", "work-dir", "probe-binary", "plugin-dir", "out"):
        parser.add_argument("--" + option, type=Path, required=True)
    opts = parser.parse_args()
    if not opts.socket.is_socket() or not opts.probe_binary.is_file() or not (opts.plugin_dir / "docker-buildx").is_file():
        parser.error("a live Docker socket, Linux ctr binary, and Buildx plugin directory are required")
    report = {"passed": False, "socket": str(opts.socket)}
    try:
        with tempfile.TemporaryDirectory(prefix="native-buildx-", dir=opts.work_dir) as tmp:
            run(opts, Path(tmp), report)
    except Exception as exc:
        report["passed"] = False
        report["error"] = str(exc)
    finally:
        opts.out.write_text(json.dumps(report, indent=2) + "\n")
    raise SystemExit(0 if report["passed"] else 1)
