"""Use the same arm64 Node image and SQLite file on two live guest kernels."""

import hashlib
import json
import re
import shutil
import tarfile

from qualify import HERE, LABEL, cli, peer, require, terminal

IMAGE = "node:24-alpine"
INDEX = "sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5"


def check(folder, workspace, runner, admission, docker, kib):
    local, = json.loads(cli(peer.DOCKER, "image", "inspect", IMAGE))
    require(local["Id"] == INDEX and local["Architecture"] == "arm64" and local["Os"] == "linux",
            "expected the qualified offline arm64 Node reference")
    archive = runner.root / "node.tar"
    cli(peer.DOCKER, "image", "save", "-o", archive, IMAGE, timeout=180)
    with tarfile.open(archive) as tar:
        manifest, = json.load(tar.extractfile("manifest.json"))
        data = tar.extractfile(manifest["Config"]).read()
        config = json.loads(data)
        config_id = "sha256:" + hashlib.sha256(data).hexdigest()
        require(manifest["Config"].split("/")[-1] == config_id.split(":")[1], "Node config hash differs")
        require(manifest["RepoTags"] == [IMAGE] and config["architecture"] == "arm64"
                and config["rootfs"]["diff_ids"] == local["RootFS"]["Layers"], "offline Node layers differ")
    runner.waited([*docker, "load", "-i", archive], "node-load", 240)
    imported, = json.loads(cli(docker, "image", "inspect", IMAGE))
    require(imported["Architecture"] == "arm64" and imported["Os"] == "linux"
            and imported["Id"] == config_id, "imported Node configuration or layers differ")
    script = HERE / "node-pages.mjs"
    shutil.copy2(script, workspace / "probe" / script.name)
    shutil.copy2(script, folder / script.name)
    directory = workspace / "node-page-data"
    directory.mkdir()
    results = {}
    for phase in ("create", "append", "verify"):
        engine = docker if phase == "append" else peer.DOCKER
        name = runner.root.name + "-sqlite-" + phase
        label = "io.micropod.bench.node-pages=" + name
        require(not cli(engine, "ps", "-aq", "--filter", "label=" + label), "Node container name in use")
        admission.names.add(name)
        try:
            cid = cli(engine, "run", "-d", "--pull=never", "--name", name, "--label", f"{LABEL}={runner.root.name}", "--label", label,
                      "--network", "none", "--cpus", "1", "--memory", "256m", "--pids-limit", "64",
                      "--mount", f"type=bind,src={workspace / 'probe'},dst=/mpcheck,readonly",
                      "--mount", f"type=bind,src={directory},dst=/data", "--entrypoint", "/usr/local/bin/node",
                      IMAGE, "--no-warnings", "/mpcheck/node-pages.mjs", phase)
            require(re.fullmatch(r"[0-9a-f]{64}", cid), "invalid Node container identity")
            status = cli(engine, "wait", cid, timeout=60)
            log = terminal.invoke(*engine, "logs", cid)
            require(status == "0", f"{phase} exited {status}: {log.stdout} {log.stderr}")
            record = json.loads(log.stdout)
            require(record["stage"] == phase and record["arch"] == "arm64" and record["pageBytes"]
                    == (kib if phase == "append" else 4) * 1024, "runtime used a different granule")
            results[phase] = {**record, "id": cid, "db_sha256": terminal.digest(directory / "jobs.sqlite")}
        finally:
            ids = cli(engine, "ps", "-aq", "--no-trunc", "--filter", "label=" + label).splitlines()
            for cid in ids:
                row, = json.loads(cli(engine, "inspect", cid))
                require(row["Config"]["Labels"].get(LABEL) == runner.root.name and row["Name"].lstrip("/") == name,
                        "another container owns this name")
                cli(engine, "rm", "-f", cid)
            require(not cli(engine, "ps", "-aq", "--filter", "label=" + label), "Node container remains")
    verify(results, kib)
    terminal.save(folder / "node-sqlite-pages.json",
                  {"image": IMAGE, "image_id": INDEX, "config_id": config_id, "layers": local["RootFS"]["Layers"],
                   "archive_sha256": terminal.digest(archive), "source_sha256": terminal.digest(script), "stages": results})


def verify(results, kib):
    create, append, final = [results[k] for k in ("create", "append", "verify")]
    require([row["pageBytes"] for row in (create, append, final)] == [4096, kib * 1024, 4096]
            and [row["rows"] for row in (create, append, final)] == [8192, 10240, 10240]
            and all(row["sqlPageBytes"] == 4096 and row["journal"] == "wal" and row["mmap"] == 16777216
                    for row in results.values())
            and all(row["node"] == create["node"] and row["sqlite"] == create["sqlite"] for row in results.values())
            and create["after"] == append["before"] and append["after"] == final["before"] == final["after"]
            and create["walFrames"] > 0 and append["walFrames"] > 0 and final["walFrames"] is None
            and create["boot"] == final["boot"] != append["boot"]
            and append["db_sha256"] == final["db_sha256"] != create["db_sha256"],
            "cross-kernel SQLite file, WAL transactions or row digests differ")
