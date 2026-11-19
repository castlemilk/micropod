#!/usr/bin/env python3
"""Exercise the actual CLI on a throwaway APFS container, including remount and recovery."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import statistics
import subprocess
import tempfile
import time
import uuid


def run(*args, cwd=None, check=True):
    p = subprocess.run(list(map(str, args)), capture_output=True, cwd=cwd, timeout=240)
    if check and p.returncode:
        raise RuntimeError(f"{args[0]} exited {p.returncode}: {p.stderr.decode(errors='replace')[-2000:]}")
    return p


def plist(*args):
    return plistlib.loads(run(*args).stdout)


def metadata_batch(directory, clients):
    payload = bytes(range(256)) * 16
    digest = hashlib.sha256(payload).digest()

    def work(i):
        root = directory / str(i)
        root.mkdir()
        for j in range(64):
            (root / f"file-{j}").write_bytes(payload)
        for j in range(64):
            path = root / f"file-{j}"
            path.rename(root / f"work-{j}")
            path = root / f"work-{j}"
            if hashlib.sha256(path.read_bytes()).digest() != digest:
                raise ValueError("file content differs")
            path.unlink()
        root.rmdir()

    start = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=clients) as pool:
        list(pool.map(work, range(clients)))
    return round(time.perf_counter() - start, 6)


def qualify(binary, result):
    with tempfile.TemporaryDirectory(prefix="micropod-apfs-") as tmp:
        work = Path(tmp).resolve()
        projects, store, state = (work / x for x in ("projects", "store", "state"))
        projects.mkdir()
        store.mkdir()
        original = projects / "script"
        original.write_bytes(b"#!/bin/sh\nexit 0\n")
        original.chmod(0o751)
        os.setxattr(original, "org.micropod.test", b"checked")
        os.link(original, projects / "hardlink")
        (projects / "dangling").symlink_to("missing")
        (projects / ".git").mkdir()
        (projects / ".git" / "fixture").write_text("retained\n")
        (store / "package").write_text("package bytes\n")
        tag = uuid.uuid4().hex[:12]
        image = work / "qualification.sparseimage"
        run("hdiutil", "create", "-size", "768m", "-type", "SPARSE", "-fs", "APFS", "-volname", "Seed-" + tag, image)
        devices = plist("hdiutil", "attach", "-nobrowse", "-owners", "on", "-plist", image)["system-entities"]
        whole = devices[0]["dev-entry"]
        seed = next(Path(row["mount-point"]) for row in devices if row.get("mount-point", "").endswith("Seed-" + tag))
        try:
            seed_info = plist("diskutil", "info", "-plist", seed)
            container = seed_info["APFSContainerReference"]
            if container == plist("diskutil", "info", "-plist", "/System/Volumes/Data")["APFSContainerReference"]:
                raise RuntimeError("Fixture unexpectedly resolved to the startup container")

            def cli(action, *args, cwd=work, check=True):
                return run(binary, "storage", "dev-volume", action, "--state-dir", state, *args, "--json", cwd=cwd, check=check)

            options = ["--projects", projects, "--pnpm-store", store, "--container", container, "--unencrypted"]
            planned = json.loads(cli("plan", *options).stdout)
            assert len(planned["sources"]) == 2 and not state.exists()
            first = json.loads(cli("create", *options).stdout)
            mount, payload = Path(first["mount"]), Path(first["payload"])
            assert first["mounted"] and first["initialized"]
            assert plist("diskutil", "info", "-plist", mount)["APFSContainerReference"] == container
            assert json.loads(cli("create", *options).stdout)["volumeUUID"] == first["volumeUUID"]
            run("sudo", "test", "-f", mount / ".fseventsd/no_log")
            run("sudo", "test", "-f", mount / ".metadata_never_index")
            assert cli("migrate", cwd=projects, check=False).returncode
            holder = subprocess.Popen(["/bin/sleep", "120"], cwd=projects)
            try:
                blocked = cli("migrate", check=False)
                if not blocked.returncode or str(holder.pid) not in blocked.stderr.decode():
                    raise RuntimeError(f"open-writer detection failed: {blocked.stderr!r}")
            finally:
                holder.terminate()
                holder.wait()
            moved = json.loads(cli("migrate").stdout)
            assert all(t["linked"] for t in moved["trees"]) and projects.is_symlink() and store.is_symlink()
            assert json.loads(cli("migrate").stdout)["trees"] == moved["trees"]
            assert os.stat(original).st_ino == os.stat(projects / "hardlink").st_ino
            assert os.stat(original).st_mode & 0o777 == 0o751
            assert os.getxattr(original, "org.micropod.test") == b"checked"
            assert os.readlink(projects / "dangling") == "missing"
            assert (projects / ".git/fixture").read_text() == "retained\n"
            os.link(store / "package", projects / "linked-package")
            assert os.stat(store / "package").st_ino == os.stat(projects / "linked-package").st_ino
            (projects / "edited").write_text("after cutover\n")
            (projects / ".git/fixture").unlink()
            remounted = json.loads(cli("remount").stdout)
            assert remounted["mounted"] and remounted["volumeUUID"] == first["volumeUUID"]
            assert (projects / "edited").read_text() == "after cutover\n"
            assert os.path.ismount(mount) and os.stat(projects).st_dev == os.stat(mount).st_dev
            restored = json.loads(cli("restore").stdout)
            assert not any(t["linked"] for t in restored["trees"]) and not projects.is_symlink()
            assert (projects / "edited").read_text() == "after cutover\n" and not (projects / ".git/fixture").exists()
            assert (Path(moved["trees"][0]["backup"]) / ".git/fixture").is_file()
            cli("restore")
            cli("migrate")
            cli("restore")
            samples = []
            for block in range(4):
                for i, n in enumerate((1, 4, 8, 16)):
                    roots = [("seed", seed), ("development", payload)]
                    if (block + i) % 2:
                        roots.reverse()
                    for name, root in roots:
                        with tempfile.TemporaryDirectory(dir=root) as testdir:
                            seconds = metadata_batch(Path(testdir), n)
                        samples.append(dict(round=block+1, clients=n, location=name, seconds=seconds))
            result.update(volume_uuid=first["volumeUUID"], checks=["plan", "own-apfs-volume", "idempotent-create",
                          "persistent-log-marker", "spotlight-marker", "working-directory-guard", "live-holder-guard",
                          "atomic-migration", "hardlinks", "xattr", "mode", "dangling-symlink", "git-directory",
                          "pnpm-store-hardlink", "uuid-remount", "restore-latest", "repeat-migration"],
                          spotlight_seed=run("mdutil", "-s", seed, check=False).stdout.decode().strip(),
                          spotlight_development=remounted["spotlight"], physical_host_claim=False,
                          samples=samples)
        finally:
            run("hdiutil", "detach", whole)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--json", required=True, type=Path)
    args = parser.parse_args()
    result = {}
    try:
        qualify(args.binary.resolve(), result)
        result["passed"] = True
    except Exception as exc:
        result.update(passed=False, error=str(exc))
        raise
    finally:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
        print("DEV_VOLUME_RECEIPT " + json.dumps(result, separators=(",", ":")), flush=True)
