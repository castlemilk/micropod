#!/usr/bin/env python3
"""Exercise the actual CLI on a throwaway APFS container, including remount and recovery."""

import argparse
import concurrent.futures
import hashlib
import json
import os
import errno
import pty
import re
import select
import signal
import shutil
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import uuid

from bench_pnpm_storage import APFSAllocation
from bench_package_caches import COMPILER, Fixture, command as package_command, stores


def run(*args, cwd=None, check=True):
    p = subprocess.run(list(map(str, args)), capture_output=True, cwd=cwd, timeout=240)
    if check and p.returncode:
        raise RuntimeError(f"{args[0]} exited {p.returncode}: {p.stderr.decode(errors='replace')[-2000:]}")
    return p


def plist(*args):
    return plistlib.loads(run(*args).stdout)


def interact(argv, secret):
    """Answer diskutil's prompts on a disposable volume without logging the secret."""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(str(argv[0]), list(map(str, argv)))
    transcript, pending = bytearray(), bytearray()
    prompts = 0
    end = time.monotonic() + 75
    try:
        while time.monotonic() < end:
            if not select.select([fd], [], [], min(2, max(0, end - time.monotonic())))[0]:
                continue
            try:
                data = os.read(fd, 8192)
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise
                break
            if not data:
                break
            transcript.extend(data)
            pending.extend(data.lower())
            if re.search(rb"(?:passphrase|password|repeat|verify|confirm)[^:\r\n]{0,100}: *$", pending):
                prompts += 1
                if prompts > 3:
                    raise RuntimeError("Unexpected number of APFS passphrase prompts")
                os.write(fd, secret + b"\n")
                pending.clear()
        else:
            detail = bytes(transcript).replace(secret, b"<redacted>").decode(errors="replace")
            raise RuntimeError(f"APFS prompt timed out after {prompts} replies: {detail[-1000:]}")
    finally:
        os.close(fd)
        if time.monotonic() >= end or prompts > 3:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        _, status = os.waitpid(pid, 0)
    if os.waitstatus_to_exitcode(status) != 0 or prompts < 1:
        report = bytes(transcript).replace(secret, b"<redacted>").decode(errors="replace")
        raise RuntimeError("Interactive APFS operation failed: " + report[-1600:])


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


def other_project(fixture, cache):
    # A different package, lockfile root, Go module and binary share only the dependency inputs.
    w = fixture.workspace("unrelated-project")
    for filename in ("package.json", "package-lock.json"):
        p = w / filename
        p.write_text(p.read_text().replace("micropod-cache-client", "second-service"))
    p = w / "go.mod"
    p.write_text(p.read_text().replace("example.test/client", "example.test/another-service"))
    p = w / "main.go"
    p.write_text(p.read_text().replace("shared.Message)", 'shared.Message + "-second")'))
    before = [p.stat().st_ino for p in fixture.payloads(cache)]
    env = fixture.environment(cache)
    fixture.batch(cache, "npm", [w])
    built, _ = package_command(fixture.argv("go"), w, env)
    commands = [line for line in built.stderr.splitlines() if COMPILER.match(line)]
    if len(commands) != 1 or not re.search(r" -p main(?: |$)", commands[0]):
        raise ValueError("The second project should compile only its own main package")
    app, _ = package_command([str(w / "app")], w, env)
    if app.stdout.strip() != "micropod-cache-ok-second" or before != [p.stat().st_ino for p in fixture.payloads(cache)]:
        raise ValueError("The second project returned stale code or replaced a shared dependency")
    return {"offline": True, "compiled_packages": ["main"], "same_dependency_inodes": True}


def qualify(binary, result, metadata_rounds=4):
    with tempfile.TemporaryDirectory(prefix="micropod-apfs-") as tmp:
        work = Path(tmp).resolve()
        projects, store, state = (work / x for x in ("projects", "store", "state"))
        projects.mkdir()
        store.mkdir()
        original = projects / "script"
        original.write_bytes(b"#!/bin/sh\nexit 0\n")
        original.chmod(0o751)
        run("/usr/bin/xattr", "-w", "org.micropod.test", "checked", original)
        os.link(original, projects / "hardlink")
        (projects / "dangling").symlink_to("missing")
        (projects / ".git").mkdir()
        (projects / ".git" / "fixture").write_text("retained\n")
        (store / "package").write_text("package bytes\n")
        os.link(store / "package", projects / "existing-link")
        package = store / "clone-payload"
        payload_bytes = bytes(range(256)) * 1024
        package.write_bytes(payload_bytes)
        imported, untouched, edited = (projects / name for name in ("imported", "untouched", "different"))
        for child in (imported, untouched, edited):
            run("/bin/cp", "-c", package, child)
        imported.chmod(0o640)
        run("/usr/bin/xattr", "-w", "org.micropod.import", "workspace", imported)
        with edited.open("r+b") as f:
            f.write(b"modified")
        expected_edit = edited.read_bytes()
        allocation = APFSAllocation()

        def shared(a, b):
            return not os.path.samefile(a, b) and allocation.read(a)[1] == allocation.read(b)[1]
        assert shared(package, imported)
        tag = uuid.uuid4().hex[:12]
        image = work / "qualification.sparseimage"
        run("hdiutil", "create", "-size", "4g", "-type", "SPARSE", "-fs", "APFS", "-volname", "Seed-" + tag, image)
        devices = plist("hdiutil", "attach", "-nobrowse", "-owners", "on", "-plist", image)["system-entities"]
        whole = devices[0]["dev-entry"]
        seed = next(Path(row["mount-point"]) for row in devices if row.get("mount-point", "").endswith("Seed-" + tag))
        try:
            seed_info = plist("diskutil", "info", "-plist", seed)
            container = seed_info["APFSContainerReference"]
            if container == plist("diskutil", "info", "-plist", "/System/Volumes/Data")["APFSContainerReference"]:
                raise RuntimeError("Fixture unexpectedly resolved to the startup container")

            def cli(action, *args, cwd=work, check=True):
                print("Volume fixture", action, flush=True)
                return run(binary, "storage", "dev-volume", action, "--state-dir", state, *args, "--json", cwd=cwd, check=check)

            options = ["--projects", projects, "--pnpm-store", store, "--container", container]
            planned = json.loads(cli("plan", *options).stdout)
            assert planned["encrypted"] and len(planned["sources"]) == 2 and not state.exists()
            secret = uuid.uuid4().hex.encode()
            command = [binary, "storage", "dev-volume"]
            state_opts = ["--state-dir", state]
            run("sudo", "-n", "true")
            print("Volume fixture encrypted create", flush=True)
            interact([*command, "create", *state_opts, *options], secret)
            first = json.loads(cli("status").stdout)
            mount, payload = Path(first["mount"]), Path(first["payload"])
            assert first["mounted"] and first["initialized"]
            assert plist("diskutil", "info", "-plist", mount)["APFSContainerReference"] == container
            assert json.loads(cli("create", *options).stdout)["volumeUUID"] == first["volumeUUID"]
            assert json.loads(cli("repair").stdout)["initialized"]
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
            # Check a second generation before enrolling the larger package stores.
            cli("restore")
            moved = json.loads(cli("migrate").stdout)
            assert all(t["linked"] for t in moved["trees"])
            assert os.stat(original).st_ino == os.stat(projects / "hardlink").st_ino
            assert os.stat(original).st_mode & 0o777 == 0o751
            assert run("/usr/bin/xattr", "-p", "org.micropod.test", original).stdout.strip() == b"checked"
            assert os.readlink(projects / "dangling") == "missing"
            assert (projects / ".git/fixture").read_text() == "retained\n"
            assert os.path.samefile(store / "package", projects / "existing-link")
            assert shared(package, imported) and shared(package, untouched)
            assert imported.stat().st_mode & 0o777 == 0o640
            assert run("/usr/bin/xattr", "-p", "org.micropod.import", imported).stdout.strip() == b"workspace"
            assert edited.read_bytes() == expected_edit and package.read_bytes() == payload_bytes
            with imported.open("r+b") as f:
                f.write(b"post-cutover")
            assert package.read_bytes() == payload_bytes and untouched.read_bytes() == payload_bytes
            os.link(store / "package", projects / "linked-package")
            assert os.stat(store / "package").st_ino == os.stat(projects / "linked-package").st_ino
            (projects / "edited").write_text("after cutover\n")
            (projects / ".git/fixture").unlink()
            fixture_root = work / "package-fixture"
            fixture_root.mkdir()
            fixture = Fixture(fixture_root)
            package_caches = stores(fixture_root / "stores")
            result["package_seed"] = fixture.prime(package_caches, "before-migration")
            shutil.rmtree(fixture.origin)
            fixture.controls(stores(fixture_root / "empty"))
            cache_options = [value for name, path in package_caches.items() for value in ("--" + name, path)]
            assert cli("add-caches", "--npm-cache", work, check=False).returncode
            nested = projects / "nested-cache"
            nested.mkdir()
            covered = json.loads(cli("add-caches", "--npm-cache", nested).stdout)
            assert len(covered["trees"]) == 2
            added = json.loads(cli("add-caches", *cache_options).stdout)
            assert len(added["trees"]) == 5 and sum(t["linked"] for t in added["trees"]) == 2
            assert json.loads(cli("add-caches", *cache_options).stdout)["trees"] == added["trees"]
            cached = json.loads(cli("migrate").stdout)
            assert all(t["linked"] for t in cached["trees"]) and all(p.is_symlink() for p in package_caches.values())
            assert json.loads(cli("create", *options, *cache_options).stdout)["trees"] == cached["trees"]
            assert json.loads(cli("add-caches", *cache_options).stdout)["trees"] == cached["trees"]
            print("Volume fixture encrypted remount", flush=True)
            interact([*command, "remount", *state_opts], secret)
            remounted = json.loads(cli("status").stdout)
            assert remounted["mounted"] and remounted["volumeUUID"] == first["volumeUUID"]
            assert (projects / "edited").read_text() == "after cutover\n"
            assert os.path.ismount(mount) and os.stat(projects).st_dev == os.stat(mount).st_dev
            def verify_packages(phase):
                fixture.payloads(package_caches)
                for tool in ("npm", "go"):
                    fixture.batch(package_caches, tool, [fixture.workspace(f"{phase}-{tool}-{i}") for i in range(2)])
            verify_packages("remounted")
            restored = json.loads(cli("restore").stdout)
            assert all(p.is_dir() and not p.is_symlink() for p in package_caches.values())
            verify_packages("restored")
            result["different_project"] = other_project(fixture, package_caches)
            assert not any(t["linked"] for t in restored["trees"]) and not projects.is_symlink()
            assert (projects / "edited").read_text() == "after cutover\n" and not (projects / ".git/fixture").exists()
            assert os.path.samefile(store / "package", projects / "existing-link")
            assert os.path.samefile(store / "package", projects / "linked-package")
            assert shared(package, untouched) and imported.read_bytes().startswith(b"post-cutover")
            assert edited.read_bytes() == expected_edit and package.read_bytes() == payload_bytes
            assert (Path(moved["trees"][0]["backup"]) / ".git/fixture").is_file()
            cli("restore")
            print("Volume fixture encrypted lock and unlock", flush=True)
            run("sudo", "/usr/sbin/diskutil", "apfs", "lockVolume", first["volumeUUID"])
            assert not json.loads(cli("status").stdout)["mounted"]
            interact([*command, "mount", *state_opts], secret)
            unlocked = json.loads(cli("status").stdout)
            assert os.path.ismount(mount) and unlocked["volumeUUID"] == first["volumeUUID"] and unlocked["mounted"]
            samples = []
            for block in range(metadata_rounds):
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
                          "pnpm-store-hardlink", "existing-cross-tree-hardlinks", "restore-cross-tree-hardlinks", "preserve-identical-apfs-clones", "clone-specific-metadata", "diverged-clones", "restore-copy-on-write", "repair", "encrypted-create-lock-unlock", "uuid-remount", "restore-latest", "repeat-migration", "enroll-existing-volume", "coalesce-nested-cache", "retry-cache-enrollment", "npm-offline-after-remount-and-restore", "go-offline-after-remount-and-restore", "go-zero-warm-compiles", "changed-project-reuses-dependencies"],
                          spotlight_seed=run("mdutil", "-s", seed, check=False).stdout.decode().strip(),
                          spotlight_development=remounted["spotlight"], physical_host_claim=False,
                          metadata_rounds=metadata_rounds, samples=samples)
        finally:
            run("hdiutil", "detach", whole)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument("--metadata-rounds", type=int, choices=range(0, 21), default=4,
                        help="Optional full filesystem scaling sweep; zero runs only the integration checks")
    args = parser.parse_args()
    result = {}
    try:
        qualify(args.binary.resolve(), result, args.metadata_rounds)
        result["passed"] = True
    except Exception as exc:
        result.update(passed=False, error=str(exc))
        raise
    finally:
        args.json.write_text(json.dumps(result, indent=2) + "\n")
        print("DEV_VOLUME_RECEIPT " + json.dumps(result, separators=(",", ":")), flush=True)
